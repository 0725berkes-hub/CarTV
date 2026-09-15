import Foundation
import OSLog

/// YouTube's private API ("InnerTube"). We speak it as the official mobile
/// clients do, so stream URLs come back un-ciphered and no API key is needed.
///
/// Browsing (home, search, channel, playlist, subs, library) uses the WEB client
/// with the user's OAuth token so results are personalised. Playback uses the
/// iOS client (falls back to ANDROID → TVHTML5) because those return direct URLs.
nonisolated final class InnerTubeClient: Sendable {
    static let shared = InnerTubeClient()

    struct ClientProfile: Sendable {
        let name: String
        let version: String
        let userAgent: String
        let clientId: Int
        var sendableExtra: [String: String] = [:]
    }

    // Client identities. Versions are bumped occasionally; keep them plausible.
    static let web = ClientProfile(name: "WEB", version: "2.20250915.01.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", clientId: 1)
    static let ios = ClientProfile(name: "IOS", version: "20.36.4",
        userAgent: "com.google.ios.youtube/20.36.4 (iPhone16,2; U; CPU iOS 18_6 like Mac OS X;)", clientId: 5,
        sendableExtra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.6.0.22G86"])
    static let android = ClientProfile(name: "ANDROID", version: "20.36.35",
        userAgent: "com.google.android.youtube/20.36.35 (Linux; U; Android 14) gzip", clientId: 3,
        sendableExtra: ["androidSdkVersion": "34", "osName": "Android", "osVersion": "14"])
    static let tv = ClientProfile(name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER", version: "2.0",
        userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15", clientId: 85)

    private let session: URLSession
    private let base = URL(string: "https://www.youtube.com/youtubei/v1/")!

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: - Core request

    /// POSTs to an InnerTube endpoint and returns the raw JSON object.
    func call(_ endpoint: String, client: ClientProfile = InnerTubeClient.web, body: [String: Any] = [:], accessToken: String? = nil, visitorData: String? = nil) async throws -> JSONObject {
        var url = base.appending(path: endpoint)
        url.append(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(String(client.clientId), forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let visitorData { req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }

        var clientCtx: [String: Any] = [
            "clientName": client.name, "clientVersion": client.version,
            "hl": "en", "gl": Locale.current.region?.identifier ?? "US",
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        for (k, v) in client.sendableExtra { clientCtx[k] = v }
        if let visitorData { clientCtx["visitorData"] = visitorData }
        var payload: [String: Any] = ["context": ["client": clientCtx, "user": ["lockedSafetyMode": false], "request": ["useSsl": true]]]
        for (k, v) in body { payload[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { Log.network.error("InnerTube \(endpoint, privacy: .public) transport: \(error.localizedDescription, privacy: .public)"); throw YTError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw YTError.network("No response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            Log.network.error("InnerTube \(endpoint, privacy: .public) HTTP \(http.statusCode): \(body, privacy: .public)")
            if http.statusCode == 401 { throw YTError.unauthorized }
            throw YTError.network("HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YTError.parse("Not a JSON object") }
        Log.network.debug("InnerTube \(endpoint, privacy: .public) OK \(data.count) bytes, keys: \(obj.keys.sorted().joined(separator: ","), privacy: .public)")
        return JSONObject(obj)
    }

    // MARK: - Player (streams)

    /// Resolves playable streams. Tries iOS → ANDROID → TV until one is playable.
    func player(videoID: String, accessToken: String? = nil) async throws -> YTPlayerResponse {
        var lastError: Error = YTError.unavailable("No client succeeded")
        for client in [InnerTubeClient.ios, InnerTubeClient.android, InnerTubeClient.tv] {
            do {
                var body: [String: Any] = [
                    "videoId": videoID,
                    "contentCheckOk": true,
                    "racyCheckOk": true,
                    "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": 20140]],
                ]
                if client.name.hasPrefix("TVHTML5") {
                    body["context"] = nil
                }
                let json = try await call("player", client: client, body: body, accessToken: client.name == "IOS" ? accessToken : nil)
                let resp = try YTPlayerResponse(json: json)
                if resp.isPlayable, !resp.formats.isEmpty || resp.hlsManifestURL != nil {
                    Log.network.info("YT player OK via \(client.name, privacy: .public) for \(videoID, privacy: .public)")
                    return resp
                }
                lastError = YTError.unavailable(resp.playabilityReason ?? "Not playable")
            } catch {
                lastError = error
                Log.network.error("YT player \(client.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError
    }

    // MARK: - Browse / search / next

    func browse(_ browseId: String, params: String? = nil, continuation: String? = nil, accessToken: String? = nil) async throws -> JSONObject {
        var body: [String: Any] = [:]
        if let continuation { body["continuation"] = continuation } else {
            body["browseId"] = browseId
            if let params { body["params"] = params }
        }
        return try await call("browse", body: body, accessToken: accessToken)
    }

    func search(_ query: String, params: String? = nil, continuation: String? = nil, accessToken: String? = nil) async throws -> JSONObject {
        var body: [String: Any] = [:]
        if let continuation { body["continuation"] = continuation } else {
            body["query"] = query
            if let params { body["params"] = params }
        }
        return try await call("search", body: body, accessToken: accessToken)
    }

    /// Watch page data: related videos, comments continuation, like state.
    func next(videoID: String, playlistID: String? = nil, continuation: String? = nil, accessToken: String? = nil) async throws -> JSONObject {
        var body: [String: Any] = [:]
        if let continuation { body["continuation"] = continuation } else {
            body["videoId"] = videoID
            if let playlistID { body["playlistId"] = playlistID }
        }
        return try await call("next", body: body, accessToken: accessToken)
    }

    /// Search-as-you-type suggestions (public endpoint, not InnerTube).
    func suggestions(_ query: String) async throws -> [String] {
        var comps = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")!
        comps.queryItems = [.init(name: "client", value: "youtube"), .init(name: "ds", value: "yt"), .init(name: "q", value: query), .init(name: "hl", value: "en")]
        let (data, _) = try await session.data(from: comps.url!)
        // Response is JSONP: window.google.ac.h([...])
        guard let text = String(data: data, encoding: .utf8), let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return [] }
        let json = String(text[text.index(after: open)..<close])
        guard let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any], arr.count > 1, let items = arr[1] as? [[Any]] else { return [] }
        return items.compactMap { $0.first as? String }
    }

    // MARK: - Actions (need auth)

    func like(videoID: String, accessToken: String, remove: Bool = false) async throws {
        _ = try await call(remove ? "like/removelike" : "like/like", body: ["target": ["videoId": videoID]], accessToken: accessToken)
    }
    func dislike(videoID: String, accessToken: String) async throws {
        _ = try await call("like/dislike", body: ["target": ["videoId": videoID]], accessToken: accessToken)
    }
    func subscribe(channelID: String, accessToken: String, remove: Bool = false) async throws {
        _ = try await call(remove ? "subscription/unsubscribe" : "subscription/subscribe", body: ["channelIds": [channelID]], accessToken: accessToken)
    }
    func addToWatchLater(videoID: String, accessToken: String) async throws {
        _ = try await call("browse/edit_playlist", body: ["playlistId": "WL", "actions": [["addedVideoId": videoID, "action": "ACTION_ADD_VIDEO"]]], accessToken: accessToken)
    }
}

enum YTError: LocalizedError, Sendable {
    case network(String), parse(String), unavailable(String), unauthorized, signInRequired
    var errorDescription: String? {
        switch self {
        case .network(let s): s
        case .parse(let s): "Couldn't read YouTube's response (\(s))"
        case .unavailable(let s): s
        case .unauthorized: "YouTube sign-in expired"
        case .signInRequired: "Sign in to YouTube to see this"
        }
    }
}

// MARK: - Lightweight JSON path helper

/// Dictionary-walking helper so parsers read like the response shape:
/// `json["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array`
nonisolated struct JSONObject: @unchecked Sendable {
    /// Foundation JSON tree (NSDictionary/NSArray/NSString/NSNumber). Never mutated after parse.
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw }

    subscript(_ key: String) -> JSONObject { JSONObject((raw as? [String: Any])?[key]) }
    subscript(_ index: Int) -> JSONObject {
        guard let arr = raw as? [Any], arr.indices.contains(index) else { return JSONObject(nil) }
        return JSONObject(arr[index])
    }
    var string: String? { raw as? String }
    var int: Int? { (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init) }
    var double: Double? { (raw as? Double) ?? (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) }
    var bool: Bool? { raw as? Bool }
    var array: [JSONObject] { (raw as? [Any])?.map(JSONObject.init) ?? [] }
    var dict: [String: Any]? { raw as? [String: Any] }
    var exists: Bool { raw != nil }
    var keys: [String] { (raw as? [String: Any])?.keys.sorted() ?? [] }

    /// `runs[].text` joined, or `simpleText`.
    var text: String? {
        if let s = self["simpleText"].string { return s }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        return runs.isEmpty ? nil : runs.joined()
    }

    /// Depth-first search for the first object containing `key`.
    func find(_ key: String, maxDepth: Int = 12) -> JSONObject {
        func walk(_ node: Any?, _ depth: Int) -> Any? {
            guard depth < maxDepth else { return nil }
            if let d = node as? [String: Any] {
                if let v = d[key] { return v }
                for v in d.values { if let r = walk(v, depth + 1) { return r } }
            } else if let a = node as? [Any] {
                for v in a { if let r = walk(v, depth + 1) { return r } }
            }
            return nil
        }
        return JSONObject(walk(raw, 0))
    }

    /// All objects anywhere below that contain `key` (used to collect renderers).
    func findAll(_ key: String, maxDepth: Int = 14) -> [JSONObject] {
        var out: [JSONObject] = []
        func walk(_ node: Any?, _ depth: Int) {
            guard depth < maxDepth else { return }
            if let d = node as? [String: Any] {
                if let v = d[key] { out.append(JSONObject(v)) }
                for v in d.values { walk(v, depth + 1) }
            } else if let a = node as? [Any] {
                for v in a { walk(v, depth + 1) }
            }
        }
        walk(raw, 0)
        return out
    }
}
