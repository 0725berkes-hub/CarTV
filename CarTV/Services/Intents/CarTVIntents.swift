import AppIntents
import Foundation

// Siri / Shortcuts / Spotlight for CarTV. Pure AppIntents — public framework,
// no entitlement, no Info.plist keys, works over CarPlay's Siri button too.
//
//   "Hey Siri, play K24 on CarTV"
//   "Hey Siri, play Al Jazeera in CarTV"
//   "Hey Siri, continue watching on CarTV"
//   "Hey Siri, resume my show in CarTV"
//   "Hey Siri, pause CarTV" / "next channel on CarTV"

// MARK: - Entity: anything playable, resolved by name

struct PlayableEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel or Title")
    static let defaultQuery = PlayableQuery()

    let id: String              // "channel:<uuid>" | "movie:<id>" | "series:<id>" | "video:<uuid>"
    let title: String
    let subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }
}

struct PlayableQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlayableEntity] {
        identifiers.compactMap { PlayableResolver.entity(id: $0) }
    }

    /// Siri passes what the user said. Match channels first (live TV is the
    /// primary use case in a car), then movies and series, then local videos.
    /// Generic words ("something", "a song", "music") aren't titles — hand back
    /// the shuffle entity so the request still does something sensible.
    @MainActor
    func entities(matching string: String) async throws -> [PlayableEntity] {
        if PlayableResolver.isGenericRequest(string) { return [PlayableResolver.shuffleEntity] }
        let hits = PlayableResolver.search(string, limit: 8)
        return hits.isEmpty ? [PlayableResolver.shuffleEntity] : hits
    }

    @MainActor
    func suggestedEntities() async throws -> [PlayableEntity] {
        let env = AppEnvironment.shared
        var out: [PlayableEntity] = []
        for f in env.favorites.favoriteItems().prefix(6) { if let e = PlayableResolver.entity(for: f) { out.append(e) } }
        for (item, _) in env.progress.continueWatching(limit: 4) { if let e = PlayableResolver.entity(for: item) { out.append(e) } }
        return out
    }
}

// MARK: - Intents

struct PlayTitleIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play on CarTV"
    static let description = IntentDescription("Plays a channel, movie, series or video in CarTV.")
    static let openAppWhenRun = true

    @Parameter(title: "What to play", requestValueDialog: "What do you want to watch?")
    var target: PlayableEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$target)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await PlayableResolver.play(id: target.id) else {
            return .result(dialog: target.id.hasPrefix("shuffle:") ? "You haven't added any videos to CarTV yet." : "I couldn't find that in CarTV.")
        }
        return .result(dialog: target.id.hasPrefix("shuffle:") ? "Shuffling your videos." : "Playing \(target.title).")
    }
}

struct ContinueWatchingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resumes the last movie or episode you were watching.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        if let (item, _) = env.progress.continueWatching(limit: 1).first {
            env.playback.play(item, origin: env.playback.carIsConnected ? .car : .phone, resume: true)
            return .result(dialog: "Resuming \(item.title).")
        }
        if let (series, pos) = env.vod.seriesInProgress(limit: 1).first {
            let eps = (try? await env.vod.episodes(for: pos.season)) ?? [pos.episode]
            let target = pos.isMidEpisode ? pos.episode
                : (eps.firstIndex { $0.id == pos.episode.id }.flatMap { $0 + 1 < eps.count ? eps[$0 + 1] : nil } ?? pos.episode)
            let queue = eps.map { PlayableItem(episode: $0, series: series, season: pos.season) }
            if let item = queue.first(where: { $0.id == target.playableID }) {
                env.vod.rememberPlayed(episodes: eps, series: series, season: pos.season)
                env.playback.play(item, queue: queue, origin: env.playback.carIsConnected ? .car : .phone, resume: true)
                return .result(dialog: "Resuming \(series.title), season \(pos.season.name) episode \(target.number).")
            }
        }
        return .result(dialog: "Nothing to continue yet.")
    }
}

