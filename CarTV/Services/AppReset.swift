import OSLog
import Foundation
import SwiftData

/// Wipes everything the app has ever stored — SwiftData rows, imported video
/// files, thumbnails, image cache, subtitle files, VOD catalogue caches,
/// UserDefaults, and the YouTube Keychain token — then returns the app to its
/// first-launch state. Used by Settings → "Clear All Data".
@MainActor
enum AppReset {

    /// Stop playback, delete every store, reset preferences, and show onboarding.
    static func eraseEverything(env: AppEnvironment) {
        Log.app.notice("Clear All Data requested")

        // 1. Stop anything live so no engine is writing progress mid-wipe.
        env.playback.stop()

        // 2. SwiftData — every model type, then compact.
        let ctx = env.modelContainer.mainContext
        try? ctx.delete(model: Favorite.self)
        try? ctx.delete(model: WatchProgress.self)
        try? ctx.delete(model: Channel.self)
        try? ctx.delete(model: Playlist.self)
        try? ctx.delete(model: LocalVideo.self)
        try? ctx.delete(model: VideoFolder.self)
        try? ctx.save()
        env.library.bump()
        env.favorites.reload()

        // 3. Files on disk. Recreate the directories so the app can write immediately.
        for dir in [AppPaths.videos, AppPaths.thumbnails, AppPaths.imageCache, AppPaths.subtitles] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for name in ["vod-cache.json", "vod-played.json"] {
            try? FileManager.default.removeItem(at: AppPaths.applicationSupport.appending(path: name))
        }
        ImageLoader.shared.clearMemory()

        // 4. Third-party sessions.
        env.youtube.auth.signOut()

        // 5. Preferences — the whole suite, so no stray key survives.
        if let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
            UserDefaults.standard.synchronize()
        }
        env.settings.reloadFromDefaults()

        // 6. In-memory service state.
        env.vod.reset()

        Log.app.notice("Clear All Data complete")
    }

    /// Only the onboarding flag — everything else stays.
    static func restartOnboarding(env: AppEnvironment) {
        env.settings.hasCompletedOnboarding = false
    }
}
