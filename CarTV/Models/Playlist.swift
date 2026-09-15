import Foundation
import SwiftData

/// How a playlist was added. Mirrors the original app's source kinds.
enum PlaylistKind: String, Codable, Sendable, CaseIterable {
    case subscription   // remote M3U URL we can refresh
    case pasted         // user pasted M3U text
    case manual         // built by hand / single stream
    case localFolder    // folder of local files (see VideoFolder)
}

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    /// Remote URL for `.subscription`, nil otherwise.
    var sourceURL: URL?
    var createdAt: Date
    var lastRefreshedAt: Date?
    var channelCount: Int
    var sortOrder: Int
    /// Optional HTTP headers (User-Agent, Referer) captured from #EXTVLCOPT / #KODIPROP.
    var defaultHeadersData: Data?
    /// Last refresh failure, shown in the UI.
    var lastError: String?

    @Relationship(deleteRule: .cascade, inverse: \Channel.playlist)
    var channels: [Channel] = []

    init(
        id: UUID = UUID(),
        name: String,
        kind: PlaylistKind,
        sourceURL: URL? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.sourceURL = sourceURL
        self.createdAt = .now
        self.channelCount = 0
        self.sortOrder = sortOrder
    }

    var kind: PlaylistKind {
        get { PlaylistKind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }

    var defaultHeaders: [String: String] {
        get {
            guard let data = defaultHeadersData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set { defaultHeadersData = try? JSONEncoder().encode(newValue) }
    }

    var canRefresh: Bool { kind == .subscription && sourceURL != nil }
}
