import Foundation
import UIKit

enum PlayerEngineKind: String, Sendable {
    case avPlayer = "AVPlayer"
    case vlc = "VLC"
}

enum PlayerState: Sendable, Equatable {
    case idle
    case loading
    case buffering
    case playing
    case paused
    case ended
    case failed(PlayerFailure)
}

enum PlayerFailure: Sendable, Equatable, Hashable {
    case unreachable
    case unsupportedFormat
    case noContent          // live stream with no segments yet
    case authRequired
    case network(String)
    case unknown(String)

    var message: String {
        switch self {
        case .unreachable:        String(localized: "Can't connect to the server")
        case .unsupportedFormat:  String(localized: "Cannot Play")
        case .noContent:          String(localized: "Live stream has no content right now")
        case .authRequired:       String(localized: "Server refused the connection")
        case .network(let s):     s
        case .unknown(let s):     s.isEmpty ? String(localized: "Playback Failed") : s
        }
    }
}

struct MediaTrack: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let languageCode: String?
}

struct PlayerSnapshot: Sendable, Equatable {
    var state: PlayerState = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval = 0        // 0 = live / unknown
    var isSeekable = false
    var videoSize: CGSize = .zero
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioTrack: Int? = nil
    var selectedSubtitleTrack: Int? = nil
    var bufferedFraction: Double = 0
}

/// Uniform playback interface implemented by `AVPlayerEngine` and `VLCEngine`.
/// All members are main-actor; engines push updates through `onUpdate`.
@MainActor
protocol PlayerEngine: AnyObject {
    var kind: PlayerEngineKind { get }
    var snapshot: PlayerSnapshot { get }
    var onUpdate: ((PlayerSnapshot) -> Void)? { get set }

    /// Primary render view (used by the car when connected, else the phone).
    var videoView: UIView { get }
    /// A secondary view mirroring the same playback, or nil if the engine can
    /// only render to one surface (VLC). AVPlayer supports any number of layers.
    func makeMirrorView() -> UIView?
    /// True when `makeMirrorView()` returns a live mirror (AVPlayer), false for single-drawable engines.
    var makeMirrorViewSupported: Bool { get }

    func load(_ item: PlayableItem, startAt: TimeInterval?, options: PlayerOptions)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    func setRate(_ rate: Float)
    func selectAudioTrack(_ id: Int?)
    func selectSubtitleTrack(_ id: Int?)
    func addExternalSubtitle(url: URL)
    func setVideoGravity(_ gravity: VideoGravity)
}

enum VideoGravity: String, CaseIterable, Sendable {
    case fit, fill, stretch
    var next: VideoGravity {
        switch self {
        case .fit: .fill
        case .fill: .stretch
        case .stretch: .fit
        }
    }
    var symbol: String {
        switch self {
        case .fit: "arrow.down.right.and.arrow.up.left.rectangle"
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .stretch: "rectangle.expand.vertical"
        }
    }
}

struct PlayerOptions: Sendable {
    var softwareDecoding = false
    var networkCachingMs = 1500
    var userAgent = PlaylistImporter.userAgent
}
