import Foundation
import SwiftData

/// A favourite pointing at either a channel or a local video.
@Model
final class Favorite {
    #Index<Favorite>([\.targetID], [\.addedAt])

    @Attribute(.unique) var id: UUID
    var targetID: UUID
    var targetKindRaw: String
    var addedAt: Date

    init(target: PlayableRef) {
        self.id = UUID()
        self.targetID = target.id
        self.targetKindRaw = target.kind.rawValue
        self.addedAt = .now
    }

    var target: PlayableRef {
        PlayableRef(id: targetID, kind: PlayableKind(rawValue: targetKindRaw) ?? .channel)
    }
}

/// Resume position + history entry.
@Model
final class WatchProgress {
    #Index<WatchProgress>([\.targetID], [\.lastWatchedAt])

    @Attribute(.unique) var targetID: UUID
    var targetKindRaw: String
    var position: TimeInterval
    var duration: TimeInterval
    var lastWatchedAt: Date
    var completed: Bool

    init(target: PlayableRef, position: TimeInterval, duration: TimeInterval) {
        self.targetID = target.id
        self.targetKindRaw = target.kind.rawValue
        self.position = position
        self.duration = duration
        self.lastWatchedAt = .now
        self.completed = duration > 0 && position / duration > 0.95
    }

    var target: PlayableRef {
        PlayableRef(id: targetID, kind: PlayableKind(rawValue: targetKindRaw) ?? .channel)
    }

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

enum PlayableKind: String, Codable, Sendable {
    case channel, localVideo, vod
}

struct PlayableRef: Hashable, Codable, Sendable {
    let id: UUID
    let kind: PlayableKind
}
