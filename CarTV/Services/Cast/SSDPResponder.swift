#if DLNA_RECEIVER
import Foundation
import Network
import OSLog

/// SSDP discovery: joins 239.255.255.250:1900, answers M-SEARCH for MediaRenderer /
/// AVTransport / RenderingControl / rootdevice / ssdp:all, and multicasts NOTIFY
/// alive every 30s. Runs entirely off the main actor on its own queue.
final class SSDPResponder: @unchecked Sendable {
    private let uuid: String
    private let httpPort: UInt16
    private let queue = DispatchQueue(label: "cartv.ssdp", qos: .utility)
    private var group: NWConnectionGroup?
    private var aliveTimer: DispatchSourceTimer?
    private let mcast = NWEndpoint.hostPort(host: "239.255.255.250", port: 1900)

    init(uuid: String, httpPort: UInt16) {
        self.uuid = uuid
        self.httpPort = httpPort
    }

    func start() {
        guard let desc = try? NWMulticastGroup(for: [mcast]) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let g = NWConnectionGroup(with: desc, using: params)
        g.setReceiveHandler(maximumMessageSize: 4096, rejectOversizedMessages: true) { [weak self] message, data, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { return }
            self.handle(text, from: message)
        }
        g.stateUpdateHandler = { [weak self] st in
            Log.network.info("SSDP group state \(String(describing: st), privacy: .public)")
            if case .ready = st { self?.sendAlive(); self?.scheduleAlive() }
        }
        g.start(queue: queue)
        group = g
    }

    func stop() {
        aliveTimer?.cancel(); aliveTimer = nil
        sendByeBye()
        group?.cancel(); group = nil
    }

    // MARK: Inbound

    private func handle(_ text: String, from message: NWConnectionGroup.Message) {
        guard text.hasPrefix("M-SEARCH") else { return }
        let lower = text.lowercased()
        let st = lower.components(separatedBy: "\r\n").first { $0.hasPrefix("st:") }?.dropFirst(3).trimmingCharacters(in: .whitespaces) ?? ""
        let matches = st == "ssdp:all"
            || st == "upnp:rootdevice"
            || st.contains("mediarenderer")
            || st.contains("avtransport")
            || st.contains("renderingcontrol")
            || st.contains("connectionmanager")
            || st == "uuid:\(uuid)"
        guard matches else { return }

        let targets: [String] = st == "ssdp:all"
            ? ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1", "urn:schemas-upnp-org:service:AVTransport:1", "urn:schemas-upnp-org:service:RenderingControl:1", "urn:schemas-upnp-org:service:ConnectionManager:1"]
            : [st == "upnp:rootdevice" || st.hasPrefix("uuid:") ? st : canonical(st)]

        for t in targets {
            let usn = t == "upnp:rootdevice" ? "uuid:\(uuid)::upnp:rootdevice" : (t.hasPrefix("uuid:") ? t : "uuid:\(uuid)::\(t)")
            let response = [
                "HTTP/1.1 200 OK",
                "CACHE-CONTROL: max-age=1800",
                "DATE: \(Self.httpDate())",
                "EXT:",
                "LOCATION: \(location)",
                "SERVER: iOS/\(ProcessInfo.processInfo.operatingSystemVersionString) UPnP/1.0 CarTV/1.0",
                "ST: \(t)",
                "USN: \(usn)",
                "", ""
            ].joined(separator: "\r\n")
            message.reply(content: response.data(using: .utf8), completion: { _ in })
        }
    }

    private func canonical(_ st: String) -> String {
        if st.contains("mediarenderer") { return "urn:schemas-upnp-org:device:MediaRenderer:1" }
        if st.contains("avtransport") { return "urn:schemas-upnp-org:service:AVTransport:1" }
        if st.contains("renderingcontrol") { return "urn:schemas-upnp-org:service:RenderingControl:1" }
        if st.contains("connectionmanager") { return "urn:schemas-upnp-org:service:ConnectionManager:1" }
        return st
    }

    // MARK: Outbound NOTIFY

    private func scheduleAlive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.sendAlive() }
        t.resume()
        aliveTimer = t
    }

    private func sendAlive() { sendNotify(nts: "ssdp:alive") }
    private func sendByeBye() { sendNotify(nts: "ssdp:byebye") }

    private func sendNotify(nts: String) {
        let nts_types = ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1", "urn:schemas-upnp-org:service:AVTransport:1", "urn:schemas-upnp-org:service:RenderingControl:1", "urn:schemas-upnp-org:service:ConnectionManager:1"]
        for nt in nts_types {
            let usn = nt == "upnp:rootdevice" ? "uuid:\(uuid)::upnp:rootdevice" : "uuid:\(uuid)::\(nt)"
            let msg = [
                "NOTIFY * HTTP/1.1",
                "HOST: 239.255.255.250:1900",
                "CACHE-CONTROL: max-age=1800",
                "LOCATION: \(location)",
                "NT: \(nt)",
                "NTS: \(nts)",
                "SERVER: iOS UPnP/1.0 CarTV/1.0",
                "USN: \(usn)",
                "", ""
            ].joined(separator: "\r\n")
            group?.send(content: msg.data(using: .utf8), completion: { _ in })
        }
    }

    private var location: String { "http://\(LocalIP.current() ?? "127.0.0.1"):\(httpPort)/description.xml" }

    nonisolated static func httpDate() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"; return f.string(from: .now)
    }
}

/// Best-effort Wi-Fi IPv4 address (en0), falling back to any non-loopback IPv4.
enum LocalIP {
    nonisolated static func current() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if name != "lo0", fallback == nil, !ip.hasPrefix("169.254") { fallback = ip }
        }
        return fallback
    }
}

#endif
