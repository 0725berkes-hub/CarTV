import OSLog
import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// Home: one calm column. Status lives in the toolbar as a pill, not a card.
/// Order: Continue Watching → Favorites → Videos → one section per playlist.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Binding var showAddSource: Bool

    @Query(sort: [SortDescriptor(\Playlist.sortOrder), SortDescriptor(\Playlist.createdAt)]) private var playlists: [Playlist]
    @Query(sort: [SortDescriptor(\LocalVideo.importedAt, order: .reverse)]) private var localVideos: [LocalVideo]

    @State private var searchText = ""
    @State private var selectedPlaylist: Playlist?
    @State private var showAllVideos = false
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importPhase: LocalImporter.Phase = .idle

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty && localVideos.isEmpty {
                    emptyState
                } else if !searchText.isEmpty {
                    SearchResultsView(query: searchText)
                } else {
                    feed
                }
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if playback.carIsConnected {
                    ToolbarItem(placement: .topBarLeading) {
                        Image(systemName: "car.fill").foregroundStyle(Theme.accent).accessibilityLabel("Car connected")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { addMenu }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Channels, videos…"))
            .navigationDestination(item: $selectedPlaylist) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(isPresented: $showAllVideos) { LocalVideosGridView(videos: localVideos, title: String(localized: "Videos")) }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .videos)
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: LocalImporter.videoTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { importFiles(urls) }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let picked = items; photoItems = []
                importPhotos(picked)
            }
            .overlay(alignment: .bottom) { importOverlay }
        }
    }

    // MARK: Feed

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s6) {
                ContinueWatchingShelf()

                FavoritesShelf()

                if !localVideos.isEmpty {
                    HomeSection(title: "Videos", count: localVideos.count, symbol: "film.stack.fill", seeAll: { showAllVideos = true }) {
                        VideoGrid3(videos: Array(localVideos.prefix(6)))
                    }
                }

                ForEach(playlists) { playlist in
                    HomeSection(title: LocalizedStringResource(stringLiteral: playlist.name),
                                count: playlist.channelCount, symbol: "antenna.radiowaves.left.and.right",
                                seeAll: { selectedPlaylist = playlist }) {
                        PlaylistStrip(playlist: playlist)
                    }
                }
            }
            .padding(.top, Theme.s2)
            .padding(.bottom, Theme.s10 + Theme.s6)
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: Theme.s6) {
            Spacer()
            Image(.launchLogo).resizable().scaledToFit().frame(width: 132)
            VStack(spacing: Theme.s2) {
                Text("Nothing here yet").font(Theme.Font.title).foregroundStyle(Theme.ink)
                Text("Add an IPTV playlist or bring in videos from your phone. Everything shows up on the car screen too.")
                    .font(Theme.Font.callout).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            VStack(spacing: Theme.s2) {
                Button { showAddSource = true } label: {
                    Label("Add Playlist", systemImage: "link.badge.plus").font(Theme.Font.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.s3)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                HStack(spacing: Theme.s2) {
                    QuickAction(symbol: "photo.on.rectangle.angled", title: "From Photos") { showPhotoPicker = true }
                    QuickAction(symbol: "doc.badge.plus", title: "From Files") { showFilePicker = true }
                }
            }
            .padding(.horizontal, Theme.s6)
            Spacer()
            Spacer()
        }
    }

    // MARK: Toolbar

    private var addMenu: some View {
        Menu {
            Button { showAddSource = true } label: { Label("Add Playlist", systemImage: "link.badge.plus") }
            Divider()
            Button { showPhotoPicker = true } label: { Label("Import from Photos", systemImage: "photo.on.rectangle.angled") }
            Button { showFilePicker = true } label: { Label("Import Video Files", systemImage: "doc.badge.plus") }
        } label: { Image(systemName: "plus") }
        .accessibilityLabel("Add")
    }

    @ViewBuilder private var importOverlay: some View {
        if case .importing(let done, let total, let name) = importPhase {
            HStack(spacing: Theme.s3) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Theme.accent)
                Text("\(done)/\(total) · \(name)").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            .padding(Theme.s3)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            .padding(Theme.s4)
        }
    }

    // MARK: Import

    private func importFiles(_ urls: [URL]) {
        Task {
            _ = await LocalImporter(container: env.modelContainer).importFiles(urls, into: nil) { importPhase = $0 }
        }
    }

    private func importPhotos(_ picked: [PhotosPickerItem]) {
        Task {
            var movies: [(url: URL, title: String)] = []
            for (i, item) in picked.enumerated() {
                importPhase = .importing(done: i, total: picked.count, name: String(localized: "Importing…"))
                if let movie = try? await item.loadTransferable(type: TransferableMovie.self) { movies.append((movie.url, movie.originalName)) }
            }
            _ = await LocalImporter(container: env.modelContainer).importMovieFiles(movies, into: nil) { importPhase = $0 }
        }
    }
}

// MARK: - Section chrome

