import Foundation
import SwiftData

@Model
final class Channel {
    #Index<Channel>([\.playlistID], [\.genreRaw], [\.normalizedName], [\.playlistID, \.genreRaw])

    @Attribute(.unique) var id: UUID
    var playlistID: UUID
    var name: String
    /// Lower-cased, diacritics-stripped name for fast search.
    var normalizedName: String
    var streamURL: URL
    var logoURL: URL?
    /// Group title as it appeared in the M3U (`group-title`).
    var groupTitle: String?
    var tvgID: String?
    var tvgName: String?
    var language: String?
    var country: String?
    /// Auto-detected genre (see `Genre`).
    var genreRaw: String
    /// Position inside the playlist to preserve original order.
    var orderIndex: Int
    /// Per-channel HTTP headers (from #EXTVLCOPT) — overrides playlist defaults.
    var headersData: Data?
    /// Health snapshot (denormalised so grids don't join).
    var healthRaw: String
    var lastCheckedAt: Date?

    var playlist: Playlist?

    init(
        id: UUID = UUID(),
        playlistID: UUID,
        name: String,
        streamURL: URL,
        logoURL: URL? = nil,
        groupTitle: String? = nil,
        tvgID: String? = nil,
        tvgName: String? = nil,
        language: String? = nil,
        country: String? = nil,
        genre: Genre,
        orderIndex: Int,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.playlistID = playlistID
        self.name = name
        self.normalizedName = name.searchNormalized
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.language = language
        self.country = country
        self.genreRaw = genre.rawValue
        self.orderIndex = orderIndex
        self.headersData = headers.isEmpty ? nil : try? JSONEncoder().encode(headers)
        self.healthRaw = SourceHealth.unknown.rawValue
    }

    var genre: Genre {
        get { Genre(rawValue: genreRaw) ?? .other }
        set { genreRaw = newValue.rawValue }
    }

    var headers: [String: String] {
        guard let headersData else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: headersData)) ?? [:]
    }

    var health: SourceHealth {
        get { SourceHealth(rawValue: healthRaw) ?? .unknown }
        set { healthRaw = newValue.rawValue }
    }

    var isLikelyLive: Bool { StreamKind.detect(from: streamURL).isLikelyLive }
}

enum SourceHealth: String, Codable, Sendable {
    case unknown, checking, healthy, unreachable
}
