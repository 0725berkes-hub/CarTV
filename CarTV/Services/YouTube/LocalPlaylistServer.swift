import Foundation
import Network
import OSLog

/// Minimal loopback HTTP server that hands AVPlayer our generated HLS playlists.
/// AVPlayer stalls on `file://` playlists whose segments are `https://`; serving the
/// playlists over http://127.0.0.1 keeps every URL in the chain network-scheme.
actor LocalPlaylistServer {
    static let shared = LocalPlaylistServer()

    private let queue = DispatchQueue(label: "cartv.hls.server", qos: .userInitiated)
    private var listener: NWListener?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?

    private init() {}

    /// Starts once; returns the base URL (http://127.0.0.1:PORT/).
    func start() async throws -> URL {
        if let baseURL { return baseURL }
        if let starting { return try await starting.value }
        let task = Task<URL, Error> { try await self.listen() }
        starting = task
        do {
            let url = try await task.value
            baseURL = url
            starting = nil
            return url
        } catch {
            starting = nil
            throw error
        }
    }

    private func listen() async throws -> URL {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        listener = l
        let box = ContinuationBox()
        l.stateUpdateHandler = { st in
            switch st {
            case .ready:
                if let p = l.port?.rawValue {
                    Log.player.info("HLS server on 127.0.0.1:\(p)")
                    box.resume(.success(URL(string: "http://127.0.0.1:\(p)/")!))
                }
            case .failed(let e): box.resume(.failure(e))
            default: break
            }
        }
        l.newConnectionHandler = { c in LocalPlaylistServer.serve(c, on: self.queue) }
        l.start(queue: queue)
        return try await withCheckedThrowingContinuation { box.set($0) }
    }

    nonisolated private static func serve(_ c: NWConnection, on queue: DispatchQueue) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            guard let data, let head = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let line = head.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { respond(c, 400, Data(), "text/plain"); return }
            let path = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            let comps = path.split(separator: "/").map(String.init)
            guard comps.count == 2, !comps[0].contains(".."), comps[1].hasSuffix(".m3u8") else { respond(c, 404, Data(), "text/plain"); return }
            let file = HLSBuilder.root.appending(path: comps[0]).appending(path: comps[1])
            guard let body = try? Data(contentsOf: file) else { respond(c, 404, Data(), "text/plain"); return }
            respond(c, 200, body, "application/vnd.apple.mpegurl")
        }
    }

    nonisolated private static func respond(_ c: NWConnection, _ status: Int, _ body: Data, _ type: String) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// One-shot continuation holder that's safe to resume from a Network.framework callback.
private final class ContinuationBox: @unchecked Sendable {
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
