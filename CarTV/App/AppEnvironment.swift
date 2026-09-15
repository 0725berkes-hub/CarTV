import OSLog
import Foundation
import SwiftData
import AVFoundation
import UIKit

/// Process-wide dependency container. One instance, created at launch,
/// shared by the phone scene, the CarPlay scene and background services.
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let modelContainer: ModelContainer
    let playback: PlaybackController
    let library: LibraryStore
    let favorites: FavoritesStore
    let progress: ProgressStore
    let carPlay: CarPlayCoordinator
    let health: SourceHealthService
    let settings: AppSettings
    #if DLNA_RECEIVER
    let cast: CastReceiver
    #endif
    let mirror: MirrorReceiver
    let vod: VODService

    private(set) var didBootstrap = false

    private init() {
        let schema = Schema([
            Playlist.self, Channel.self,
            VideoFolder.self, LocalVideo.self,
            Favorite.self, WatchProgress.self
        ])
        let config = ModelConfiguration(
            "CarTV",
            schema: schema,
            url: AppPaths.applicationSupport.appending(path: "CarTV.store"),
            cloudKitDatabase: .none
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Corrupt store → move aside and start fresh rather than crash-looping.
            Log.app.error("Model container failed (\(error.localizedDescription)); resetting store")
            try? FileManager.default.removeItem(at: config.url)
            modelContainer = try! ModelContainer(for: schema, configurations: [config])
        }

        settings  = AppSettings()
        library   = LibraryStore(container: modelContainer)
        favorites = FavoritesStore(container: modelContainer)
        progress  = ProgressStore(container: modelContainer)
        health    = SourceHealthService(container: modelContainer)
        vod       = VODService()
        playback  = PlaybackController(settings: settings, progress: progress)
        carPlay   = CarPlayCoordinator(playback: playback)
        #if DLNA_RECEIVER
        cast      = CastReceiver(playback: playback)
        #endif
        mirror    = MirrorReceiver()
        playback.siblingsProvider = { [library] item in library.siblings(of: item) }
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        AudioSessionController.configure()
        playback.attachNowPlaying()
        #if DLNA_RECEIVER
        cast.start()   // needs com.apple.developer.networking.multicast
        #endif
        mirror.start()
        Log.app.info("Bootstrapped. Store at \(AppPaths.applicationSupport.path, privacy: .public)")
    }
}
