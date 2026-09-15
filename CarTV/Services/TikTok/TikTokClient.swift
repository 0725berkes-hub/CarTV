import Foundation
import OSLog

/// tiktok.com web API, the same calls the site makes in your browser. Read-only.
///
/// Every request: your cookies, desktop Safari UA, tiktok.com Referer, and an
/// `X-Bogus` signature over the query. The FYP returns your personalised feed
/// because the session is yours.
nonisolated final class TikTokClient: Sendable {

    enum Failure: LocalizedError {
        case signedOut, emptyBody, http(Int), parse, rateLimited
        var errorDescription: String? {
            switch self {
            case .signedOut:   String(localized: "Sign in to TikTok first")
            case .emptyBody:   String(localized: "TikTok returned nothing — signature or session may be stale")
            case .http(let c): String(localized: "TikTok returned \(c)")
            case .parse:       String(localized: "Couldn't read TikTok's response")
            case .rateLimited: String(localized: "Too many requests — try again in a minute")
            }
        }
    }

    private let session: TTSession
    private let http: URLSession
    private let base = URL(string: "https://www.tiktok.com/api/")!

    init(session: TTSession) {
        self.session = session
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil            // we manage the Cookie header ourselves
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 25
        c.httpAdditionalHeaders = [
            "User-Agent": TTSession.userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://www.tiktok.com/",
        ]
        http = URLSession(configuration: c)
    }

    // MARK: Feeds

    /// For You. Each call returns a fresh batch; TikTok's cursor is a formality.
    func forYou(count: Int = 12) async throws -> TTFeedPage {
        let d = try await get("recommend/item_list/", [
            "count": "\(count)", "coverFormat": "2", "from_page": "fyp", "pullType": "0",
            "isNonPersonalized": "false", "user_is_login": "true", "vv_count_fyp": "0",
            "showAboutThisAd": "true", "showAds": "false", "history_len": "3",
        ])
        return page(d)
    }

    /// Following feed (people you follow).
    func following(count: Int = 12, cursor: Int = 0) async throws -> TTFeedPage {
        let d = try await get("recommend/item_list/", [
            "count": "\(count)", "coverFormat": "2", "from_page": "following", "pullType": "0",
            "user_is_login": "true", "cursor": "\(cursor)",
        ])
        return page(d)
    }

    /// A creator's posts.
    func userPosts(secUID: String, count: Int = 30, cursor: Int = 0) async throws -> (TTFeedPage, nextCursor: Int) {
        let d = try await get("post/item_list/", [
            "secUid": secUID, "count": "\(count)", "cursor": "\(cursor)", "coverFormat": "2",
        ])
        return (page(d), TTParser.int(d["cursor"]))
    }

    /// Video search.
    func search(_ query: String, offset: Int = 0) async throws -> (TTFeedPage, nextOffset: Int) {
        let d = try await get("search/item/full/", [
            "keyword": query, "offset": "\(offset)", "search_source": "normal_search", "web_search_code": "",
        ])
        let raw = (d["item_list"] as? [[String: Any]]) ?? []
        let items = raw.compactMap(TTParser.video)
        return (TTFeedPage(items: items, hasMore: d["has_more"] as? Bool ?? (TTParser.int(d["has_more"]) == 1)),
                TTParser.int(d["cursor"]))
    }

    /// Who am I — for the sign-in confirmation and the handle in the UI.
    func me() async throws -> (handle: String, nickname: String, avatar: URL?) {
        let d = try await get("user/detail/", ["uniqueId": "", "secUid": ""], allowEmpty: true)
        let user = (d["userInfo"] as? [String: Any])?["user"] as? [String: Any]
        guard let h = TTParser.str(user?["uniqueId"]) else {
            // Fall back to the odin id from cookies; the feed still works.
            let odin = await MainActor.run { session.odinID }
            return (odin ?? "me", "", nil)
        }
        return (h, TTParser.str(user?["nickname"]) ?? h, TTParser.url(user?["avatarMedium"]))
    }

    // MARK: Request

    private func page(_ d: [String: Any]) -> TTFeedPage {
        let raw = (d["itemList"] as? [[String: Any]]) ?? []
        return TTFeedPage(items: raw.compactMap(TTParser.video), hasMore: d["hasMore"] as? Bool ?? true)
    }

    private func get(_ path: String, _ extra: [String: String], allowEmpty: Bool = false) async throws -> [String: Any] {
        let snap = await MainActor.run { session.snapshot }
        guard snap.isSignedIn else { throw Failure.signedOut }

        // The site always sends this long device/browser block; keep it identical.
        var q: [(String, String)] = [
            ("WebIdLastTime", "\(Int(Date().timeIntervalSince1970) - 86_400)"),
            ("aid", "1988"), ("app_language", "en"), ("app_name", "tiktok_web"),
            ("browser_language", "en-US"), ("browser_name", "Mozilla"), ("browser_online", "true"),
            ("browser_platform", "MacIntel"), ("browser_version", String(TTSession.userAgent.dropFirst("Mozilla/".count))),
            ("channel", "tiktok_web"), ("cookie_enabled", "true"), ("data_collection_enabled", "true"),
            ("device_platform", "web_pc"), ("focus_state", "true"), ("is_fullscreen", "false"),
            ("is_page_visible", "true"), ("language", "en"), ("os", "mac"),
            ("priority_region", ""), ("referer", ""), ("region", "US"),
            ("screen_height", "1117"), ("screen_width", "1728"), ("tz_name", "UTC"),
            ("webcast_language", "en"),
        ]
        if let odin = snap.odinID { q.append(("odinId", odin)) }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { q.append((k, v)) }
        q.append(("msToken", snap.msToken))

        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
        let query = comps.percentEncodedQuery ?? ""
        let xb = XBogus.sign(query: query, userAgent: TTSession.userAgent)
        comps.percentEncodedQuery = query + "&X-Bogus=" + xb

        var req = URLRequest(url: comps.url!)
        req.setValue(snap.cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, resp) = try await http.data(for: req)
        guard let hr = resp as? HTTPURLResponse else { throw Failure.parse }
        await MainActor.run { session.absorb(hr) }
        if hr.statusCode == 429 { throw Failure.rateLimited }
        guard (200..<300).contains(hr.statusCode) else { throw Failure.http(hr.statusCode) }
        if data.isEmpty {
            if allowEmpty { return [:] }
            Log.network.error("TikTok \(path, privacy: .public): empty body")
            throw Failure.emptyBody
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.parse }
        if let code = obj["statusCode"] as? Int, code != 0 {
            Log.network.error("TikTok \(path, privacy: .public): statusCode \(code) \(TTParser.str(obj["statusMsg"]) ?? "", privacy: .public)")
            if code == 8 || code == 10201 { throw Failure.signedOut }
        }
        return obj
    }

    // MARK: Media headers

    /// Headers AVPlayer / the downloader must send for the CDN to serve the MP4 (403 without).
    @MainActor var mediaHeaders: [String: String] {
        ["User-Agent": TTSession.userAgent, "Referer": "https://www.tiktok.com/", "Cookie": session.cookieHeader]
    }
}
