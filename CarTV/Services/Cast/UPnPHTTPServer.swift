import Foundation
import Network
import OSLog

/// Tiny HTTP/1.1 server for the UPnP MediaRenderer: device description, SCPDs,
/// and SOAP control for AVTransport / RenderingControl / ConnectionManager.
/// Network I/O on its own queue; state changes hop to the main actor.
final class UPnPHTTPServer: @unchecked Sendable {
    var onReady: (@MainActor (UInt16) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    private weak var receiver: CastReceiver?
    private let queue = DispatchQueue(label: "cartv.upnp.http", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(receiver: CastReceiver) { self.receiver = receiver }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if let port = l.port?.rawValue { Task { @MainActor [weak self] in self?.onReady?(port) } }
                case .failed(let e):
                    Task { @MainActor [weak self] in self?.onFailure?(e.localizedDescription) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            Task { @MainActor in onFailure?(error.localizedDescription) }
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        connections[ObjectIdentifier(c)] = c
        c.stateUpdateHandler = { [weak self, weak c] st in
            if case .failed = st, let c { self?.connections[ObjectIdentifier(c)] = nil }
            if case .cancelled = st, let c { self?.connections[ObjectIdentifier(c)] = nil }
        }
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                self.route(req, on: c)
            } else if done || error != nil || buf.count > 1_000_000 {
                c.cancel()
            } else {
                self.readRequest(c, buffer: buf)
            }
        }
    }

    private func route(_ req: HTTPRequest, on c: NWConnection) {
        let path = req.path.lowercased()
        switch (req.method, path) {
        case ("GET", "/description.xml"):
            Task { @MainActor [weak self] in
                guard let self, let r = self.receiver else { return }
                let body = UPnPXML.deviceDescription(uuid: r.uuid, name: r.deviceName)
                self.send(c, 200, body, "text/xml; charset=\"utf-8\"")
            }
        case ("GET", "/avtransport.xml"): send(c, 200, UPnPXML.avTransportSCPD, "text/xml; charset=\"utf-8\"")
        case ("GET", "/renderingcontrol.xml"): send(c, 200, UPnPXML.renderingControlSCPD, "text/xml; charset=\"utf-8\"")
        case ("GET", "/connectionmanager.xml"): send(c, 200, UPnPXML.connectionManagerSCPD, "text/xml; charset=\"utf-8\"")
        case ("POST", "/avtransport/control"), ("POST", "/renderingcontrol/control"), ("POST", "/connectionmanager/control"):
            handleSOAP(req, on: c)
        case ("SUBSCRIBE", _):
            // Minimal eventing: accept and hand back a SID; we don't push events.
            send(c, 200, "", nil, extra: ["SID": "uuid:\(UUID().uuidString.lowercased())", "TIMEOUT": "Second-1800"])
        case ("UNSUBSCRIBE", _): send(c, 200, "", nil)
        default: send(c, 404, "Not Found", "text/plain")
        }
    }

    // MARK: SOAP

