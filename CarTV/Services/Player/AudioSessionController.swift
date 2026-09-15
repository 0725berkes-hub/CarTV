import AVFoundation
import OSLog

/// Configures the shared audio session for video playback (required for CarPlay
/// video routing and for background audio to continue). All calls are async so
/// the main thread never blocks on the audio server.
nonisolated enum AudioSessionController {
    static func configure() {
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
            } catch {
                Logger(subsystem: "kurdsoft.CarTV", category: "player").error("Audio session category failed: \(error.localizedDescription)")
            }
        }
    }

    static func activate() {
        Task.detached(priority: .userInitiated) {
            do {
                if #available(iOS 27.0, *) {
                    try await AVAudioSession.sharedInstance().activate(options: [])
                } else {
                    // Off the main thread already (detached task), so the sync call can't stall the UI.
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                }
            } catch {
                Logger(subsystem: "kurdsoft.CarTV", category: "player").error("Audio session activate failed: \(error.localizedDescription)")
            }
        }
    }

    static func deactivateIfIdle() {
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
