import UniformTypeIdentifiers
import SwiftUI
import SwiftData
import PhotosUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Binding var showAddSource: Bool

    @Query(sort: [SortDescriptor(\Playlist.sortOrder), SortDescriptor(\Playlist.createdAt)]) private var playlists: [Playlist]
    @Query(sort: [SortDescriptor(\VideoFolder.sortOrder)]) private var folders: [VideoFolder]
    @Query(filter: #Predicate<LocalVideo> { $0.folder == nil }, sort: [SortDescriptor(\LocalVideo.importedAt, order: .reverse)]) private var looseVideos: [LocalVideo]

    /// One `fileImporter` for both files and folders. Two `.fileImporter` modifiers
    /// on the same view fight over the presentation: the picker sticks on "Loading"
    /// and the callback never fires. `picker` selects what the single one asks for.
    enum FilePicker { case files, folder }
    @State private var picker: FilePicker?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importPhase: LocalImporter.Phase = .idle
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var deleting: Playlist?
    @State private var renamingFolder: VideoFolder?
    @State private var folderName = ""
    @State private var deletingFolder: VideoFolder?
    @State private var refreshing: Set<UUID> = []
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                favoritesSection
                if env.settings.mytvEnabled { mytvSection }
                sourcesSection
                localSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MoreToolbarMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAddSource = true } label: { Label("Add Playlist", systemImage: "link.badge.plus") }
                        Divider()
                        Button { picker = .files } label: { Label("Import Video Files", systemImage: "doc.badge.plus") }
                        Button { picker = .folder } label: { Label("Import Folder", systemImage: "folder.badge.plus") }
                        Button { showPhotoPicker = true } label: { Label("Import from Photos", systemImage: "photo.on.rectangle.angled") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .task(id: env.settings.mytvEnabled) { if env.settings.mytvEnabled { env.vod.loadIfNeeded() } }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            // Every VOD screen is a value route on this one stack. Mixing closure-
            // based links with value destinations made SwiftUI re-push the hub.
            .navigationDestination(for: VODRoute.self) { route in
                switch route {
                case .hub:                    VODHubView()
                case .movie(let m):           MovieDetailView(movie: m)
                case .series(let s):          SeriesDetailView(series: s)
                case .grid(let t, let m, let s): VODGridView(title: t, movies: m, series: s)
                }
            }
            .navigationDestination(for: VideoFolder.self) { FolderDetailView(folder: $0) }
            .fileImporter(
                isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                allowedContentTypes: picker == .folder ? [.folder] : LocalImporter.videoTypes,
                allowsMultipleSelection: picker != .folder
            ) { result in
                picker = nil
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error): toast = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .videos)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let picked = items; photoItems = []
                Task {
                    var movies: [(url: URL, title: String)] = []
                    for (i, item) in picked.enumerated() {
                        importPhase = .importing(done: i, total: picked.count, name: String(localized: "Importing…"))
                        if let movie = try? await item.loadTransferable(type: TransferableMovie.self) { movies.append((movie.url, movie.originalName)) }
                    }
                    let importer = LocalImporter(container: env.modelContainer)
                    let s = await importer.importMovieFiles(movies, into: nil) { importPhase = $0 }
                    toast = String(localized: "Imported \(s.imported) videos")
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { if let p = renaming { env.library.rename(p, to: renameText) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
                TextField("Name", text: $folderName)
                Button("Save") { if let f = renamingFolder { env.library.rename(f, to: folderName) }; renamingFolder = nil }
                    .disabled(folderName.trimmed.isEmpty)
                Button("Cancel", role: .cancel) { renamingFolder = nil }
            }
            .confirmationDialog(
                "Delete “\(deletingFolder?.name ?? "")”?",
                isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Folder and Videos", role: .destructive) { if let f = deletingFolder { env.library.delete(f, deleteFiles: true) }; deletingFolder = nil }
                Button("Delete Folder, Keep Videos") { if let f = deletingFolder { env.library.delete(f, deleteFiles: false) }; deletingFolder = nil }
            } message: { Text("Keeping the videos moves them to “Videos”.") }
            .confirmationDialog("Delete Playlist", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let p = deleting { env.library.delete(p) }; deleting = nil }
            } message: { Text("This removes the playlist and its channels from CarTV.") }
            .overlay(alignment: .bottom) { importOverlay }
            .overlay(alignment: .top) {
                if let toast {
                    BannerView(banner: ImportBanner(text: toast, isError: false))
                        .task { try? await Task.sleep(for: .seconds(2.5)); self.toast = nil }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var favoritesSection: some View {
        let _ = env.favorites.revision
        let count = env.favorites.favoriteItems().count
        Section {
            NavigationLink { FavoritesView() } label: {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "heart.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.live).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Favorites").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                        Text(count == 0 ? String(localized: "Long-press anything to save it here") : String(localized: "\(count) saved"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    @ViewBuilder private var mytvSection: some View {
        Section {
            NavigationLink(value: VODRoute.hub) {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "popcorn.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Movies & Series").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                        Text(vodSubtitle).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        } header: {
            Text("MyTV+").eyebrow()
        }
    }

    private var vodSubtitle: String {
        let v = env.vod
        if v.movies.isEmpty {
            if case .failed = v.phase { return String(localized: "Couldn't load — tap to retry") }
            return String(localized: "Loading catalogue…")
        }
        return String(localized: "\(v.movies.count) movies · \(v.series.count) series")
    }

    @ViewBuilder private var sourcesSection: some View {
        Section {
            if playlists.isEmpty {
                Button { showAddSource = true } label: {
                    Label("Add an M3U playlist", systemImage: "link.badge.plus").foregroundStyle(Theme.accent)
                }
            }
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    PlaylistRow(playlist: playlist, isRefreshing: refreshing.contains(playlist.id) || env.health.isChecking(playlist))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deleting = playlist } label: { Label("Delete", systemImage: "trash") }
                    Button { renameText = playlist.name; renaming = playlist } label: { Label("Rename", systemImage: "pencil") }.tint(Theme.amber)
                    if playlist.canRefresh {
                        Button { refresh(playlist) } label: { Label("Refresh", systemImage: "arrow.clockwise") }.tint(Theme.accent)
                    }
                }
                .contextMenu {
                    if playlist.canRefresh { Button { refresh(playlist) } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
                    Button { env.health.check(playlist, force: true) } label: { Label("Check channels", systemImage: "waveform.path.ecg") }
                    Button { renameText = playlist.name; renaming = playlist } label: { Label("Rename", systemImage: "pencil") }
                    if let url = playlist.sourceURL {
                        Button { UIPasteboard.general.url = url; toast = String(localized: "Copied") } label: { Label("Copy Subscription URL", systemImage: "doc.on.doc") }
                    }
                    Button(role: .destructive) { deleting = playlist } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .onMove { from, to in
                var arr = playlists; arr.move(fromOffsets: from, toOffset: to); env.library.move(arr)
            }
        } header: {
            Text("My Sources").eyebrow()
        }
        
    }

    @ViewBuilder private var localSection: some View {
        Section {
            ForEach(folders) { folder in
                NavigationLink(value: folder) {
                    HStack(spacing: Theme.s3) {
                        Image(systemName: "folder.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.amber).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                            Text("\(folder.videos.count) videos").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deletingFolder = folder } label: { Label("Delete", systemImage: "trash") }
                    Button { folderName = folder.name; renamingFolder = folder } label: { Label("Rename", systemImage: "pencil") }.tint(Theme.amber)
                }
                .contextMenu {
                    Button { folderName = folder.name; renamingFolder = folder } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { deletingFolder = folder } label: { Label("Delete Folder", systemImage: "trash") }
                }
            }
            if !looseVideos.isEmpty {
                NavigationLink { LocalVideosGridView(videos: looseVideos, title: String(localized: "Videos")) } label: {
                    HStack(spacing: Theme.s3) {
                        Image(systemName: "film.stack.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Videos").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                            Text("\(looseVideos.count) videos").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
            }
            if folders.isEmpty && looseVideos.isEmpty {
                Button { picker = .files } label: {
                    Label("Import Video Files", systemImage: "doc.badge.plus").foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("Local").eyebrow()
        } footer: {
            Text("Bring videos over from your phone and play them on the road").font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
        }
        
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

    // MARK: Actions

    private func importFiles(_ urls: [URL]) {
        Task {
            let importer = LocalImporter(container: env.modelContainer)
            let s = await importer.importFiles(urls, into: nil) { importPhase = $0 }
            toast = switch (s.imported, s.skipped) {
            case (0, _):      String(localized: "No videos imported — check the files are downloaded and are video files")
            case (_, 0):      String(localized: "Imported \(s.imported) videos")
            default:          String(localized: "Imported \(s.imported), skipped \(s.skipped)")
            }
        }
    }

    private func refresh(_ playlist: Playlist) {
        refreshing.insert(playlist.id)
        Task {
            let importer = PlaylistImporter(container: env.modelContainer)
            do {
                let s = try await importer.refresh(playlist.id)
                toast = String(localized: "Refreshed \(s.name)")
            } catch {
                toast = error.localizedDescription
            }
            refreshing.remove(playlist.id)
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    let isRefreshing: Bool
    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: playlist.kind == .subscription ? "antenna.radiowaves.left.and.right" : "list.bullet")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(TileTint.color(for: playlist.name)).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(Theme.Font.headline).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(playlist.channelCount) channels")
                    if let err = playlist.lastError {
                        Text("·"); Text(err).foregroundStyle(Theme.amber).lineLimit(1)
                    } else if let d = playlist.lastRefreshedAt {
                        Text("·"); Text(d.formatted(.relative(presentation: .named)))
                    }
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            if isRefreshing { ProgressView().controlSize(.small) }
        }
    }
}
