import OSLog
import Foundation
import UIKit
import Observation

/// Where playback was started from. Determines default surface behaviour.
enum PlaybackOrigin: Sendable { case phone, car }

/// The app-wide playback state machine. Owns both engines, picks the right one
/// per item, falls back AVPlayer → VLC on failure, tracks progress, and exposes
/// a single `videoView` that the phone or car UI can host.
@Observable
final class PlaybackController {

    // MARK: Observable state

    private(set) var current: PlayableItem?
    private(set) var queue: [PlayableItem] = []
    private(set) var snapshot = PlayerSnapshot()
    private(set) var engineKind: PlayerEngineKind = .avPlayer
    private(set) var gravity: VideoGravity = .fit
    private(set) var isFallingBack = false
    /// True while the full-screen phone player is presented.
    var isPhonePlayerPresented = false
    var phoneIsForeground = true
    var carIsConnected = false {
        didSet { if carIsConnected != oldValue { onCarConnectionChanged?(carIsConnected) } }
    }
    var onCarConnectionChanged: ((Bool) -> Void)?
    /// Bumped whenever `videoView` should be re-hosted (engine switch).
    private(set) var videoViewRevision = 0
    /// External subtitle cues rendered by the UI (for AVPlayer or translated tracks).
    let subtitles = SubtitleController()

    var isPlaying: Bool { snapshot.state == .playing }
    var isActive: Bool { current != nil && snapshot.state != .idle }
    var hasFailed: PlayerFailure? {
        if case .failed(let f) = snapshot.state { return f }
        return nil
    }

    var videoView: UIView { engine.videoView }

    /// Phone-side render view.
    /// - AVPlayer: a second layer mirroring the same player (both screens show video).
    /// - VLC: one drawable only, so it follows attention — the phone gets it while the
    ///   full-screen phone player is open; the car gets it otherwise. Never a placeholder.
    func phoneVideoView() -> UIView {
        if !carIsConnected { return engine.videoView }
        return engine.makeMirrorView() ?? engine.videoView
    }

    /// Car-side render view. For VLC, yields to the phone while the phone player is open.
    func carVideoView() -> UIView? {
        if engine.makeMirrorViewSupported { return engine.videoView }
        return isPhonePlayerPresented ? nil : engine.videoView
    }

    // MARK: Dependencies

    private let settings: AppSettings
    private let progress: ProgressStore
    private let nowPlaying = NowPlayingCenter()
    private let avEngine = AVPlayerEngine()
    private var _vlcEngine: VLCEngine?
    private var vlcEngine: VLCEngine {
        if let e = _vlcEngine { return e }
        let e = VLCEngine(); _vlcEngine = e; return e
    }
    private var engine: PlayerEngine
    private var progressTimer: Timer?
    private var attemptedVLC = false
    private var lastSavedPosition: TimeInterval = 0

    init(settings: AppSettings, progress: ProgressStore) {
        self.settings = settings
        self.progress = progress
        self.engine = avEngine
        bind(avEngine)
    }

    func attachNowPlaying() {
        nowPlaying.install(controller: self)
    }

    // MARK: Commands

    func play(_ item: PlayableItem, queue: [PlayableItem]? = nil, origin: PlaybackOrigin, resume: Bool = true) {
        // 1. Instant UI: set current + present the player synchronously, nothing slow yet.
        if let queue { self.queue = queue } else if !self.queue.contains(where: { $0.id == item.id }) { self.queue = [item] }
        current = item
        attemptedVLC = false
        isFallingBack = false
        lastSavedPosition = 0
        snapshot = PlayerSnapshot(state: .loading)
        if origin == .phone { isPhonePlayerPresented = true }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // 2. Next turn: engine + I/O, after the presentation has been committed.
        let startAt = resume && !item.isLive ? progress.resumePosition(for: item.ref) : nil
        let kind: PlayerEngineKind = (item.streamKind.prefersAVPlayer && !settings.softwareDecoding) ? .avPlayer : .vlc
        Task { @MainActor [weak self] in
            guard let self, self.current?.id == item.id else { return }
            self.start(on: kind, item: item, startAt: startAt)
            AudioSessionController.activate()
            self.startProgressTimer()
            self.subtitles.reset(for: item)
            self.progress.touch(item.ref)
            if self.queue.count <= 1, let siblings = self.siblingsProvider?(item), siblings.count > 1 { self.queue = siblings }
            if origin == .phone, self.carIsConnected { AppEnvironment.shared.carPlay.showOnCarScreen() }
        }
    }

    /// Supplied by AppEnvironment so tiles don't need to fetch siblings on tap.
    var siblingsProvider: ((PlayableItem) -> [PlayableItem])?