    private func handleSOAP(_ req: HTTPRequest, on c: NWConnection) {
        guard let action = req.headers["soapaction"]?.split(separator: "#").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) else {
            send(c, 400, "", nil); return
        }
        let body = req.body
        let service = req.path.lowercased().contains("renderingcontrol") ? "RenderingControl" : req.path.lowercased().contains("connectionmanager") ? "ConnectionManager" : "AVTransport"
        Log.network.debug("SOAP \(service, privacy: .public)#\(action, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self, let r = self.receiver else { return }
            var args: [String: String] = [:]
            switch action {
            case "SetAVTransportURI":
                r.handleSetURI(SOAP.arg("CurrentURI", body).xmlUnescaped, metadata: SOAP.arg("CurrentURIMetaData", body).xmlUnescaped.nilIfEmpty)
            case "Play": r.handlePlay()
            case "Pause": r.handlePause()
            case "Stop": r.handleStop()
            case "Seek":
                let target = SOAP.arg("Target", body)
                r.handleSeek(seconds: SOAP.seconds(from: target))
            case "SetVolume":
                r.handleSetVolume(Int(SOAP.arg("DesiredVolume", body)) ?? 100)
            case "GetVolume": args["CurrentVolume"] = "100"
            case "GetMute": args["CurrentMute"] = "0"
            case "GetTransportInfo":
                args["CurrentTransportState"] = r.transportState
                args["CurrentTransportStatus"] = "OK"
                args["CurrentSpeed"] = "1"
            case "GetPositionInfo":
                args["Track"] = "1"
                args["TrackDuration"] = SOAP.hms(r.durationSeconds)
                args["TrackMetaData"] = ""
                args["TrackURI"] = r.currentURI.xmlEscaped
                args["RelTime"] = SOAP.hms(r.positionSeconds)
                args["AbsTime"] = SOAP.hms(r.positionSeconds)
                args["RelCount"] = "2147483647"
                args["AbsCount"] = "2147483647"
            case "GetMediaInfo":
                args["NrTracks"] = "1"
                args["MediaDuration"] = SOAP.hms(r.durationSeconds)
                args["CurrentURI"] = r.currentURI.xmlEscaped
                args["CurrentURIMetaData"] = ""
                args["NextURI"] = ""; args["NextURIMetaData"] = ""
                args["PlayMedium"] = "NETWORK"; args["RecordMedium"] = "NOT_IMPLEMENTED"; args["WriteStatus"] = "NOT_IMPLEMENTED"
            case "GetTransportSettings": args["PlayMode"] = "NORMAL"; args["RecQualityMode"] = "NOT_IMPLEMENTED"
            case "GetDeviceCapabilities": args["PlayMedia"] = "NETWORK"; args["RecMedia"] = "NOT_IMPLEMENTED"; args["RecQualityModes"] = "NOT_IMPLEMENTED"
            case "GetProtocolInfo":
                args["Source"] = ""
                args["Sink"] = UPnPXML.sinkProtocolInfo
            case "GetCurrentConnectionIDs": args["ConnectionIDs"] = "0"
            case "GetCurrentTransportActions": args["Actions"] = "Play,Pause,Stop,Seek"
            case "SetNextAVTransportURI", "Next", "Previous", "SetPlayMode", "SetMute": break
            default:
                self.send(c, 500, SOAP.fault(401, "Invalid Action"), "text/xml; charset=\"utf-8\"", extra: ["EXT": ""])
                return
            }
            self.send(c, 200, SOAP.response(service: service, action: action, args: args), "text/xml; charset=\"utf-8\"", extra: ["EXT": ""])
        }
    }

    // MARK: Response

    private func send(_ c: NWConnection, _ status: Int, _ body: String, _ contentType: String?, extra: [String: String] = [:]) {
        let reason: String = switch status { case 200: "OK"; case 400: "Bad Request"; case 404: "Not Found"; case 500: "Internal Server Error"; default: "OK" }
        let data = body.data(using: .utf8) ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\nServer: CarTV/1.0 UPnP/1.0\r\nDate: \(SSDPResponder.httpDate())\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = head.data(using: .utf8)!
        out.append(data)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - HTTP parsing

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: String

    nonisolated static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ")
        guard request.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let c = l.firstIndex(of: ":") { headers[String(l[..<c]).lowercased()] = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyData = data[sep.upperBound...]
        guard bodyData.count >= length else { return nil }
        return HTTPRequest(method: String(request[0]).uppercased(), path: String(request[1]), headers: headers, body: String(data: bodyData.prefix(length), encoding: .utf8) ?? "")
    }
}

// MARK: - SOAP helpers

