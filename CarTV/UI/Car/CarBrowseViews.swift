import SwiftUI
import SwiftData

// MARK: - Home

struct CarHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    @Query(sort: [SortDescriptor(\Playlist.sortOrder), SortDescriptor(\Playlist.createdAt)]) private var playlists: [Playlist]
    @Query(sort: [SortDescriptor(\LocalVideo.importedAt, order: .reverse)]) private var videos: [LocalVideo]

    var body: some View {
        let _ = env.library.revision
        let _ = env.progress.revision
        ScrollView {
            LazyVStack(alignment: .leading, spacing: m.compact ? Theme.s4 : Theme.s6) {
                if playlists.isEmpty && videos.isEmpty {
                    CarEmptyState(symbol: "iphone.and.arrow.forward", title: "Add sources on your iPhone first", message: "Open CarTV on your iPhone and add an M3U playlist or import videos. They appear here instantly.")
                }
                let cont = env.progress.continueWatching(limit: 10)
                if !cont.isEmpty {
                    CarShelf(title: "Continue Watching") {
                        ForEach(cont, id: \.0.id) { item, p in CarTileButton(item: item, progress: p.fraction) }
                    }
                }
                let favs = env.favorites.favoriteItems()
                if !favs.isEmpty {
                    CarShelf(title: "Favorites") {
                        ForEach(favs.prefix(16)) { item in CarTileButton(item: item, queue: favs) }
                    }
                }
                ForEach(playlists) { playlist in
                    let items = env.library.channels(in: playlist, limit: 16).map { PlayableItem(channel: $0, playlistName: playlist.name) }
                    if !items.isEmpty {
                        CarShelf(title: LocalizedStringResource(stringLiteral: playlist.name), seeAll: .playlist(playlist)) {
                            ForEach(items) { item in CarTileButton(item: item, queue: nil) }
                        }
                    }
                }
                if !videos.isEmpty {
                    CarShelf(title: "Videos", seeAll: .folder(VideoFolder.loose)) {
                        ForEach(videos.prefix(16)) { v in
                            let item = PlayableItem(video: v)
                            CarTileButton(item: item, progress: env.progress.progress(for: item.ref)?.fraction)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.s2)
            .padding(.bottom, m.gutter)
        }
    }
}

// MARK: - Favorites

struct CarFavoritesView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let _ = env.favorites.revision
        let items = env.favorites.favoriteItems()
        if items.isEmpty {
            CarEmptyState(symbol: "heart", title: "Nothing saved yet", message: "Touch and hold any channel or poster on your iPhone to keep it here.")
        } else {
            CarGrid(items: items)
        }
    }
}

// MARK: - Library

struct CarLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push
    @Query(sort: [SortDescriptor(\Playlist.sortOrder)]) private var playlists: [Playlist]
    @Query(sort: [SortDescriptor(\VideoFolder.sortOrder)]) private var folders: [VideoFolder]
    @Query(filter: #Predicate<LocalVideo> { $0.folder == nil }) private var looseVideos: [LocalVideo]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                ForEach(playlists) { p in
                    Button { push(.playlist(p)) } label: {
                        CarSourceCard(symbol: "antenna.radiowaves.left.and.right", title: p.name, subtitle: String(localized: "\(p.channelCount) channels"), tint: TileTint.color(for: p.name))
                    }.buttonStyle(CarFocusButtonStyle())
                }
                ForEach(folders) { f in
                    Button { push(.folder(f)) } label: {
                        CarSourceCard(symbol: "folder.fill", title: f.name, subtitle: String(localized: "\(f.videos.count) videos"), tint: Theme.amber)
                    }.buttonStyle(CarFocusButtonStyle())
                }
                if !looseVideos.isEmpty {
                    Button { push(.folder(VideoFolder.loose)) } label: {
                        CarSourceCard(symbol: "film.stack.fill", title: String(localized: "Videos"), subtitle: String(localized: "\(looseVideos.count) videos"), tint: Theme.accent)
                    }.buttonStyle(CarFocusButtonStyle())
                }
            }
            .padding(.horizontal, m.gutter).padding(.bottom, m.gutter)
        }
        .overlay { if playlists.isEmpty && folders.isEmpty && looseVideos.isEmpty { CarEmptyState(symbol: "square.stack", title: "Your library is empty", message: "Add sources on your iPhone first") } }
    }
}

extension VideoFolder {
    /// Sentinel used for the "loose videos" route.
    nonisolated(unsafe) static let loose = VideoFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: String(localized: "Videos"))
}

