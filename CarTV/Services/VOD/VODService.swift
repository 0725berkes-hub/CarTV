import OSLog
import Foundation
import Observation

/// MyTV+ movies & series, fetched straight from the upstream API on-device
/// (same path as `MyTVService` channels — no middle server).
///
/// The movie catalogue is ~22 MB / 12K items, so it's loaded once, cached as
/// JSON in Application Support, and refreshed in the background at most every
/// 12 hours. Seasons/episodes are fetched on demand and memoised per session.
@Observable
final class VODService {

    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    private(set) var movies: [VODMovie] = []
    private(set) var series: [VODSeries] = []
    private(set) var phase: Phase = .idle
    private(set) var lastRefreshed: Date?

    /// Category → movies, in upstream order. Rebuilt whenever `movies` changes.
    private(set) var movieShelves: [(name: String, items: [VODMovie])] = []
    private(set) var seriesShelves: [(name: String, items: [VODSeries])] = []

    private var seasonCache: [String: [VODSeason]] = [:]
    private var episodeCache: [String: [VODEpisode]] = [:]
    private var loadTask: Task<Void, Never>?

    nonisolated private static let ttl: TimeInterval = 12 * 3600
    nonisolated private static let cacheURL = AppPaths.applicationSupport.appending(path: "vod-cache.json")

    // MARK: Load

    /// Load from disk immediately, then refresh from the network if stale.
    ///
    /// All the heavy work (22 MB download, JSON parse, mapping 12K items) runs on a
    /// detached background task; only the final `apply` touches the main actor.
    /// Doing this inline would freeze the UI on "Loading catalogue…" for 10–30 s.
    func loadIfNeeded(force: Bool = false) {
        guard loadTask == nil else { return }
        let hadMovies = !movies.isEmpty
        let lastRefreshed = self.lastRefreshed
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }

            // 1. Disk cache → instant shelves.
            if !hadMovies, let cached = await Self.readCache() {
                self?.apply(cached)
            }
            guard let self else { return }

            // 2. Refresh if stale.
            let effectiveLast = self.lastRefreshed ?? lastRefreshed
            let stale = force || effectiveLast.map { Date.now.timeIntervalSince($0) > Self.ttl } ?? true
            guard stale else { phase = .ready; return }
            if movies.isEmpty { phase = .loading }
            Log.playlist.info("VOD: fetching catalogue…")

            let result = await Task.detached(priority: .userInitiated) { () -> Result<Catalogue, Error> in
                do { return .success(try await Self.fetchCatalogue()) } catch { return .failure(error) }
            }.value

