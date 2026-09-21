import Foundation
import Observation
import OSLog

/// High-level YouTube façade for the UI: feeds, search, watch data, and resolving
/// a video into something `PlaybackController` can play. Caches aggressively so
/// the car UI never waits on the network twice for the same screen.
@Observable
final class YouTubeService {
    let auth: YTAuth
    @ObservationIgnored let history: YTWatchHistory
    /// Set by onboarding when the user opted into YouTube sign-in; the YouTube tab
    /// presents the account sheet once it appears and clears this.
    var pendingSignInPrompt = false
    /// Set when the full-screen player closes on a YouTube video: the YouTube tab
    /// should land on that video's detail page, not wherever it was.
    var pendingWatchPage: YTVideo?
    private let api = InnerTubeClient.shared

    // Resolved stream cache: videoID → (playable URL, expiry)
    private var streamCache: [String: (url: URL, expires: Date, variants: [(Int, String)], captions: [SubtitleTrack], tracking: (URL?, URL?))] = [:]
    private var pageCache: [String: (page: YTPage, at: Date)] = [:]
    private let pageTTL: TimeInterval = 600

    init() {
        let a = YTAuth()
        auth = a
        history = YTWatchHistory(auth: a)
        HLSBuilder.purge()
        if let data = UserDefaults.standard.data(forKey: "yt.stubs"), let d = try? JSONDecoder().decode([String: Stub].self, from: data) { stubs = d }
    }

    /// Minimal persisted metadata so favourites show a title/thumbnail without a network call.
    private struct Stub: Codable { var title: String; var channel: String?; var thumb: URL?; var duration: Int? }
    private var stubs: [String: Stub] = [:] {
        didSet { if let d = try? JSONEncoder().encode(stubs) { UserDefaults.standard.set(d, forKey: "yt.stubs") } }
    }
    func remember(_ v: YTVideo) { stubs[v.id] = Stub(title: v.title, channel: v.channelName, thumb: v.thumbnailURL, duration: v.durationSeconds) }
    func cachedStub(_ id: String) -> PlayableItem? {
        let s = stubs[id]
        var v = YTVideo(id: id, title: s?.title ?? "YouTube")
        v.channelName = s?.channel; v.thumbnailURL = s?.thumb; v.durationSeconds = s?.duration
        // Stub URL is the watch page; PlaybackController resolves .youtube items before loading.
        return item(for: v, url: v.watchURL)
    }

    // MARK: Feeds

    enum Feed: Hashable { case home, explore, subscriptions, watchLater, liked, history, library, playlists, playlist(String), channel(String, tab: ChannelTab) }

    /// Signed-out Home is intentionally empty on YouTube; Explore stitches popular
    /// categories together so the tab is never blank.
    static let exploreTopics = ["Music", "Gaming", "News", "Sports", "Movies trailers", "Comedy", "Technology", "Cooking", "Travel vlog", "Kurdish music"]
    enum ChannelTab: String, Hashable, CaseIterable { case videos, live, playlists }

