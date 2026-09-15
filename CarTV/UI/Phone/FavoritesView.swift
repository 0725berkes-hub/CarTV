import SwiftUI

struct FavoritesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            Group {
                let _ = env.favorites.revision
                let _ = env.library.revision
                let items = env.favorites.favoriteItems()
                if items.isEmpty {
                    EmptyState(symbol: "heart", title: "Nothing saved yet", message: "Touch and hold any channel or video to keep it here.")
                } else {
                    ItemGrid(items: items, showHealth: false)
                }
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Adaptive grid used by Favorites, playlist detail and search.
/// Channels → 16:9 tiles; local videos → 3:4 thumbs.
struct ItemGrid: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let items: [PlayableItem]
    var showHealth = true
    var healthLookup: (PlayableItem) -> SourceHealth = { _ in .unknown }

    var body: some View {
        let allLocal = items.allSatisfy(\.isLocal)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: allLocal ? 104 : 156), spacing: Theme.s2)], spacing: Theme.s3) {
                ForEach(items) { item in
                    Button { playback.play(item, queue: items, origin: .phone) } label: {
                        if item.isLocal {
                            VideoThumbCell(item: item, progress: env.progress.progress(for: item.ref)?.fraction, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                        } else {
                            ChannelTile(item: item, health: showHealth ? healthLookup(item) : .unknown, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ItemContextMenu(item: item) }
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.bottom, Theme.s10)
        }
    }
}