/// "Play something" / "play a video" / "shuffle my videos" → shuffle the local
/// library (optionally one folder). Live TV and the MyTV catalogue are excluded:
/// a random channel or a random 2-hour movie isn't what anyone means by that.
struct ShuffleVideosIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Videos"
    static let description = IntentDescription("Plays a random video from your library, shuffling through the rest.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: VideoFolderEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$folder, .hasAnyValue) {
            Summary("Shuffle videos in \(\.$folder)")
        } otherwise: {
            Summary("Shuffle all videos")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        let origin: PlaybackOrigin = env.playback.carIsConnected ? .car : .phone
        let videos: [LocalVideo]
        let where_: String
        if let folder, let f = env.library.folders().first(where: { $0.id.uuidString == folder.id }) {
            videos = env.library.localVideos(in: f)
            where_ = f.name
        } else {
            videos = env.library.localVideos()
            where_ = String(localized: "your library")
        }
        guard !videos.isEmpty else {
            return .result(dialog: folder == nil ? "You haven't added any videos to CarTV yet." : "That folder is empty.")
        }
        let pool = videos.map(PlayableItem.init(video:))
        env.playback.playRandom(from: pool, origin: origin)
        let count = pool.count
        return .result(dialog: count == 1 ? "Playing your video." : "Shuffling \(count) videos from \(where_).")
    }
}

struct VideoFolderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Folder")
    static let defaultQuery = VideoFolderQuery()
    let id: String
    let name: String
    let count: Int
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(count) videos")
    }
}

struct VideoFolderQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [VideoFolderEntity] {
        AppEnvironment.shared.library.folders().filter { identifiers.contains($0.id.uuidString) }.map(Self.entity)
    }
    @MainActor
    func entities(matching string: String) async throws -> [VideoFolderEntity] {
        let q = string.searchNormalized
        return AppEnvironment.shared.library.folders().filter { $0.name.searchNormalized.contains(q) }.map(Self.entity)
    }
    @MainActor
    func suggestedEntities() async throws -> [VideoFolderEntity] {
        AppEnvironment.shared.library.folders().map(Self.entity)
    }
    @MainActor
    private static func entity(_ f: VideoFolder) -> VideoFolderEntity {
        VideoFolderEntity(id: f.id.uuidString, name: f.name, count: f.videos.count)
    }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause CarTV"
    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared.playback.pause()
        return .result()
    }
}

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume CarTV"
    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared.playback.resume()
        return .result()
    }
}

struct NextItemIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next on CarTV"
    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared.playback.next()
        return .result()
    }
}

struct PreviousItemIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous on CarTV"
    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared.playback.previous()
        return .result()
    }
}

// MARK: - Phrases Siri listens for

