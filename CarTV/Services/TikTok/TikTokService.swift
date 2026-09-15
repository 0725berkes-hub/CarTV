import Foundation
import Observation
import OSLog

/// Feed state for the TikTok tab: For You, Following, creator pages. Prefetches
/// the next batch when you're three from the end so swiping never waits.
@Observable
final class TikTokService {
    let session = TTSession()
    let client: TikTokClient

    enum Feed: String, CaseIterable, Identifiable { case forYou, following; var id: String { rawValue } }

    private(set) var forYou: [TTVideo] = []
    private(set) var following: [TTVideo] = []
    private(set) var loading: Set<Feed> = []
    private(set) var error: String?
    private var followingCursor = 0
    private var seen: Set<String> = []

    /// Set by onboarding / settings to open the sign-in sheet on the tab.
    var pendingSignInPrompt = false

    init() { client = TikTokClient(session: session) }

    func items(for feed: Feed) -> [TTVideo] { feed == .forYou ? forYou : following }

    // MARK: Load

    func loadMore(_ feed: Feed) {
        guard session.isSignedIn, !loading.contains(feed) else { return }
        loading.insert(feed)
        Task { @MainActor in
            defer { loading.remove(feed) }
            do {
                switch feed {
                case .forYou:
                    let page = try await client.forYou(count: 12)
                    append(page.items, to: &forYou)
                case .following:
                    let page = try await client.following(count: 12, cursor: followingCursor)
                    followingCursor += page.items.count
                    append(page.items, to: &following)
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
                Log.network.error("TikTok \(feed.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if case TikTokClient.Failure.signedOut = error { session.signOut() }
            }
        }
    }

    /// Pull-to-refresh: a fresh For You batch on top.
    func refresh(_ feed: Feed) async {
        guard session.isSignedIn else { return }
        do {
            switch feed {
            case .forYou:
                let page = try await client.forYou(count: 12)
                seen.removeAll()
                forYou = []
                append(page.items, to: &forYou)
            case .following:
                followingCursor = 0
                let page = try await client.following(count: 12)
                following = []
                append(page.items, to: &following)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Called by the pager as the index moves; keeps ~3 ahead in the buffer.
    func prefetchIfNeeded(_ feed: Feed, index: Int) {
        let n = items(for: feed).count
        if n - index <= 3 { loadMore(feed) }
    }

    private func append(_ new: [TTVideo], to list: inout [TTVideo]) {
        for v in new where !seen.contains(v.id) {
            seen.insert(v.id)
            list.append(v)
        }
    }

    // MARK: Sign-in lifecycle

    func didSignIn() {
        Task { @MainActor in
            if let me = try? await client.me() { session.setHandle(me.handle) }
            loadMore(.forYou)
        }
    }

    func signOut() {
        session.signOut()
        forYou = []; following = []; seen = []; followingCursor = 0; error = nil
    }

    // MARK: Save to library

    /// Download the MP4 into Local Videos (offline, CarPlay-safe). Uses the same
    /// headers the CDN requires for playback.
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

    /// Resolve a previously seen video (favorites, history) from the in-memory feeds.
    func cached(playableID: UUID) -> PlayableItem? {
        (forYou + following).first { $0.playableID == playableID }.map { playable($0) }
    }

    /// Picks a rendition. Car gets ≤720p to keep decode light; phone gets the best.
    func playable(_ v: TTVideo, forCar: Bool = false) -> PlayableItem {
        var url = v.playURL
        if forCar, let lighter = v.bitrates.first(where: { $0.gearName.contains("540") || $0.gearName.contains("720") }) { url = lighter.url }
        return PlayableItem(tiktok: v, url: url, headers: client.mediaHeaders)
    }
}
