import OSLog
import Foundation
import AVFoundation
import SwiftData
import UIKit
import UniformTypeIdentifiers
import PhotosUI
import SwiftUI
import CoreTransferable

/// Copies video files into the app container, extracts metadata + a thumbnail,
/// and records `LocalVideo` rows. Work happens off the main actor.
nonisolated final class LocalImporter: Sendable {

    enum Phase: Sendable, Equatable {
        case idle
        case importing(done: Int, total: Int, name: String)
    }

    struct Summary: Sendable {
        let imported: Int
        let skipped: Int
    }

    nonisolated static var videoTypes: [UTType] {
        let extra = ["org.matroska.mkv", "public.avi", "com.microsoft.windows-media-wmv", "org.webmproject.webm", "com.adobe.flash.video"].compactMap(UTType.init)
        return Array(Set([UTType.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2TransportStream, .mpeg] + extra))
    }

    nonisolated static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "mts", "webm", "flv", "wmv", "mpg", "mpeg", "3gp", "ogv", "vob"]

    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    // MARK: Files app

    /// Import security-scoped URLs from a document picker. Folders are walked recursively.
    func importFiles(_ urls: [URL], into folderID: UUID?, progress: @escaping @MainActor @Sendable (Phase) -> Void) async -> Summary {
        var files: [URL] = []
        var folderName: String?
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                folderName = folderName ?? url.lastPathComponent
                files += Self.videoFiles(in: url)
            } else if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        guard !files.isEmpty else { return Summary(imported: 0, skipped: urls.count) }

        var targetFolder = folderID
        if targetFolder == nil, let folderName, urls.count == 1 {
            targetFolder = await MainActor.run { AppEnvironment.shared.library.createFolder(named: folderName).id }
        }

        var imported = 0, skipped = 0
        for (i, file) in files.enumerated() {
            await progress(.importing(done: i, total: files.count, name: file.lastPathComponent))
            let accessed = file.startAccessingSecurityScopedResource()
            defer { if accessed { file.stopAccessingSecurityScopedResource() } }
            if await importOne(source: file, title: file.deletingPathExtension().lastPathComponent, folderID: targetFolder) { imported += 1 } else { skipped += 1 }
        }
        await progress(.idle)
        await MainActor.run { AppEnvironment.shared.library.bump() }
        return Summary(imported: imported, skipped: skipped)
    }

    // MARK: Photos

    /// Photos picker: the caller loads each item to a temp URL on the main actor
    /// (`PhotosPickerItem` is not Sendable) and passes the URLs here.
    func importMovieFiles(_ movies: [(url: URL, title: String)], into folderID: UUID?, progress: @escaping @MainActor @Sendable (Phase) -> Void) async -> Summary {
        var imported = 0, skipped = 0
        for (i, movie) in movies.enumerated() {
            await progress(.importing(done: i, total: movies.count, name: movie.title))
            let title = movie.title.nilIfEmpty ?? String(localized: "Video \(i + 1)")
            if await importOne(source: movie.url, title: title, folderID: folderID, move: true) { imported += 1 } else { skipped += 1 }
        }
        await progress(.idle)
        await MainActor.run { AppEnvironment.shared.library.bump() }
        return Summary(imported: imported, skipped: skipped)
    }

    // MARK: Core

    private func importOne(source: URL, title: String, folderID: UUID?, move: Bool = false) async -> Bool {
        let ext = source.pathExtension.lowercased().nilIfEmpty ?? "mp4"
        let id = UUID()
        let relative = "\(id.uuidString).\(ext)"
        let dest = AppPaths.videos.appending(path: relative)
        do {
            if move { try FileManager.default.moveItem(at: source, to: dest) }
            else { try FileManager.default.copyItem(at: source, to: dest) }
        } catch {
            Log.media.error("Copy failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            return false
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let asset = AVURLAsset(url: dest)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var width = 0, height = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let sz = natural.applying(transform)
            width = Int(abs(sz.width)); height = Int(abs(sz.height))
        }
        let thumbRelative = await VideoThumbnailer.generate(for: dest, id: id, duration: duration)

        let context = ModelContext(container)
        let video = LocalVideo(id: id, title: title, relativePath: relative, fileSize: size, duration: duration.isFinite ? duration : 0, width: width, height: height)
        video.thumbnailRelativePath = thumbRelative
        if let folderID, let folder = try? context.fetch(FetchDescriptor<VideoFolder>(predicate: #Predicate { $0.id == folderID })).first {
            video.folder = folder
        }
        context.insert(video)
        do { try context.save() } catch {
            Log.media.error("Save failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: dest)
            return false
        }
        return true
    }

    nonisolated private static func videoFiles(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where videoExtensions.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Moves a picked movie to a temp file we own.
struct TransferableMovie: Transferable {
    let url: URL
    /// Original filename from Photos (e.g. "IMG_2041.MOV"), used as the title.
    let originalName: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (received.file.pathExtension.nilIfEmpty ?? "mov"))
            try FileManager.default.copyItem(at: received.file, to: dest)
            return TransferableMovie(url: dest, originalName: received.file.deletingPathExtension().lastPathComponent)
        }
    }
}

enum VideoThumbnailer {
    /// Returns the relative path of the written JPEG, or nil.
    nonisolated static func generate(for url: URL, id: UUID, duration: TimeInterval) async -> String? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 800, height: 800)
        let t = duration.isFinite && duration > 0 ? min(duration * 0.15, 30) : 1
        do {
            let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let img = UIImage(cgImage: cg)
            guard let data = img.jpegData(compressionQuality: 0.8) else { return nil }
            let rel = "\(id.uuidString).jpg"
            try data.write(to: AppPaths.thumbnails.appending(path: rel), options: .atomic)
            return rel
        } catch {
            // MKV/AVI → AVFoundation can't decode; VLC thumbnailer is a later enhancement.
            return nil
        }
    }
}
