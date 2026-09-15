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
///
/// Items are grouped by shape so a row never mixes 16:9 channel tiles with 2:3
/// posters: channels first (wide), then movies/episodes and local videos
/// (portrait). Each group gets its own column width so tiles line up.
struct ItemGrid: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let items: [PlayableItem]
    var showHealth = true
    var healthLookup: (PlayableItem) -> SourceHealth = { _ in .unknown }

    var body: some View {
        let channels = items.filter { $0.ref.kind == .channel }
        let portrait = items.filter { $0.ref.kind != .channel }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s5) {
                if !channels.isEmpty {
                    if !portrait.isEmpty { Text("Channels").eyebrow().padding(.horizontal, Theme.s4) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: Theme.s2)], spacing: Theme.s3) {
                        ForEach(channels) { item in cell(item, queue: channels) }
                    }
                    .padding(.horizontal, Theme.s4)
                }
                if !portrait.isEmpty {
                    if !channels.isEmpty { Text("Movies & Videos").eyebrow().padding(.horizontal, Theme.s4) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: Theme.s3)], alignment: .leading, spacing: Theme.s4) {
                        ForEach(portrait) { item in cell(item, queue: portrait) }
                    }
                    .padding(.horizontal, Theme.s4)
                }
            }
            .padding(.top, Theme.s2)
            .padding(.bottom, Theme.s10)
        }
    }

    private func cell(_ item: PlayableItem, queue: [PlayableItem]) -> some View {
        Button { playback.play(item, queue: queue, origin: .phone, resume: true) } label: {
            ItemCell(item: item, health: showHealth ? healthLookup(item) : .unknown)
        }
        .buttonStyle(.plain)
        .contextMenu { ItemContextMenu(item: item) }
    }
}

/// The one cell to use anywhere a mixed list of PlayableItems is shown.
/// Picks the right shape per item so callers stop special-casing `isLocal`.
struct ItemCell: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let item: PlayableItem
    var health: SourceHealth = .unknown

    var body: some View {
        let progress = env.progress.progress(for: item.ref)?.fraction
        let fav = env.favorites.isFavorite(item)
        let playing = playback.current?.id == item.id
        switch item.ref.kind {
        case .channel:
            ChannelTile(item: item, health: health, isFavorite: fav, isPlaying: playing)
        case .vod:
            PosterTile(item: item, progress: progress, isFavorite: fav, isPlaying: playing)
        case .localVideo:
            VideoThumbCell(item: item, progress: progress, isFavorite: fav, isPlaying: playing)
        case .youtube:
            VideoCard(item: item, progress: progress, isFavorite: fav)
        }
    }
}

/// 2:3 poster for movies and episodes — full-bleed artwork, no tinted ground.
struct PosterTile: View {
    let item: PlayableItem
    var progress: Double? = nil
    var isFavorite = false
    var isPlaying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                TileTint.gradient(for: item.title)
                RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 240, height: 360), contentMode: .fill) {
                    Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.6))
                }
                VStack {
                    HStack { Spacer(); if isFavorite { Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.live).shadow(radius: 2) } }
                    Spacer()
                }.padding(6)
                if isPlaying { Rectangle().fill(.black.opacity(0.4)); EqualizerBars() }
                if let progress, progress > 0.02 { VStack { Spacer(); ProgressBar(fraction: progress, height: 2.5) } }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            .overlay { if isPlaying { RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2) } }
            Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if let sub = item.subtitle { Text(sub).font(Theme.Font.label).foregroundStyle(Theme.inkMuted).lineLimit(1) }
        }
        .contentShape(Rectangle())
    }
}
