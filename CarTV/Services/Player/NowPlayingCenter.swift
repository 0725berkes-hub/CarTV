import MediaPlayer
import UIKit

/// Publishes Now Playing info and handles lock-screen / CarPlay hardware commands.
///
/// MediaRemote invokes command handlers and the artwork request block on
/// arbitrary threads, so every closure handed to it is `@Sendable` and hops to
/// the main actor before touching the controller.
final class NowPlayingCenter {
    private weak var controller: PlaybackController?
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var installed = false
    private var lastPublishedState: PlayerState = .idle
    private var lastPublishedItemID: UUID?
    private var lastPublishedPosition: TimeInterval = -100

    func install(controller: PlaybackController) {
        guard !installed else { return }
        installed = true
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { @Sendable [weak controller] _ in
            onMain { controller?.resume() }; return .success
        }
        center.pauseCommand.addTarget { @Sendable [weak controller] _ in
            onMain { controller?.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable [weak controller] _ in
            onMain { controller?.togglePlayPause() }; return .success
        }
        center.stopCommand.addTarget { @Sendable [weak controller] _ in
            onMain { controller?.stop() }; return .success
        }
        center.nextTrackCommand.addTarget { @Sendable [weak controller] _ in
            onMain { if controller?.hasNext == true { controller?.next() } }; return .success
        }
        center.previousTrackCommand.addTarget { @Sendable [weak controller] _ in
            onMain { if controller?.hasPrevious == true { controller?.previous() } }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { @Sendable [weak controller] _ in
            onMain { controller?.skip(by: 15) }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { @Sendable [weak controller] _ in
            onMain { controller?.skip(by: -15) }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak controller] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            onMain { controller?.seek(to: t) }
            return .success
        }
    }

    func update(item: PlayableItem?, snapshot: PlayerSnapshot) {
        guard let item else { clear(); return }

        // Throttle: the system interpolates elapsed time from playbackRate, so we
        // only need to republish on state/item change, seeks, or every few seconds.
        let stateChanged = snapshot.state != lastPublishedState || item.id != lastPublishedItemID
        let jumped = abs(snapshot.position - lastPublishedPosition) > 3
        guard stateChanged || jumped else { return }
        lastPublishedState = snapshot.state
        lastPublishedItemID = item.id
        lastPublishedPosition = snapshot.position

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle ?? "CarTV",
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive || snapshot.duration == 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if snapshot.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration }
        if let artwork, lastArtworkURL == item.artworkURL { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let seekable = snapshot.isSeekable
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = seekable
        center.skipBackwardCommand.isEnabled = seekable
        center.changePlaybackPositionCommand.isEnabled = seekable

        if item.artworkURL != lastArtworkURL {
            lastArtworkURL = item.artworkURL
            artwork = nil
            artworkTask?.cancel()
            guard let url = item.artworkURL else { return }
            artworkTask = Task { [weak self] in
                guard let image = await ImageLoader.shared.image(for: url, targetSize: CGSize(width: 600, height: 600)) else { return }
                guard !Task.isCancelled else { return }
                // The request handler runs on a MediaRemote thread → must be @Sendable.
                let art = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
                self?.artwork = art
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastPublishedState = .idle
        lastPublishedItemID = nil
        lastArtworkURL = nil
        artwork = nil
    }
}

/// Run `body` on the main actor: synchronously if we're already there, otherwise hop.
nonisolated func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}
