import SwiftUI

struct FavoritesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @State private var segment: Segment = .favorites

    enum Segment: Hashable { case favorites, history }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("Favorites").tag(Segment.favorites)
                    Text("History").tag(Segment.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s3)

                switch segment {
                case .favorites: favorites
                case .history: history
                }
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(segment == .favorites ? "Favorites" : "History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if segment == .history, !env.progress.recent(limit: 1).isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { env.progress.clearHistory() } label: { Image(systemName: "trash") }
                    }
                }
            }
        }
    }

    private var favorites: some View {
        let _ = env.favorites.revision
        let _ = env.library.revision
        let items = env.favorites.favoriteItems()
        return Group {
            if items.isEmpty {
                EmptyState(symbol: "heart", title: "Nothing saved yet", message: "Touch and hold any channel or poster to keep it here.")
            } else {
                ItemGrid(items: items, showHealth: false)
            }
        }
    }

    private var history: some View {
        let _ = env.progress.revision
        let entries = env.progress.recent(limit: 100)
        let pairs: [(PlayableItem, WatchProgress)] = entries.compactMap { p in env.library.item(for: p.target).map { ($0, p) } }
        return Group {
            if pairs.isEmpty {
                EmptyState(symbol: "clock", title: "Nothing to show", message: "Channels and videos you watch appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.s2) {
                        ForEach(pairs, id: \.0.id) { item, progress in
                            Button { playback.play(item, queue: nil, origin: .phone) } label: {
                                HistoryRow(item: item, progress: progress)
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
    }
}

struct HistoryRow: View {
    let item: PlayableItem
    let progress: WatchProgress
    var body: some View {
        HStack(spacing: Theme.s3) {
            ZStack {
                TileTint.gradient(for: item.title)
                RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 160, height: 90), contentMode: item.isLocal ? .fill : .fit) {
                    Monogram(text: item.title, size: 16)
                }
                .padding(item.isLocal ? 0 : 8)
                if progress.fraction > 0.02 { VStack { Spacer(); ProgressBar(fraction: progress.fraction) } }
            }
            .frame(width: 104, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(Theme.Font.headline).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 6) {
                    if item.isLive { LiveBadge(compact: true) }
                    Text(progress.duration > 0 && !progress.completed
                         ? String(localized: "Watched to \(Int(progress.position) / 60):\(String(format: "%02d", Int(progress.position) % 60))")
                         : progress.lastWatchedAt.formatted(.relative(presentation: .named)))
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, Theme.s1)
    }
}

/// Adaptive grid used by Favorites, playlist detail and search.
struct ItemGrid: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let items: [PlayableItem]
    var showHealth = true
    var healthLookup: (PlayableItem) -> SourceHealth = { _ in .unknown }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: Theme.s3)], spacing: Theme.s4) {
                ForEach(items) { item in
                    Button { playback.play(item, queue: items, origin: .phone) } label: {
                        if item.isLocal {
                            VideoCard(item: item, progress: env.progress.progress(for: item.ref)?.fraction, isFavorite: env.favorites.isFavorite(item))
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
