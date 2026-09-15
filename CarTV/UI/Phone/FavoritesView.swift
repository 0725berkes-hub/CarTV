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
            .toolbar { ToolbarItem(placement: .topBarLeading) { MoreToolbarMenu() } }
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
        // Two shapes only: landscape cards (channels, YouTube, videos, episodes) and
        // movie posters. Each gets its own grid so rows are one height.
        let landscape = items.filter { !ItemCell.isPoster($0) }
        let posters = items.filter { ItemCell.isPoster($0) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s5) {
                if !landscape.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: Theme.s2)], spacing: Theme.s3) {
                        ForEach(landscape) { item in cell(item, queue: landscape) }
                    }
                    .padding(.horizontal, Theme.s4)
                }
                if !posters.isEmpty {
                    if !landscape.isEmpty { Text("Movies").eyebrow().padding(.horizontal, Theme.s4) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: Theme.s3)], alignment: .leading, spacing: Theme.s4) {
                        ForEach(posters) { item in cell(item, queue: posters) }
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
///
/// Shape rule: **everything is a 16:9 landscape card** except catalogue movies,
/// which are 2:3 posters. Channels, YouTube, local videos and episodes all share
/// the landscape card so a shelf or grid row is always one height. Local videos
/// used to be 3:4 thumbs — that's what made Favorites look like a ransom note.
struct ItemCell: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let item: PlayableItem
    var health: SourceHealth = .unknown

    /// Whether this item renders as a poster (true) or a landscape card (false).
    static func isPoster(_ item: PlayableItem) -> Bool {
        item.ref.kind == .vod && item.subtitle?.hasPrefix("Season") != true
    }

    var body: some View {
        let progress = env.progress.progress(for: item.ref)?.fraction
        let fav = env.favorites.isFavorite(item)
        let playing = playback.current?.id == item.id
        if Self.isPoster(item) {
            PosterTile(item: item, progress: progress, isFavorite: fav, isPlaying: playing)
        } else if item.ref.kind == .channel {
            ChannelTile(item: item, health: health, isFavorite: fav, isPlaying: playing)
        } else {
            VideoCard(item: item, progress: progress, isFavorite: fav, isPlaying: playing)
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
