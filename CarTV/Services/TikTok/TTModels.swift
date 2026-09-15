import Foundation

/// One item from the web feed. Shaped for playback: direct MP4, cover, author, sound.
nonisolated struct TTVideo: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let desc: String
    let createTime: Date
    let duration: Int                  // seconds
    let width: Int
    let height: Int
    let playURL: URL                   // MP4; needs Referer + cookies
    let downloadURL: URL?              // watermark-free when present
    let coverURL: URL?
    let dynamicCoverURL: URL?          // animated webp
    let author: TTAuthor
    let music: TTMusic?
    let stats: TTStats
    /// Ordered high → low. Lets the car pick a lighter rendition.
    let bitrates: [TTBitrate]

    var isPortrait: Bool { height > width }
    var playableID: UUID { UUID.stable("tiktok:\(id)") }
    var webURL: URL { URL(string: "https://www.tiktok.com/@\(author.uniqueID)/video/\(id)")! }
}

nonisolated struct TTAuthor: Hashable, Sendable, Codable {
    let id: String
    let uniqueID: String               // @handle
    let nickname: String
    let avatarURL: URL?
    let secUID: String
    let verified: Bool
}

nonisolated struct TTMusic: Hashable, Sendable, Codable {
    let id: String
    let title: String
    let authorName: String
    let coverURL: URL?
    let original: Bool
}

nonisolated struct TTStats: Hashable, Sendable, Codable {
    let plays: Int
    let likes: Int
    let comments: Int
    let shares: Int
}

nonisolated struct TTBitrate: Hashable, Sendable, Codable {
    let gearName: String               // "adapt_540_1", "lower_720_1", …
    let bitrate: Int
    let qualityType: Int
    let url: URL
}

nonisolated struct TTFeedPage: Sendable {
    let items: [TTVideo]
    let hasMore: Bool
}

// MARK: - Parsing (item_list JSON → models)

nonisolated enum TTParser {
    static func video(_ d: [String: Any]) -> TTVideo? {
        guard let id = str(d["id"]),
              let v = d["video"] as? [String: Any],
              let play = url(v["playAddr"]),
              let a = d["author"] as? [String: Any],
              let handle = str(a["uniqueId"]) else { return nil }

        let stats = d["stats"] as? [String: Any] ?? d["statsV2"] as? [String: Any] ?? [:]
        let m = d["music"] as? [String: Any]

        var bitrates: [TTBitrate] = []
        for b in (v["bitrateInfo"] as? [[String: Any]]) ?? [] {
            guard let pa = b["PlayAddr"] as? [String: Any],
                  let list = pa["UrlList"] as? [String], let first = list.first, let u = URL(string: first) else { continue }
            bitrates.append(TTBitrate(gearName: str(b["GearName"]) ?? "", bitrate: int(b["Bitrate"]), qualityType: int(b["QualityType"]), url: u))
        }
        bitrates.sort { $0.bitrate > $1.bitrate }

        return TTVideo(
            id: id,
            desc: str(d["desc"]) ?? "",
            createTime: Date(timeIntervalSince1970: TimeInterval(int(d["createTime"]))),
            duration: int(v["duration"]),
            width: int(v["width"]), height: int(v["height"]),
            playURL: play,
            downloadURL: url(v["downloadAddr"]),
            coverURL: url(v["cover"]) ?? url(v["originCover"]),
            dynamicCoverURL: url(v["dynamicCover"]),
            author: TTAuthor(id: str(a["id"]) ?? "", uniqueID: handle, nickname: str(a["nickname"]) ?? handle,
                             avatarURL: url(a["avatarMedium"]) ?? url(a["avatarThumb"]), secUID: str(a["secUid"]) ?? "",
                             verified: a["verified"] as? Bool ?? false),
            music: m.map { TTMusic(id: str($0["id"]) ?? "", title: str($0["title"]) ?? "", authorName: str($0["authorName"]) ?? "",
                                   coverURL: url($0["coverMedium"]) ?? url($0["coverThumb"]), original: $0["original"] as? Bool ?? false) },
            stats: TTStats(plays: int(stats["playCount"]), likes: int(stats["diggCount"]), comments: int(stats["commentCount"]), shares: int(stats["shareCount"])),
            bitrates: bitrates
        )
    }

    static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    static func int(_ v: Any?) -> Int {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }
    static func url(_ v: Any?) -> URL? {
        guard let s = str(v), s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }
}
