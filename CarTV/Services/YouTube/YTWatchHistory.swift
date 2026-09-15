import Foundation
import OSLog

/// Reports playback to YouTube the way its own clients do, so videos watched in
/// CarTV show up in the account's History and "Continue watching", and resume
/// positions sync across devices. Two beacons from the player response:
/// `videostatsPlaybackUrl` once at start, `videostatsWatchtimeUrl` periodically.
@MainActor
final class YTWatchHistory {
    private struct Session {
        let videoID: String
        let playback: URL?
        let watchtime: URL?
        let cpn: String
        var startedReported = false
        var lastReportedAt: TimeInterval = 0       // media time of the last watchtime beacon
        var lastWallReport = Date.distantPast
    }
    private var session: Session?
    private let auth: YTAuth
    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    init(auth: YTAuth) { self.auth = auth }

    func begin(videoID: String, playbackURL: URL?, watchtimeURL: URL?) {
        session = Session(videoID: videoID, playback: playbackURL, watchtime: watchtimeURL, cpn: Self.cpn())
    }

    func end() { session = nil }

    /// Called from the progress timer. Sends the start beacon once playback has
    /// actually begun, then a watchtime beacon at most every 10s of wall time.
    func tick(videoID: String, position: TimeInterval, duration: TimeInterval, playing: Bool) {
        guard var s = session, s.videoID == videoID, playing, position > 0.5 else { return }
        if !s.startedReported, let u = s.playback {
            s.startedReported = true
            send(u, extra: ["cpn": s.cpn, "cmt": fmt(position), "len": fmt(duration), "st": "0", "et": fmt(position)])
        }
        if s.startedReported, Date().timeIntervalSince(s.lastWallReport) >= 10, let u = s.watchtime {
            let from = s.lastReportedAt
            send(u, extra: ["cpn": s.cpn, "cmt": fmt(position), "len": fmt(duration), "st": fmt(from), "et": fmt(position), "state": "playing", "final": "0"])
            s.lastReportedAt = position
            s.lastWallReport = .now
        }
        session = s
    }

    /// Flush on pause / stop / next so the resume point is exact.
    func flush(videoID: String, position: TimeInterval, duration: TimeInterval) {
        guard let s = session, s.videoID == videoID, s.startedReported, let u = s.watchtime else { return }
        send(u, extra: ["cpn": s.cpn, "cmt": fmt(position), "len": fmt(duration), "st": fmt(s.lastReportedAt), "et": fmt(position), "state": "paused", "final": "1"])
        session?.lastReportedAt = position
        session?.lastWallReport = .now
    }

    private func send(_ base: URL, extra: [String: String]) {
        Task { [auth, ua] in
            guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
            var items = comps.queryItems ?? []
            items.append(contentsOf: [
                URLQueryItem(name: "ns", value: "yt"), URLQueryItem(name: "el", value: "detailpage"),
                URLQueryItem(name: "ver", value: "2"), URLQueryItem(name: "c", value: "VISIONOS"), URLQueryItem(name: "cver", value: "1.02"),
                URLQueryItem(name: "rt", value: fmt(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000))),
            ])
            for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
            comps.queryItems = items
            guard let url = comps.url else { return }
            var req = URLRequest(url: url)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            if let token = await auth.token() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            do {
                let (_, r) = try await URLSession.shared.data(for: req)
                if let http = r as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Log.network.notice("YT stats \(url.path, privacy: .public) HTTP \(http.statusCode)")
                }
            } catch {
                Log.network.notice("YT stats failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private func fmt(_ t: TimeInterval) -> String { String(format: "%.1f", max(0, t)) }

    /// Client playback nonce: 16 chars from YouTube's alphabet.
    nonisolated private static func cpn() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
