import Foundation

/// Movies and series from the MyTV+ catalogue. Plain value types held in memory
/// and cached as JSON on disk (not SwiftData — 12K movies churn daily).

struct VODMovie: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let category: String
    let year: String
    let duration: String        // minutes, as a string from upstream
    let rating: String
    let age: String
    let description: String
    let director: String
    let stars: String
    let poster: URL?
    let backdrop: URL?
    let stream: URL
    let trailer: URL?
    let subtitles: SubtitleLinks

    /// Stable identity for favorites / progress: derived from the upstream id.
    nonisolated var playableID: UUID { UUID.stable("movie:\(id)") }
}

struct VODSeries: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let category: String
    let seasons: Int
    let rating: String
    let age: String
    let poster: URL?
}

struct VODSeason: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let seriesID: String
    let name: String            // "1", "2", …
    let year: String
    let description: String
    let actors: String
    let poster: URL?
}

struct VODEpisode: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let seasonID: String
    let name: String            // "S01E01"
    let stream: URL
    let subtitles: SubtitleLinks

    nonisolated var playableID: UUID { UUID.stable("episode:\(id)") }

    /// "S01E07" → 7
    nonisolated var number: Int {
        if let r = name.range(of: #"E(\d+)"#, options: .regularExpression) {
            return Int(name[r].dropFirst()) ?? 0
        }
        return 0
    }
}

struct SubtitleLinks: Codable, Hashable, Sendable {
    var english: URL?
    var arabic: URL?
    var kurdish: URL?

    nonisolated var isEmpty: Bool { english == nil && arabic == nil && kurdish == nil }

    /// Ordered (code, label, url) for menus.
    nonisolated var tracks: [(code: String, label: String, url: URL)] {
        var t: [(String, String, URL)] = []
        if let english { t.append(("en", "English", english)) }
        if let arabic  { t.append(("ar", "Arabic", arabic)) }
        if let kurdish { t.append(("ckb", "Kurdish", kurdish)) }
        return t
    }

    /// Best track for the user's preferred language, else English, else first.
    nonisolated func preferred(for language: String?) -> URL? {
        switch language {
        case "ar": return arabic ?? english ?? kurdish
        case "ckb", "ku": return kurdish ?? english ?? arabic
        default: return english ?? arabic ?? kurdish
        }
    }
}

extension UUID {
    /// Deterministic UUID (v5-style) from a string, so the same catalogue item
    /// always maps to the same id across launches.
    nonisolated static func stable(_ s: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in s.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(b)) &* 0x9E3779B97F4A7C15
        }
        var bytes = withUnsafeBytes(of: h1.bigEndian, Array.init) + withUnsafeBytes(of: h2.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
