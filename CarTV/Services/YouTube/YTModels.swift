import Foundation
import OSLog

// MARK: - Feed items

nonisolated struct YTVideo: Identifiable, Hashable, Sendable {
    let id: String              // 11-char video ID
    var title: String
    var channelName: String?
    var channelID: String?
    var channelAvatarURL: URL?
    var thumbnailURL: URL?
    var durationSeconds: Int?   // nil for live
    var durationText: String?
    var viewsText: String?
    var publishedText: String?
    var isLive = false
    var progressFraction: Double? = nil   // from history / resume

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

nonisolated struct YTChannel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var handle: String?
    var avatarURL: URL?
    var bannerURL: URL?
    var subscribersText: String?
    var videoCountText: String?
    var description: String?
    var isSubscribed: Bool?
}

nonisolated struct YTPlaylist: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var channelName: String?
    var thumbnailURL: URL?
    var videoCountText: String?
}

nonisolated enum YTItem: Identifiable, Hashable, Sendable {
    case video(YTVideo), channel(YTChannel), playlist(YTPlaylist)
    var id: String {
        switch self { case .video(let v): "v:\(v.id)"; case .channel(let c): "c:\(c.id)"; case .playlist(let p): "p:\(p.id)" }
    }
}

nonisolated struct YTShelf: Identifiable, Sendable {
    let id = UUID()
    var title: String?
    var items: [YTItem]
    /// Per-shelf "load more" token (TV layout paginates each shelf separately).
    var continuation: String?
}

nonisolated struct YTPage: Sendable {
    var shelves: [YTShelf]
    var continuation: String?
    var flatItems: [YTItem] { shelves.flatMap(\.items) }
}

nonisolated struct YTComment: Identifiable, Sendable {
    let id: String
    var author: String
    var avatarURL: URL?
    var text: String
    var likesText: String?
    var publishedText: String?
    var replyCount: Int?
}

// MARK: - Player response

nonisolated struct YTFormat: Sendable, Hashable {
    let itag: Int
    var url: URL
    let mimeType: String          // e.g. video/mp4; codecs="avc1.640028"
    let bitrate: Int
    let width: Int?
    let height: Int?
    let fps: Int?
    let qualityLabel: String?     // "1080p60"
    let audioSampleRate: Int?
    let audioChannels: Int?
    let contentLength: Int64?
    let initRange: ClosedRange<Int64>?
    let indexRange: ClosedRange<Int64>?
    let approxDurationMs: Int64?
    let language: String?
    let isDefaultAudio: Bool

    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isMuxed: Bool { isVideo && mimeType.contains("mp4a") }   // progressive
    var container: String { mimeType.split(separator: ";").first.map { String($0.split(separator: "/").last ?? "") } ?? "" }
    var codecs: String {
        guard let r = mimeType.range(of: "codecs=\"") else { return "" }
        return String(mimeType[r.upperBound...].prefix { $0 != "\"" })
    }
    var isAVC: Bool { codecs.hasPrefix("avc1") }
    var isHEVC: Bool { codecs.hasPrefix("hvc1") || codecs.hasPrefix("hev1") }
    var isAAC: Bool { codecs.hasPrefix("mp4a") }
}