enum SOAP {
    nonisolated static func arg(_ name: String, _ body: String) -> String {
        guard let open = body.range(of: "<\(name)"), let gt = body.range(of: ">", range: open.upperBound..<body.endIndex),
              let close = body.range(of: "</\(name)>", range: gt.upperBound..<body.endIndex) else { return "" }
        return String(body[gt.upperBound..<close.lowerBound])
    }
    nonisolated static func response(service: String, action: String, args: [String: String]) -> String {
        let inner = args.map { "<\($0.key)>\($0.value)</\($0.key)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(inner)</u:\(action)Response></s:Body></s:Envelope>
        """
    }
    nonisolated static func fault(_ code: Int, _ desc: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode><errorDescription>\(desc)</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """
    }
    nonisolated static func hms(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00:00" }
        let s = Int(t); return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    nonisolated static func seconds(from hms: String) -> TimeInterval {
        let parts = hms.split(separator: ":").compactMap { Double($0) }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}

// MARK: - XML documents

enum UPnPXML {
    nonisolated static let sinkProtocolInfo = [
        "http-get:*:video/mp4:*", "http-get:*:video/x-matroska:*", "http-get:*:video/webm:*", "http-get:*:video/quicktime:*",
        "http-get:*:video/x-msvideo:*", "http-get:*:video/mpeg:*", "http-get:*:video/MP2T:*", "http-get:*:video/vnd.dlna.mpeg-tts:*",
        "http-get:*:application/vnd.apple.mpegurl:*", "http-get:*:application/x-mpegURL:*", "http-get:*:video/*:*",
        "http-get:*:audio/mpeg:*", "http-get:*:audio/mp4:*", "http-get:*:audio/aac:*", "http-get:*:audio/*:*", "http-get:*:*:*"
    ].joined(separator: ",")

    nonisolated static func deviceDescription(uuid: String, name: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
        <specVersion><major>1</major><minor>0</minor></specVersion>
        <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>\(name.xmlEscaped)</friendlyName>
        <manufacturer>Kurdsoft</manufacturer>
        <manufacturerURL>https://kurdsoft.dev</manufacturerURL>
        <modelDescription>CarTV cast receiver</modelDescription>
        <modelName>CarTV</modelName>
        <modelNumber>1</modelNumber>
        <UDN>uuid:\(uuid)</UDN>
        <dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">DMR-1.50</dlna:X_DLNADOC>
        <serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><SCPDURL>/avtransport.xml</SCPDURL><controlURL>/avtransport/control</controlURL><eventSubURL>/avtransport/event</eventSubURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId><SCPDURL>/renderingcontrol.xml</SCPDURL><controlURL>/renderingcontrol/control</controlURL><eventSubURL>/renderingcontrol/event</eventSubURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><SCPDURL>/connectionmanager.xml</SCPDURL><controlURL>/connectionmanager/control</controlURL><eventSubURL>/connectionmanager/event</eventSubURL></service>
        </serviceList>
        </device>
        </root>
        """
    }

    nonisolated private static func scpd(_ actions: [(String, [(String, String, String)])], vars: [(String, String)]) -> String {
        let a = actions.map { name, args in
            "<action><name>\(name)</name><argumentList>" + args.map { "<argument><name>\($0.0)</name><direction>\($0.1)</direction><relatedStateVariable>\($0.2)</relatedStateVariable></argument>" }.joined() + "</argumentList></action>"
        }.joined()
        let v = vars.map { "<stateVariable sendEvents=\"no\"><name>\($0.0)</name><dataType>\($0.1)</dataType></stateVariable>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>\(a)</actionList><serviceStateTable>\(v)</serviceStateTable></scpd>"
    }

    nonisolated static let avTransportSCPD = scpd([
        ("SetAVTransportURI", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("CurrentURI","in","AVTransportURI"),("CurrentURIMetaData","in","AVTransportURIMetaData")]),
        ("Play", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Speed","in","TransportPlaySpeed")]),
        ("Pause", [("InstanceID","in","A_ARG_TYPE_InstanceID")]),
        ("Stop", [("InstanceID","in","A_ARG_TYPE_InstanceID")]),
        ("Seek", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Unit","in","A_ARG_TYPE_SeekMode"),("Target","in","A_ARG_TYPE_SeekTarget")]),
        ("GetTransportInfo", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("CurrentTransportState","out","TransportState"),("CurrentTransportStatus","out","TransportStatus"),("CurrentSpeed","out","TransportPlaySpeed")]),
        ("GetPositionInfo", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Track","out","CurrentTrack"),("TrackDuration","out","CurrentTrackDuration"),("TrackMetaData","out","CurrentTrackMetaData"),("TrackURI","out","CurrentTrackURI"),("RelTime","out","RelativeTimePosition"),("AbsTime","out","AbsoluteTimePosition"),("RelCount","out","RelativeCounterPosition"),("AbsCount","out","AbsoluteCounterPosition")]),
        ("GetMediaInfo", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("NrTracks","out","NumberOfTracks"),("MediaDuration","out","CurrentMediaDuration"),("CurrentURI","out","AVTransportURI"),("CurrentURIMetaData","out","AVTransportURIMetaData"),("NextURI","out","NextAVTransportURI"),("NextURIMetaData","out","NextAVTransportURIMetaData"),("PlayMedium","out","PlaybackStorageMedium"),("RecordMedium","out","RecordStorageMedium"),("WriteStatus","out","RecordMediumWriteStatus")]),
        ("GetCurrentTransportActions", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Actions","out","CurrentTransportActions")]),
    ], vars: [("TransportState","string"),("TransportStatus","string"),("TransportPlaySpeed","string"),("AVTransportURI","string"),("AVTransportURIMetaData","string"),("CurrentTrack","ui4"),("CurrentTrackDuration","string"),("CurrentTrackMetaData","string"),("CurrentTrackURI","string"),("RelativeTimePosition","string"),("AbsoluteTimePosition","string"),("RelativeCounterPosition","i4"),("AbsoluteCounterPosition","i4"),("NumberOfTracks","ui4"),("CurrentMediaDuration","string"),("NextAVTransportURI","string"),("NextAVTransportURIMetaData","string"),("PlaybackStorageMedium","string"),("RecordStorageMedium","string"),("RecordMediumWriteStatus","string"),("CurrentTransportActions","string"),("A_ARG_TYPE_InstanceID","ui4"),("A_ARG_TYPE_SeekMode","string"),("A_ARG_TYPE_SeekTarget","string")])

    nonisolated static let renderingControlSCPD = scpd([
        ("SetVolume", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Channel","in","A_ARG_TYPE_Channel"),("DesiredVolume","in","Volume")]),
        ("GetVolume", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Channel","in","A_ARG_TYPE_Channel"),("CurrentVolume","out","Volume")]),
        ("SetMute", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Channel","in","A_ARG_TYPE_Channel"),("DesiredMute","in","Mute")]),
        ("GetMute", [("InstanceID","in","A_ARG_TYPE_InstanceID"),("Channel","in","A_ARG_TYPE_Channel"),("CurrentMute","out","Mute")]),
    ], vars: [("Volume","ui2"),("Mute","boolean"),("A_ARG_TYPE_InstanceID","ui4"),("A_ARG_TYPE_Channel","string")])

    nonisolated static let connectionManagerSCPD = scpd([
        ("GetProtocolInfo", [("Source","out","SourceProtocolInfo"),("Sink","out","SinkProtocolInfo")]),
        ("GetCurrentConnectionIDs", [("ConnectionIDs","out","CurrentConnectionIDs")]),
    ], vars: [("SourceProtocolInfo","string"),("SinkProtocolInfo","string"),("CurrentConnectionIDs","string")])
}
