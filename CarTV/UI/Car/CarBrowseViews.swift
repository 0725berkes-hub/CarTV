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
    @Query(sort: [SortDescriptor(\Playlist.sortOrder)]) private var playlists: [Playlist]
    @Query(sort: [SortDescriptor(\VideoFolder.sortOrder)]) private var folders: [VideoFolder]
    @Query(filter: #Predicate<LocalVideo> { $0.folder == nil }) private var looseVideos: [LocalVideo]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                ForEach(playlists) { p in
                    NavigationLink(value: CarRoute.playlist(p)) {
                        CarSourceCard(symbol: "antenna.radiowaves.left.and.right", title: p.name, subtitle: String(localized: "\(p.channelCount) channels"), tint: TileTint.color(for: p.name))
                    }.buttonStyle(CarFocusButtonStyle())
                }
                ForEach(folders) { f in
                    NavigationLink(value: CarRoute.folder(f)) {
                        CarSourceCard(symbol: "folder.fill", title: f.name, subtitle: String(localized: "\(f.videos.count) videos"), tint: Theme.amber)
                    }.buttonStyle(CarFocusButtonStyle())
                }
                if !looseVideos.isEmpty {
                    NavigationLink(value: CarRoute.folder(VideoFolder.loose)) {
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
    let playlist: Playlist
    var body: some View {
        let _ = env.library.revision
        let genres = env.library.genreCounts(in: playlist)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                NavigationLink(value: CarRoute.genre(playlist, nil)) {
                    CarSourceCard(symbol: "square.grid.2x2.fill", title: String(localized: "All"), subtitle: String(localized: "\(playlist.channelCount) channels"), tint: Theme.accent)
                }.buttonStyle(CarFocusButtonStyle())
                ForEach(genres, id: \.0) { g, count in
                    NavigationLink(value: CarRoute.genre(playlist, g)) {
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
        CarGrid(items: videos.map(PlayableItem.init(video:)), wide: true, shuffleable: true)
    }
}

// MARK: - Building blocks

struct CarShelf<Content: View>: View {
    @Environment(\.carMetrics) private var m
    let title: LocalizedStringResource
    var seeAll: CarRoute? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.Car.title(m.compact ? 15 : 20)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                if let seeAll {
                    NavigationLink(value: seeAll) {
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

    @ViewBuilder private var shuffleRow: some View {
        if shuffleable, items.count > 1 {
            Button { playback.playRandom(from: items, origin: .car) } label: {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "shuffle").font(.system(size: m.compact ? 18 : 22, weight: .bold))
                    Text("Shuffle Play").font(.system(size: m.compact ? 15 : 18, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    Text("\(items.count)").font(.system(size: m.compact ? 12 : 14, weight: .semibold)).monospacedDigit().foregroundStyle(.black.opacity(0.6))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, Theme.s4)
                .frame(height: m.compact ? 52 : Theme.Car.minTarget + 8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CarFocusButtonStyle())
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
            .padding(.horizontal, m.gutter)
            .padding(.bottom, Theme.s2)
        }
    }

    /// Items sorted by title, grouped by first letter (digits/symbols → "#").
    private var sections: [(key: String, items: [PlayableItem])] {
        let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var groups: [String: [PlayableItem]] = [:]
        for it in sorted { groups[Self.indexKey(for: it.title), default: []].append(it) }
        return groups.keys.sorted { a, b in
            if a == "#" { return false }; if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, groups[$0]!) }
    }

    nonisolated static func indexKey(for title: String) -> String {
        guard let c = title.trimmed.first else { return "#" }
        let s = String(c).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        return s.first?.isLetter == true ? s : "#"
    }

    var body: some View {
        let cols = [GridItem(.adaptive(minimum: wide ? m.tileWidth * 0.8 : m.tileWidth * 1.15), spacing: Theme.s3)]
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    shuffleRow
                    if showIndex {
                        LazyVStack(alignment: .leading, spacing: Theme.s4, pinnedViews: .sectionHeaders) {
                            ForEach(sections, id: \.key) { section in
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
                        .padding(.horizontal, m.gutter).padding(.bottom, m.gutter)
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
                if item.isLocal {
                    VideoThumbCell(item: item, progress: progress, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                } else {
                    ChannelTile(item: item, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id, progress: progress, compact: m.compact)
                }
            }
            .if(fixedWidth) { $0.frame(width: item.isLocal ? m.tileWidth * 0.72 : m.tileWidth) }
            .padding(6)
        }
        .buttonStyle(CarFocusButtonStyle())
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