struct CarTVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Vague "play something" style requests → shuffle local videos. Listed first
        // so they don't get swallowed by the entity matcher below.
        AppShortcut(intent: ShuffleVideosIntent(), phrases: [
            "Play something on \(.applicationName)",
            "Play something in \(.applicationName)",
            "Play a video on \(.applicationName)",
            "Play a video in \(.applicationName)",
            "Play any video on \(.applicationName)",
            "Play my videos on \(.applicationName)",
            "Play videos on \(.applicationName)",
            "Shuffle my videos on \(.applicationName)",
            "Shuffle videos in \(.applicationName)",
            "Shuffle \(.applicationName)",
            "Surprise me on \(.applicationName)",
            "Play videos from \(\.$folder) on \(.applicationName)",
            "Shuffle \(\.$folder) on \(.applicationName)",
            "Play something from \(\.$folder) in \(.applicationName)",
        ], shortTitle: "Shuffle Videos", systemImageName: "shuffle")

        AppShortcut(intent: PlayTitleIntent(), phrases: [
            "Play \(\.$target) on \(.applicationName)",
            "Play \(\.$target) in \(.applicationName)",
            "Watch \(\.$target) on \(.applicationName)",
            "Put on \(\.$target) in \(.applicationName)",
            "Open \(\.$target) on \(.applicationName)",
        ], shortTitle: "Play", systemImageName: "play.fill")

        AppShortcut(intent: ContinueWatchingIntent(), phrases: [
            "Continue watching on \(.applicationName)",
            "Continue watching in \(.applicationName)",
            "Resume my show on \(.applicationName)",
            "Resume my movie on \(.applicationName)",
            "Pick up where I left off in \(.applicationName)",
        ], shortTitle: "Continue Watching", systemImageName: "play.circle.fill")

        AppShortcut(intent: PausePlaybackIntent(), phrases: [
            "Pause \(.applicationName)",
        ], shortTitle: "Pause", systemImageName: "pause.fill")

        AppShortcut(intent: ResumePlaybackIntent(), phrases: [
            "Resume \(.applicationName)",
            "Unpause \(.applicationName)",
        ], shortTitle: "Resume", systemImageName: "play.fill")

        AppShortcut(intent: NextItemIntent(), phrases: [
            "Next channel on \(.applicationName)",
            "Next episode on \(.applicationName)",
            "Skip on \(.applicationName)",
        ], shortTitle: "Next", systemImageName: "forward.end.fill")

        AppShortcut(intent: PreviousItemIntent(), phrases: [
            "Previous channel on \(.applicationName)",
            "Go back on \(.applicationName)",
        ], shortTitle: "Previous", systemImageName: "backward.end.fill")
    }
}

// MARK: - Resolver (shared by query + intents)

@MainActor
enum PlayableResolver {
    /// Pseudo-entity: "Play something" chosen via the title intent shuffles local videos.
    static let shuffleEntity = PlayableEntity(id: "shuffle:videos", title: String(localized: "Something from my videos"), subtitle: String(localized: "Shuffle"))

    /// "something", "anything", "a song", "some music", "a video", "whatever"…
    static func isGenericRequest(_ s: String) -> Bool {
        let q = s.searchNormalized
        let generic = ["something", "anything", "whatever", "a song", "some music", "music", "a video", "some video", "a movie", "any video", "random", "shuffle"]
        return generic.contains { q == $0 || q == "\($0)s" }
    }

    static func entity(for item: PlayableItem) -> PlayableEntity? {
        switch item.ref.kind {
        case .channel:    return PlayableEntity(id: "channel:\(item.id.uuidString)", title: item.title, subtitle: item.subtitle)
        case .localVideo: return PlayableEntity(id: "video:\(item.id.uuidString)", title: item.title, subtitle: item.subtitle)
        case .vod:
            if let m = AppEnvironment.shared.vod.movie(playableID: item.id) { return PlayableEntity(id: "movie:\(m.id)", title: m.title, subtitle: m.year.nilIfEmpty) }
            return PlayableEntity(id: "vod:\(item.id.uuidString)", title: item.title, subtitle: item.subtitle)
        }
    }