nonisolated struct YTPlayerResponse: Sendable {
    let videoID: String
    let title: String
    let author: String
    let channelID: String
    let lengthSeconds: Int
    let isLive: Bool
    let thumbnailURL: URL?
    let description: String?
    let viewCount: Int?
    let keywords: [String]
    let hlsManifestURL: URL?
    let dashManifestURL: URL?
    var formats: [YTFormat]        // adaptive + progressive
    let isPlayable: Bool
    let playabilityStatus: String?
    let playabilityReason: String?
    let expiresAt: Date
    let captionTracks: [(name: String, lang: String, url: URL)]

    init(json: JSONObject) throws {
        let vd = json["videoDetails"]
        guard let id = vd["videoId"].string else { throw YTError.parse("videoDetails missing") }
        videoID = id
        title = vd["title"].string ?? ""
        author = vd["author"].string ?? ""
        channelID = vd["channelId"].string ?? ""
        lengthSeconds = vd["lengthSeconds"].int ?? 0
        isLive = vd["isLive"].bool ?? vd["isLiveContent"].bool ?? false
        description = vd["shortDescription"].string
        viewCount = vd["viewCount"].int
        keywords = vd["keywords"].array.compactMap(\.string)
        let thumbs = vd["thumbnail"]["thumbnails"].array
        thumbnailURL = thumbs.last?["url"].string.flatMap(URL.init)

        let status = json["playabilityStatus"]
        isPlayable = status["status"].string == "OK"
        playabilityStatus = status["status"].string
        playabilityReason = status["reason"].string ?? status["errorScreen"].find("reason").text

        let sd = json["streamingData"]
        hlsManifestURL = sd["hlsManifestUrl"].string.flatMap(URL.init)
        dashManifestURL = sd["dashManifestUrl"].string.flatMap(URL.init)
        let ttl = sd["expiresInSeconds"].double ?? 21600
        expiresAt = Date().addingTimeInterval(ttl - 60)

        var fmts: [YTFormat] = []
        for f in sd["adaptiveFormats"].array + sd["formats"].array {
            guard let itag = f["itag"].int, let mime = f["mimeType"].string else { continue }
            // Web clients hand out `signatureCipher` instead of a bare URL; the
            // signature is applied later by YTChallengeSolver (see `solved()`).
            var url: URL
            if let urlStr = f["url"].string, let u = URL(string: urlStr) { url = u }
            else if let cipher = f["signatureCipher"].string, let c = YTChallengeSolver.parseCipher(cipher) {
                url = YTChallengeSolver.appending(url: c.url, param: "__cipher_s", value: c.s + "|" + c.sp)
            } else { continue }
            func range(_ k: String) -> ClosedRange<Int64>? {
                guard let s = f[k]["start"].string.flatMap(Int64.init), let e = f[k]["end"].string.flatMap(Int64.init) else { return nil }
                return s...e
            }
            let audioTrack = f["audioTrack"]
            fmts.append(YTFormat(
                itag: itag, url: url, mimeType: mime,
                bitrate: f["bitrate"].int ?? f["averageBitrate"].int ?? 0,
                width: f["width"].int, height: f["height"].int, fps: f["fps"].int,
                qualityLabel: f["qualityLabel"].string,
                audioSampleRate: f["audioSampleRate"].int, audioChannels: f["audioChannels"].int,
                contentLength: f["contentLength"].string.flatMap(Int64.init),
                initRange: range("initRange"), indexRange: range("indexRange"),
                approxDurationMs: f["approxDurationMs"].string.flatMap(Int64.init),
                language: audioTrack["id"].string.map { String($0.split(separator: ".").first ?? "") },
                isDefaultAudio: audioTrack["audioIsDefault"].bool ?? !audioTrack.exists
            ))
        }
        formats = fmts

        captionTracks = json["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array.compactMap { t in
            guard let u = t["baseUrl"].string.flatMap(URL.init), let lang = t["languageCode"].string else { return nil }
            return (t["name"].text ?? lang, lang, u)
        }
    }

    /// Resolves `n` throttling params and `sig` ciphers on every format URL.
    /// Must run before the URLs are handed to a player; without it Google serves
    /// only the first ~1 MB of each stream.
    func solved() async -> YTPlayerResponse {
        var nChallenges: [String] = [], sigChallenges: [String] = []
        var pending: [(idx: Int, n: String?, cipher: (s: String, sp: String)?)] = []
        for (i, f) in formats.enumerated() {
            let n = YTChallengeSolver.nParam(of: f.url)
            var cipher: (String, String)? = nil
            if let q = f.url.absoluteString.firstIndex(of: "?"),
               let pair = f.url.absoluteString[q...].split(separator: "&").first(where: { $0.hasPrefix("__cipher_s=") || $0.hasPrefix("?__cipher_s=") }) {
                let raw = (String(pair.split(separator: "=", maxSplits: 1).last ?? "")).removingPercentEncoding ?? ""
                let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { cipher = (parts[0], parts[1]); sigChallenges.append(parts[0]) }
            }
            if let n { nChallenges.append(n) }
            pending.append((i, n, cipher))
        }
        guard !nChallenges.isEmpty || !sigChallenges.isEmpty else { return self }
        do {
            let r = try await YTChallengeSolver.shared.solve(n: nChallenges, sig: sigChallenges)
            var copy = self
            for p in pending {
                var url = copy.formats[p.idx].url
                if let n = p.n { url = YTChallengeSolver.replacing(url: url, n: n, nSolved: r.n[n]) }
                if let c = p.cipher {
                    url = YTChallengeSolver.removing(url: url, param: "__cipher_s")
                    if let sig = r.sig[c.s] { url = YTChallengeSolver.appending(url: url, param: c.sp, value: sig) }
                }
                copy.formats[p.idx].url = url
            }
            return copy
        } catch {
            Log.network.error("YT challenge solve failed: \(error.localizedDescription, privacy: .public)")
            return self
        }
    }

    // MARK: Selection helpers

    /// Best AVC video-only formats for AVPlayer (HEVC too if available), deduped per height.
    var avVideoFormats: [YTFormat] {
        var byHeight: [Int: YTFormat] = [:]
        for f in formats where f.isVideo && !f.isMuxed && (f.isAVC || f.isHEVC) && f.container == "mp4" {
            guard let h = f.height else { continue }
            if let cur = byHeight[h] { if f.bitrate > cur.bitrate { byHeight[h] = f } } else { byHeight[h] = f }
        }
        return byHeight.values.sorted { ($0.height ?? 0) < ($1.height ?? 0) }
    }
    var avAudioFormats: [YTFormat] {
        formats.filter { $0.isAudio && $0.isAAC && $0.container == "mp4" }.sorted { $0.bitrate > $1.bitrate }
    }
    var bestDefaultAudio: YTFormat? {
        let aac = avAudioFormats
        return aac.first(where: \.isDefaultAudio) ?? aac.first
    }
    var progressiveFormats: [YTFormat] {
        formats.filter { $0.isMuxed && $0.container == "mp4" }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }
}
