import Foundation
import OSLog

/// Account-linked history, owned by the video actually playing rather than by stream resolution.
@MainActor
final class YTWatchHistory {
    private struct Session {
        let videoID: String
        let cpn: String
        let beganAt = Date()
        var playback: URL?
        var watchtime: URL?
        var startedReported = false
        var reporting = false
        var lastReportedAt: TimeInterval = 0
        var lastWallReport = Date.distantPast
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        var playing = false
    }
    private var session: Session?
    private var trackingTask: Task<Void, Never>?
    private let auth: YTAuth
    init(auth: YTAuth) { self.auth = auth }

    func begin(videoID: String) {
        guard session?.videoID != videoID else { return }
        end()
        let cpn = Self.cpn()
        session = Session(videoID: videoID, cpn: cpn)
        trackingTask = Task { [weak self, auth] in
            guard let token = await auth.token(), !Task.isCancelled else { return }
            do {
                let urls = try await InnerTubeClient.shared.historyTracking(videoID: videoID, cpn: cpn, accessToken: token)
                guard let self, !Task.isCancelled, self.session?.cpn == cpn else { return }
                self.session?.playback = urls.0
                self.session?.watchtime = urls.1
                if let latest = self.session {
                    self.tick(videoID: latest.videoID, position: latest.position, duration: latest.duration, playing: latest.playing)
                }
            } catch {
                if !Task.isCancelled { Log.network.notice("YT account history setup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func end() { trackingTask?.cancel(); trackingTask = nil; session = nil }

    func tick(videoID: String, position: TimeInterval, duration: TimeInterval, playing: Bool) {
        guard var s = session, s.videoID == videoID else { return }
        s.position = position; s.duration = duration; s.playing = playing
        session = s
        guard playing, position > 0.5, !s.reporting,
              Date().timeIntervalSince(s.lastWallReport) >= 10,
              let playback = s.playback, let watchtime = s.watchtime else { return }
        session?.reporting = true
        session?.lastWallReport = .now
        Task { [weak self] in
            guard let self else { return }
            do {
                if !s.startedReported {
                    try await self.send(playback, session: s, extra: ["st": "0", "et": self.fmt(position)])
                    if self.session?.cpn == s.cpn { self.session?.startedReported = true }
                }
                try await self.send(watchtime, session: s, extra: ["st": self.fmt(s.lastReportedAt), "et": self.fmt(position), "state": "playing", "final": "0"])
                if self.session?.cpn == s.cpn { self.session?.lastReportedAt = position }
            } catch { Log.network.notice("YT history report failed: \(error.localizedDescription, privacy: .public)") }
            if self.session?.cpn == s.cpn { self.session?.reporting = false }
        }
    }

    /// Snapshot before switching videos; the outgoing report retains its own nonce and URLs.
    func flush(videoID: String, position: TimeInterval, duration: TimeInterval) {
        guard var s = session, s.videoID == videoID else { return }
        s.position = position; s.duration = duration; s.playing = false
        session = s
        guard position > 0.5, let playback = s.playback, let watchtime = s.watchtime else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if !s.startedReported { try await self.send(playback, session: s, extra: ["st": "0", "et": self.fmt(position)]) }
                try await self.send(watchtime, session: s, extra: ["st": self.fmt(s.lastReportedAt), "et": self.fmt(position), "state": "paused", "final": "1"])
            } catch { Log.network.notice("YT final history report failed: \(error.localizedDescription, privacy: .public)") }
        }
        session?.lastReportedAt = position
        session?.lastWallReport = .now
    }

    private func send(_ base: URL, session s: Session, extra: [String: String]) async throws {
        guard let token = await auth.token() else { throw YTError.signInRequired }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw YTError.parse("History URL") }
        var fields = extra
        fields["cpn"] = s.cpn; fields["cmt"] = fmt(s.position); fields["len"] = fmt(s.duration)
        fields["rt"] = fmt(Date().timeIntervalSince(s.beganAt))
        // Keep the authenticated client's tracking identity and remove duplicate query keys.
        var items = (comps.queryItems ?? []).filter { fields[$0.name] == nil }
        for (key, value) in ["ns": "yt", "el": "detailpage", "ver": "2", "c": "TVHTML5", "cver": InnerTubeClient.tvhtml5.version] {
            if !items.contains(where: { $0.name == key }) { items.append(URLQueryItem(name: key, value: value)) }
        }
        items.append(contentsOf: fields.map { URLQueryItem(name: $0.key, value: $0.value) })
        comps.queryItems = items
        guard let url = comps.url else { throw YTError.parse("History URL") }
        var request = URLRequest(url: url)
        request.setValue(InnerTubeClient.tvhtml5.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YTError.network("History HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }

    nonisolated private func fmt(_ t: TimeInterval) -> String { String(format: "%.1f", max(0, t)) }
    nonisolated private static func cpn() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