            switch result {
            case .success(let fresh):
                apply(fresh)
                Log.playlist.info("VOD: \(fresh.movies.count) movies, \(fresh.series.count) series")
                await Self.writeCache(fresh)
            case .failure(let error):
                Log.playlist.error("VOD refresh failed: \(error.localizedDescription)")
                phase = movies.isEmpty ? .failed(error.localizedDescription) : .ready
            }
        }
    }

    private func apply(_ c: Catalogue) {
        movies = c.movies
        series = c.series
        lastRefreshed = c.fetchedAt
        movieShelves = Self.group(c.movies, by: \.category)
        seriesShelves = Self.group(c.series, by: \.category)
        phase = .ready
    }

    nonisolated private static func group<T>(_ items: [T], by key: KeyPath<T, String>) -> [(name: String, items: [T])] {
        var order: [String] = []
        var map: [String: [T]] = [:]
        for it in items {
            let k = it[keyPath: key].nilIfEmpty ?? "Other"
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(it)
        }
        return order.map { ($0, map[$0]!) }
    }

    // MARK: Played episodes (so Continue Watching / History can resolve them)

    /// Episodes aren't in the catalogue — only in per-season fetches. Remember every
    /// episode that starts playing, with its series/season context, so a resume
    /// point can rebuild the PlayableItem after relaunch. Small: last 200 plays.
    private var played: [UUID: PlayedEpisode] = [:]
    private var playedLoaded = false
    nonisolated private static let playedURL = AppPaths.applicationSupport.appending(path: "vod-played.json")

    nonisolated private struct PlayedEpisode: Codable, Sendable {
        let episode: VODEpisode
        let series: VODSeries
        let season: VODSeason
        let at: Date
    }

    func rememberPlayed(episodes: [VODEpisode], series: VODSeries, season: VODSeason) {
        loadPlayedIfNeeded()
        let now = Date()
        for e in episodes { played[e.playableID] = PlayedEpisode(episode: e, series: series, season: season, at: now) }
        if played.count > 200 {
            for (k, _) in played.sorted(by: { $0.value.at < $1.value.at }).prefix(played.count - 200) { played.removeValue(forKey: k) }
        }
        let snapshot = played
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.playedURL, options: .atomic) }
        }
    }

    func playedItem(id: UUID) -> PlayableItem? {
        loadPlayedIfNeeded()
        guard let p = played[id] else { return nil }
        return PlayableItem(episode: p.episode, series: p.series, season: p.season)
    }

    private func loadPlayedIfNeeded() {
        guard !playedLoaded else { return }
        playedLoaded = true
        if let data = try? Data(contentsOf: Self.playedURL),
           let map = try? JSONDecoder().decode([UUID: PlayedEpisode].self, from: data) {
            played = map
        }
    }

    /// Where the user is in a series: the most recently watched episode (with its
    /// season) and whether it's mid-episode or finished. Drives "Continue S2 E4"
    /// on both phone and car. nil = never started.
    struct SeriesPosition {
        let episode: VODEpisode
        let season: VODSeason
        let progress: WatchProgress?
        var isMidEpisode: Bool { (progress?.completed == false) && (progress?.position ?? 0) > 5 }
    }

    func position(in series: VODSeries) -> SeriesPosition? {
        loadPlayedIfNeeded()
        let store = AppEnvironment.shared.progress
        return played.values
            .filter { $0.series.id == series.id }
            .compactMap { p -> (PlayedEpisode, WatchProgress)? in
                guard let w = store.progress(for: PlayableRef(id: p.episode.playableID, kind: .vod)) else { return nil }
                return (p, w)
            }
            .max { $0.1.lastWatchedAt < $1.1.lastWatchedAt }
            .map { SeriesPosition(episode: $0.0.episode, season: $0.0.season, progress: $0.1) }
    }

    /// Series with any watch history, newest first. For a "Continue Watching" shelf.
    func seriesInProgress(limit: Int = 12) -> [(series: VODSeries, position: SeriesPosition)] {
        loadPlayedIfNeeded()
        var seen: Set<String> = []
        return played.values
            .sorted { $0.at > $1.at }
            .compactMap { p -> (VODSeries, SeriesPosition)? in
                guard !seen.contains(p.series.id), let pos = position(in: p.series) else { return nil }
                seen.insert(p.series.id)
                return (p.series, pos)
            }
            .prefix(limit).map { $0 }
    }

    // MARK: Lookup

    func movie(id: String) -> VODMovie? { movies.first { $0.id == id } }
    func series(id: String) -> VODSeries? { series.first { $0.id == id } }

    func search(_ query: String, limit: Int = 60) -> (movies: [VODMovie], series: [VODSeries]) {
        let q = query.searchNormalized
        guard !q.isEmpty else { return ([], []) }
        return (Array(movies.filter { $0.title.searchNormalized.contains(q) }.prefix(limit)),
                Array(series.filter { $0.title.searchNormalized.contains(q) }.prefix(limit)))
    }

    // MARK: Seasons / episodes (on demand)

    func seasons(for s: VODSeries) async throws -> [VODSeason] {
        if let c = seasonCache[s.id] { return c }
        let raw: [[String: Any]] = try await MyTVAPI.post(.seasons, extra: ["id": s.id, "seasonNumber": "1"])
        let list = raw.compactMap { d -> VODSeason? in
            guard let id = MyTVAPI.str(d["id"]) else { return nil }
            return VODSeason(id: id, seriesID: s.id,
                             name: MyTVAPI.str(d["name"]) ?? "",
                             year: MyTVAPI.str(d["year"]) ?? "",
                             description: MyTVAPI.str(d["description"]) ?? "",
                             actors: MyTVAPI.str(d["actors"]) ?? "",
                             poster: MyTVAPI.url(d["logoV2"] ?? d["logo"]))
        }
        seasonCache[s.id] = list
        return list
    }

    func episodes(for season: VODSeason) async throws -> [VODEpisode] {
        if let c = episodeCache[season.id] { return c }
        let raw: [[String: Any]] = try await MyTVAPI.post(.episodes, extra: ["id": season.id, "seasonNumber": season.name])
        let list = raw.compactMap { d -> VODEpisode? in
            guard let id = MyTVAPI.str(d["id"]),
                  let stream = MyTVAPI.url(d["episodeLink"]) ?? MyTVAPI.url(d["link"]) else { return nil }
            return VODEpisode(id: id, seasonID: season.id,
                              name: MyTVAPI.str(d["name"]) ?? "",
                              stream: stream,
                              subtitles: SubtitleLinks(english: MyTVAPI.url(d["titleEnglishLink"]),
                                                       arabic: MyTVAPI.url(d["titleArabicLink"]),
                                                       kurdish: MyTVAPI.url(d["titleKurdishLink"])))
        }
        .sorted { $0.number < $1.number }
        episodeCache[season.id] = list
        return list
    }

    // MARK: Catalogue fetch

    nonisolated private struct Catalogue: Codable, Sendable {
        var movies: [VODMovie]
        var series: [VODSeries]
        var fetchedAt: Date
    }

    /// Catalogue via the edge first (2.9 MB gzipped, ~3 s), falling back to the raw
    /// upstream (23 MB uncompressed, 30–90 s) if the edge is unreachable.
    nonisolated private static func fetchCatalogue() async throws -> Catalogue {
        do {
            return try await fetchFromEdge()
        } catch {
            Log.playlist.notice("VOD: edge failed (\(error.localizedDescription, privacy: .public)); trying upstream")
            return try await fetchFromUpstream()
        }
    }

    /// The Cloudflare Worker's payload is already shaped like our models, so this
    /// is a straight Codable decode — no dictionary walking.
    nonisolated private static func fetchFromEdge() async throws -> Catalogue {
        var req = URLRequest(url: MyTVAPI.edgeCatalogue, timeoutInterval: 30)
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let t0 = Date()
        let (data, resp) = try await MyTVAPI.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        Log.playlist.info("VOD: edge catalogue \(data.count / 1024) KB in \(Int(Date().timeIntervalSince(t0)))s")
        struct Edge: Decodable { let movies: [VODMovie]; let series: [VODSeries] }
        let e = try JSONDecoder().decode(Edge.self, from: data)
        guard e.movies.count > 100 else { throw URLError(.cannotParseResponse) }
        return Catalogue(movies: e.movies, series: e.series, fetchedAt: .now)
    }

    nonisolated private static func fetchFromUpstream() async throws -> Catalogue {
        async let m: [[String: Any]] = MyTVAPI.post(.movies)
        async let s: [[String: Any]] = MyTVAPI.post(.series)
        let (rawMovies, rawSeries) = try await (m, s)

        let movies = rawMovies.compactMap { d -> VODMovie? in
            guard let id = MyTVAPI.str(d["id"]), let stream = MyTVAPI.url(d["link"]) else { return nil }
            return VODMovie(
                id: id,
                title: MyTVAPI.str(d["name"]) ?? "",
                category: MyTVAPI.str(d["packageName"]) ?? "",
                year: MyTVAPI.str(d["year"]) ?? "",
                duration: MyTVAPI.str(d["duration"]) ?? "",
                rating: MyTVAPI.str(d["rating"]) ?? "",
                age: MyTVAPI.str(d["age"]) ?? "",
                description: MyTVAPI.str(d["description"]) ?? "",
                director: MyTVAPI.str(d["director"]) ?? "",
                stars: MyTVAPI.str(d["stars"]) ?? "",
                poster: MyTVAPI.url(d["logoV2"]),
                backdrop: MyTVAPI.url(d["imageInsideV2"]),
                stream: stream,
                trailer: MyTVAPI.url(d["trailerLink"]),
                subtitles: SubtitleLinks(english: MyTVAPI.url(d["titleEnglishLink"]),
                                         arabic: MyTVAPI.url(d["titleArabicLink"]),
                                         kurdish: MyTVAPI.url(d["titleKurdishLink"])))
        }
        let series = rawSeries.compactMap { d -> VODSeries? in
            guard let id = MyTVAPI.str(d["id"]) else { return nil }
            return VODSeries(id: id,
                             title: MyTVAPI.str(d["name"]) ?? "",
                             category: MyTVAPI.str(d["seriesName"]) ?? "",
                             seasons: Int(MyTVAPI.str(d["numberOfSeasons"]) ?? "") ?? 0,
                             rating: MyTVAPI.str(d["rating"]) ?? "",
                             age: MyTVAPI.str(d["age"]) ?? "",
                             poster: MyTVAPI.url(d["logoV2"]))
        }
        guard movies.count > 100 else { throw URLError(.cannotParseResponse) }
        return Catalogue(movies: movies, series: series, fetchedAt: .now)
    }

    // MARK: Disk cache

    nonisolated private static func readCache() async -> Catalogue? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: cacheURL) else { return nil }
            return try? JSONDecoder().decode(Catalogue.self, from: data)
        }.value
    }

    nonisolated private static func writeCache(_ c: Catalogue) async {
        await Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(c) { try? data.write(to: cacheURL, options: .atomic) }
        }.value
    }
}

