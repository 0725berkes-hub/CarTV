import SwiftUI
import SwiftData

// MARK: - Home

struct CarHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @Query(sort: [SortDescriptor(\Playlist.sortOrder), SortDescriptor(\Playlist.createdAt)]) private var playlists: [Playlist]
    @Query(sort: [SortDescriptor(\VideoFolder.sortOrder)]) private var folders: [VideoFolder]
    @Query(sort: [SortDescriptor(\LocalVideo.importedAt, order: .reverse)]) private var videos: [LocalVideo]

    private var defaultVideoGroup: (name: String, videos: [LocalVideo])? {
        var groups: [(name: String, videos: [LocalVideo])] = []
        let loose = videos.filter { $0.folder == nil }
        if !loose.isEmpty { groups.append((String(localized: "Videos"), loose)) }
        for folder in folders {
            let folderVideos = videos.filter { $0.folder?.id == folder.id }
            if !folderVideos.isEmpty { groups.append((folder.name, folderVideos)) }
        }
        return groups.max { $0.videos.count < $1.videos.count }
    }

    var body: some View {
        let _ = env.library.revision
        let _ = env.progress.revision
        ScrollView {
            LazyVStack(alignment: .leading, spacing: m.compact ? Theme.s4 : Theme.s6) {
                if playlists.isEmpty && videos.isEmpty && env.favorites.favoriteItems().isEmpty {
                    CarEmptyState(symbol: "iphone.and.arrow.forward", title: "Add sources on your iPhone first", message: "Open CarFlix on your iPhone and add an M3U playlist or import videos. They appear here instantly.")
                }

                if let group = defaultVideoGroup {
                    Button {
                        playback.playRandom(from: group.videos.map(PlayableItem.init(video:)), origin: .car)
                    } label: {
                        HStack(spacing: Theme.s3) {
                            Image(systemName: "shuffle")
                                .font(.system(size: m.compact ? 18 : 22, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: m.compact ? 32 : 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Shuffle \(group.name)"))
                                    .font(.system(size: m.compact ? 14 : 17, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text(String(localized: "\(group.videos.count) videos"))
                                    .font(.system(size: m.compact ? 11 : 13, weight: .medium))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: m.compact ? 11 : 13, weight: .bold))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.horizontal, m.compact ? Theme.s3 : Theme.s4)
                        .frame(height: m.compact ? 54 : 64)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).strokeBorder(Theme.accent.opacity(0.28)))
                    }
                    .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                    .padding(.horizontal, m.gutter)
                }

                BrowserShortcuts(isCar: true).padding(.horizontal, m.gutter)

                let favs = env.favorites.favoriteItems()
                if !favs.isEmpty {
                    CarShelf(title: "Favorites", seeAll: favs.count > 8 ? .favorites : nil) {
                        ForEach(favs.prefix(16)) { item in CarTileButton(item: item, queue: favs) }
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


                ForEach(playlists) { playlist in
                    let items = env.library.channels(in: playlist, limit: 16).map { PlayableItem(channel: $0, playlistName: playlist.name) }
                    if !items.isEmpty {
                        CarShelf(title: LocalizedStringResource(stringLiteral: playlist.name), seeAll: .playlist(playlist)) {
                            ForEach(items) { item in CarTileButton(item: item, queue: nil) }
                        }
                    }
                }

            }
            .padding(.top, Theme.s2)
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

    @State private var query = ""
    @State private var searchItems: [PlayableItem] = []

    var body: some View {
        let _ = env.vod.movies.count
        let _ = env.favorites.revision
        Group {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CarGrid(items: searchItems)
            } else {
                sources
            }
        }
        .carSearchable(text: $query, prompt: "Search library")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            searchItems = env.library.searchChannels(query).map { PlayableItem(channel: $0, playlistName: $0.playlist?.name) }
                + env.library.searchLocalVideos(query).map(PlayableItem.init(video:))
        }
    }

    private var sources: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                let favCount = env.favorites.favoriteItems().count
                if favCount > 0 {
                    Button { push(CarRoute.favorites) } label: {
                        CarSourceCard(symbol: "heart.fill", title: String(localized: "Favorites"), subtitle: String(localized: "\(favCount) saved"), tint: Theme.live)
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
                if env.settings.mytvEnabled {
                    Button { push(CarRoute.movies) } label: {
                        CarSourceCard(symbol: "popcorn.fill", title: String(localized: "Movies"),
                                      subtitle: env.vod.movies.isEmpty ? String(localized: "Loading…") : String(localized: "\(env.vod.movies.count) movies"), tint: Theme.accent)
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                    Button { push(CarRoute.series) } label: {
                        CarSourceCard(symbol: "tv.fill", title: String(localized: "Series"),
                                      subtitle: env.vod.series.isEmpty ? String(localized: "Loading…") : String(localized: "\(env.vod.series.count) series"), tint: Theme.live)
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
                ForEach(playlists) { p in
                    Button { push(CarRoute.playlist(p)) } label: {
                        CarSourceCard(symbol: "antenna.radiowaves.left.and.right", title: p.name, subtitle: String(localized: "\(p.channelCount) channels"), tint: TileTint.color(for: p.name))
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
                ForEach(folders) { f in
                    Button { push(CarRoute.folder(f)) } label: {
                        CarSourceCard(symbol: "folder.fill", title: f.name, subtitle: String(localized: "\(f.videos.count) videos"), tint: Theme.amber)
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
                if !looseVideos.isEmpty {
                    Button { push(CarRoute.folder(VideoFolder.loose)) } label: {
                        CarSourceCard(symbol: "film.stack.fill", title: String(localized: "Videos"), subtitle: String(localized: "\(looseVideos.count) videos"), tint: Theme.accent)
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
            }
            .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
        }
        .overlay { if playlists.isEmpty && folders.isEmpty && looseVideos.isEmpty && !env.settings.mytvEnabled { CarEmptyState(symbol: "square.stack", title: "Your library is empty", message: "Add sources on your iPhone first") } }
        .task { if env.settings.mytvEnabled { env.vod.loadIfNeeded() } }
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
                Button { push(CarRoute.genre(playlist, nil)) } label: {
                    CarSourceCard(symbol: "square.grid.2x2.fill", title: String(localized: "All"), subtitle: String(localized: "\(playlist.channelCount) channels"), tint: Theme.accent)
                }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                ForEach(genres, id: \.0) { g, count in
                    Button { push(CarRoute.genre(playlist, g)) } label: {
                        CarSourceCard(symbol: g.symbol, title: String(localized: g.title), subtitle: String(localized: "\(count) channels"), tint: g.tint)
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
            }
            .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
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
    @State private var query = ""
    var body: some View {
        let _ = env.library.revision
        let videos = folder.id == VideoFolder.loose.id ? env.library.localVideos().filter { $0.folder == nil } : env.library.localVideos(in: folder)
        let filtered = query.isEmpty ? videos : videos.filter { $0.title.localizedStandardContains(query) }
        CarGrid(items: filtered.map(PlayableItem.init(video:)), shuffleable: true)
            .carSearchable(text: $query, prompt: "Search videos")
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
                            .padding(.horizontal, Theme.s3)
                            .frame(minHeight: m.compact ? 36 : 44)
                            .contentShape(Capsule())
                    }.buttonStyle(CarFocusButtonStyle(radius: 100))
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

/// Grid for the car. Large tiles (fewer, bigger targets), and when the list is
/// long an A–Z rail on the trailing edge jumps straight to a letter — the same
/// gesture people already know from Contacts, and far safer than scrolling 300 rows.
struct CarGrid: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let items: [PlayableItem]
    var wide = false
    /// Show a big "Shuffle" row at the top (videos, not live channels).
    var shuffleable = false

    private var showIndex: Bool { items.count > 24 }

    struct IndexSection: Identifiable { let key: String; let items: [PlayableItem]; var id: String { key } }

    /// Items sorted by title, grouped by first letter (digits/symbols → "#", last).
    private var sections: [IndexSection] {
        let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var groups: [String: [PlayableItem]] = [:]
        for it in sorted { groups[it.title.indexKey, default: []].append(it) }
        let keys = groups.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return keys.map { IndexSection(key: $0, items: groups[$0] ?? []) }
    }

    /// Compact Play / Shuffle pills, like the header actions in Music and TV.
    @ViewBuilder private var shuffleRow: some View {
        if shuffleable, items.count > 1 {
            HStack(spacing: Theme.s2) {
                actionPill("play.fill", "Play", prominent: true) {
                    if let first = items.first { playback.play(first, queue: items, origin: .car) }
                }
                actionPill("shuffle", "Shuffle", prominent: false) {
                    playback.playRandom(from: items, origin: .car)
                }
                Spacer(minLength: 0)
                Text("\(items.count) videos").font(.system(size: m.compact ? 12 : 14, weight: .medium)).foregroundStyle(Theme.inkMuted).monospacedDigit()
            }
            .padding(.horizontal, m.gutter)
            .padding(.bottom, Theme.s3)
        }
    }

    private func actionPill(_ symbol: String, _ title: LocalizedStringResource, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: m.compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Theme.ink)
                .padding(.horizontal, m.compact ? Theme.s4 : Theme.s5)
                .frame(height: m.compact ? 40 : 44)
                .contentShape(Capsule())
        }
        .buttonStyle(CarPressStyle())
        .glassEffect(prominent ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
    }

    var body: some View {
        let landscape = items.filter { !ItemCell.isPoster($0) }
        let posters = items.filter { ItemCell.isPoster($0) }
        if !landscape.isEmpty && !posters.isEmpty {
            // Mixed list (Favorites): never put a 16:9 tile next to a 2:3 poster.
            ScrollView {
                VStack(alignment: .leading, spacing: m.compact ? Theme.s4 : Theme.s6) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: m.tileWidth * 1.15), spacing: Theme.s3)], spacing: Theme.s3) {
                        ForEach(landscape) { item in CarTileButton(item: item, queue: landscape, progress: env.progress.progress(for: item.ref)?.fraction, fixedWidth: false) }
                    }
                    .padding(.horizontal, m.gutter)
                    Text("Movies").font(Theme.Car.title(m.compact ? 14 : 18)).foregroundStyle(Theme.ink).padding(.horizontal, m.gutter)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: m.tileWidth * 0.8), spacing: Theme.s3)], spacing: Theme.s3) {
                        ForEach(posters) { item in CarTileButton(item: item, queue: posters, progress: env.progress.progress(for: item.ref)?.fraction, fixedWidth: false) }
                    }
                    .padding(.horizontal, m.gutter)
                }
                .padding(.top, Theme.s2).padding(.bottom, m.gutter)
            }
        } else {
            uniformGrid
        }
    }

    private var uniformGrid: some View {
        let cols = [GridItem(.adaptive(minimum: wide ? m.tileWidth * 0.8 : m.tileWidth * 1.15), spacing: Theme.s3)]
        return ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    shuffleRow
                    if showIndex {
                        LazyVStack(alignment: .leading, spacing: Theme.s4, pinnedViews: .sectionHeaders) {
                            ForEach(sections) { section in
                                Section {
                                    LazyVGrid(columns: cols, spacing: Theme.s3) {
                                        ForEach(section.items) { item in
                                            CarTileButton(item: item, queue: items, progress: env.progress.progress(for: item.ref)?.fraction, wide: wide, fixedWidth: false)
                                        }
                                    }
                                    .padding(.horizontal, m.gutter)
                                } header: {
                                    Text(section.key)
                                        .font(Theme.Car.title(m.compact ? 16 : 22)).foregroundStyle(Theme.inkMuted)
                                        .padding(.horizontal, m.gutter).padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.ground.opacity(0.92))
                                        .id("section-\(section.key)")
                                }
                            }
                        }
                        .padding(.bottom, m.gutter)
                    } else {
                        LazyVGrid(columns: cols, spacing: Theme.s3) {
                            ForEach(items) { item in
                                CarTileButton(item: item, queue: items, progress: env.progress.progress(for: item.ref)?.fraction, wide: wide, fixedWidth: false)
                            }
                        }
                        .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
                    }
                }
                if showIndex {
                    CarIndexRail(keys: sections.map(\.key)) { key in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("section-\(key)", anchor: .top) }
                    }
                }
            }
        }
        .overlay { if items.isEmpty { CarEmptyState(symbol: "tv", title: "Nothing to show") } }
    }
}