    static func entity(id: String) -> PlayableEntity? {
        let env = AppEnvironment.shared
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "shuffle": return shuffleEntity
        case "channel": return UUID(uuidString: parts[1]).flatMap { env.library.channel(id: $0) }.map { PlayableEntity(id: id, title: $0.name, subtitle: $0.groupTitle) }
        case "video":   return UUID(uuidString: parts[1]).flatMap { env.library.localVideo(id: $0) }.map { PlayableEntity(id: id, title: $0.title, subtitle: nil) }
        case "movie":   return env.vod.movie(id: parts[1]).map { PlayableEntity(id: id, title: $0.title, subtitle: $0.year.nilIfEmpty) }
        case "series":  return env.vod.series(id: parts[1]).map { PlayableEntity(id: id, title: $0.title, subtitle: String(localized: "Series")) }
        case "vod":     return UUID(uuidString: parts[1]).flatMap { env.library.item(for: PlayableRef(id: $0, kind: .vod)) }.map { PlayableEntity(id: id, title: $0.title, subtitle: $0.subtitle) }
        default: return nil
        }
    }

    static func search(_ query: String, limit: Int) -> [PlayableEntity] {
        let env = AppEnvironment.shared
        let q = query.searchNormalized
        guard !q.isEmpty else { return [] }
        var out: [PlayableEntity] = []
        // Channels: exact-ish first ("k24" → "K24 HD"), then contains.
        let channels = env.library.searchChannels(query, limit: 30)
        let ranked = channels.sorted { a, b in
            let an = a.normalizedName, bn = b.normalizedName
            let ap = an.hasPrefix(q) ? 0 : 1, bp = bn.hasPrefix(q) ? 0 : 1
            return ap != bp ? ap < bp : an.count < bn.count
        }
        for c in ranked.prefix(limit) { out.append(PlayableEntity(id: "channel:\(c.id.uuidString)", title: c.name, subtitle: c.groupTitle)) }
        if out.count < limit {
            let r = env.vod.search(query, limit: limit)
            for m in r.movies.prefix(limit - out.count) { out.append(PlayableEntity(id: "movie:\(m.id)", title: m.title, subtitle: m.year.nilIfEmpty)) }
            for s in r.series.prefix(max(0, limit - out.count)) { out.append(PlayableEntity(id: "series:\(s.id)", title: s.title, subtitle: String(localized: "Series"))) }
        }
        if out.count < limit {
            for v in env.library.searchLocalVideos(query, limit: limit - out.count) { out.append(PlayableEntity(id: "video:\(v.id.uuidString)", title: v.title, subtitle: nil)) }
        }
        return out
    }

    /// Start playback for an entity id. Series resume at the user's position.
    static func play(id: String) async throws -> Bool {
        let env = AppEnvironment.shared
        let origin: PlaybackOrigin = env.playback.carIsConnected ? .car : .phone
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        switch parts[0] {
        case "shuffle":
            let pool = env.library.localVideos().map(PlayableItem.init(video:))
            guard !pool.isEmpty else { return false }
            env.playback.playRandom(from: pool, origin: origin)
        case "channel":
            guard let uuid = UUID(uuidString: parts[1]), let c = env.library.channel(id: uuid) else { return false }
            let item = PlayableItem(channel: c, playlistName: c.playlist?.name)
            env.playback.play(item, queue: env.library.siblings(of: item), origin: origin)
        case "video":
            guard let uuid = UUID(uuidString: parts[1]), let v = env.library.localVideo(id: uuid) else { return false }
            env.playback.play(PlayableItem(video: v), origin: origin, resume: true)
        case "movie":
            guard let m = env.vod.movie(id: parts[1]) else { return false }
            let item = PlayableItem(movie: m)
            env.playback.play(item, queue: [item], origin: origin, resume: true)
        case "series":
            guard let s = env.vod.series(id: parts[1]) else { return false }
            let pos = env.vod.position(in: s)
            let season: VODSeason
            if let pos { season = pos.season } else {
                guard let first = try await env.vod.seasons(for: s).first else { return false }
                season = first
            }
            let eps = try await env.vod.episodes(for: season)
            guard !eps.isEmpty else { return false }
            let target: VODEpisode
            if let pos, pos.isMidEpisode { target = pos.episode }
            else if let pos, let i = eps.firstIndex(where: { $0.id == pos.episode.id }), i + 1 < eps.count { target = eps[i + 1] }
            else { target = pos?.episode ?? eps[0] }
            let queue = eps.map { PlayableItem(episode: $0, series: s, season: season) }
            guard let item = queue.first(where: { $0.id == target.playableID }) else { return false }
            env.vod.rememberPlayed(episodes: eps, series: s, season: season)
            env.playback.play(item, queue: queue, origin: origin, resume: true)
        case "vod":
            guard let uuid = UUID(uuidString: parts[1]), let item = env.library.item(for: PlayableRef(id: uuid, kind: .vod)) else { return false }
            env.playback.play(item, origin: origin, resume: true)
        default: return false
        }
        return true
    }
}
