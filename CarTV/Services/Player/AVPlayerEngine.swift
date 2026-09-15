import OSLog
import AVFoundation
import UIKit

/// AVPlayer-backed engine: HLS, MP4/MOV, local files. Hardware decode, AirPlay-capable.
///
/// AVFoundation delivers KVO and notifications on its own queues. Every callback
/// here is `@Sendable` and hops to the main actor via `onMain` before touching state.
final class AVPlayerEngine: NSObject, PlayerEngine {
    let kind: PlayerEngineKind = .avPlayer
    private(set) var snapshot = PlayerSnapshot() {
        didSet { if snapshot != oldValue { onUpdate?(snapshot) } }
    }
    var onUpdate: ((PlayerSnapshot) -> Void)?

    let videoView: UIView
    private let playerLayer: AVPlayerLayer
    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var playerObservers: [NSKeyValueObservation] = []
    private var itemObservers: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var stallTimer: Timer?
    private var hasEverPlayed = false
    private var generation = 0
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    override init() {
        let view = PlayerLayerView()
        videoView = view
        playerLayer = view.playerLayer
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.automaticallyWaitsToMinimizeStalling = false   // start on first decodable frame; we re-enable after playback begins
        player.preventsDisplaySleepDuringVideoPlayback = true

        playerObservers.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            onMain { self?.refreshState() }
        })
    }

    // MARK: PlayerEngine

    func load(_ playable: PlayableItem, startAt: TimeInterval?, options: PlayerOptions) {
        tearDownItem()
        generation &+= 1
        let gen = generation
        hasEverPlayed = false
        userPaused = false
        snapshot = PlayerSnapshot(state: .loading)

        var headers = playable.headers
        if headers["User-Agent"] == nil { headers["User-Agent"] = options.userAgent }
        let asset = AVURLAsset(url: playable.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetPreferPreciseDurationAndTimingKey: !playable.isLive
        ])
        let newItem = AVPlayerItem(asset: asset)
        // 0 = let AVFoundation pick. Forcing a tiny buffer on live HLS makes it render
        // one frame and then sit at rate 0 waiting for data it was told not to wait for.
        newItem.preferredForwardBufferDuration = 0
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        newItem.preferredPeakBitRateForExpensiveNetworks = 0
        newItem.startsOnFirstEligibleVariant = true
        if let h = maxHeight { newItem.preferredMaximumResolution = CGSize(width: CGFloat(h) * 16 / 9, height: CGFloat(h)) }
        // Live streams need AVPlayer's stall management from the first frame; for
        // VOD we start eagerly and re-enable it once playback begins.
        player.automaticallyWaitsToMinimizeStalling = playable.isLive
        item = newItem

        let refresh: @Sendable (AVPlayerItem, Any) -> Void = { [weak self] _, _ in
            onMain { guard let self, self.generation == gen else { return }; self.refreshState() }
        }
        itemObservers.append(newItem.observe(\.status, options: [.new], changeHandler: refresh))
        itemObservers.append(newItem.observe(\.isPlaybackBufferEmpty, options: [.new], changeHandler: refresh))
        itemObservers.append(newItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new], changeHandler: refresh))
        itemObservers.append(newItem.observe(\.loadedTimeRanges, options: [.new]) { @Sendable [weak self] _, _ in
            onMain { guard let self, self.generation == gen else { return }; self.updateBuffered() }
        })

        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: nil) { @Sendable [weak self] _ in
            onMain { guard let self, self.generation == gen else { return }; self.snapshot.state = .ended }
        })
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: newItem, queue: nil) { @Sendable [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            onMain { guard let self, self.generation == gen else { return }; self.fail(with: err) }
        })
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: newItem, queue: nil) { @Sendable [weak self] _ in
            onMain {
                guard let self, self.generation == gen, let log = self.item?.errorLog()?.events.last else { return }
                Log.player.error("AVPlayer error log: \(log.errorStatusCode) \(log.errorComment ?? "", privacy: .public)")
                if !self.hasEverPlayed, log.errorStatusCode == 404 || log.errorStatusCode == 403 {
                    self.fail(with: nil, code: log.errorStatusCode)
                }
            }
        })

        // Track groups are loaded asynchronously and cached for selection + UI.
        audibleGroup = nil; legibleGroup = nil
        Task { [weak self] in
            let a = try? await asset.loadMediaSelectionGroup(for: .audible)
            let l = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.generation == gen else { return }
            self.audibleGroup = a
            self.legibleGroup = l
            var s = self.snapshot
            self.loadTracks(newItem, into: &s)
            self.snapshot = s
        }

        player.replaceCurrentItem(with: newItem)
        if let startAt, startAt > 0 {
            // Exact resume: zero tolerance both ways so we land on the frame we left, not the next keyframe.
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { @Sendable [weak self] time in
            let seconds = time.seconds
            onMain { guard let self, self.generation == gen else { return }; self.tick(seconds) }
        }

        // Fail-fast: if nothing has rendered in 12s, hand off to VLC.
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { @Sendable [weak self] _ in
            onMain {
                guard let self, self.generation == gen, !self.hasEverPlayed else { return }
                self.fail(with: nil, reason: .unsupportedFormat)
            }
        }
        player.play()
    }

    private var userPaused = false
    func play() { userPaused = false; player.play() }
    func pause() { userPaused = true; player.pause() }

    // MARK: Quality cap

    /// Tallest variant AVPlayer may pick, in pixels. nil = Auto. Sticky across
    /// items so a user's 720p choice survives channel/episode changes.
    private var maxHeight: Int?

    func setMaxResolution(height: Int?) {
        maxHeight = height
        guard let item else { return }
        if let h = height {
            item.preferredMaximumResolution = CGSize(width: CGFloat(h) * 16 / 9, height: CGFloat(h))
        } else {
            item.preferredMaximumResolution = .zero
        }
    }

    var makeMirrorViewSupported: Bool { true }

    func makeMirrorView() -> UIView? {
        mirrors.removeAll { $0.superview == nil && $0.window == nil }
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = playerLayer.videoGravity
        mirrors.append(v)
        return v
    }
    private var mirrors: [PlayerLayerView] = []

    func stop() {
        tearDownItem()
        snapshot = PlayerSnapshot()
    }

    func seek(to seconds: TimeInterval) {
        guard snapshot.isSeekable else { return }
        let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
    }

    func setRate(_ rate: Float) { player.rate = rate }

    func selectAudioTrack(_ id: Int?) {
        guard let item, let group = audibleGroup else { return }
        if let id, group.options.indices.contains(id) { item.select(group.options[id], in: group) }
        snapshot.selectedAudioTrack = id
    }

    func selectSubtitleTrack(_ id: Int?) {
        guard let item, let group = legibleGroup else { return }
        if let id, group.options.indices.contains(id) { item.select(group.options[id], in: group) }
        else { item.select(nil, in: group) }
        snapshot.selectedSubtitleTrack = id
    }

    func addExternalSubtitle(url: URL) {
        // AVPlayer cannot side-load subtitle files; PlaybackController overlays them via SubtitleController.
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        let g: AVLayerVideoGravity = switch gravity {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
        playerLayer.videoGravity = g
        mirrors.removeAll { $0.superview == nil && $0.window == nil }
        mirrors.forEach { $0.playerLayer.videoGravity = g }
    }

    // MARK: Internals

    private func tearDownItem() {
        stallTimer?.invalidate()
        stallTimer = nil
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        itemObservers.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
    }

    private func tick(_ seconds: Double) {
        guard let item else { return }
        var s = snapshot
        s.position = max(0, seconds.isFinite ? seconds : 0)
        let dur = item.duration
        s.duration = (dur.isIndefinite || !dur.seconds.isFinite) ? 0 : dur.seconds
        let seekableWindow = item.seekableTimeRanges.last?.timeRangeValue.duration.seconds ?? 0
        s.isSeekable = s.duration > 0 || seekableWindow > 30
        if s.videoSize == .zero, item.presentationSize != .zero { s.videoSize = item.presentationSize }
        snapshot = s
    }

    private func updateBuffered() {
        guard let item, snapshot.duration > 0, let range = item.loadedTimeRanges.last?.timeRangeValue else { return }
        let end = (range.start + range.duration).seconds
        snapshot.bufferedFraction = min(1, max(0, end / snapshot.duration))
    }

    private func refreshState() {
        guard let item else { return }
        if item.status == .failed { fail(with: item.error as NSError?); return }
        if case .failed = snapshot.state { return }
        if snapshot.state == .ended { return }

        var s = snapshot
        switch player.timeControlStatus {
        case .playing:
            if !hasEverPlayed {
                hasEverPlayed = true
                // Now that we're rendering, let AVPlayer manage stalls normally.
                player.automaticallyWaitsToMinimizeStalling = true
            }
            stallTimer?.invalidate()
            s.state = .playing
            if s.videoSize == .zero { s.videoSize = item.presentationSize }
        case .paused:
            // Before the first frame, "paused" just means not started yet. If the item
            // is ready and we asked to play but the rate is 0, the player stopped itself
            // (typical for live HLS after the first frame) — kick it again.
            if !hasEverPlayed, item.status == .readyToPlay, player.rate == 0, !userPaused {
                player.play()
                s.state = .loading
            } else {
                s.state = hasEverPlayed ? .paused : .loading
            }
        case .waitingToPlayAtSpecifiedRate:
            s.state = hasEverPlayed ? .buffering : .loading
        @unknown default:
            break
        }
        snapshot = s
    }

    private func loadTracks(_ item: AVPlayerItem, into s: inout PlayerSnapshot) {
        if let group = audibleGroup {
            s.audioTracks = group.options.enumerated().map { i, o in MediaTrack(id: i, name: o.displayName, languageCode: o.extendedLanguageTag) }
            if let sel = item.currentMediaSelection.selectedMediaOption(in: group) { s.selectedAudioTrack = group.options.firstIndex(of: sel) }
        }
        if let group = legibleGroup {
            s.subtitleTracks = group.options.enumerated().map { i, o in MediaTrack(id: i, name: o.displayName, languageCode: o.extendedLanguageTag) }
            if let sel = item.currentMediaSelection.selectedMediaOption(in: group) { s.selectedSubtitleTrack = group.options.firstIndex(of: sel) }
        }
    }

    private func fail(with error: NSError?, code: Int? = nil, reason: PlayerFailure? = nil) {
        stallTimer?.invalidate()
        let failure: PlayerFailure
        if let reason {
            failure = reason
        } else if let code {
            failure = (code == 401 || code == 403) ? .authRequired : .unreachable
        } else if let e = error {
            switch (e.domain, e.code) {
            case (NSURLErrorDomain, NSURLErrorTimedOut), (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorCannotFindHost):
                failure = .unreachable
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
                failure = .network(String(localized: "Check that Wi‑Fi is on, then try again."))
            case (AVFoundationErrorDomain, AVError.Code.contentIsNotAuthorized.rawValue):
                failure = .authRequired
            default:
                // Most AVFoundation/CoreMedia failures are format problems VLC can handle.
                failure = (e.domain == AVFoundationErrorDomain || e.domain == "CoreMediaErrorDomain") ? .unsupportedFormat : .unknown(e.localizedDescription)
            }
            Log.player.error("AVPlayer failed: \(e.domain, privacy: .public) \(e.code) \(e.localizedDescription, privacy: .public)")
        } else {
            failure = .unsupportedFormat
        }
        snapshot.state = .failed(failure)
    }
}

/// A view whose backing layer is an AVPlayerLayer, so resizing is free.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }
}
