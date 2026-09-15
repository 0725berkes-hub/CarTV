import OSLog
import Foundation
import SwiftData
import Observation

/// Probes stream URLs for reachability with bounded concurrency and writes the
/// result back to `Channel.health`. Results are cached for `ttl`.
@Observable
final class SourceHealthService {
    private let container: ModelContainer
    private let session: URLSession
    private let ttl: TimeInterval = 6 * 3600
    private let maxConcurrent = 6

    /// Playlist IDs currently being checked.
    private(set) var checking: Set<UUID> = []
    private(set) var progressText: String?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(container: ModelContainer) {
        self.container = container
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.httpAdditionalHeaders = ["User-Agent": PlaylistImporter.userAgent]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    func isChecking(_ playlist: Playlist) -> Bool { checking.contains(playlist.id) }

    /// Check all channels in a playlist whose result is missing or stale.
    func check(_ playlist: Playlist, force: Bool = false) {
        let pid = playlist.id
        guard tasks[pid] == nil else { return }
        checking.insert(pid)
        tasks[pid] = Task { [weak self] in
            guard let self else { return }
            await self.run(playlistID: pid, force: force)
            await MainActor.run {
                self.checking.remove(pid)
                self.tasks[pid] = nil
                self.progressText = nil
                AppEnvironment.shared.library.bump()
            }
        }
    }

    func cancel(_ playlist: Playlist) {
        tasks[playlist.id]?.cancel()
    }

    /// Single-channel probe used by the player to give a fast "unreachable" verdict.
    nonisolated func probe(_ url: URL, headers: [String: String]) async -> SourceHealth {
        guard url.isHTTP else { return .unknown } // rtsp/rtmp/file → let the player decide
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (_, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            switch http.statusCode {
            case 200..<400: return .healthy
            case 401, 403:  return .healthy   // auth-protected but alive; the player will surface auth errors
            default:        return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    // MARK: Internals

    private func run(playlistID: UUID, force: Bool) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let channels = try? context.fetch(FetchDescriptor<Channel>(predicate: #Predicate { $0.playlistID == playlistID })) else { return }

        let cutoff = Date.now.addingTimeInterval(-ttl)
        let targets = channels.filter { force || $0.lastCheckedAt == nil || $0.lastCheckedAt! < cutoff }
        guard !targets.isEmpty else { return }

        // Collapse duplicates by host+path so we don't hammer one server.
        var byID: [UUID: (URL, [String: String])] = [:]
        for c in targets { byID[c.id] = (c.streamURL, c.headers) }
        let total = targets.count
        var done = 0

        await withTaskGroup(of: (UUID, SourceHealth).self) { group in
            var iterator = byID.makeIterator()
            var inFlight = 0
            func enqueue() {
                guard let (id, pair) = iterator.next() else { return }
                inFlight += 1
                group.addTask { [self] in (id, await self.probe(pair.0, headers: pair.1)) }
            }
            for _ in 0..<maxConcurrent { enqueue() }
            for await (id, health) in group {
                inFlight -= 1
                done += 1
                if let c = targets.first(where: { $0.id == id }) {
                    c.health = health
                    c.lastCheckedAt = .now
                }
                if done % 25 == 0 {
                    try? context.save()
                    let text = String(localized: "Checked \(done)/\(total)")
                    await MainActor.run { self.progressText = text }
                }
                if Task.isCancelled { group.cancelAll(); break }
                enqueue()
            }
        }
        try? context.save()
    }
}
