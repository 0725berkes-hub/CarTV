import OSLog
import UIKit
import MobileVLCKit

/// libVLC-backed engine: MPEG-TS, MKV, AVI, RTSP/RTMP and anything AVPlayer rejects.
final class VLCEngine: NSObject, PlayerEngine, VLCMediaPlayerDelegate {
    let kind: PlayerEngineKind = .vlc
    private(set) var snapshot = PlayerSnapshot() {
        didSet { if snapshot != oldValue { onUpdate?(snapshot) } }
    }
    var onUpdate: ((PlayerSnapshot) -> Void)?

    let videoView: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }()

    private var player: VLCMediaPlayer?
    private var openTimer: Timer?
    private var currentGravity: VideoGravity = .fit
    private var tracksLoaded = false
    private var lastKnownItemIsLive = false
    private var videoRecoveryTicks = 0
    private var attemptedVideoRecovery = false

    private static let libraryConfigured: Void = {
        let lib = VLCLibrary.shared()
        lib.setHumanReadableName("CarTV", withHTTPUserAgent: PlaylistImporter.userAgent)
        #if DEBUG
        let logger = VLCConsoleLogger()
        logger.level = .error
        lib.loggers = [logger]
        #else
        lib.loggers = []
        #endif
    }()

    override init() {
        super.init()
        _ = Self.libraryConfigured
    }

    // MARK: PlayerEngine

    func load(_ item: PlayableItem, startAt: TimeInterval?, options: PlayerOptions) {
        stop()
        snapshot = PlayerSnapshot(state: .loading)
        tracksLoaded = false
        lastKnownItemIsLive = item.isLive
        videoRecoveryTicks = 0
        attemptedVideoRecovery = false

        var vlcOptions: [String] = [
            "--network-caching=\(options.networkCachingMs)",
            "--live-caching=\(options.networkCachingMs)",
            "--http-reconnect",
            "--adaptive-logic=highest",
            "--drop-late-frames",
            "--skip-frames",
            "--avcodec-fast",
            "--no-sub-autodetect-file",
            "--no-spu",   // no embedded/DVB subtitles drawn over the picture
            "--http-user-agent=\(item.headers["User-Agent"] ?? options.userAgent)",
        ]
        // clock-jitter/synchro=0 helps VOD seeking but makes live TS streams
        // freeze on the first frame while the PCR settles. Live gets VLC defaults.
        if !item.isLive { vlcOptions += ["--clock-jitter=0", "--clock-synchro=0"] }
        if let referer = item.headers["Referer"] { vlcOptions.append("--http-referrer=\(referer)") }
        if options.softwareDecoding {
            vlcOptions.append("--avcodec-hw=none")
        } else {
            vlcOptions.append("--avcodec-hw=videotoolbox")
        }

        let p = VLCMediaPlayer(options: vlcOptions)
        p.delegate = self
        p.drawable = videoView
        let media = VLCMedia(url: item.url)
        // Per-media options mirror the global ones for backends that ignore instance flags.
        media.addOption(":network-caching=\(options.networkCachingMs)")
        media.addOption(":http-user-agent=\(item.headers["User-Agent"] ?? options.userAgent)")
        if let referer = item.headers["Referer"] { media.addOption(":http-referrer=\(referer)") }
        if let cookie = item.headers["Cookie"] { media.addOption(":http-cookie=\(cookie)") }
        if item.streamKind == .rtsp { media.addOption(":rtsp-tcp") }
        p.media = media
        player = p
        applyGravity()

        p.play()
        if let startAt, startAt > 1 {
            // Seek after the stream opens; VLC ignores seeks before that.
            let ms = Int32(startAt * 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { @Sendable [weak self] in
                onMain {
                    guard let self, self.player === p, p.isSeekable else { return }
                    p.time = VLCTime(int: ms)
                }
            }
        }

        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { @Sendable [weak self] _ in
            onMain {
                guard let self, self.snapshot.state == .loading || self.snapshot.state == .buffering, self.snapshot.position == 0 else { return }
                self.snapshot.state = .failed(self.lastKnownItemIsLive ? .noContent : .unreachable)
                self.player?.stop()
            }
        }
    }

    var makeMirrorViewSupported: Bool { false }
    func makeMirrorView() -> UIView? { nil }

    func play() { player?.play() }
    func pause() { if player?.canPause == true { player?.pause() } }

    func stop() {
        openTimer?.invalidate()
        player?.delegate = nil
        player?.stop()
        player?.drawable = nil
        player = nil
        snapshot = PlayerSnapshot()
    }

    func seek(to seconds: TimeInterval) {
        guard let player, player.isSeekable else { return }
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
        snapshot.position = seconds
    }

    func setRate(_ rate: Float) { player?.rate = rate }

    func selectAudioTrack(_ id: Int?) {
        guard let player, let id else { return }
        player.currentAudioTrackIndex = Int32(id)
        snapshot.selectedAudioTrack = id
    }

    func selectSubtitleTrack(_ id: Int?) {
        guard let player else { return }
        player.currentVideoSubTitleIndex = Int32(id ?? -1)
        snapshot.selectedSubtitleTrack = id
    }

    func addExternalSubtitle(url: URL) {
        guard let player else { return }
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { @Sendable [weak self] in onMain { self?.reloadTracks() } }
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        currentGravity = gravity
        applyGravity()
    }

    func setMuted(_ muted: Bool) { player?.audio?.isMuted = muted }

    private func applyGravity() {
        guard let player else { return }
        switch currentGravity {
        case .fit:
            player.videoAspectRatio = nil
            player.scaleFactor = 0
        case .fill:
            // Crop to fill: compute the aspect of the drawable and let VLC crop.
            let size = videoView.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            player.videoCropGeometry = UnsafeMutablePointer(mutating: (String(format: "%d:%d", Int(size.width), Int(size.height)) as NSString).utf8String)
            player.scaleFactor = 0
        case .stretch:
            let size = videoView.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            player.videoCropGeometry = nil
            player.videoAspectRatio = UnsafeMutablePointer(mutating: (String(format: "%d:%d", Int(size.width), Int(size.height)) as NSString).utf8String)
        }
        if currentGravity != .fill { player.videoCropGeometry = nil }
    }

    // MARK: VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        onMain { [weak self] in self?.handleStateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        onMain { [weak self] in self?.handleTimeChanged() }
    }

    private func handleStateChanged() {
        guard let player else { return }
        var s = snapshot
        switch player.state {
        case .opening:   s.state = .loading
        case .buffering:
            // libVLC flips into .buffering on every segment; only surface it if we actually stalled.
            if player.isPlaying || s.position > 0 { s.state = .playing } else { s.state = s.state == .idle ? .loading : .buffering }
        case .playing:
            openTimer?.invalidate()
            s.state = .playing
            if !tracksLoaded { loadTracks(into: &s) }
        case .paused:    s.state = .paused
        case .stopped:   if s.state != .idle && s.state != .ended && !isFailed(s.state) { s.state = .ended }
        case .ended:     s.state = .ended
        case .error:
            openTimer?.invalidate()
            let msg = VLCLibrary.currentErrorMessage ?? ""
            Log.player.error("VLC error: \(msg, privacy: .public)")
            s.state = .failed(classify(msg))
        case .esAdded:
            if !tracksLoaded { loadTracks(into: &s) }
        @unknown default: break
        }
        s.isSeekable = player.isSeekable && (player.media?.length.intValue ?? 0) > 0
        snapshot = s
    }

    private func handleTimeChanged() {
        guard let player else { return }
        var s = snapshot
        s.position = TimeInterval(player.time.intValue) / 1000
        let len = TimeInterval(player.media?.length.intValue ?? 0) / 1000
        s.duration = len > 0 ? len : 0
        s.isSeekable = player.isSeekable && len > 0
        if s.state == .buffering || s.state == .loading { s.state = .playing }
        if s.videoSize == .zero, player.hasVideoOut { s.videoSize = player.videoSize }
        if s.videoSize == .zero, !player.hasVideoOut, s.position > 0.5 {
            videoRecoveryTicks += 1
            if videoRecoveryTicks == 8, !attemptedVideoRecovery {
                attemptedVideoRecovery = true
                Log.player.notice("VLC audio started without video; restarting media")
                player.stop()
                player.play()
            }
        } else if s.videoSize != .zero {
            videoRecoveryTicks = 0
        }
        snapshot = s
    }

    // MARK: Internals

    private func isFailed(_ state: PlayerState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func loadTracks(into s: inout PlayerSnapshot) {
        guard let player else { return }
        let aNames = player.audioTrackNames as? [String] ?? []
        let aIdx = player.audioTrackIndexes as? [NSNumber] ?? []
        s.audioTracks = zip(aIdx, aNames).compactMap { idx, name in
            idx.intValue >= 0 ? MediaTrack(id: idx.intValue, name: name, languageCode: nil) : nil
        }
        s.selectedAudioTrack = Int(player.currentAudioTrackIndex)

        let sNames = player.videoSubTitlesNames as? [String] ?? []
        let sIdx = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        s.subtitleTracks = zip(sIdx, sNames).compactMap { idx, name in
            idx.intValue >= 0 ? MediaTrack(id: idx.intValue, name: name, languageCode: nil) : nil
        }
        let cur = Int(player.currentVideoSubTitleIndex)
        s.selectedSubtitleTrack = cur >= 0 ? cur : nil
        tracksLoaded = !s.audioTracks.isEmpty
    }

    private func reloadTracks() {
        var s = snapshot
        tracksLoaded = false
        loadTracks(into: &s)
        snapshot = s
    }

    private func classify(_ message: String) -> PlayerFailure {
        let m = message.lowercased()
        if m.contains("401") || m.contains("403") || m.contains("unauthorized") || m.contains("forbidden") { return .authRequired }
        if m.contains("404") || m.contains("not found") || m.contains("connection failed") || m.contains("resolve") || m.contains("timeout") { return .unreachable }
        if m.contains("codec") || m.contains("demux") || m.contains("unsupported") { return .unsupportedFormat }
        return lastKnownItemIsLive ? .noContent : .unknown(message)
    }
}