    func fetch(_ feed: Feed, continuation: String? = nil) async throws -> YTPage {
        let key = "\(feed)"
        let ttl: TimeInterval = { if case .home = feed { return 90 } else { return pageTTL } }()
        if continuation == nil, let c = pageCache[key], Date().timeIntervalSince(c.at) < ttl { return c.page }
        let token = await auth.token()
        let json: JSONObject
        switch feed {
        case .home:
            guard token != nil else { return try await fetch(.explore, continuation: continuation) }
            json = try await api.browse("FEwhat_to_watch", continuation: continuation, accessToken: token)
            // Skip the "Personalized mix" radio tiles that don't map to a single video well.
            var page = YTParser.page(json)
            page.shelves = page.shelves.map { shelf in
                var s = shelf
                s.items = s.items.filter { if case .video(let v) = $0 { return !(v.channelName?.localizedCaseInsensitiveContains("mix for you") ?? false) }; return true }
                return s
            }.filter { !$0.items.isEmpty }
            if continuation == nil { pageCache[key] = (page, Date()) }
            return page
        case .explore:
            // One search per topic, in parallel → one shelf each. No continuation.
            if continuation != nil { return YTPage(shelves: [], continuation: nil) }
            var shelves: [YTShelf] = []
            try await withThrowingTaskGroup(of: (Int, YTShelf?).self) { group in
                for (i, topic) in Self.exploreTopics.enumerated() {
                    group.addTask { [api] in
                        let j = try? await api.search(topic, params: "EgIQAQ%3D%3D")   // videos only
                        let items = j.map { YTParser.collectItems($0) }?.prefix(8).map { $0 } ?? []
                        return (i, items.isEmpty ? nil : YTShelf(title: topic, items: items))
                    }
                }
                var ordered: [(Int, YTShelf)] = []
                for try await (i, shelf) in group { if let shelf { ordered.append((i, shelf)) } }
                shelves = ordered.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let page = YTPage(shelves: shelves, continuation: nil)
            pageCache[key] = (page, Date())
            return page
        case .subscriptions:  guard token != nil else { throw YTError.signInRequired }; json = try await api.browse("FEsubscriptions", continuation: continuation, accessToken: token)
        case .watchLater:     guard token != nil else { throw YTError.signInRequired }; json = try await api.browse("VLWL", continuation: continuation, accessToken: token)
        case .liked:          guard token != nil else { throw YTError.signInRequired }; json = try await api.browse("VLLL", continuation: continuation, accessToken: token)
        case .history:        guard token != nil else { throw YTError.signInRequired }; json = try await api.browse("FEhistory", continuation: continuation, accessToken: token)
        case .library:        guard token != nil else { throw YTError.signInRequired }; json = try await api.browse("FElibrary", continuation: continuation, accessToken: token)
        case .playlists:
            guard token != nil else { throw YTError.signInRequired }
            json = try await api.browse("FEplaylist_aggregation", continuation: continuation, accessToken: token)
            var page = YTParser.page(json)
            page.shelves = page.shelves.map { shelf in
                var s = shelf; s.items = s.items.filter { if case .playlist = $0 { return true } else { return false } }; return s
            }.filter { !$0.items.isEmpty }
            if continuation == nil { pageCache[key] = (page, Date()) }
            return page
        case .playlist(let id):
            if id.hasPrefix("RD") {
                // Mixes have no browse page; their queue comes from `next` for the seed video.
                let seed = String(id.dropFirst(2)).replacingOccurrences(of: "MM", with: "")
                json = try await api.next(videoID: seed.isEmpty ? "" : seed, playlistID: id, continuation: continuation, accessToken: token)
                var page = YTPage(shelves: [], continuation: nil)
                // TV layout: the mix queue is the "Up next" shelf whose tiles all belong
                // to the mix (mdxExpandedVideoList lists the ids). WEB layout: the
                // `playlist` panel. Fall back to related if neither exists.
                let mixIDs = Set(json["mdxExpandedVideoList"]["videoIds"].array.compactMap(\.string))
                let all = YTParser.collectItems(json["contents"]).compactMap { if case .video(let v) = $0 { return v } else { return nil } }
                var vids = mixIDs.isEmpty ? [] : all.filter { mixIDs.contains($0.id) && !$0.title.isEmpty }
                if vids.isEmpty { vids = YTParser.collectItems(json["contents"].find("playlist")).compactMap { if case .video(let v) = $0 { return v } else { return nil } } }
                if vids.isEmpty { vids = YTParser.watch(json).related }
                // Seed video first if it isn't already.
                if !seed.isEmpty, !vids.contains(where: { $0.id == seed }), let seedVideo = all.first(where: { $0.id == seed }) { vids.insert(seedVideo, at: 0) }
                var uniq = Set<String>(); vids = vids.filter { uniq.insert($0.id).inserted }
                page.shelves = [YTShelf(title: String(localized: "Mix"), items: vids.map { .video($0) })]
                if continuation == nil { pageCache[key] = (page, Date()) }
                return page
            }
            json = try await api.browse("VL" + id.replacingOccurrences(of: "VL", with: ""), continuation: continuation, accessToken: token)
        case .channel(let id, let tab):
            let params: String? = switch tab { case .videos: "EgZ2aWRlb3PyBgQKAjoA"; case .live: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D"; case .playlists: "EglwbGF5bGlzdHPyBgQKAkIA" }
            json = try await api.browse(id, params: params, continuation: continuation, accessToken: token)
        }
        let page = Self.dedupe(YTParser.page(json))
        if continuation == nil { pageCache[key] = (page, Date()) }
        return page
    }

    func search(_ query: String, continuation: String? = nil) async throws -> YTPage {
        let json = try await api.search(query, continuation: continuation, accessToken: await auth.token())
        return YTParser.page(json)
    }

    func suggestions(_ query: String) async -> [String] {
        (try? await api.suggestions(query)) ?? []
    }

    func channel(_ id: String) async throws -> (YTChannel, YTPage) {
        let token = await auth.token()
        let json = try await api.browse(id, params: "EgZ2aWRlb3PyBgQKAjoA", accessToken: token)
        return (YTParser.channelHeader(json, id: id), YTParser.page(json))
    }

    /// Remove items already present earlier on the page (shelves overlap a lot on TV Home).
    nonisolated static func dedupe(_ page: YTPage) -> YTPage {
        var seen = Set<String>(); var p = page
        p.shelves = p.shelves.map { sh in var s = sh; s.items = s.items.filter { seen.insert($0.id).inserted }; return s }.filter { !$0.items.isEmpty }
        return p
    }

    /// Home never ends on YouTube: when the page and all its shelves are exhausted,
    /// ask for a fresh Home (recommendations differ each call) and keep the unseen ones.
    func moreHome(excluding seen: Set<String>) async throws -> YTPage {
        pageCache["\(Feed.home)"] = nil
        var p = try await fetch(.home)
        p.shelves = p.shelves.map { sh in var s = sh; s.items = s.items.filter { !seen.contains($0.id) }; return s }.filter { !$0.items.isEmpty }
        return p
    }

    /// Drop cached pages so the next fetch hits the network (Refresh button).
    func invalidateFeeds() { pageCache.removeAll() }

    /// Drop network-derived state after a long suspension or CarPlay reconnect.
    /// Sign-in, remembered video metadata, and user preferences remain intact.
    func refreshTransientState() {
        streamCache.removeAll()
        pageCache.removeAll()
        HLSBuilder.purge(olderThan: 0)
        api.resetTransientState()
        Task { await YTChallengeSolver.shared.reset() }
        Log.network.info("YouTube transient session state refreshed")
    }

    /// More items for a single shelf (TV layout paginates per shelf).
    func more(shelf continuation: String) async throws -> YTShelf? {
        let json = try await api.browse("", continuation: continuation, accessToken: await auth.token())
        let items = YTParser.collectItems(json)
        guard !items.isEmpty else { return nil }
        let next = json.find("continuations").array.first?["nextContinuationData"]["continuation"].string ?? json.find("continuationCommand")["token"].string
        return YTShelf(title: nil, items: items, continuation: next)
    }

    func watch(_ videoID: String) async throws -> YTParser.WatchInfo {
        YTParser.watch(try await api.next(videoID: videoID, accessToken: await auth.token()))
    }

    func comments(continuation: String) async throws -> (items: [YTComment], continuation: String?) {
        YTParser.comments(try await api.next(videoID: "", continuation: continuation, accessToken: await auth.token()))
    }

    func related(continuation: String) async throws -> YTPage {
        let json = try await api.next(videoID: "", continuation: continuation, accessToken: await auth.token())
        var page = YTParser.page(json)
        // TV: the next token sits on the continued sectionList, not on a shelf.
        if page.continuation == nil {
            page.continuation = json["continuationContents"].find("continuations").array.first?["nextContinuationData"]["continuation"].string
        }
        return page
    }

    // MARK: Actions

    func like(_ id: String, undo: Bool = false) async throws { guard let t = await auth.token() else { throw YTError.signInRequired }; try await api.like(videoID: id, accessToken: t, remove: undo) }
    func dislike(_ id: String) async throws { guard let t = await auth.token() else { throw YTError.signInRequired }; try await api.dislike(videoID: id, accessToken: t) }
    func subscribe(_ channelID: String, undo: Bool = false) async throws {
        guard let t = await auth.token() else { throw YTError.signInRequired }
        try await api.subscribe(channelID: channelID, accessToken: t, remove: undo)
        pageCache.removeValue(forKey: "\(Feed.subscriptions)")
    }
    func watchLater(_ id: String) async throws { guard let t = await auth.token() else { throw YTError.signInRequired }; try await api.addToWatchLater(videoID: id, accessToken: t); pageCache.removeValue(forKey: "\(Feed.watchLater)") }

    // MARK: Playback

    struct Resolved: Sendable {
        let item: PlayableItem
        let variants: [(height: Int, label: String)]
        let captions: [SubtitleTrack]
    }

    /// Resolves a video into a PlayableItem: HLS (native) → generated HLS → progressive MP4.
    func resolve(_ video: YTVideo, fresh: Bool = false) async throws -> Resolved {
        if fresh { streamCache[video.id] = nil }
        if let c = streamCache[video.id], c.expires > Date() {
            let r = Resolved(item: item(for: video, url: c.url, subtitleTracks: c.captions), variants: c.variants.map { ($0.0, $0.1) }, captions: c.captions)
            AppEnvironment.shared.playback.pendingQualityVariants = r.variants
            history.begin(videoID: video.id, playbackURL: c.tracking.0, watchtimeURL: c.tracking.1)
            return r
        }
        var resp = try await api.player(videoID: video.id, accessToken: await auth.token())
        let url: URL
        var variants: [(Int, String)] = []
        if let hls = resp.hlsManifestURL {
            // Native HLS: mirror the master locally so the quality picker gets the
            // real ladder and a manual pick can swap to a single-variant master.
            if let mirrored = try? await HLSBuilder.mirrorNativeMaster(hls, videoID: video.id) {
                url = mirrored.masterURL
                variants = mirrored.variants.map { ($0.height, $0.label) }
            } else {
                url = hls
            }
        } else if !resp.avVideoFormats.isEmpty, resp.bestDefaultAudio != nil {
            var built: HLSBuilder.Result
            do {
                built = try await HLSBuilder.build(resp)
            } catch YTError.network(let msg) where msg.hasPrefix("HTTP 4") {
                // A stale/invalid challenge solution → Google refuses the range. Drop the
                // cached player + solutions and do the whole thing once more.
                Log.network.notice("YT streams refused (\(msg, privacy: .public)); re-solving with a fresh player")
                await YTChallengeSolver.shared.reset()
                resp = try await api.player(videoID: video.id, accessToken: await auth.token())
                built = try await HLSBuilder.build(resp)
            }
            url = built.masterURL
            variants = built.variants.map { ($0.height, $0.label) }
        } else if let prog = resp.progressiveFormats.first {
            url = prog.url
        } else {
            throw YTError.unavailable(resp.playabilityReason ?? String(localized: "No playable streams"))
        }
        let captions = resp.captionTracks.map { SubtitleTrack(name: $0.name, languageCode: $0.lang, url: $0.url) }
        streamCache[video.id] = (url, resp.expiresAt, variants, captions, (resp.playbackURL, resp.watchtimeURL))
        AppEnvironment.shared.playback.pendingQualityVariants = variants.map { ($0.0, $0.1) }
        history.begin(videoID: video.id, playbackURL: resp.playbackURL, watchtimeURL: resp.watchtimeURL)
        var enriched = video
        if enriched.title.isEmpty { enriched.title = resp.title }
        if enriched.channelName == nil { enriched.channelName = resp.author }
        if enriched.durationSeconds == nil, resp.lengthSeconds > 0 { enriched.durationSeconds = resp.lengthSeconds }
        enriched.isLive = resp.isLive
        return Resolved(item: item(for: enriched, url: url, subtitleTracks: captions), variants: variants.map { ($0.0, $0.1) }, captions: captions)
    }

    private func item(for v: YTVideo, url: URL, subtitleTracks: [SubtitleTrack] = []) -> PlayableItem {
        var item = PlayableItem(
            ref: PlayableRef(id: Self.uuid(for: v.id), kind: .youtube),
            title: v.title,
            subtitle: v.channelName,
            url: url,
            artworkURL: v.thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(v.id)/hqdefault.jpg"),
            headers: [:],
            genre: nil,
            isLive: v.isLive,
            duration: TimeInterval(v.durationSeconds ?? 0),
            streamKind: url.isFileURL ? .hls : .hls
        )
        item.subtitleTracks = subtitleTracks
        return item
    }

    /// Stable UUID derived from the 11-char video ID so favorites/progress round-trip.
    nonisolated static func uuid(for videoID: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in videoID.utf8.enumerated() where i < 16 { bytes[i] = b }
        bytes[11] = 0x59; bytes[12] = 0x54   // "YT" marker
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    nonisolated static func videoID(from uuid: UUID) -> String? {
        let u = uuid.uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10]
        guard u.11 == 0x59, u.12 == 0x54 else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parse any YouTube URL/ID into a video ID.
    nonisolated static func videoID(from text: String) -> String? {
        let t = text.trimmed
        if t.count == 11, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return t }
        guard let url = URL.lenient(t) else { return nil }
        if url.host?.contains("youtu.be") == true { return url.pathComponents.dropFirst().first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let comps = url.pathComponents
        if let i = comps.firstIndex(where: { ["embed", "shorts", "live", "v"].contains($0) }), i + 1 < comps.count { return comps[i + 1] }
        return nil
    }
}
