import Foundation

/// Immutable, Sendable description of something the player can play.
/// Built from a `Channel` or `LocalVideo`; safe to hand across actors and to CarPlay.
nonisolated struct PlayableItem: Identifiable, Hashable, Sendable {
    let ref: PlayableRef
    let title: String
    let subtitle: String?
    var url: URL
    let artworkURL: URL?
    let headers: [String: String]
    let genre: Genre?
    let isLive: Bool
    /// Known duration for VOD; 0 for live/unknown.
    let duration: TimeInterval
    let streamKind: StreamKind
    /// External subtitle tracks (MyTV+ movies/episodes and YouTube captions).
    var subtitleLinks: SubtitleLinks = SubtitleLinks()
    var subtitleTracks: [SubtitleTrack] = []

    var id: UUID { ref.id }

    init(ref: PlayableRef, title: String, subtitle: String?, url: URL, artworkURL: URL?, headers: [String: String], genre: Genre?, isLive: Bool, duration: TimeInterval, streamKind: StreamKind) {
        self.ref = ref; self.title = title; self.subtitle = subtitle; self.url = url; self.artworkURL = artworkURL
        self.headers = headers; self.genre = genre; self.isLive = isLive; self.duration = duration; self.streamKind = streamKind
    }
    var isLocal: Bool { url.isFileURL }

    @MainActor init(channel: Channel, playlistName: String?) {
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
        self.subtitleLinks = SubtitleLinks(
            english: movie.subtitles.english,
            arabic: movie.subtitles.arabic,
            kurdish: movie.subtitles.kurdish
        )
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
        self.subtitleLinks = SubtitleLinks(
            english: episode.subtitles.english,
            arabic: episode.subtitles.arabic,
            kurdish: episode.subtitles.kurdish
        )
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

    @MainActor init(video: LocalVideo) {
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

extension PlayableItem {
    /// A cast item: no library record, plays straight from the URL.
    /// A TikTok from the feed. Direct MP4 with the cookie/referer headers the CDN requires.
    init(tiktok v: TTVideo, url: URL, headers: [String: String]) {
        self.init(
            ref: PlayableRef(id: v.playableID, kind: .tiktok),
            title: v.desc.nilIfEmpty ?? "@\(v.author.uniqueID)",
            subtitle: "@\(v.author.uniqueID)" + (v.music.map { " · \($0.title)" } ?? ""),
            url: url,
            artworkURL: v.coverURL,
            headers: headers,
            genre: nil,
            isLive: false,
            duration: TimeInterval(v.duration),
            streamKind: .mp4
        )
    }

    init(castURL url: URL, title: String, artwork: URL?) {
        self.init(
            ref: PlayableRef(id: UUID(), kind: .channel),
            title: title,
            subtitle: String(localized: "Cast"),
            url: url,
            artworkURL: artwork,
            headers: [:],
            genre: nil,
            isLive: false,
            duration: 0,
            streamKind: StreamKind.detect(from: url)
        )
    }
}

