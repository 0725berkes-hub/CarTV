import AVFoundation
import OSLog
import Observation

/// Configures the shared audio session for video playback (required for CarPlay
/// video routing and for background audio to continue) and reacts to the two
/// things that silently kill playback in a car:
///
/// 1. **Interruptions** — an incoming call, Siri, or the head unit's own phone
///    stack ("restricted call") takes the route. iOS deactivates our session. When
///    it ends, iOS says whether we *should* resume. Without handling this, the
///    player sits paused on a dead session and tapping play does nothing.
/// 2. **Media services reset** — CoreAudio's daemon restarts (happens when CarPlay
///    reconnects on some cars). Every AVPlayer/VLC object is now stale; the only
///    recovery is to tear down and reload.
///
/// All calls are async so the main thread never blocks on the audio server.
nonisolated enum AudioSessionController {

    /// What playback should do in response to a session event. Delivered on the main actor.
    enum Event: Sendable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case mediaServicesReset
        case routeLost            // the output we were playing to went away (BT dropped)
    }

    nonisolated(unsafe) private static var configurationTask: Task<Void, Never>?
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private static var handler: (@MainActor @Sendable (Event) -> Void)?

    static func configure(onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        handler = onEvent
        configurationTask = Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
            } catch {
                Logger(subsystem: "kurdsoft.CarTV", category: "player").error("Audio session category failed: \(error.localizedDescription)")
            }
        }
        installObservers()
    }

    private static func installObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let log = Logger(subsystem: "kurdsoft.CarTV", category: "player")

        if #available(iOS 27.0, *) {
            observers.append(nc.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: nil) { note in
                guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                      context.source == .system, context.interruptionContext != nil else { return }
                log.notice("Audio session interrupted by the system")
                emit(.interruptionBegan)
            })
            observers.append(nc.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: nil) { note in
                guard let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
                emit(.interruptionEnded(shouldResume: context.recommendation == .shouldResume))
            })
        } else {
            observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    log.notice("Audio interruption began")
                    emit(.interruptionBegan)
                case .ended:
                    let opts = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    let resume = opts.contains(.shouldResume)
                    log.notice("Audio interruption ended, shouldResume=\(resume)")
                    emit(.interruptionEnded(shouldResume: resume))
                @unknown default: break
                }
            })
        }

        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { _ in
            log.error("Media services were reset")
            // Category is gone with the daemon; set it again before anyone plays.
            Task.detached(priority: .userInitiated) {
                try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
                emit(.mediaServicesReset)
            }
        })

        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .oldDeviceUnavailable {
                log.notice("Audio route lost (old device unavailable)")
                emit(.routeLost)
            }
        })
    }

    private static func emit(_ e: Event) {
        guard let handler else { return }
        Task { @MainActor in handler(e) }
    }

    /// Activate and report whether it worked. Playback must not start on `false`.
    @discardableResult
    static func activate() async -> Bool {
        await configurationTask?.value
        do {
            if #available(iOS 27.0, *) {
                try await AVAudioSession.sharedInstance().activate(options: [])
            } else {
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                }.value
            }
            return true
        } catch {
            Logger(subsystem: "kurdsoft.CarTV", category: "player").error("Audio session activate failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fire-and-forget variant for call sites that don't need the result.
    static func activate() {
        Task { _ = await activate() as Bool }
    }

    static func deactivateIfIdle() {
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
