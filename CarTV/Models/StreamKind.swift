import Foundation

/// Coarse classification of a stream URL, used to pick the playback engine
/// and to decide whether seeking makes sense.
nonisolated enum StreamKind: Sendable, Equatable {
    case hls            // .m3u8 — AVPlayer first
    case mp4            // mp4/mov/m4v — AVPlayer first
    case mpegTS         // .ts or typical IPTV path → VLC
    case mkv            // VLC only
    case rtsp, rtmp     // VLC only
    case localFile      // pick by extension
    case unknown        // try AVPlayer, fall back to VLC

    static func detect(from url: URL) -> StreamKind {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "rtsp" || scheme == "rtsps" { return .rtsp }
        if scheme.hasPrefix("rtmp") { return .rtmp }
        if url.isFileURL { return .localFile }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m3u8", "m3u":                 return .hls
        case "mp4", "m4v", "mov":           return .mp4
        case "ts", "mts", "m2ts", "mpeg", "mpg": return .mpegTS
        case "mkv", "webm", "avi", "flv", "wmv": return .mkv
        default: break
        }

        // The MyTV+ relay serves HLS at /live/<id> with no extension.
        // Xtream-style paths: /live/<user>/<pass>/<id>.ts  or  /movie/… /series/…
        let path = url.path.lowercased()
        if path.contains("/live/") && ext.isEmpty { return .mpegTS }
        if url.query?.contains("m3u8") == true { return .hls }
        return .unknown
    }

    /// True when the content is probably a live broadcast rather than VOD.
    var isLikelyLive: Bool {
        switch self {
        case .mpegTS, .rtsp, .rtmp: true
        case .hls, .unknown:        true   // most IPTV HLS is live; player reads duration to confirm
        case .mp4, .mkv, .localFile: false
        }
    }

    /// Whether AVPlayer has a realistic chance of playing this.
    var prefersAVPlayer: Bool {
        switch self {
        case .hls, .mp4, .unknown: true
        case .localFile: true
        case .mpegTS, .mkv, .rtsp, .rtmp: false
        }
    }
}