/// Trailing-edge letter rail. Tap or drag your finger along it; each letter is a
/// full-height touch target so it works with a glance.
struct CarIndexRail: View {
    @Environment(\.carMetrics) private var m
    let keys: [String]
    let jump: (String) -> Void
    @State private var active: String?

    var body: some View {
        GeometryReader { geo in
            let rowH = max(14, min(28, geo.size.height / CGFloat(max(keys.count, 1))))
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { k in
                    Text(k)
                        .font(.system(size: m.compact ? 11 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(active == k ? Color.black : Theme.accent)
                        .frame(width: m.compact ? 28 : 36, height: rowH)
                        .background(active == k ? Theme.accent : .clear, in: Capsule())
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let idx = Int((v.location.y - (geo.size.height - rowH * CGFloat(keys.count)) / 2) / rowH)
                        guard keys.indices.contains(idx) else { return }
                        if active != keys[idx] {
                            active = keys[idx]
                            jump(keys[idx])
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in active = nil }
            )
        }
        .frame(width: m.compact ? 36 : 44)
        .padding(.trailing, Theme.s1)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.vertical, Theme.s3)
        .padding(.trailing, Theme.s2)
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
                if ItemCell.isPoster(item) {
                    PosterTile(item: item, progress: progress, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                } else if item.ref.kind == .channel {
                    ChannelTile(item: item, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id, progress: progress, compact: m.compact)
                } else {
                    VideoCard(item: item, progress: progress, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                }
            }
            // Same two-shape rule as the phone: movie posters are narrow, everything
            // else (channels, YouTube, videos, episodes) is a 16:9 card at tile width.
            .if(fixedWidth) { $0.frame(width: ItemCell.isPoster(item) ? m.tileWidth * 0.62 : m.tileWidth) }
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
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
    var assetName: String? = nil
    var body: some View {
        HStack(spacing: Theme.s3) {
            Group {
                if let assetName {
                    Image(assetName).resizable().scaledToFit()
                        .frame(width: m.compact ? 30 : 40, height: m.compact ? 30 : 40)
                } else {
                    Image(systemName: symbol).font(.system(size: m.compact ? 20 : 26, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: m.compact ? 30 : 40)
                }
            }
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
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
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


private struct CarSearchModifier: ViewModifier {
    @Binding var text: String
    let prompt: String
    var submit: () -> Void
    @Environment(\.carMetrics) private var m
    @State private var showsKeyboard = false
    @Environment(CarKeyboardPresentation.self) private var keyboard: CarKeyboardPresentation?

    func body(content: Content) -> some View {
        VStack(spacing: Theme.s2) {
            Button {
                if let keyboard {
                    keyboard.show(text: $text, placeholder: prompt, onGo: submit, onDone: {})
                } else { showsKeyboard = true }
            } label: {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.accent)
                    Text(text.isEmpty ? prompt : text).lineLimit(1)
                        .foregroundStyle(text.isEmpty ? Theme.inkMuted : Theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "keyboard").foregroundStyle(Theme.inkMuted)
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, Theme.s3).frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: Capsule()).contentShape(Rectangle())
            }
            .buttonStyle(CarPressStyle()).padding(.horizontal, m.gutter)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if showsKeyboard {
                CarBrowserKeyboard(text: $text, placeholder: prompt,
                    onGo: { showsKeyboard = false; submit() },
                    onDone: { showsKeyboard = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.ground)
            }
        }
    }
}

extension View {
    func carSearchable(text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {}) -> some View {
        modifier(CarSearchModifier(text: text, prompt: prompt, submit: onSubmit))
    }
}
