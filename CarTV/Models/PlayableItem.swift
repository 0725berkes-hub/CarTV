import Foundation

/// Immutable, Sendable description of something the player can play.
/// Built from a `Channel` or `LocalVideo`; safe to hand across actors and to CarPlay.
struct PlayableItem: Identifiable, Hashable, Sendable {
    let ref: PlayableRef
    let title: String
    let subtitle: String?
    let url: URL
    let artworkURL: URL?
    let headers: [String: String]
    let genre: Genre?
    let isLive: Bool
    /// Known duration for VOD; 0 for live/unknown.
    let duration: TimeInterval
    let streamKind: StreamKind

    var id: UUID { ref.id }
    var isLocal: Bool { url.isFileURL }

    init(channel: Channel, playlistName: String?) {
        self.ref = PlayableRef(id: channel.id, kind: .channel)
        self.title = channel.name
        self.subtitle = channel.groupTitle ?? playlistName
        self.url = channel.streamURL
        self.artworkURL = channel.logoURL
        var merged = channel.playlist?.defaultHeaders ?? [:]
        channel.headers.forEach { merged[$0.key] = $0.value }
        self.headers = merged
        self.genre = channel.genre
        self.streamKind = StreamKind.detect(from: channel.streamURL)
        self.isLive = streamKind.isLikelyLive
        self.duration = 0
    }

    init(video: LocalVideo) {
        self.ref = PlayableRef(id: video.id, kind: .localVideo)
        self.title = video.title
        self.subtitle = video.folder?.name
        self.url = video.fileURL
        self.artworkURL = video.thumbnailURL
        self.headers = [:]
        self.genre = nil
        self.streamKind = .localFile
        self.isLive = false
        self.duration = video.duration
    }
}