struct HomeSection<Content: View>: View {
    let title: LocalizedStringResource
    var count: Int? = nil
    var symbol: String? = nil
    var seeAll: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            ShelfHeader(title: title, subtitle: count.map { "\($0)" }, actionTitle: seeAll == nil ? nil : "See all", action: seeAll)
            content()
        }
    }
}

// MARK: - Shelves

/// Movies, episodes and local videos with a real resume point. Tapping resumes
/// exactly where you stopped; swipe/long-press to remove one from the shelf.
struct ContinueWatchingShelf: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        let _ = env.progress.revision
        let _ = env.vod.movies.count    // VOD items resolve from the in-memory catalogue
        let items = env.progress.continueWatching(limit: 12)
        if !items.isEmpty {
            HomeSection(title: "Continue Watching", count: items.count, symbol: "play.circle.fill") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.s3) {
                        ForEach(items, id: \.0.id) { item, p in
                            Button { playback.play(item, origin: .phone, resume: true) } label: {
                                ContinueCard(item: item, progress: p)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { playback.play(item, origin: .phone, resume: false) } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                                Button(role: .destructive) { env.progress.remove(item.ref) } label: { Label("Remove from Continue Watching", systemImage: "xmark") }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.s4)
                }
            }
        }
    }
}

private struct ContinueCard: View {
    let item: PlayableItem
    let progress: WatchProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                ZStack {
                    TileTint.gradient(for: item.title)
                    RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 480, height: 270), contentMode: .fill) {
                        Image(systemName: "play.rectangle").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.6))
                    }
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "play.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white).shadow(radius: 4)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\((progress.duration - progress.position).clockString) left")
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                    }
                    .font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                    ProgressBar(fraction: progress.fraction, height: 3)
                }
                .padding(8)
            }
            .frame(width: 220)
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            Text(item.title).font(Theme.Font.tile).foregroundStyle(Theme.ink).lineLimit(1)
            if let sub = item.subtitle { Text(sub).font(Theme.Font.label).foregroundStyle(Theme.inkMuted).lineLimit(1) }
        }
        .frame(width: 220)
        .contentShape(Rectangle())
    }
}

struct FavoritesShelf: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    var body: some View {
        let _ = env.favorites.revision
        let items = env.favorites.favoriteItems()
        if !items.isEmpty {
            HomeSection(title: "Favorites", count: items.count, symbol: "heart.fill") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.s2) {
                        ForEach(items.prefix(20)) { item in
                            Button { playback.play(item, queue: items, origin: .phone) } label: {
                                if item.isLocal {
                                    VideoThumbCell(item: item, isFavorite: true).frame(width: 104)
                                } else {
                                    ChannelTile(item: item, isFavorite: true, isPlaying: playback.current?.id == item.id, compact: true).frame(width: 140)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, Theme.s4)
                }
            }
        }
    }
}

/// Fixed 3-column grid of local videos (Home preview).
struct VideoGrid3: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let videos: [LocalVideo]
    var body: some View {
        let items = videos.map(PlayableItem.init(video:))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.s2), count: 3), spacing: Theme.s3) {
            ForEach(Array(zip(videos, items)), id: \.1.id) { _, item in
                Button { playback.play(item, queue: nil, origin: .phone) } label: {
                    VideoThumbCell(item: item, progress: env.progress.progress(for: item.ref)?.fraction, isFavorite: env.favorites.isFavorite(item))
                }
                .buttonStyle(.plain)
                .contextMenu { ItemContextMenu(item: item) }
            }
        }
        .padding(.horizontal, Theme.s4)
    }
}

/// One horizontal row of channels for a playlist.
struct PlaylistStrip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let playlist: Playlist

    var body: some View {
        let _ = env.library.revision
        let channels = env.library.channels(in: playlist, limit: 20)
        let items = channels.map { PlayableItem(channel: $0, playlistName: playlist.name) }
        if items.isEmpty {
            Text(playlist.lastError ?? String(localized: "Nothing to show"))
                .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).padding(.horizontal, Theme.s4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.s2) {
                    ForEach(Array(zip(channels, items)), id: \.1.id) { channel, item in
                        Button { playback.play(item, queue: nil, origin: .phone) } label: {
                            ChannelTile(item: item, health: channel.health, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id, compact: true)
                                .frame(width: 140)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { ItemContextMenu(item: item) }
                    }
                }
                .padding(.horizontal, Theme.s4)
            }
        }
    }
}

// MARK: - Bits

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.caption)
                .padding(.horizontal, Theme.s3).padding(.vertical, 8)
                .foregroundStyle(selected ? Color.black : Theme.ink)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
    }
}

/// Long-press menu shared by every tile.
struct ItemContextMenu: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let item: PlayableItem
    var body: some View {
        let fav = env.favorites.isFavorite(item)
        Button { playback.play(item, queue: nil, origin: .phone) } label: { Label("Play", systemImage: "play.fill") }
        Button {
            env.favorites.toggle(item.ref)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Label(fav ? "Remove Favorite" : "Add to Favorites", systemImage: fav ? "heart.slash" : "heart")
        }
        if !item.isLocal {
            Button { UIPasteboard.general.url = item.url } label: { Label("Copy Stream URL", systemImage: "link") }
        }
    }
}
