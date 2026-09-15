import Foundation
import JavaScriptCore
import OSLog

/// Solves YouTube's `n` and `sig` stream-URL challenges the way yt-dlp does:
/// the player's own `base.js` is run through the EJS solver (vendored in
/// Resources/YouTube/ytsolver.js) inside JavaScriptCore. Without the `n`
/// transform Google throttles/403s the stream after the first megabytes —
/// which is what made seeking "finish" the video.
actor YTChallengeSolver {
    static let shared = YTChallengeSolver()

    struct PlayerInfo: Sendable {
        let url: URL
        let id: String
        let signatureTimestamp: Int
    }

    private var playerInfo: PlayerInfo?
    private var playerJS: [String: String] = [:]          // player id → base.js
    private var preprocessed: [String: String] = [:]      // player id → EJS preprocessed player
    private var nCache: [String: String] = [:]
    private var sigCache: [String: String] = [:]
    private var playerFetchedAt: Date = .distantPast

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()
    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

    // MARK: Player discovery

    /// Current player script URL + signature timestamp (cached ~1h).
    func player() async throws -> PlayerInfo {
        if let p = playerInfo, Date().timeIntervalSince(playerFetchedAt) < 3600 { return p }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        // https:\/\/www.youtube.com\/s\/player\/8c3fda2d\/www-widgetapi.vflset\/www-widgetapi.js
        guard let r = text.range(of: #"player\\/([0-9a-f]{8})\\/"#, options: .regularExpression) else {
            throw YTError.parse("player id not found")
        }
        let id = String(text[r]).replacingOccurrences(of: #"player\/"#, with: "").replacingOccurrences(of: #"\/"#, with: "")
        let url = URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!
        let js = try await fetchPlayerJS(id: id, url: url)
        let sts = Self.signatureTimestamp(in: js) ?? 20140
        let info = PlayerInfo(url: url, id: id, signatureTimestamp: sts)
        playerInfo = info
        playerFetchedAt = .now
        Log.network.info("YT player \(id, privacy: .public) sts=\(sts)")
        return info
    }

    private func fetchPlayerJS(id: String, url: URL) async throws -> String {
        if let js = playerJS[id] { return js }
        var req = URLRequest(url: url)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let js = String(decoding: data, as: UTF8.self)
        guard js.count > 100_000 else { throw YTError.parse("player js too small") }
        playerJS = [id: js]          // keep only the current player in memory
        preprocessed = [:]
        return js
    }

    nonisolated private static func signatureTimestamp(in js: String) -> Int? {
        guard let r = js.range(of: #"signatureTimestamp:(\d+)"#, options: .regularExpression) else { return nil }
        return Int(js[r].split(separator: ":").last ?? "")
    }

    // MARK: Embedded player context

    struct EmbedContext: Sendable {
        let clientVersion: String
        let visitorData: String?
        let client: [String: String]          // full INNERTUBE_CONTEXT.client from the embed page
        let encryptedContext: String
        let encryptedHostFlags: String?
    }

    /// The embed page carries an `embeddedPlayerEncryptedContext`; without it the
    /// WEB_EMBEDDED_PLAYER `/player` call answers "This video is unavailable" (152-18).
    func embedContext(videoID: String) async throws -> EmbedContext {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1")!)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        req.setValue("PREF=hl=en&tz=UTC; SOCS=CAI", forHTTPHeaderField: "Cookie")
        req.setValue("en-us,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await session.data(for: req)
        let html = String(decoding: data, as: UTF8.self)

        func capture(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
        guard let ctxJSON = capture(#""INNERTUBE_CONTEXT":(\{.*?\}),"INNERTUBE_CONTEXT_CLIENT_NAME""#),
              let ctxData = ctxJSON.data(using: .utf8),
              let ctx = try? JSONSerialization.jsonObject(with: ctxData) as? [String: Any],
              let clientAny = ctx["client"] as? [String: Any],
              let epc = capture(#""embeddedPlayerEncryptedContext":"([^"]+)""#) else {
            throw YTError.parse("embed context not found")
        }
        var client: [String: String] = [:]
        for (k, v) in clientAny {
            if let s = v as? String { client[k] = s }
            else if let n = v as? NSNumber { client[k] = n.stringValue }
        }
        // Numeric field must stay numeric; drop and let the caller set it.
        client.removeValue(forKey: "utcOffsetMinutes")
        let version = client["clientVersion"] ?? "2.20260914.00.00"
        return EmbedContext(clientVersion: version, visitorData: client["visitorData"], client: client,
                            encryptedContext: epc, encryptedHostFlags: capture(#""encryptedHostFlags":"([^"]+)""#))
    }

    // MARK: Solving

    /// Returns the `n` → transformed map and `s` → signature map for the given challenges.
    func solve(n: [String], sig: [String]) async throws -> (n: [String: String], sig: [String: String]) {
        var nOut: [String: String] = [:], sOut: [String: String] = [:]
        var nNeed: [String] = [], sNeed: [String] = []
        for c in Set(n) { if let v = nCache[c] { nOut[c] = v } else { nNeed.append(c) } }
        for c in Set(sig) { if let v = sigCache[c] { sOut[c] = v } else { sNeed.append(c) } }
        guard !nNeed.isEmpty || !sNeed.isEmpty else { return (nOut, sOut) }

        let info = try await player()
        let js = try await fetchPlayerJS(id: info.id, url: info.url)

        var requests: [[String: Any]] = []
        if !nNeed.isEmpty { requests.append(["type": "n", "challenges": nNeed]) }
        if !sNeed.isEmpty { requests.append(["type": "sig", "challenges": sNeed]) }
        var input: [String: Any] = ["requests": requests]
        if let pre = preprocessed[info.id] {
            input["type"] = "preprocessed"; input["preprocessed_player"] = pre
        } else {
            input["type"] = "player"; input["player"] = js; input["output_preprocessed"] = true
        }

        let result = try Self.runSolver(input: input)
        if let pre = result["preprocessed_player"] as? String { preprocessed[info.id] = pre }
        guard let responses = result["responses"] as? [[String: Any]] else { throw YTError.parse("solver: no responses") }
        for (req, resp) in zip(requests, responses) {
            guard resp["type"] as? String == "result", let data = resp["data"] as? [String: String] else {
                Log.network.error("YT solver error: \(String(describing: resp["error"]), privacy: .public)")
                continue
            }
            if req["type"] as? String == "n" { for (k, v) in data { nCache[k] = v; nOut[k] = v } }
            else { for (k, v) in data { sigCache[k] = v; sOut[k] = v } }
        }
        return (nOut, sOut)
    }

    nonisolated private static func runSolver(input: [String: Any]) throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "ytsolver", withExtension: "js"),
              let solver = try? String(contentsOf: url, encoding: .utf8) else {
            throw YTError.parse("ytsolver.js missing from bundle")
        }
        guard let ctx = JSContext() else { throw YTError.parse("JSContext") }
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() }
        ctx.evaluateScript(solver)
        if let jsError { throw YTError.parse("solver load: \(jsError)") }
        let payload = try JSONSerialization.data(withJSONObject: input)
        ctx.setObject(String(decoding: payload, as: UTF8.self), forKeyedSubscript: "__ytInput" as NSString)
        let started = Date()
        let out = ctx.evaluateScript("JSON.stringify(jsc(JSON.parse(__ytInput)))")
        if let jsError { throw YTError.parse("solver run: \(jsError)") }
        guard let s = out?.toString(), let data = s.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTError.parse("solver: bad output")
        }
        if obj["type"] as? String == "error" { throw YTError.parse("solver: \(obj["error"] ?? "unknown")") }
        Log.network.info("YT challenges solved in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return obj
    }

    // MARK: URL rewriting

    /// Applies `n` and (if present) `sig` solutions to a format's URL / signatureCipher.
    nonisolated static func nParam(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "n" }?.value
    }

    nonisolated static func replacing(url: URL, n: String?, nSolved: String?) -> URL {
        guard let n, let nSolved, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = comps.queryItems?.map { $0.name == "n" && $0.value == n ? URLQueryItem(name: "n", value: nSolved) : $0 }
        return comps.url ?? url
    }

    /// signatureCipher = "s=<sig>&sp=<param>&url=<encoded url>"
    nonisolated static func parseCipher(_ cipher: String) -> (s: String, sp: String, url: URL)? {
        var comps = URLComponents(); comps.percentEncodedQuery = cipher
        let items = comps.queryItems ?? []
        guard let s = items.first(where: { $0.name == "s" })?.value,
              let u = items.first(where: { $0.name == "url" })?.value, let url = URL(string: u) else { return nil }
        return (s, items.first(where: { $0.name == "sp" })?.value ?? "signature", url)
    }

    nonisolated static func appending(url: URL, param: String, value: String) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: param, value: value)]
        return comps.url ?? url
    }
}
