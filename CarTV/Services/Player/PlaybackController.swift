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

    // MARK: Quality (HLS variants)

    /// Available variants for the current item (height, label). Empty when the stream
    /// isn't an HLS master we control (live TV, progressive files).
    private(set) var qualityVariants: [(height: Int, label: String)] = []
    /// nil = Auto (adaptive). A value pins that height until the user changes it.
    var selectedQualityHeight: Int? {
        didSet {
            UserDefaults.standard.set(selectedQualityHeight ?? 0, forKey: "playback.quality")
            applyQuality()
        }
    }
    var qualityLabel: String {
        guard let h = selectedQualityHeight, let v = qualityVariants.first(where: { $0.height == h }) else { return String(localized: "Auto") }
        return v.label
    }

    /// Set by the YouTube resolver just before `play()`; consumed on start.
    var pendingQualityVariants: [(height: Int, label: String)] = []

    func setQualityVariants(_ v: [(height: Int, label: String)]) {
        qualityVariants = v.sorted { $0.height > $1.height }
        applyQuality()
    }

    private func applyQuality() {
        guard let av = engine as? AVPlayerEngine else { return }
        let pinned = selectedQualityHeight.flatMap { h in qualityVariants.contains { $0.height == h } ? h : nil }
        av.setMaxResolution(height: pinned)
        // Our own YouTube HLS has one master per height: swap to it so the pick is
        // exact (and can go *up*, which a resolution cap never does).
        guard let item = current, item.ref.kind == .youtube,
              item.url.host == "127.0.0.1", item.url.lastPathComponent.hasPrefix("master") else { return }
        let want = pinned.map { "master-\($0).m3u8" } ?? "master.m3u8"
        guard item.url.lastPathComponent != want else { return }
        let url = item.url.deletingLastPathComponent().appending(path: want)
        let at = snapshot.position
        var swapped = item; swapped.url = url
        current = swapped
        if let i = queue.firstIndex(where: { $0.id == item.id }) { queue[i] = swapped }
        Log.player.info("Quality → \(want, privacy: .public) at \(Int(at))s")
        start(on: .avPlayer, item: swapped, startAt: at > 1 ? at : nil)
    }

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
        let q = UserDefaults.standard.integer(forKey: "playback.quality")
        selectedQualityHeight = q > 0 ? q : nil
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
        attemptedYouTubeRefresh = false
        attemptedMyTVRefresh = false
        lastSeekTarget = 0
        isFallingBack = false
        lastSavedPosition = 0
        userPausedExplicitly = false
        sessionNeedsReload = false
        qualityVariants = []
        snapshot = PlayerSnapshot(state: .loading)
        if origin == .phone { isPhonePlayerPresented = true }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // 2. Next turn: engine + I/O, after the presentation has been committed.
        let startAt = resume && !item.isLive ? progress.resumePosition(for: item.ref) : nil
        let kind: PlayerEngineKind = (item.streamKind.prefersAVPlayer && !settings.softwareDecoding) ? .avPlayer : .vlc
        Task { @MainActor [weak self] in
            guard let self, self.current?.id == item.id else { return }
            var item = item
            var kind = kind
            // YouTube favourites/stubs carry the watch-page URL; resolve to a real stream first.
            if item.ref.kind == .youtube, item.url.host?.contains("youtube.com") == true || item.url.host?.contains("youtu.be") == true {
                guard let vid = YouTubeService.videoID(from: item.ref.id) else { return }
                do {
                    var v = YTVideo(id: vid, title: item.title); v.channelName = item.subtitle; v.thumbnailURL = item.artworkURL
                    let resolved = try await AppEnvironment.shared.youtube.resolve(v)
                    guard self.current?.id == item.id else { return }
                    item = resolved.item
                    self.current = item
                    if let i = self.queue.firstIndex(where: { $0.id == item.id }) { self.queue[i] = item }
                    kind = .avPlayer
                } catch {
                    self.snapshot = PlayerSnapshot(state: .failed(.unknown(error.localizedDescription)))
                    return
                }
            }
            self.start(on: kind, item: item, startAt: startAt)
            _ = await AudioSessionController.activate() as Bool
            self.startProgressTimer()
            self.subtitles.reset(for: item)
            self.progress.touch(item.ref)
            if self.queue.count <= 1, let siblings = self.siblingsProvider?(item), siblings.count > 1 { self.queue = siblings }
            self.ensureYouTubeUpNext(after: item)
            if origin == .phone, self.carIsConnected { AppEnvironment.shared.carPlay.showOnCarScreen() }
        }
    }

    /// Supplied by AppEnvironment so tiles don't need to fetch siblings on tap.
    var siblingsProvider: ((PlayableItem) -> [PlayableItem])?

    func togglePlayPause() {
        switch snapshot.state {
        case .playing: pause()
        case .paused, .ended: resume()
        case .failed: retry()
        default: break
        }
    }

    func pause() { userPausedExplicitly = true; engine.pause(); persistProgress(force: true) }
    private var userPausedExplicitly = false

    /// Resume with a health check. After a call or a CarPlay reconnect the engine can
    /// be paused on a dead audio session or a torn-down pipeline: `play()` is accepted
    /// and nothing happens. Detect that and reload at the current position instead.
    func resume() {
        guard let item = current else { return }
        userPausedExplicitly = false
        if sessionNeedsReload {
            sessionNeedsReload = false
            reloadInPlace(item)
            return
        }
        let before = snapshot.position
        engine.play()
        // If the clock hasn't moved in 1.5 s and we're still not playing, the engine is stuck.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.current?.id == item.id, !self.isPlaying,
                  abs(self.snapshot.position - before) < 0.25,
                  self.snapshot.state != .failed(.unreachable) else { return }
            Log.player.notice("Resume stalled for \(item.title, privacy: .public); reloading in place")
            self.reloadInPlace(item)
        }
    }

    /// Tear down the engine and reload the same item at the same position, on the
    /// same surface. Used after audio interruptions and media-services resets.
    private func reloadInPlace(_ item: PlayableItem) {
        let at = item.isLive ? nil : (snapshot.position > 2 ? snapshot.position : progress.resumePosition(for: item.ref))
        Task { @MainActor in
            guard await AudioSessionController.activate() else {
                Log.player.error("Audio session won't activate; cannot resume")
                return
            }
            let kind: PlayerEngineKind = (item.streamKind.prefersAVPlayer && !settings.softwareDecoding) ? .avPlayer : .vlc
            engine.stop()
            attemptedVLC = false
            start(on: kind, item: item, startAt: at)
        }
    }

    /// CarPlay came back after a disconnect. Re-host the video and, if playback was
    /// paused by the drop (not by the user), bring it back through the health check.
    func carReconnected() {
        videoViewRevision &+= 1
        guard current != nil else { return }
        if !isPlaying, !userPausedExplicitly {
            sessionNeedsReload = true
            resume()
        }
    }

    // MARK: Audio session events

    /// Set when the session was interrupted or reset; the next resume reloads.
    private var sessionNeedsReload = false
    private var wasPlayingBeforeInterruption = false

    func handleAudioSession(_ event: AudioSessionController.Event) {
        switch event {
        case .interruptionBegan:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { engine.pause(); persistProgress(force: true) }
        case .interruptionEnded(let shouldResume):
            // The session was deactivated under us; a plain play() would run on a dead
            // session. Reload if the system says resume, otherwise just mark it.
            sessionNeedsReload = true
            if shouldResume, wasPlayingBeforeInterruption, current != nil { resume() }
            wasPlayingBeforeInterruption = false
        case .mediaServicesReset:
            // Every AVPlayer/VLC object is invalid now. Reload whatever we had.
            let wasPlaying = isPlaying
            sessionNeedsReload = false
            if let item = current {
                if wasPlaying { reloadInPlace(item) } else { sessionNeedsReload = true }
            }
        case .routeLost:
            // Output vanished (BT dropped / head unit rebooted). Pause cleanly so the
            // next play goes through the health-checked resume.
            if isPlaying { engine.pause(); persistProgress(force: true) }
            sessionNeedsReload = true
        }
    }

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
        lastSeekTarget = seconds
        engine.seek(to: seconds)
        var s = snapshot; s.position = seconds; snapshot = s
    }

    /// Where the user last asked to be — kept so a refused seek resumes there, not at 0.
    private var lastSeekTarget: TimeInterval = 0
    private var attemptedYouTubeRefresh = false
    private var attemptedMyTVRefresh = false

    private func refreshYouTubeStream(item: PlayableItem, resumeAt: TimeInterval) {
        guard let vid = YouTubeService.videoID(from: item.ref.id) else { return }
        isFallingBack = true
        Task { @MainActor [weak self] in
            guard let self, self.current?.id == item.id else { return }
            var v = YTVideo(id: vid, title: item.title); v.channelName = item.subtitle; v.thumbnailURL = item.artworkURL
            do {
                let resolved = try await AppEnvironment.shared.youtube.resolve(v, fresh: true)
                guard self.current?.id == item.id else { return }
                let fresh = resolved.item
                self.current = fresh
                if let i = self.queue.firstIndex(where: { $0.id == item.id }) { self.queue[i] = fresh }
                self.start(on: .avPlayer, item: fresh, startAt: resumeAt > 1 ? resumeAt : nil)
            } catch {
                self.isFallingBack = false
                self.snapshot = PlayerSnapshot(state: .failed(.network(error.localizedDescription)))
            }
        }
    }

    func skip(by delta: TimeInterval) {
        guard snapshot.isSeekable else { return }
        let target = min(max(0, snapshot.position + delta), snapshot.duration > 0 ? snapshot.duration - 1 : .greatestFiniteMagnitude)
        seek(to: target)
    }

    private var origin: PlaybackOrigin { isPhonePlayerPresented ? .phone : .car }

    /// YouTube: when the current video is the last thing in the queue, fetch
    /// YouTube's own "up next" for it so Next (phone, car, lock screen, Finished
    /// card) always has somewhere to go — like a normal video in a playlist.
    private func ensureYouTubeUpNext(after item: PlayableItem) {
        guard item.ref.kind == .youtube, let vid = YouTubeService.videoID(from: item.ref.id) else { return }
        guard let i = queue.firstIndex(where: { $0.id == item.id }), i >= queue.count - 1 else { return }
        Task { @MainActor [weak self] in
            guard let self, let w = try? await AppEnvironment.shared.youtube.watch(vid), !w.related.isEmpty else { return }
            guard self.current?.id == item.id else { return }
            let yt = AppEnvironment.shared.youtube
            w.related.forEach { yt.remember($0) }
            let ids = Set(self.queue.map(\.id))
            let more = w.related.compactMap { yt.cachedStub($0.id) }.filter { !ids.contains($0.id) }
            guard !more.isEmpty else { return }
            self.queue.append(contentsOf: more.prefix(20))
            Log.player.info("YouTube up next: +\(more.count) for \(item.title, privacy: .public)")
        }
    }

    /// Replace the up-next queue without interrupting the current item.
    func setQueue(_ items: [PlayableItem]) {
        guard let cur = current else { queue = items; return }
        var q = items
        if !q.contains(where: { $0.id == cur.id }) { q.insert(cur, at: 0) }
        queue = q
        shuffleTrail.removeAll()
    }

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

    /// The current item was deleted from the library: advance past it (or stop) and
    /// drop it from the queue so previous/shuffle never land on it again.
    func removeCurrentFromQueue() {
        guard let cur = current else { return }
        let nextItem = upcoming(auto: false)
        queue.removeAll { $0.id == cur.id }
        shuffleTrail.removeAll { $0 == cur.id }
        if let nextItem { play(nextItem, origin: origin, resume: false) } else { stop() }
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
        if !pendingQualityVariants.isEmpty { setQualityVariants(pendingQualityVariants); pendingQualityVariants = [] } else { applyQuality() }
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
            // YouTube: a 403 after a seek means the stream URL was byte-capped or expired.
            // Never hop to VLC or the next video — fetch a fresh URL once and resume
            // where the user was; otherwise show a clear, stay-put error.
            if let item = current, item.ref.kind == .youtube {
                let at = max(snapshot.position, lastSeekTarget)
                // Only a refused *stream* (403/404 → authRequired/unreachable) warrants a
                // fresh URL; a decode/stall failure gets an honest message instead.
                let refused = failure == .authRequired || failure == .unreachable
                if refused, !attemptedYouTubeRefresh {
                    attemptedYouTubeRefresh = true
                    Log.player.notice("YouTube stream refused (\(failure.message, privacy: .public)); refreshing URL at \(Int(at))s")
                    refreshYouTubeStream(item: item, resumeAt: at)
                } else {
                    Log.player.error("YouTube playback failed: \(failure.message, privacy: .public)")
                    isFallingBack = false
                }
                return
            }
            // MyTV+: the link set is network-bound. If a channel refuses, re-import the
            // list for the network we're on now and retry that channel with its new URL.
            if let item = current, item.ref.kind == .channel, !attemptedMyTVRefresh,
               let ch = AppEnvironment.shared.library.channel(id: item.ref.id), ch.playlist?.sourceURL == MyTVService.sourceURL {
                attemptedMyTVRefresh = true
                isFallingBack = true
                Log.player.notice("MyTV+ channel refused; refreshing links and retrying \(item.title, privacy: .public)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await MyTVService.refreshForCurrentNetwork(env: AppEnvironment.shared, force: true)
                    guard self.current?.id == item.id, let fresh = AppEnvironment.shared.library.item(for: item.ref) else { return }
                    self.current = fresh
                    if let i = self.queue.firstIndex(where: { $0.id == item.id }) { self.queue[i] = fresh }
                    self.attemptedVLC = false
                    self.start(on: .avPlayer, item: fresh, startAt: nil)
                }
                return
            }
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
            // A YouTube stream that "ends" nowhere near its duration was cut off (403 byte cap),
            // not finished — treat it like a refused stream instead of showing Finished / Up Next.
            if let item = current, item.ref.kind == .youtube, snap.duration > 30, snap.position < snap.duration - 15 {
                handle(PlayerSnapshot(state: .failed(.network("Stream cut off")), position: max(snap.position, lastSeekTarget), duration: snap.duration))
                return
            }
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
