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

    // Multi-select
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var showMove = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false

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
        for v in list { groups[v.title.indexKey, default: []].append(v) }
        return groups.keys.sorted { a, b in
            if a == "#" { return false }; if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, groups[$0]!) }
    }

    private var selectedVideos: [LocalVideo] { videos.filter { selection.contains($0.id) } }

    var body: some View {
        let list = sorted
        let items = list.map(PlayableItem.init(video:))
        let cols = [GridItem(.adaptive(minimum: 156), spacing: Theme.s3)]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4, pinnedViews: .sectionHeaders) {
                ForEach(grouped, id: \.key) { group in
                    Section {
                        LazyVGrid(columns: cols, spacing: Theme.s3) {
                            ForEach(group.videos) { video in
                                let item = PlayableItem(video: video)
                                let picked = selection.contains(video.id)
                                Button {
                                    if selecting { toggle(video) } else { playback.play(item, queue: items, origin: .phone, resume: true) }
                                } label: {
                                    ItemCell(item: item)
                                        .overlay(alignment: .topLeading) { if selecting { SelectionBadge(on: picked).padding(8) } }
                                        .opacity(selecting && !picked ? 0.72 : 1)
                                        .overlay {
                                            if picked {
                                                RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous)
                                                    .strokeBorder(Theme.accent, lineWidth: 2.5)
                                                    .frame(maxHeight: .infinity, alignment: .top)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .animation(.easeOut(duration: 0.15), value: picked)
                                .contextMenu {
                                    if !selecting {
                                        ItemContextMenu(item: item)
                                        Divider()
                                        Button { selecting = true; selection = [video.id] } label: { Label("Select", systemImage: "checkmark.circle") }
                                        Button { renameText = video.title; renaming = video } label: { Label("Rename", systemImage: "pencil") }
                                        Button(role: .destructive) { env.library.delete(video) } label: { Label("Delete", systemImage: "trash") }
                                    }
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
            .padding(.bottom, selecting ? Theme.s10 + 56 : Theme.s10)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(selecting ? (selection.isEmpty ? String(localized: "Select Videos") : String(localized: "\(selection.count) Selected")) : title)
        .navigationSubtitle(selecting ? Text("") : Text("\(videos.count) videos"))
        .navigationBarBackButtonHidden(selecting)
        .searchable(text: $query, prompt: Text("Find a video"))
        .toolbar { toolbarContent(items: items, visible: list) }
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .overlay { if list.isEmpty { EmptyState(symbol: "film", title: query.isEmpty ? "No videos in that folder" : "No matches") } }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let v = renaming { env.library.rename(v, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            selection.count == 1 ? "Delete this video?" : "Delete \(selection.count) videos?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                env.library.delete(selectedVideos)
                endSelecting()
            }
        } message: { Text("The files are removed from this iPhone.") }
        .confirmationDialog("Move to", isPresented: $showMove, titleVisibility: .visible) {
            ForEach(env.library.folders()) { f in
                Button(f.name) { env.library.move(selectedVideos, to: f); endSelecting() }
            }
            Button("Videos (no folder)") { env.library.move(selectedVideos, to: nil); endSelecting() }
            Button("New Folder…") { showNewFolder = true }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create & Move") {
                let f = env.library.createFolder(named: newFolderName)
                env.library.move(selectedVideos, to: f)
                newFolderName = ""
                endSelecting()
            }.disabled(newFolderName.trimmed.isEmpty)
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(items: [PlayableItem], visible: [LocalVideo]) -> some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == visible.count ? "Deselect All" : "Select All") {
                    selection = selection.count == visible.count ? [] : Set(visible.map(\.id))
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { endSelecting() } }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button { playback.playRandom(from: items, origin: .phone) } label: { Image(systemName: "shuffle") }
                    .disabled(items.isEmpty)
                    .accessibilityLabel("Shuffle")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    Divider()
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.title).tag($0) } }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(items.isEmpty)
            }
        }
    }

    /// Bottom bar while selecting — Files/Photos style: actions in a row, count in the title.
    private var selectionBar: some View {
        let n = selection.count
        let picked = selectedVideos
        let allFav = !picked.isEmpty && picked.allSatisfy { env.favorites.isFavorite(PlayableItem(video: $0)) }
        return HStack(spacing: 0) {
            barButton("play.fill", "Play") {
                let q = picked.map(PlayableItem.init(video:))
                if let first = q.first { playback.play(first, queue: q, origin: .phone, resume: true); endSelecting() }
            }
            barButton(allFav ? "heart.slash" : "heart", allFav ? "Unfavorite" : "Favorite") {
                for v in picked {
                    let ref = PlayableRef(id: v.id, kind: .localVideo)
                    if allFav { env.favorites.remove(ref) } else { env.favorites.add(ref) }
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            barButton("folder", "Move") { showMove = true }
            barButton("trash", "Delete", destructive: true) { confirmDelete = true }
        }
        .disabled(n == 0)
        .opacity(n == 0 ? 0.45 : 1)
        .padding(.horizontal, Theme.s2).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func barButton(_ symbol: String, _ title: LocalizedStringResource, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .contentShape(Rectangle())
        }
        .foregroundStyle(destructive ? Theme.live : Theme.accent)
    }

    // MARK: Selection

    private func toggle(_ v: LocalVideo) {
        if selection.contains(v.id) { selection.remove(v.id) } else { selection.insert(v.id) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func endSelecting() {
        withAnimation(.easeOut(duration: 0.2)) { selecting = false; selection = [] }
    }
}

/// Filled check when selected, hollow ring when not — the system look on photos/files.
struct SelectionBadge: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().fill(on ? Theme.accent : Color.black.opacity(0.35)).frame(width: 24, height: 24)
            Circle().strokeBorder(.white, lineWidth: on ? 0 : 1.5).frame(width: 24, height: 24)
            if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black) }
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .contentTransition(.symbolEffect(.replace))
    }
}