    func togglePlayPause() {
        switch snapshot.state {
        case .playing: engine.pause()
        case .paused, .ended: engine.play()
        case .failed: retry()
        default: break
        }
    }

    func pause() { engine.pause() }
    func resume() { engine.play() }

    func stop() {
        persistProgress(force: true)
        progressTimer?.invalidate()
        engine.stop()
        current = nil
        queue = []
        snapshot = PlayerSnapshot()
        isPhonePlayerPresented = false
        subtitles.reset(for: nil)
        nowPlaying.clear()
        AudioSessionController.deactivateIfIdle()
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
        var s = snapshot; s.position = seconds; snapshot = s
    }

    func skip(by delta: TimeInterval) {
        guard snapshot.isSeekable else { return }
        let target = min(max(0, snapshot.position + delta), snapshot.duration > 0 ? snapshot.duration - 1 : .greatestFiniteMagnitude)
        seek(to: target)
    }

    func next() {
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }), i + 1 < queue.count else { return }
        play(queue[i + 1], origin: isPhonePlayerPresented ? .phone : .car)
    }

    func previous() {
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }), i > 0 else { return }
        play(queue[i - 1], origin: isPhonePlayerPresented ? .phone : .car)
    }

    var hasNext: Bool {
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }) else { return false }
        return i + 1 < queue.count
    }
    var hasPrevious: Bool {
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }) else { return false }
        return i > 0
    }

    func retry() {
        guard let item = current else { return }
        play(item, origin: isPhonePlayerPresented ? .phone : .car)
    }

    /// Force the other engine (Settings → "Software decoding" or a manual switch).
    func switchEngine() {
        guard let item = current else { return }
        let other: PlayerEngineKind = engineKind == .avPlayer ? .vlc : .avPlayer
        attemptedVLC = true
        start(on: other, item: item, startAt: snapshot.position > 2 ? snapshot.position : nil)
    }

    func cycleGravity() {
        gravity = gravity.next
        engine.setVideoGravity(gravity)
    }

    func selectAudioTrack(_ id: Int?) { engine.selectAudioTrack(id) }
    func selectSubtitleTrack(_ id: Int?) {
        subtitles.disableExternal()
        engine.selectSubtitleTrack(id)
    }
    func loadExternalSubtitle(_ url: URL) {
        engine.selectSubtitleTrack(nil)
        subtitles.loadExternal(url)
    }

    // MARK: Engine plumbing

    private func start(on kind: PlayerEngineKind, item: PlayableItem, startAt: TimeInterval?) {
        if kind != engineKind || engine.kind != kind {
            engine.stop()
            engine = kind == .avPlayer ? avEngine : vlcEngine
            engineKind = kind
            bind(engine)
            videoViewRevision &+= 1
        }
        engine.setVideoGravity(gravity)
        var options = PlayerOptions()
        options.softwareDecoding = settings.softwareDecoding
        options.networkCachingMs = item.isLive ? 1000 : 1500
        engine.load(item, startAt: startAt, options: options)
        Log.player.info("▶︎ \(item.title, privacy: .public) via \(kind.rawValue, privacy: .public)")
    }

    private func bind(_ e: PlayerEngine) {
        e.onUpdate = { [weak self] snap in
            guard let self, self.engine === e else { return }
            self.handle(snap)
        }
    }

    private func handle(_ snap: PlayerSnapshot) {
        snapshot = snap
        subtitles.tick(position: snap.position)
        nowPlaying.update(item: current, snapshot: snap)

        if case .failed(let failure) = snap.state {
            // AVPlayer couldn't handle it → try VLC once, transparently.
            if engineKind == .avPlayer, !attemptedVLC, let item = current, failure != .authRequired {
                attemptedVLC = true
                isFallingBack = true
                Log.player.notice("Falling back to VLC for \(item.title, privacy: .public): \(failure.message, privacy: .public)")
                start(on: .vlc, item: item, startAt: nil)
                return
            }
            isFallingBack = false
        } else if snap.state == .playing {
            isFallingBack = false
        }

        if snap.state == .ended {
            persistProgress(force: true)
            if hasNext, current?.isLive == false { next() }
        }
    }

    // MARK: Progress

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { @Sendable [weak self] _ in
            onMain { self?.persistProgress(force: false) }
        }
    }

    private func persistProgress(force: Bool) {
        guard let item = current, !item.isLive, snapshot.duration > 0 else { return }
        guard force || abs(snapshot.position - lastSavedPosition) >= 4 else { return }
        lastSavedPosition = snapshot.position
        progress.record(item.ref, position: snapshot.position, duration: snapshot.duration)
    }
}
