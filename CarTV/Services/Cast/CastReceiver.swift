import Foundation
import Network
import UIKit
import OSLog
import Observation

/// Makes this iPhone show up as a DLNA / UPnP MediaRenderer ("CarTV (iPhone)") so
/// any app with a Cast button can send it a video URL. We then play that URL
/// through the normal `PlaybackController`, which puts it on the car screen.
///
/// Pieces: `SSDPResponder` answers M-SEARCH on 239.255.255.250:1900 and sends
/// periodic NOTIFY; `UPnPHTTPServer` serves the device/service XML and handles
/// SOAP actions on a random TCP port.
@Observable
final class CastReceiver {
    enum State: Equatable { case off, starting, ready(name: String), failed(String) }

    private(set) var state: State = .off
    private(set) var lastCastTitle: String?
    private(set) var isCasting = false

    let uuid: String
    var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "cast.deviceName"); if case .ready = state { restart() } }
    }

    private let playback: PlaybackController
    private var http: UPnPHTTPServer?
    private var ssdp: SSDPResponder?
    private(set) var port: UInt16 = 0

    init(playback: PlaybackController) {
        self.playback = playback
        let defaults = UserDefaults.standard
        if let u = defaults.string(forKey: "cast.uuid") { uuid = u } else {
            let u = UUID().uuidString.lowercased(); defaults.set(u, forKey: "cast.uuid"); uuid = u
        }
        deviceName = defaults.string(forKey: "cast.deviceName") ?? "CarTV (\(UIDevice.current.name))"
    }

    func start() {
        guard state == .off || { if case .failed = state { return true }; return false }() else { return }
        state = .starting
        let server = UPnPHTTPServer(receiver: self)
        server.onReady = { [weak self] port in
            guard let self else { return }
            self.port = port
            let responder = SSDPResponder(uuid: self.uuid, httpPort: port)
            responder.start()
            self.ssdp = responder
            self.state = .ready(name: self.deviceName)
            Log.network.info("Cast receiver ready on :\(port)")
        }
        server.onFailure = { [weak self] msg in self?.state = .failed(msg) }
        server.start()
        http = server
    }

    func stop() {
        ssdp?.stop(); ssdp = nil
        http?.stop(); http = nil
        state = .off
    }

    private func restart() { stop(); start() }

    // MARK: Called from the HTTP server (main actor)

    func handleSetURI(_ uri: String, metadata: String?) {
        let title = DIDLParser.title(from: metadata) ?? URL(string: uri)?.lastPathComponent ?? String(localized: "Cast")
        lastCastTitle = title
        guard let url = URL(string: uri) else { return }
        let item = PlayableItem(castURL: url, title: title, artwork: DIDLParser.albumArt(from: metadata))
        isCasting = true
        playback.play(item, queue: [item], origin: .car, resume: false)
    }
    func handlePlay() { if playback.current != nil { playback.resume() } }
    func handlePause() { playback.pause() }
    func handleStop() { isCasting = false; playback.stop() }
    func handleSeek(seconds: TimeInterval) { playback.seek(to: seconds) }
    func handleSetVolume(_ v: Int) { SystemVolume.set(Float(v) / 100) }

    /// Snapshot for GetPositionInfo / GetTransportInfo.
    var transportState: String {
        switch playback.snapshot.state {
        case .playing: "PLAYING"
        case .paused: "PAUSED_PLAYBACK"
        case .loading, .buffering: "TRANSITIONING"
        case .idle, .ended, .failed: "STOPPED"
        }
    }
    var positionSeconds: TimeInterval { playback.snapshot.position }
    var durationSeconds: TimeInterval { playback.snapshot.duration }
    var currentURI: String { playback.current?.url.absoluteString ?? "" }
}

extension PlayableItem {
    /// A cast item: no library record, plays straight from the URL.
    init(castURL url: URL, title: String, artwork: URL?) {
        self.init(
            ref: PlayableRef(id: UUID(), kind: .channel),
            title: title,
            subtitle: String(localized: "Cast"),
            url: url,
            artworkURL: artwork,
            headers: [:],
            genre: nil,
            isLive: false,
            duration: 0,
            streamKind: StreamKind.detect(from: url)
        )
    }
}

/// Minimal DIDL-Lite reader — just the fields we surface.
enum DIDLParser {
    nonisolated static func title(from xml: String?) -> String? { tag("dc:title", in: xml) }
    nonisolated static func albumArt(from xml: String?) -> URL? { tag("upnp:albumArtURI", in: xml).flatMap(URL.init) }
    nonisolated private static func tag(_ name: String, in xml: String?) -> String? {
        guard let xml, let r = xml.range(of: "<\(name)"), let close = xml.range(of: ">", range: r.upperBound..<xml.endIndex),
              let end = xml.range(of: "</\(name)>", range: close.upperBound..<xml.endIndex) else { return nil }
        return String(xml[close.upperBound..<end.lowerBound]).xmlUnescaped.trimmed.nilIfEmpty
    }
}

extension String {
    nonisolated var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    nonisolated var xmlUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// System volume via MPVolumeView's hidden slider (the only sanctioned route).
enum SystemVolume {
    static func set(_ value: Float) {
        let v = MPVolumeViewHolder.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { v.slider?.setValue(value, animated: false) }
    }
}
import MediaPlayer
final class MPVolumeViewHolder {
    static let shared = MPVolumeViewHolder()
    let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
    var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }
    private init() {
        view.isHidden = false; view.alpha = 0.01
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.addSubview(view)
    }
}
