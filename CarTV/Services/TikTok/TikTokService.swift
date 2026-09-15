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

    enum Feed: String, CaseIterable, Identifiable { case forYou, following; var id: String { rawValue } }

    private(set) var forYou: [TTVideo] = []
    private(set) var following: [TTVideo] = []
    /// Creator pages, keyed by handle. Filled when the engine visits a profile.
    private(set) var profiles: [String: [TTVideo]] = [:]
    var onProfileItems: ((String, [TTVideo]) -> Void)?
    private(set) var loading: Set<Feed> = []
    private(set) var error: String?
    private var seen: Set<String> = []
    private var waitTimers: [Feed: Task<Void, Never>] = [:]

    var pendingSignInPrompt = false

    init() {
        client = TikTokClient(session: session)
        engine.onItems = { [weak self] feed, items in
            guard let self else { return }
            switch feed {
            case .profile(let h):
                var list = self.profiles[h] ?? []
                for v in items where !list.contains(where: { $0.id == v.id }) { list.append(v) }
                self.profiles[h] = list
                self.onProfileItems?(h, list)
            case .following:
                self.append(items, to: .following); self.loading.remove(.following); self.waitTimers[.following]?.cancel()
                if !items.isEmpty { self.error = nil }
            case .forYou:
                self.append(items, to: .forYou); self.loading.remove(.forYou); self.waitTimers[.forYou]?.cancel()
                if !items.isEmpty { self.error = nil }
            }
        }
        if session.isSignedIn { Task { @MainActor in engine.start() } }
    }

    func items(for feed: Feed) -> [TTVideo] { feed == .forYou ? forYou : following }

    // MARK: Load

    @MainActor
    func loadMore(_ feed: Feed) {
        guard session.isSignedIn, !loading.contains(feed) else { return }
        loading.insert(feed)
        let target: TTWebEngine.Feed = feed == .forYou ? .forYou : .following
        if engine.currentFeed != target { engine.load(target) } else { engine.requestMore() }
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
        seen.removeAll()
        if feed == .forYou { forYou = [] } else { following = [] }
        error = nil
        loading.insert(feed)
        engine.load(feed == .forYou ? .forYou : .following)   // fresh page → fresh batch
    }

    @MainActor
    func prefetchIfNeeded(_ feed: Feed, index: Int) {
        if items(for: feed).count - index <= 4 { loadMore(feed) }
    }

    private func append(_ new: [TTVideo], to feed: Feed) {
        var list = items(for: feed)
        for v in new where !seen.contains(v.id) { seen.insert(v.id); list.append(v) }
        if feed == .forYou { forYou = list } else { following = list }
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
        if case .profile = engine.currentFeed { engine.load(feed == .forYou ? .forYou : .following) }
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
        forYou = []; following = []; seen = []; error = nil; loading = []
    }

    // MARK: Save to library

    func saveToLibrary(_ v: TTVideo, from url: URL) {
        Task.detached(priority: .userInitiated) { [headers = client.mediaHeaders] in
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            guard let (tmp, resp) = try? await URLSession.shared.download(for: req),
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
        (forYou + following).first { $0.playableID == playableID }.map { playable($0) }
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
        var out: [PlayableItem] = []; out.reserveCapacity(list.count)
        for v in list { out.append(await proxiedPlayable(v, forCar: forCar)) }
        return out
    }
}
