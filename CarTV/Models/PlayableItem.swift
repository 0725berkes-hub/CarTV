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
    /// External subtitle tracks (MyTV+ movies/episodes). Empty for channels and local files.
    var subtitleLinks: SubtitleLinks = SubtitleLinks()

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

    init(movie: VODMovie) {
        self.ref = PlayableRef(id: movie.playableID, kind: .vod)
        self.title = movie.title
        self.subtitle = [movie.year.nilIfEmpty, movie.category.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
        self.url = movie.stream
        self.artworkURL = movie.backdrop ?? movie.poster
        self.headers = ["User-Agent": MyTVAPI.userAgent]
        self.genre = nil
        self.streamKind = StreamKind.detect(from: movie.stream)
        self.isLive = false
        self.duration = (Double(movie.duration) ?? 0) * 60
        self.subtitleLinks = movie.subtitles
    }

    init(episode: VODEpisode, series: VODSeries, season: VODSeason) {
        self.ref = PlayableRef(id: episode.playableID, kind: .vod)
        self.title = series.title
        self.subtitle = "Season \(season.name) · Episode \(episode.number)"
        self.url = episode.stream
        self.artworkURL = season.poster ?? series.poster
        self.headers = ["User-Agent": MyTVAPI.userAgent]
        self.genre = nil
        self.streamKind = StreamKind.detect(from: episode.stream)
        self.isLive = false
        self.duration = 0
        self.subtitleLinks = episode.subtitles
    }

    /// A trailer for a movie: same artwork/title, different URL, no subtitles, no progress tracking.
    init(trailer url: URL, of movie: PlayableItem) {
        self.ref = PlayableRef(id: UUID.stable("trailer:\(movie.id.uuidString)"), kind: .vod)
        self.title = movie.title
        self.subtitle = String(localized: "Trailer")
        self.url = url
        self.artworkURL = movie.artworkURL
        self.headers = movie.headers
        self.genre = nil
        self.streamKind = StreamKind.detect(from: url)
        self.isLive = false
        self.duration = 0
        self.subtitleLinks = SubtitleLinks()
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