// MARK: - Upstream client

/// Thin client for the MyTV+ Android API. Responses are plain JSON or the
/// AES-CBC blob `MyTVService` already decrypts, depending on region.
nonisolated enum MyTVAPI {
    enum Endpoint: Sendable {
        case movies, series, seasons, episodes
        nonisolated var url: URL {
            switch self {
            case .movies:   URL(string: "https://androidapi.appmytv.com/android/v2/movies/getMoviesDetail_local.php")!
            case .series:   URL(string: "https://androidapi.appmytv.com/android/v2/series/getSeriesDetail_local.php")!
            case .seasons:  URL(string: "https://mytv-plus.net/android/v2/series/getSeriesSeasonDetail.php")!
            case .episodes: URL(string: "https://mytv-plus.net/android/v2/series/getSeriesEpisodeDetail.php")!
            }
        }
    }

    nonisolated static let userAgent = "And$MyTV"
    /// Cloudflare Worker that slims and gzips the catalogue (see coding/mytv-worker).
    nonisolated static let edgeCatalogue = URL(string: "https://mytv.hankus1.workers.dev/vod/catalogue")!
    nonisolated private static let base: [String: String] = [
        "appVersion": "3.15.1", "deviceType": "android",
        "uuid": "58182e46-8a20-443e-9e43-9b63bc44589c", "userId": "6414575", "country": "IQ",
    ]

    /// One session for catalogue pulls: generous resource timeout for the 22 MB movie
    /// list, gzip accepted, no cookies, and it fails fast when there's no network
    /// instead of waiting for connectivity forever.
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 180
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate", "Accept": "application/json, */*"]
        return URLSession(configuration: c)
    }()

    nonisolated static func post(_ ep: Endpoint, extra: [String: String] = [:]) async throws -> [[String: Any]] {
        var req = URLRequest(url: ep.url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: base.merging(extra) { $1 })
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let t0 = Date()
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "MyTVAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server returned \(http.statusCode)"])
        }
        Log.playlist.info("VOD: \(ep.url.lastPathComponent, privacy: .public) \(data.count / 1024) KB in \(Int(Date().timeIntervalSince(t0)))s")
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return arr }
        let plain = try MyTVService.decrypt(String(decoding: data, as: UTF8.self).trimmed)
        guard let arr = try JSONSerialization.jsonObject(with: plain) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return arr
    }

    nonisolated static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.trimmed.nilIfEmpty
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    nonisolated static func url(_ v: Any?) -> URL? {
        guard let s = str(v), s.hasPrefix("http") else { return nil }
        return URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }
}
