import AVFoundation
import Foundation
import Observation
import OSLog

/// Downloads YouTube videos into the local library.
///
/// Source order: our own resolved streams (embedded player + challenge solver —
/// full quality, no third party) → optional RapidAPI "youtube-media-downloader"
/// when a key is set in Settings. Adaptive video+audio pairs are fetched
/// separately and muxed into one MP4 with AVFoundation, so 720p/1080p work.
@Observable
@MainActor
final class YTDownloadManager {
    struct Job: Identifiable, Sendable {
        let id: String                 // videoID
        let title: String
        let thumbnailURL: URL?
        var progress: Double = 0       // 0…1 across download + mux
        var phase: Phase = .queued
        enum Phase: Sendable, Equatable { case queued, downloading, muxing, importing, done, failed(String) }
        var isActive: Bool { switch phase { case .queued, .downloading, .muxing, .importing: true; default: false } }
    }

    private(set) var jobs: [Job] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    func job(for videoID: String) -> Job? { jobs.first { $0.id == videoID } }
    var active: [Job] { jobs.filter(\.isActive) }

    /// Preferred height cap for downloads (nil = best available).
    var maxHeight: Int? = 1080

    // MARK: Public

    func download(_ video: YTVideo, into folderID: UUID?) {
        if let existing = job(for: video.id), existing.isActive { return }
        jobs.removeAll { $0.id == video.id }
        jobs.insert(Job(id: video.id, title: video.title, thumbnailURL: video.thumbnailURL), at: 0)
        let title = video.title.nilIfEmpty ?? video.id
        tasks[video.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.fetchFile(videoID: video.id, title: title)
                self.update(video.id) { $0.phase = .importing; $0.progress = 0.97 }
                let importer = LocalImporter(container: AppEnvironment.shared.modelContainer)
                let summary = await importer.importMovieFiles([(url: file, title: title)], into: folderID) { _ in }
                guard summary.imported > 0 else { throw YTError.unavailable(String(localized: "Could not add the file to your library")) }
                self.update(video.id) { $0.phase = .done; $0.progress = 1 }
                Log.media.info("YT download done: \(title, privacy: .public)")
            } catch is CancellationError {
                self.jobs.removeAll { $0.id == video.id }
            } catch {
                Log.media.error("YT download failed \(video.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.update(video.id) { $0.phase = .failed(error.localizedDescription) }
            }
            self.tasks[video.id] = nil
        }
    }