struct CarPlaylistView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push
    let playlist: Playlist
    var body: some View {
        let _ = env.library.revision
        let genres = env.library.genreCounts(in: playlist)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                Button { push(.genre(playlist, nil)) } label: {
                    CarSourceCard(symbol: "square.grid.2x2.fill", title: String(localized: "All"), subtitle: String(localized: "\(playlist.channelCount) channels"), tint: Theme.accent)
                }.buttonStyle(CarFocusButtonStyle())
                ForEach(genres, id: \.0) { g, count in
                    Button { push(.genre(playlist, g)) } label: {
                        CarSourceCard(symbol: g.symbol, title: String(localized: g.title), subtitle: String(localized: "\(count) channels"), tint: g.tint)
                    }.buttonStyle(CarFocusButtonStyle())
                }
            }
            .padding(.horizontal, m.gutter).padding(.bottom, m.gutter)
        }
    }
}

struct CarChannelGridView: View {
    @Environment(AppEnvironment.self) private var env
    let playlist: Playlist
    let genre: Genre?
    var body: some View {
        let _ = env.library.revision
        let items = env.library.channels(in: playlist, genre: genre).map { PlayableItem(channel: $0, playlistName: playlist.name) }
        CarGrid(items: items)
    }
}

struct CarVideosGridView: View {
    @Environment(AppEnvironment.self) private var env
    let folder: VideoFolder
    var body: some View {
        let _ = env.library.revision
        let videos = folder.id == VideoFolder.loose.id ? env.library.localVideos().filter { $0.folder == nil } : env.library.localVideos(in: folder)
        CarGrid(items: videos.map(PlayableItem.init(video:)), wide: true)
    }
}

// MARK: - Building blocks

struct CarShelf<Content: View>: View {
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push
    let title: LocalizedStringResource
    var seeAll: CarRoute? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.Car.title(m.compact ? 15 : 20)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                if let seeAll {
                    Button { push(seeAll) } label: {
                        HStack(spacing: 3) { Text("See all"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                            .font(.system(size: m.compact ? 12 : 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, Theme.s2).padding(.vertical, 6)
                    }.buttonStyle(CarFocusButtonStyle())
                }
            }
            .padding(.horizontal, m.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.s2) { content() }
                    .padding(.horizontal, m.gutter)
            }
        }
    }
}

struct CarGrid: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    let items: [PlayableItem]
    var wide = false
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? m.tileWidth * 0.72 : m.tileWidth), spacing: Theme.s2)], spacing: Theme.s3) {
                ForEach(items) { item in
                    CarTileButton(item: item, queue: items, progress: env.progress.progress(for: item.ref)?.fraction, wide: wide, fixedWidth: false)
                }
            }
            .padding(.horizontal, m.gutter).padding(.bottom, m.gutter)
        }
        .overlay { if items.isEmpty { CarEmptyState(symbol: "tv", title: "Nothing to show") } }
    }
}

struct CarTileButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let item: PlayableItem
    var queue: [PlayableItem]? = nil
    var progress: Double? = nil
    var wide = false
    var fixedWidth = true

    var body: some View {
        Button {
            playback.play(item, queue: queue, origin: .car)
        } label: {
            Group {
                if item.isLocal {
                    VideoThumbCell(item: item, progress: progress, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                } else {
                    ChannelTile(item: item, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id, progress: progress, compact: m.compact)
                }
            }
            .if(fixedWidth) { $0.frame(width: item.isLocal ? m.tileWidth * 0.72 : m.tileWidth) }
        }
        .buttonStyle(CarFocusButtonStyle())
        .contextMenu {
            Button { env.favorites.toggle(item.ref) } label: {
                Label(env.favorites.isFavorite(item) ? "Remove Favorite" : "Add to Favorites", systemImage: "heart")
            }
        }
    }
}

struct CarSourceCard: View {
    @Environment(\.carMetrics) private var m
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: symbol).font(.system(size: m.compact ? 20 : 26, weight: .semibold)).foregroundStyle(tint)
                .frame(width: m.compact ? 30 : 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: m.compact ? 15 : 18, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(.system(size: m.compact ? 11 : 13, weight: .medium)).foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
        .frame(minHeight: Theme.Car.minTarget)
        .contentShape(Rectangle())
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
    }
}

struct CarEmptyState: View {
    @Environment(\.carMetrics) private var m
    let symbol: String
    let title: LocalizedStringResource
    var message: LocalizedStringResource? = nil
    var body: some View {
        VStack(spacing: Theme.s2) {
            Image(systemName: symbol).font(.system(size: m.compact ? 30 : 44, weight: .medium)).foregroundStyle(Theme.accent)
            Text(title).font(Theme.Car.title(m.compact ? 16 : 22)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            if let message { Text(message).font(.system(size: m.compact ? 12 : 15)).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center).frame(maxWidth: 420) }
        }
        .padding(m.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
