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
    ///
    /// Security scope is held on the *picked* URLs for the whole import. Starting and
    /// stopping per file (or per loop iteration via `defer`) drops the grant before the
    /// copy runs; the second `start` then returns false and every copy fails with
    /// "permission denied" — which looked like an endless spinner with nothing added.
    func importFiles(_ urls: [URL], into folderID: UUID?, progress: @escaping @MainActor @Sendable (Phase) -> Void) async -> Summary {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        var files: [URL] = []
        var folderName: String?
        for url in urls {
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

        // Stage 1 — copy everything into the container first (fast, I/O-bound). Metadata
        // and thumbnails come after, so the user sees files land instead of a spinner
        // that waits on AVFoundation for each one.
        var staged: [(dest: URL, id: UUID, relative: String, title: String)] = []
        var skipped = 0
        for (i, file) in files.enumerated() {
            await progress(.importing(done: i, total: files.count, name: file.lastPathComponent))
            // iCloud Drive: the picker may hand us a placeholder that isn't on disk yet.
            await Self.ensureDownloaded(file)
            let ext = file.pathExtension.lowercased().nilIfEmpty ?? "mp4"
            let id = UUID()
            let relative = "\(id.uuidString).\(ext)"
            let dest = AppPaths.videos.appending(path: relative)
            do {
                try Self.copyCoordinated(from: file, to: dest)
                staged.append((dest, id, relative, file.deletingPathExtension().lastPathComponent))
            } catch {
                Log.media.error("Copy failed for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                skipped += 1
            }
        }

        // Stage 2 — metadata + thumbnail + row, three at a time. Index-driven so the
        // only things each child task captures are immutable values.
        var imported = 0
        let jobs = staged
        await withTaskGroup(of: Bool.self) { group in
            var next = 0
            var done = 0
            while next < min(3, jobs.count) {
                let j = jobs[next]; next += 1
                group.addTask { await self.record(dest: j.dest, id: j.id, relative: j.relative, title: j.title, folderID: targetFolder) }
            }
            for await ok in group {
                done += 1
                if ok { imported += 1 } else { skipped += 1 }
                await progress(.importing(done: files.count - jobs.count + done, total: files.count, name: String(localized: "Preparing…")))
                if next < jobs.count {
                    let j = jobs[next]; next += 1
                    group.addTask { await self.record(dest: j.dest, id: j.id, relative: j.relative, title: j.title, folderID: targetFolder) }
                }
            }
        }
        await progress(.idle)
        await MainActor.run { AppEnvironment.shared.library.bump() }
        return Summary(imported: imported, skipped: skipped)
    }

    /// Ask iCloud to materialize a placeholder and wait (bounded) for it to land.
    private static func ensureDownloaded(_ url: URL) async {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus, status != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<600 {   // up to 60 s
            try? await Task.sleep(for: .milliseconds(100))
            if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               v.ubiquitousItemDownloadingStatus == .current { return }
        }
    }

    /// Copy through NSFileCoordinator so providers (iCloud, third-party File Provider
    /// extensions) hand us a readable, fully-materialized file.
    private static func copyCoordinated(from source: URL, to dest: URL) throws {
        var coordErr: NSError?
        var copyErr: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordErr) { readable in
            do { try FileManager.default.copyItem(at: readable, to: dest) } catch { copyErr = error }
        }
        if let e = coordErr { throw e }
        if let e = copyErr { throw e }
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
        return await record(dest: dest, id: id, relative: relative, title: title, folderID: folderID)
    }

    /// Metadata + thumbnail + SwiftData row for a file already inside the container.
    private func record(dest: URL, id: UUID, relative: String, title: String, folderID: UUID?) async -> Bool {
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
        let t = duration.isFinite && duration > 0 ? min(duration * 0.15, 30) : 1
        do {
            // A bad file can make AVFoundation sit forever. 8 s is plenty for a keyframe.
            // The generator is built inside the child task so nothing non-Sendable
            // crosses the task boundary — only the URL and the time do.
            let cg = try await withThrowingTaskGroup(of: CGImage.self) { group in
                group.addTask {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 800, height: 800)
                    gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
                    gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
                    return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                }
                group.addTask { try await Task.sleep(for: .seconds(8)); throw CancellationError() }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
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