    func cancel(_ videoID: String) {
        tasks[videoID]?.cancel()
        tasks[videoID] = nil
        jobs.removeAll { $0.id == videoID }
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    // MARK: Pipeline

    private func update(_ id: String, _ f: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        f(&jobs[i])
    }

    private func fetchFile(videoID: String, title: String) async throws -> URL {
        update(videoID) { $0.phase = .downloading }
        let env = AppEnvironment.shared
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ytdl-\(videoID)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 1. Our own stream resolution.
        do {
            let resp = try await InnerTubeClient.shared.player(videoID: videoID, accessToken: await env.youtube.auth.token())
            if let out = try await downloadFromFormats(resp, into: tmp, videoID: videoID) { return out }
        } catch {
            Log.media.notice("YT download: own streams unavailable (\(error.localizedDescription, privacy: .public))")
        }

        // 2. RapidAPI fallback, if configured.
        if let key = env.settings.rapidAPIKey?.nilIfEmpty {
            let (url, ext) = try await rapidAPIDownloadURL(videoID: videoID, key: key)
            let dest = tmp.appending(path: "video.\(ext)")
            try await download(url, to: dest, videoID: videoID, weight: 0.95, offset: 0)
            return dest
        }
        throw YTError.unavailable(String(localized: "No downloadable stream for this video"))
    }

    /// Progressive MP4 if it's good enough; otherwise best AVC video + AAC audio, muxed.
    private func downloadFromFormats(_ resp: YTPlayerResponse, into tmp: URL, videoID: String) async throws -> URL? {
        let cap = maxHeight ?? .max
        let videos = resp.avVideoFormats.filter { ($0.height ?? 0) <= cap }
        let best = videos.last
        let progressive = resp.progressiveFormats.first { ($0.height ?? 0) <= cap }

        // A progressive file saves the mux step when it isn't much worse than the best adaptive one.
        if let p = progressive, best == nil || (p.height ?? 0) >= (best?.height ?? 0) {
            let dest = tmp.appending(path: "video.mp4")
            try await download(p.url, to: dest, videoID: videoID, weight: 0.95, offset: 0, expectedLength: p.contentLength)
            return dest
        }
        guard let v = best, let a = resp.bestDefaultAudio else { return nil }
        let vFile = tmp.appending(path: "v.mp4"), aFile = tmp.appending(path: "a.m4a")
        let total = Double((v.contentLength ?? 0) + (a.contentLength ?? 0))
        let vShare = total > 0 ? Double(v.contentLength ?? 0) / total * 0.85 : 0.6
        try await download(v.url, to: vFile, videoID: videoID, weight: vShare, offset: 0, expectedLength: v.contentLength)
        try await download(a.url, to: aFile, videoID: videoID, weight: 0.85 - vShare, offset: vShare, expectedLength: a.contentLength)
        update(videoID) { $0.phase = .muxing; $0.progress = 0.86 }
        let out = tmp.appending(path: "video.mp4")
        try await Self.mux(video: vFile, audio: aFile, to: out)
        try? FileManager.default.removeItem(at: vFile); try? FileManager.default.removeItem(at: aFile)
        return out
    }

    /// Streams a URL to disk in chunks (Google caps single requests, and chunking
    /// gives real progress). Range requests: 10 MB pieces.
    private func download(_ url: URL, to dest: URL, videoID: String, weight: Double, offset: Double, expectedLength: Int64? = nil) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var total = expectedLength ?? 0
        if total == 0 {
            var head = URLRequest(url: url); head.httpMethod = "HEAD"
            if let (_, r) = try? await session.data(for: head), let h = r as? HTTPURLResponse { total = h.expectedContentLength }
        }
        let chunk: Int64 = 10 * 1024 * 1024
        var pos: Int64 = 0
        while total <= 0 || pos < total {
            try Task.checkCancellation()
            var req = URLRequest(url: url)
            let end = total > 0 ? min(pos + chunk - 1, total - 1) : pos + chunk - 1
            req.setValue("bytes=\(pos)-\(end)", forHTTPHeaderField: "Range")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw YTError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) while downloading")
            }
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            pos += Int64(data.count)
            if total <= 0, http.statusCode == 200 { break }   // server ignored Range → whole file arrived
            let frac = total > 0 ? Double(pos) / Double(total) : 0.5
            update(videoID) { $0.progress = min(0.85, offset + weight * frac) }
            if http.statusCode == 200 && total > 0 && pos >= total { break }
        }
    }

    nonisolated private static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video), aAsset = AVURLAsset(url: audio)
        guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
              let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw YTError.unavailable("Cannot read downloaded streams")
        }
        let vDur = try await vAsset.load(.duration), aDur = try await aAsset.load(.duration)
        let dur = CMTimeMinimum(vDur, aDur)
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aTrack, at: .zero)
        cv.preferredTransform = try await vTrack.load(.preferredTransform)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw YTError.unavailable("Cannot create export session")
        }
        try? FileManager.default.removeItem(at: out)
        try await export.export(to: out, as: .mp4)
    }

    // MARK: RapidAPI fallback

    private func rapidAPIDownloadURL(videoID: String, key: String) async throws -> (URL, String) {
        var comps = URLComponents(string: "https://youtube-media-downloader.p.rapidapi.com/v2/video/details")!
        comps.queryItems = [.init(name: "videoId", value: videoID), .init(name: "urlAccess", value: "normal"), .init(name: "videos", value: "true"), .init(name: "audios", value: "false")]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "x-rapidapi-key")
        req.setValue("youtube-media-downloader.p.rapidapi.com", forHTTPHeaderField: "x-rapidapi-host")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YTError.network("RapidAPI HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let json = JSONObject(try JSONSerialization.jsonObject(with: data))
        let cap = maxHeight ?? .max
        // Prefer items that carry audio and fit the cap, tallest first.
        let items = json["videos"]["items"].array
        let candidates = items.filter { ($0["hasAudio"].bool ?? true) && ($0["height"].int ?? 0) <= cap && $0["url"].string != nil }
            .sorted { ($0["height"].int ?? 0) > ($1["height"].int ?? 0) }
        guard let pick = candidates.first, let u = pick["url"].string, let url = URL(string: u) else {
            throw YTError.unavailable(String(localized: "RapidAPI returned no downloadable file"))
        }
        return (url, pick["extension"].string ?? "mp4")
    }
}
