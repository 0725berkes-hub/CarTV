import Foundation
import Observation
import OSLog

/// Feed state for the TikTok tab. Items come from `TTWebEngine` — TikTok's own
/// web app running hidden in WebKit and signing its own requests — so this class
/// never builds an API URL. It just buffers, dedupes, and asks for more.
@Observable
final class TikTokService {
    let session = TTSession()
    let engine = TTWebEngine()
    /// Still used for `mediaHeaders` (CDN needs Referer + tt_chain_token) and creator pages.
    let client: TikTokClient

    enum Feed: String, CaseIterable, Identifiable {
        case forYou, following, saved, liked
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self { case .forYou: "For You"; case .following: "Following"; case .saved: "Saved"; case .liked: "Liked" }
        }
    }

    private(set) var forYou: [TTVideo] = []
    private(set) var following: [TTVideo] = []
    private(set) var saved: [TTVideo] = []
    private(set) var liked: [TTVideo] = []
    /// Creator pages, keyed by handle. Filled when the engine visits a profile.
    private(set) var profiles: [String: [TTVideo]] = [:]
    var onProfileItems: ((String, [TTVideo]) -> Void)?
    private(set) var loading: Set<Feed> = []
    private(set) var error: String?
    /// Per-feed dedupe. A video that's both Saved and Liked must appear in both lists.
    private var seen: [Feed: Set<String>] = [:]
    private var waitTimers: [Feed: Task<Void, Never>] = [:]

    var pendingSignInPrompt = false

    init() {
        client = TikTokClient(session: session)
        engine.onItems = { [weak self] feed, items in
            guard let self else { return }
            let target: Feed?
            switch feed {
            case .profile(let h):
                var list = self.profiles[h] ?? []
                for v in items where !list.contains(where: { $0.id == v.id }) { list.append(v) }
                self.profiles[h] = list
                self.onProfileItems?(h, list)
                target = nil
            case .following: target = .following
            case .forYou:    target = .forYou
            case .saved:     target = .saved
            case .liked:     target = .liked
            }
            if let t = target {
                self.append(items, to: t); self.loading.remove(t); self.waitTimers[t]?.cancel()
                if !items.isEmpty { self.error = nil }
                // If the player is walking this feed, hand it the new tail so Next keeps going.
                Task { @MainActor in await self.extendPlayerQueue(from: t) }
            }
        }
        if session.isSignedIn { Task { @MainActor in engine.start() } }

        // Player ran off the end of the feed → load more, then it advances on its own.
        Task { @MainActor [weak self] in
            guard let self else { return }
            AppEnvironment.shared.playback.queueExhausted = { [weak self] in
                guard let self, let feed = self.activeFeedForPlayer else { return }
                self.loadMore(feed)
            }
            AppEnvironment.shared.playback.onItemChanged = { [weak self] item in
                guard let self, item?.ref.kind == .tiktok else { return }
                self.prefetchForPlayer()
            }
        }
    }

    /// Which feed the player's current queue came from (nil if it's not playing TikTok).
    private(set) var activeFeedForPlayer: Feed?

    @MainActor
    private func extendPlayerQueue(from feed: Feed) async {
        let pb = AppEnvironment.shared.playback
        guard pb.current?.ref.kind == .tiktok, activeFeedForPlayer == feed else { return }
        let all = items(for: feed)
        let have = Set(pb.queue.map(\.id))
        let missing = all.filter { !have.contains($0.playableID) }
        guard !missing.isEmpty else { return }
        pb.extendQueue(with: await proxiedQueue(missing))
        // Auto-resume if the player stalled at the end waiting for this.
        if !pb.isPlaying, pb.snapshot.state == .ended || pb.snapshot.state == .idle { pb.next() }
    }

    /// Mark which feed the player is walking. Call when starting playback from a feed.
    @MainActor
    func playerStarted(feed: Feed) { activeFeedForPlayer = feed }

    /// Play `v` from `feed` on the phone pager. If the player already holds this feed's
    /// queue, this is a plain index jump — no proxy round-trips, no cookie sync — so a
    /// swipe starts the next video immediately. The queue is only (re)built when the
    /// user switches feeds or the item isn't in the queue yet.
    @MainActor
    func playInline(_ v: TTVideo, from feed: Feed, queue list: [TTVideo]) {
        let pb = AppEnvironment.shared.playback
        guard pb.current?.id != v.playableID else { return }
        if activeFeedForPlayer == feed, let existing = pb.queue.first(where: { $0.id == v.playableID }) {
            pb.play(existing, origin: .phone, resume: false, presentPlayer: false)
            return
        }
        Task { @MainActor in
            let q = await proxiedQueue(list)
            guard let item = q.first(where: { $0.id == v.playableID }), pb.current?.id != item.id else { return }
            playerStarted(feed: feed)
            pb.play(item, queue: q, origin: .phone, resume: false, presentPlayer: false)
        }
    }

    func items(for feed: Feed) -> [TTVideo] {
        switch feed { case .forYou: forYou; case .following: following; case .saved: saved; case .liked: liked }
    }

    /// The handle the hidden page is logged in as. nil = guest = not your FYP.
    var pageUser: String? { engine.pageUser }

    // MARK: Load

    private func engineTarget(_ feed: Feed) -> TTWebEngine.Feed {
        let me = session.state.handle ?? engine.pageUser ?? ""
        switch feed {
        case .forYou: return .forYou
        case .following: return .following
        case .saved: return .saved(handle: me)
        case .liked: return .liked(handle: me)
        }
    }

    @MainActor
    func loadMore(_ feed: Feed) {
        guard session.isSignedIn, !loading.contains(feed) else { return }
        loading.insert(feed)
        let target = engineTarget(feed)
        if engine.currentFeed.path != target.path { engine.load(target) } else { engine.requestMore() }
        // If nothing arrives in 12 s the page is stuck (captcha, login wall, network). Surface it.
        waitTimers[feed]?.cancel()
        waitTimers[feed] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.loading.contains(feed) else { return }
            self.loading.remove(feed)
            if self.items(for: feed).isEmpty {
                self.error = String(localized: "TikTok didn't respond. Pull to refresh, or sign in again if it keeps happening.")
            }
        }
    }

    @MainActor
    func refresh(_ feed: Feed) async {
        guard session.isSignedIn else { return }
        seen[feed] = []
        switch feed { case .forYou: forYou = []; case .following: following = []; case .saved: saved = []; case .liked: liked = [] }
        error = nil
        loading.insert(feed)
        // The player's queue is the old list; drop it so the pager restarts on the new batch.
        let pb = AppEnvironment.shared.playback
        if activeFeedForPlayer == feed, pb.current?.ref.kind == .tiktok { pb.stop(); activeFeedForPlayer = nil }
        waitTimers[feed]?.cancel()
        waitTimers[feed] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.loading.contains(feed) else { return }
            self.loading.remove(feed)
            if self.items(for: feed).isEmpty { self.error = String(localized: "TikTok didn't respond. Try again in a moment.") }
        }
        engine.load(engineTarget(feed))   // fresh page → fresh batch
    }

    @MainActor
    func prefetchIfNeeded(_ feed: Feed, index: Int) {
        if items(for: feed).count - index <= 8 { loadMore(feed) }
    }

    /// Player-driven prefetch: the car's Next button doesn't move the phone pager.
    /// Also pre-warms the *next* video's first bytes so Next starts instantly.
    @MainActor
    func prefetchForPlayer() {
        let pb = AppEnvironment.shared.playback
        guard let feed = activeFeedForPlayer, let i = pb.currentIndex else { return }
        if pb.queue.count - i <= 8 { loadMore(feed) }
        let list = items(for: feed)
        for n in 1...3 where list.indices.contains(i + n) {
            TTMediaProxy.prewarm(playable(list[i + n]).url, headers: client.mediaHeaders)
        }
    }

    private func append(_ new: [TTVideo], to feed: Feed) {
        var list = items(for: feed)
        var s = seen[feed] ?? []
        // Server order, always. For You/Following is the ranked feed; Saved/Liked come
        // back most-recently-saved/liked first (exactly what TikTok's own tabs show), and
        // pages continue via the list's cursor, so appending keeps that order intact.
        for v in new where !s.contains(v.id) { s.insert(v.id); list.append(v) }
        seen[feed] = s
        switch feed { case .forYou: forYou = list; case .following: following = list; case .saved: saved = list; case .liked: liked = list }
    }

    /// Open a creator's profile in the engine; posts arrive via `profiles[handle]`.
    @MainActor
    func loadProfile(_ handle: String) {
        engine.load(.profile(handle: handle))
    }
    @MainActor
    func loadMoreProfile() { engine.requestMore() }

    /// Return the engine to the feed the user was on after leaving a profile.
    @MainActor
    func leaveProfile(backTo feed: Feed) {
        if case .profile = engine.currentFeed { engine.load(engineTarget(feed)) }
    }

    // MARK: Sign-in lifecycle

    @MainActor
    func didSignIn() {
        engine.start()
        Task { if let me = try? await client.me() { session.setHandle(me.handle) } }
        loadMore(.forYou)
    }

    @MainActor
    func sessionExpired() {
        Log.network.error("TikTok: session expired (redirected to /login)")
        signOut()
        error = String(localized: "TikTok signed you out. Sign in again.")
    }

    @MainActor
    func signOut() {
        engine.stop()
        session.signOut()
        forYou = []; following = []; saved = []; liked = []; seen = [:]; error = nil; loading = []
    }

    // MARK: Save to library

    func saveToLibrary(_ v: TTVideo, from url: URL) {
        Task.detached(priority: .userInitiated) { [headers = client.mediaHeaders] in
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false    // keep our Cookie header
            guard let (tmp, resp) = try? await URLSession(configuration: cfg).download(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else {
                Log.media.error("TikTok save failed: \(v.id, privacy: .public)"); return
            }
            let staged = FileManager.default.temporaryDirectory.appending(path: "tt-\(v.id).mp4")
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.moveItem(at: tmp, to: staged)
            let title = v.desc.nilIfEmpty.map { String($0.prefix(60)) } ?? "@\(v.author.uniqueID)"
            let importer = await LocalImporter(container: AppEnvironment.shared.modelContainer)
            _ = await importer.importMovieFiles([(staged, title)], into: nil) { _ in }
        }
    }

    // MARK: Playable

    func cached(playableID: UUID) -> PlayableItem? {
        (forYou + following + saved + liked).first { $0.playableID == playableID }.map { playable($0) }
    }

    func playable(_ v: TTVideo, forCar: Bool = false) -> PlayableItem {
        var url = v.playURL
        if forCar, let lighter = v.bitrates.first(where: { $0.gearName.contains("540") || $0.gearName.contains("720") }) { url = lighter.url }
        return PlayableItem(tiktok: v, url: url, headers: client.mediaHeaders)
    }

    func proxiedPlayable(_ v: TTVideo, forCar: Bool = false) async -> PlayableItem {
        let direct = playable(v, forCar: forCar)
        guard let local = try? await TTMediaProxy.shared.localURL(for: direct.url, headers: client.mediaHeaders) else { return direct }
        return PlayableItem(tiktok: v, url: local, headers: [:])
    }

    func proxiedQueue(_ list: [TTVideo], forCar: Bool = false) async -> [PlayableItem] {
        await session.syncFromWebKit()          // latest tt_chain_token before the CDN sees us
        var out: [PlayableItem] = []; out.reserveCapacity(list.count)
        for v in list { out.append(await proxiedPlayable(v, forCar: forCar)) }
        return out
    }
}
