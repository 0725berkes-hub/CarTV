import SwiftUI

struct PlaylistDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let playlist: Playlist

    @State private var genre: Genre? = nil        // nil = all
    @State private var channels: [Channel] = []
    @State private var genres: [(Genre, Int)] = []
    @State private var query = ""
    @State private var isRefreshing = false
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            genreTabs
            content
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Find a channel"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if playlist.canRefresh {
                        Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    Button { env.health.check(playlist, force: true) } label: { Label("Check channels", systemImage: "waveform.path.ecg") }
                    if let url = playlist.sourceURL {
                        Button { UIPasteboard.general.url = url; toast = String(localized: "Copied") } label: { Label("Copy Subscription URL", systemImage: "doc.on.doc") }
                    }
                } label: {
                    if isRefreshing || env.health.isChecking(playlist) { ProgressView().controlSize(.small) } else { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task(id: env.library.revision) { reload() }
        .onChange(of: genre) { _, _ in reload() }
        .overlay(alignment: .top) {
            if let toast {
                BannerView(banner: ImportBanner(text: toast, isError: false))
                    .task { try? await Task.sleep(for: .seconds(2)); self.toast = nil }
            } else if let p = env.health.progressText, env.health.isChecking(playlist) {
                BannerView(banner: ImportBanner(text: p, isError: false))
            }
        }
    }

    private var genreTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s2) {
                Chip(title: String(localized: "All"), selected: genre == nil) { genre = nil }
                ForEach(genres, id: \.0) { g, count in
                    Button { genre = g } label: {
                        HStack(spacing: 6) {
                            Image(systemName: g.symbol).font(.system(size: 11, weight: .semibold))
                            Text(g.title)
                            Text("\(count)").foregroundStyle(genre == g ? .black.opacity(0.6) : Theme.inkFaint).monospacedDigit()
                        }
                        .font(Theme.Font.caption)
                        .padding(.horizontal, Theme.s3).padding(.vertical, 7)
                        .background(genre == g ? Theme.accent : Theme.surface, in: Capsule())
                        .foregroundStyle(genre == g ? Color.black : Theme.ink)
                        .overlay(Capsule().strokeBorder(genre == g ? .clear : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
        }
    }

    @ViewBuilder private var content: some View {
        let filtered = query.isEmpty ? channels : channels.filter { $0.normalizedName.contains(query.searchNormalized) }
        if filtered.isEmpty {
            EmptyState(symbol: "tv", title: query.isEmpty ? "Nothing to show" : "No matches")
        } else {
            let items = filtered.map { PlayableItem(channel: $0, playlistName: playlist.name) }
            let healthByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0.health) })
            ItemGrid(items: items, healthLookup: { healthByID[$0.id] ?? .unknown })
                .onAppear {
                    ImageLoader.shared.prefetch(items.prefix(30).compactMap(\.artworkURL), targetSize: CGSize(width: 240, height: 135))
                }
        }
    }

    private func reload() {
        genres = env.library.genreCounts(in: playlist)
        channels = env.library.channels(in: playlist, genre: genre)
    }

    private func refresh() {
        isRefreshing = true
        Task {
            let importer = PlaylistImporter(container: env.modelContainer)
            do {
                let s = try await importer.refresh(playlist.id)
                toast = String(localized: "Found \(s.added) channels")
            } catch { toast = error.localizedDescription }
            isRefreshing = false
        }
    }
}

// MARK: - Local video screens

struct FolderDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let folder: VideoFolder
    var body: some View {
        let _ = env.library.revision
        LocalVideosGridView(videos: env.library.localVideos(in: folder), title: folder.name)
    }
}

struct LocalVideosGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let videos: [LocalVideo]
    let title: String
    @State private var renaming: LocalVideo?
    @State private var renameText = ""
    @State private var query = ""
    @State private var sort: Sort = .newest

    enum Sort: String, CaseIterable, Identifiable {
        case newest, name, duration
        var id: String { rawValue }
        var title: LocalizedStringResource { switch self { case .newest: "Newest"; case .name: "Name"; case .duration: "Longest" } }
    }

    private var sorted: [LocalVideo] {
        let base = query.isEmpty ? videos : videos.filter { $0.normalizedTitle.contains(query.searchNormalized) }
        switch sort {
        case .newest: return base.sorted { $0.importedAt > $1.importedAt }
        case .name: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .duration: return base.sorted { $0.duration > $1.duration }
        }
    }

    /// When sorted by name with many videos, group by first letter with sticky headers
    /// so a long library is scannable, like Contacts.
    private var grouped: [(key: String, videos: [LocalVideo])] {
        let list = sorted
        guard sort == .name, list.count > 24 else { return [("", list)] }
        var groups: [String: [LocalVideo]] = [:]
        for v in list { groups[CarGrid.indexKey(for: v.title), default: []].append(v) }
        return groups.keys.sorted { a, b in
            if a == "#" { return false }; if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, groups[$0]!) }
    }

    var body: some View {
        let list = sorted
        let items = list.map(PlayableItem.init(video:))
        let cols = [GridItem(.adaptive(minimum: 104), spacing: Theme.s2)]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4, pinnedViews: .sectionHeaders) {
                ForEach(grouped, id: \.key) { group in
                    Section {
                        LazyVGrid(columns: cols, spacing: Theme.s3) {
                            ForEach(group.videos) { video in
                                let item = PlayableItem(video: video)
                                Button { playback.play(item, queue: items, origin: .phone) } label: {
                                    VideoThumbCell(item: item, progress: env.progress.progress(for: item.ref)?.fraction, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    ItemContextMenu(item: item)
                                    Divider()
                                    Button { renameText = video.title; renaming = video } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { env.library.delete(video) } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.s4)
                    } header: {
                        if !group.key.isEmpty {
                            Text(group.key).font(Theme.Font.title2).foregroundStyle(Theme.inkMuted)
                                .padding(.horizontal, Theme.s4).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.ground.opacity(0.94))
                        }
                    }
                }
            }
            .padding(.top, Theme.s2)
            .padding(.bottom, Theme.s10)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationSubtitle(Text("\(videos.count) videos"))
        .searchable(text: $query, prompt: Text("Find a video"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.title).tag($0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .overlay { if list.isEmpty { EmptyState(symbol: "film", title: query.isEmpty ? "No videos in that folder" : "No matches") } }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let v = renaming { env.library.rename(v, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}
