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

    enum RepeatMode: String, CaseIterable { case off, all, one
        var symbol: String { switch self { case .off: "repeat"; case .all: "repeat"; case .one: "repeat.1" } }
        var next: RepeatMode { switch self { case .off: .all; case .all: .one; case .one: .off } }
        var title: LocalizedStringResource { switch self { case .off: "Repeat Off"; case .all: "Repeat All"; case .one: "Repeat One" } }
    }
    var shuffle = false { didSet { UserDefaults.standard.set(shuffle, forKey: "playback.shuffle") } }
    var repeatMode: RepeatMode = .off { didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "playback.repeat") } }
    /// History of shuffled picks so "previous" walks back through what actually played.
    private var shuffleTrail: [UUID] = []
    private(set) var snapshot = PlayerSnapshot()
    private(set) var engineKind: PlayerEngineKind = .avPlayer
    private(set) var gravity: VideoGravity = .fit
    private(set) var isFallingBack = false
    /// True while the full-screen phone player is presented.
    var isPhonePlayerPresented = false {
        // Leaving the full-screen player is the moment people expect "where I left off"
        // to be saved — don't wait up to 5 s for the timer.
        didSet { if !isPhonePlayerPresented, oldValue { persistProgress(force: true) } }
    }
    var phoneIsForeground = true {
        didSet { if !phoneIsForeground, oldValue { persistProgress(force: true) } }
    }
    var carIsConnected = false {
        didSet {
            if carIsConnected != oldValue {
                if !carIsConnected { isCarPlayerPresented = false }
                onCarConnectionChanged?(carIsConnected)
            }
        }
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

    /// True while the car's full-screen player is on screen.
    var isCarPlayerPresented = false

    /// Screen mirroring is showing on the car (set from MirrorReceiver state).
    var isMirroring = false

    /// Bumped whenever surface ownership may change (car connects, car player shows/hides).
    var surfaceRevision: Int { videoViewRevision &* 31 &+ (carIsConnected ? 1 : 0) &+ (isCarPlayerPresented ? 2 : 0) }

    /// Phone-side render view.
    /// - AVPlayer: the phone keeps the primary view; the car gets a mirror layer.
    /// - VLC: one drawable. The car wins while its player is on screen; otherwise phone.
    func phoneVideoView() -> UIView? {
        if !carIsConnected { return engine.videoView }
        if engine.makeMirrorViewSupported { return engine.videoView }
        return isCarPlayerPresented ? nil : engine.videoView
    }

    /// Car-side render view — never nil. AVPlayer: a fresh mirror layer (so the phone
    /// keeps its own); VLC: the single drawable.
    func carVideoView() -> UIView {
        if engine.makeMirrorViewSupported, let mirror = engine.makeMirrorView() { return mirror }
        return engine.videoView
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
        shuffle = UserDefaults.standard.bool(forKey: "playback.shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "playback.repeat") ?? "") ?? .off
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
        case .playing: engine.pause(); persistProgress(force: true)
        case .paused, .ended: engine.play()
        case .failed: retry()
        default: break
        }
    }

    func pause() { engine.pause(); persistProgress(force: true) }
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

    private var origin: PlaybackOrigin { isPhonePlayerPresented ? .phone : .car }

    /// Next item honouring shuffle/repeat; nil when the queue is exhausted.
    private func upcoming(auto: Bool) -> PlayableItem? {
        guard let cur = current else { return nil }
        if auto, repeatMode == .one { return cur }
        if shuffle {
            let others = queue.filter { $0.id != cur.id }
            guard !others.isEmpty else { return repeatMode == .all || !auto ? cur : nil }
            return others.randomElement()
        }
        guard let i = queue.firstIndex(where: { $0.id == cur.id }) else { return nil }
        if i + 1 < queue.count { return queue[i + 1] }
        return (repeatMode == .all || !auto) && !queue.isEmpty ? queue.first : nil
    }

    func next() {
        guard let cur = current, let item = upcoming(auto: false) else { return }
        if shuffle { shuffleTrail.append(cur.id) }
        play(item, origin: origin, resume: false)
    }

    func previous() {
        // Within the first 3s: go back; otherwise restart the current item (system convention).
        if snapshot.isSeekable, snapshot.position > 3 { seek(to: 0); return }
        if shuffle {
            while let id = shuffleTrail.popLast() {
                if let item = queue.first(where: { $0.id == id }) { play(item, origin: origin, resume: false); return }
            }
        }
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }) else { return }
        let target = i > 0 ? queue[i - 1] : (repeatMode == .all ? queue.last : nil)
        if let target { play(target, origin: origin, resume: false) }
    }

    /// Pick a random item from the queue (or the given pool) and play it.
    func playRandom(from pool: [PlayableItem]? = nil, origin: PlaybackOrigin) {
        let source = pool ?? queue
        guard let item = source.filter({ $0.id != current?.id }).randomElement() ?? source.first else { return }
        shuffle = true
        play(item, queue: pool, origin: origin, resume: false)
    }

    func replay() {
        if snapshot.isSeekable { seek(to: 0); resume() }
        else if let cur = current { play(cur, origin: origin, resume: false) }
    }

    func toggleShuffle() { shuffle.toggle(); shuffleTrail.removeAll() }
    func cycleRepeat() { repeatMode = repeatMode.next }

    var hasNext: Bool { queue.count > 1 || repeatMode != .off }
    var hasPrevious: Bool { queue.count > 1 || snapshot.position > 3 || repeatMode == .all }

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
                // Keep the resume point: if AVPlayer never rendered, fall back to the
                // saved position rather than the start of the file.
                let resumeAt = snapshot.position > 2 ? snapshot.position : progress.resumePosition(for: item.ref)
                start(on: .vlc, item: item, startAt: item.isLive ? nil : resumeAt)
                return
            }
            isFallingBack = false
        } else if snap.state == .playing {
            isFallingBack = false
        }

        if snap.state == .ended {
            persistProgress(force: true)
            guard current?.isLive == false else { return }
            // Repeat/shuffle are explicit intents → continue automatically.
            if repeatMode != .off || shuffle, let item = upcoming(auto: true) {
                if item.id == current?.id { replay() } else { play(item, origin: origin, resume: false) }
            }
            // Otherwise stay on .ended; the players show Replay / Next / Random.
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
