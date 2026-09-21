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
    private var videoRecoveryTicks = 0
    private var expectsVideo = true
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

    private var knownDuration: TimeInterval = 0

    func load(_ playable: PlayableItem, startAt: TimeInterval?, options: PlayerOptions) {
        tearDownItem()
        generation &+= 1
        let gen = generation
        hasEverPlayed = false
        videoRecoveryTicks = 0
        expectsVideo = playable.ref.kind == .channel || playable.ref.kind == .vod || playable.ref.kind == .youtube
        userPaused = false
        lastTickPosition = -1; frozenTicks = 0
        knownDuration = playable.isLive ? 0 : playable.duration
        snapshot = PlayerSnapshot(state: .loading)

        var headers = playable.headers
        if headers["User-Agent"] == nil { headers["User-Agent"] = options.userAgent }
        var assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: !playable.isLive]
        // AVFoundation silently drops `Cookie` from the header-fields option (it's a
        // reserved header). Cookies must go in as HTTPCookie objects instead, or the
        // CDN 403s and we fall back to VLC for nothing (TikTok, some Xtream hosts).
        if let raw = headers.removeValue(forKey: "Cookie"), let host = playable.url.host {
            var jar: [HTTPCookie] = []
            for pair in raw.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                // Domain: the CDN host's registrable suffix (v16-webapp-prime.tiktok.com → .tiktok.com)
                let parts = host.split(separator: ".")
                let domain = parts.count >= 2 ? "." + parts.suffix(2).joined(separator: ".") : host
                if let c = HTTPCookie(properties: [.name: kv[0], .value: kv[1], .domain: domain, .path: "/", .secure: "TRUE"]) { jar.append(c) }
            }
            if !jar.isEmpty { assetOptions[AVURLAssetHTTPCookiesKey] = jar }
        }
        assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        let asset = AVURLAsset(url: playable.url, options: assetOptions)
        let newItem = AVPlayerItem(asset: asset)
        // 0 = let AVFoundation pick. Forcing a tiny buffer on live HLS makes it render
        // one frame and then sit at rate 0 waiting for data it was told not to wait for.
        newItem.preferredForwardBufferDuration = 0
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        // Korek can establish the connection quickly but struggles when AVPlayer
        // immediately selects a high-bitrate 1080p rendition.
        newItem.preferredPeakBitRateForExpensiveNetworks = playable.isLive ? 0 : 2_500_000
        newItem.startsOnFirstEligibleVariant = true
        if let h = maxHeight { newItem.preferredMaximumResolution = CGSize(width: CGFloat(h) * 16 / 9, height: CGFloat(h)) }
        // Live streams need AVPlayer's stall management from the first frame, and so
        // does segmented VOD over the network (YouTube HLS): with waiting off, play()
        // before the first segments land sets rate 1 on nothing and the clock never
        // starts — the "pause and resume to make it play" symptom. Only local files
        // and progressive MP4 start eagerly.
        let eager = playable.url.isFileURL || playable.streamKind == .mp4
        player.automaticallyWaitsToMinimizeStalling = !eager
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
                // 403/404 mid-stream (YouTube byte cap after a seek, expired URL) must
                // surface as a failure, never as a silent stall or a fake "ended".
                if log.errorStatusCode == 404 || log.errorStatusCode == 403 {
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

        // Fail-fast: if nothing has rendered in 12s, hand off to VLC. YouTube's
        // segmented VOD needs the first video + audio byte ranges; give it longer.
        stallTimer?.invalidate()
        let stallAfter: TimeInterval = playable.ref.kind == .youtube ? 30 : (playable.isLive ? 8 : 12)
        stallTimer = Timer.scheduledTimer(withTimeInterval: stallAfter, repeats: false) { @Sendable [weak self] _ in
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
        let wasPlaying = !userPaused
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { @Sendable [weak self] finished in
            onMain {
                guard let self, finished, wasPlaying else { return }
                // Landing far outside the buffered range can leave the player at rate 0.
                if self.player.timeControlStatus != .playing { self.player.play() }
            }
        }
        var s = snapshot; s.position = seconds; s.state = .buffering; snapshot = s
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

    func setMuted(_ muted: Bool) { player.isMuted = muted }

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

    private var lastTickPosition: Double = -1
    private var frozenTicks = 0

    private func tick(_ seconds: Double) {
        guard let item else { return }
        var s = snapshot
        s.position = max(0, seconds.isFinite ? seconds : 0)
        // Watchdog: rate > 0 but the clock isn't moving for ~3s → the pipeline
        // wedged (common right after start or a far seek). A pause/play cycle is
        // exactly what the user would do by hand; do it for them once.
        if player.rate > 0, !userPaused, abs(s.position - lastTickPosition) < 0.05 {
            frozenTicks += 1
            if frozenTicks == 6 {
                Log.player.notice("AVPlayer clock frozen at \(Int(s.position))s; nudging")
                player.pause(); player.play()
            }
        } else {
            frozenTicks = 0
        }
        lastTickPosition = s.position
        let dur = item.duration
        s.duration = (dur.isIndefinite || !dur.seconds.isFinite) ? 0 : dur.seconds
        let seekableWindow = item.seekableTimeRanges.last?.timeRangeValue.duration.seconds ?? 0
        // VOD with a known length is seekable from the first tick — the whole
        // timeline, not just what has buffered (HLS byte-range VOD reports the
        // full duration up front; AVPlayer fetches the target on seek).
        if s.duration == 0, knownDuration > 0 { s.duration = knownDuration }
        s.isSeekable = s.duration > 0 || seekableWindow > 30
        if s.videoSize == .zero, item.presentationSize != .zero { s.videoSize = item.presentationSize }

        // A cellular connection can start the audio track while the video track is
        // still wedged. Let PlaybackController switch to VLC instead of leaving a
        // black screen that only a manual close/reopen would recover.
        if s.videoSize == .zero, player.rate > 0, s.position > 0.5,
              expectsVideo {
            videoRecoveryTicks += 1
            if videoRecoveryTicks == 8 {
                fail(with: nil, reason: .unsupportedFormat)
                return
            }
        } else if s.videoSize != .zero {
            videoRecoveryTicks = 0
        }

        // The clock is the ground truth. If time is advancing and the player says it's
        // playing, we're playing — regardless of what the last KVO said. KVO on
        // timeControlStatus coalesces, so a brief .waiting can be the last thing we
        // heard while video has long since resumed. That's the stuck "Loading…" bug.
        if (s.state == .buffering || s.state == .loading), player.rate > 0, player.timeControlStatus == .playing {
            if !hasEverPlayed { hasEverPlayed = true; player.automaticallyWaitsToMinimizeStalling = true }
            stallTimer?.invalidate()
            s.state = .playing
        }
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
            // "Paused" without the user asking for it means the player stopped itself:
            // not started yet, or it gave up after a seek/stall (with automatic stall
            // waiting off it just sits at rate 0). Kick it again either way.
            if item.status == .readyToPlay, player.rate == 0, !userPaused, snapshot.state != .ended {
                player.play()
                s.state = hasEverPlayed ? .buffering : .loading
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
        backgroundColor = .clear   // let the host draw pillars (blurred cover) behind letterboxed video
    }
    required init?(coder: NSCoder) { fatalError() }
}
