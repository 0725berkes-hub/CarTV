import OSLog
import Foundation
import SwiftData
import Observation

/// Main-actor façade over SwiftData for playlists, channels and local videos.
/// Heavy imports run on a background `ModelContext` inside `PlaylistImporter`.
@Observable
final class LibraryStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Bumped whenever the library changes so non-@Query consumers (CarPlay) can refresh.
    private(set) var revision = 0

    /// URLs handed to us by the system (Files app / Share sheet) awaiting import.
    var pendingExternalImports: [URL] = []

    init(container: ModelContainer) {
        self.container = container
    }

    func bump() { revision &+= 1 }

    // MARK: Playlists

    func playlists() -> [Playlist] {
        let d = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        return (try? context.fetch(d)) ?? []
    }

    func playlist(id: UUID) -> Playlist? {
        var d = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func channels(in playlist: Playlist, genre: Genre? = nil, limit: Int? = nil) -> [Channel] {
        let pid = playlist.id
        var d: FetchDescriptor<Channel>
        if let genre {
            let g = genre.rawValue
            d = FetchDescriptor(predicate: #Predicate { $0.playlistID == pid && $0.genreRaw == g })
        } else {
            d = FetchDescriptor(predicate: #Predicate { $0.playlistID == pid })
        }
        d.sortBy = [SortDescriptor(\.orderIndex)]
        if let limit { d.fetchLimit = limit }
        return (try? context.fetch(d)) ?? []
    }

    private var genreCache: [UUID: (rev: Int, counts: [(Genre, Int)])] = [:]

    /// Genres present in a playlist with counts, in canonical `Genre` order.
    /// One fetch of the `genreRaw` column, grouped in memory, cached per revision.
    func genreCounts(in playlist: Playlist) -> [(Genre, Int)] {
        let pid = playlist.id
        if let c = genreCache[pid], c.rev == revision { return c.counts }
        var d = FetchDescriptor<Channel>(predicate: #Predicate { $0.playlistID == pid })
        d.propertiesToFetch = [\.genreRaw]
        let rows = (try? context.fetch(d)) ?? []
        var tally: [String: Int] = [:]
        for r in rows { tally[r.genreRaw, default: 0] += 1 }
        let result = Genre.allCases.compactMap { g -> (Genre, Int)? in
            guard let n = tally[g.rawValue], n > 0 else { return nil }
            return (g, n)
        }
        genreCache[pid] = (revision, result)
        return result
    }

    func channelsByGenre(in playlist: Playlist) -> [(Genre, [Channel])] {
        genreCounts(in: playlist).map { ($0.0, channels(in: playlist, genre: $0.0)) }
    }

    func channel(id: UUID) -> Channel? {
        var d = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func searchChannels(_ query: String, limit: Int = 100) -> [Channel] {
        let q = query.searchNormalized
        guard !q.isEmpty else { return [] }
        var d = FetchDescriptor<Channel>(predicate: #Predicate { $0.normalizedName.contains(q) })
        d.fetchLimit = limit
        d.sortBy = [SortDescriptor(\.normalizedName)]
        return (try? context.fetch(d)) ?? []
    }

    func rename(_ playlist: Playlist, to name: String) {
        playlist.name = name.trimmed
        save()
    }

    func delete(_ playlist: Playlist) {
        let pid = playlist.id
        // Remove favourites & progress that point into this playlist.
        let channelIDs = Set(channels(in: playlist).map(\.id))
        try? context.delete(model: Favorite.self, where: #Predicate { channelIDs.contains($0.targetID) })
        try? context.delete(model: WatchProgress.self, where: #Predicate { channelIDs.contains($0.targetID) })
        try? context.delete(model: Channel.self, where: #Predicate { $0.playlistID == pid })
        context.delete(playlist)
        save()
    }

    func move(_ playlists: [Playlist]) {
        for (i, p) in playlists.enumerated() { p.sortOrder = i }
        save()
    }

    // MARK: Local videos

    func folders() -> [VideoFolder] {
        let d = FetchDescriptor<VideoFolder>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        return (try? context.fetch(d)) ?? []
    }

    func localVideos(in folder: VideoFolder? = nil, limit: Int? = nil) -> [LocalVideo] {
        var d: FetchDescriptor<LocalVideo>
        if let folder {
            let fid = folder.id
            d = FetchDescriptor(predicate: #Predicate { $0.folder?.id == fid })
        } else {
            d = FetchDescriptor()
        }
        d.sortBy = [SortDescriptor(\.importedAt, order: .reverse)]
        if let limit { d.fetchLimit = limit }
        return (try? context.fetch(d)) ?? []
    }

    func localVideo(id: UUID) -> LocalVideo? {
        var d = FetchDescriptor<LocalVideo>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func searchLocalVideos(_ query: String, limit: Int = 50) -> [LocalVideo] {
        let q = query.searchNormalized
        guard !q.isEmpty else { return [] }
        var d = FetchDescriptor<LocalVideo>(predicate: #Predicate { $0.normalizedTitle.contains(q) })
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    func createFolder(named name: String) -> VideoFolder {
        let folder = VideoFolder(name: name.trimmed, sortOrder: folders().count)
        context.insert(folder)
        save()
        return folder
    }

    func delete(_ folder: VideoFolder, deleteFiles: Bool) {
        for video in localVideos(in: folder) { delete(video, removeFile: deleteFiles) }
        context.delete(folder)
        save()
    }

    func rename(_ video: LocalVideo, to title: String) {
        video.title = title.trimmed
        video.normalizedTitle = video.title.searchNormalized
        save()
    }

    func delete(_ video: LocalVideo, removeFile: Bool = true) {
        let vid = video.id
        if removeFile {
            try? FileManager.default.removeItem(at: video.fileURL)
            if let thumb = video.thumbnailURL { try? FileManager.default.removeItem(at: thumb) }
        }
        try? context.delete(model: Favorite.self, where: #Predicate { $0.targetID == vid })
        try? context.delete(model: WatchProgress.self, where: #Predicate { $0.targetID == vid })
        context.delete(video)
        save()
    }

    // MARK: Resolve

    func item(for ref: PlayableRef) -> PlayableItem? {
        switch ref.kind {
        case .channel:
            guard let c = channel(id: ref.id) else { return nil }
            return PlayableItem(channel: c, playlistName: c.playlist?.name)
        case .localVideo:
            guard let v = localVideo(id: ref.id) else { return nil }
            return PlayableItem(video: v)
        case .vod:
            // Movies resolve from the in-memory catalogue; episodes from the small
            // on-disk index VODService keeps of everything that has been played.
            let vod = AppEnvironment.shared.vod
            if let m = vod.movies.first(where: { $0.playableID == ref.id }) { return PlayableItem(movie: m) }
            return vod.playedItem(id: ref.id)
        }
    }

    /// Neighbouring channels for the in-player channel drawer / next-previous.
    func siblings(of item: PlayableItem) -> [PlayableItem] {
        switch item.ref.kind {
        case .channel:
            guard let c = channel(id: item.id), let p = c.playlist else { return [item] }
            return channels(in: p, genre: c.genre).map { PlayableItem(channel: $0, playlistName: p.name) }
        case .localVideo:
            guard let v = localVideo(id: item.id) else { return [item] }
            return localVideos(in: v.folder).map(PlayableItem.init(video:))
        case .vod:
            return [item]   // the VOD views pass an explicit episode queue
        case .youtube:
            return [item]   // YouTube views pass related/playlist queues explicitly
        }
    }

    // MARK: External imports

    func enqueueExternalImport(_ url: URL) {
        pendingExternalImports.append(url)
    }

    // MARK: Persistence

    func save() {
        do {
            try context.save()
            bump()
        } catch {
            Log.playlist.error("Save failed: \(error.localizedDescription)")
        }
    }

    var isEmpty: Bool {
        ((try? context.fetchCount(FetchDescriptor<Playlist>())) ?? 0) == 0
            && ((try? context.fetchCount(FetchDescriptor<LocalVideo>())) ?? 0) == 0
    }
}
