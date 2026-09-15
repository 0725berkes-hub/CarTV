import Foundation
import Network
import OSLog

/// Loopback relay for TikTok MP4s. The CDN demands `Referer: https://www.tiktok.com/`
/// and the `tt_chain_token` cookie on every request, including AVFoundation's
/// byte-range probes. AVURLAsset can't reliably attach cookies to media loads
/// (that's the -1102 "no permission" you see), and VLC's `:http-cookie` is per-
/// media and flaky. So both engines play `http://127.0.0.1:PORT/tt/<token>` and
/// this relays each range request upstream with the headers the CDN wants.
///
/// Streams (doesn't buffer): the client's Range header is forwarded, the upstream
/// 206 + Content-Range + body are piped back as they arrive. Seeking is exact.
actor TTMediaProxy {
    static let shared = TTMediaProxy()

    private let queue = DispatchQueue(label: "cartv.tt.proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?

    /// token → (upstream URL, headers). Tokens are opaque so the loopback URL never
    /// leaks cookies into logs or the Now Playing metadata.
    nonisolated(unsafe) private static var routes: [String: (url: URL, headers: [String: String])] = [:]
    nonisolated private static let routesLock = NSLock()

    private init() {}

    /// Register an upstream MP4 and get a loopback URL that plays it.
    func localURL(for upstream: URL, headers: [String: String]) async throws -> URL {
        let base = try await start()
        let token = Self.token(for: upstream)
        Self.routesLock.withLock { Self.routes[token] = (upstream, headers) }
        return base.appending(path: "tt").appending(path: token)
    }

    nonisolated private static func token(for url: URL) -> String {
        // Stable per URL so re-plays hit the same route; short for tidy logs.
        var h: UInt64 = 0xcbf29ce484222325
        for b in url.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    // MARK: Server

    private func start() async throws -> URL {
        if let baseURL { return baseURL }
        if let starting { return try await starting.value }
        let task = Task<URL, Error> { try await self.listen() }
        starting = task
        do { let u = try await task.value; baseURL = u; starting = nil; return u }
        catch { starting = nil; throw error }
    }

    private func listen() async throws -> URL {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        listener = l
        let box = ProxyContinuationBox()
        l.stateUpdateHandler = { st in
            switch st {
            case .ready:
                if let p = l.port?.rawValue {
                    Log.player.info("TikTok media proxy on 127.0.0.1:\(p)")
                    box.resume(.success(URL(string: "http://127.0.0.1:\(p)/")!))
                }
            case .failed(let e): box.resume(.failure(e))
            default: break
            }
        }
        l.newConnectionHandler = { c in TTMediaProxy.serve(c, on: self.queue) }
        l.start(queue: queue)
        return try await withCheckedThrowingContinuation { box.set($0) }
    }

    // MARK: Relay

    nonisolated private static func serve(_ c: NWConnection, on queue: DispatchQueue) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            guard let data, let head = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let lines = head.components(separatedBy: "\r\n")
            let req = lines.first?.split(separator: " ") ?? []
            guard req.count >= 2, req[0] == "GET" || req[0] == "HEAD" else { respondHead(c, 400, [:], close: true); return }
            let path = String(req[1])
            guard path.hasPrefix("/tt/") else { respondHead(c, 404, [:], close: true); return }
            let token = String(path.dropFirst(4))
            guard let route = routesLock.withLock({ routes[token] }) else { respondHead(c, 404, [:], close: true); return }

            var range: String?
            for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
                range = l.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            relay(c, route: route, method: String(req[0]), range: range)
        }
    }

    /// One upstream request per client request; headers and body streamed through.
    nonisolated private static func relay(_ c: NWConnection, route: (url: URL, headers: [String: String]), method: String, range: String?) {
        var up = URLRequest(url: route.url)
        up.httpMethod = method
        route.headers.forEach { up.setValue($1, forHTTPHeaderField: $0) }
        if let range { up.setValue(range, forHTTPHeaderField: "Range") }
        up.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let delegate = RelayDelegate(connection: c)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.dataTask(with: up).resume()
    }

    nonisolated static func respondHead(_ c: NWConnection, _ status: Int, _ headers: [String: String], close: Bool) {
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in if close { c.cancel() } })
    }

    nonisolated static func statusText(_ s: Int) -> String {
        switch s { case 200: "OK"; case 206: "Partial Content"; case 403: "Forbidden"; case 404: "Not Found"; case 416: "Range Not Satisfiable"; default: "Error" }
    }
}

/// Streams an upstream response into the NWConnection as chunks arrive.
private final class RelayDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: NWConnection
    var session: URLSession?
    private var headSent = false
    private var failed = false

    init(connection: NWConnection) { self.connection = connection }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        var headers: [String: String] = [:]
        for key in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
            if let v = http.value(forHTTPHeaderField: key) { headers[key] = v }
        }
        if headers["Accept-Ranges"] == nil { headers["Accept-Ranges"] = "bytes" }
        if headers["Content-Type"] == nil { headers["Content-Type"] = "video/mp4" }
        if http.statusCode >= 400 { Log.player.error("TikTok proxy upstream \(http.statusCode)") }
        var head = "HTTP/1.1 \(http.statusCode) \(TTMediaProxy.statusText(http.statusCode))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        headSent = true
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.failed = true; dataTask.cancel() }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !failed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.failed = true; dataTask.cancel() }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !headSent { TTMediaProxy.respondHead(connection, 502, [:], close: true) }
        else { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() }) }
        session.finishTasksAndInvalidate()
    }
}

private final class ProxyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<URL, Error>?
    private var pending: Result<URL, Error>?
    func set(_ c: CheckedContinuation<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        if let p = pending { c.resume(with: p); pending = nil } else { cont = c }
    }
    func resume(_ r: Result<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        if let c = cont { cont = nil; c.resume(with: r) } else if pending == nil { pending = r }
    }
}
