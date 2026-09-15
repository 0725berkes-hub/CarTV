import Foundation
import Network
import OSLog

/// Minimal loopback HTTP server that hands AVPlayer our generated HLS playlists.
/// AVPlayer stalls on `file://` playlists whose segments are `https://`; serving the
/// playlists over http://127.0.0.1 keeps every URL in the chain network-scheme.
nonisolated final class LocalPlaylistServer: @unchecked Sendable {
    static let shared = LocalPlaylistServer()

    private let queue = DispatchQueue(label: "cartv.hls.server", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let lock = NSLock()
    private var started = false

    private init() {}

    /// Starts once; returns the base URL (http://127.0.0.1:PORT/).
    func start() async throws -> URL {
        lock.lock()
        if started, port != 0 { let p = port; lock.unlock(); return URL(string: "http://127.0.0.1:\(p)/")! }
        lock.unlock()

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .loopback
                let l = try NWListener(using: params)
                l.stateUpdateHandler = { [weak self] st in
                    guard let self, !resumed else { return }
                    switch st {
                    case .ready:
                        if let p = l.port?.rawValue {
                            self.lock.lock(); self.port = p; self.started = true; self.lock.unlock()
                            resumed = true
                            Log.player.info("HLS server on 127.0.0.1:\(p)")
                            cont.resume(returning: URL(string: "http://127.0.0.1:\(p)/")!)
                        }
                    case .failed(let e): resumed = true; cont.resume(throwing: e)
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] c in self?.serve(c) }
                l.start(queue: queue)
                listener = l
            } catch { cont.resume(throwing: error) }
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let line = head.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { self.respond(c, 400, Data(), "text/plain"); return }
            let path = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            // Path: /<videoID>/<file>.m3u8 → HLSBuilder.root/<videoID>/<file>.m3u8
            let comps = path.split(separator: "/").map(String.init)
            guard comps.count == 2, !comps[0].contains(".."), comps[1].hasSuffix(".m3u8") else { self.respond(c, 404, Data(), "text/plain"); return }
            let file = HLSBuilder.root.appending(path: comps[0]).appending(path: comps[1])
            guard let body = try? Data(contentsOf: file) else { self.respond(c, 404, Data(), "text/plain"); return }
            self.respond(c, 200, body, "application/vnd.apple.mpegurl")
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ body: Data, _ type: String) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
