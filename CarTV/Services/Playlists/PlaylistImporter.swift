import OSLog
import Foundation
import SwiftData

/// Imports and refreshes playlists. Network + parsing + inserts happen off the
/// main actor on a private `ModelContext`; the main store is notified at the end.
nonisolated final class PlaylistImporter: Sendable {

    enum Phase: Sendable, Equatable {
        case idle
        case downloading
        case parsing
        case saving(done: Int, total: Int)
        case checking
    }

    enum ImportError: LocalizedError, Sendable {
        case invalidURL
        case network(String)
        case http(Int)
        case emptyResponse
        case htmlPage
        case mediaManifest
        case noChannels
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL:     String(localized: "Invalid URL")
            case .network(let m): m
            case .http(let code): String(localized: "Server returned \(code)")
            case .emptyResponse:  String(localized: "Server returned no data")
            case .htmlPage:       String(localized: "This URL returns a webpage, not a video stream")
            case .mediaManifest:  String(localized: "This URL is a media stream, not a channel list.\nPlease paste an M3U subscription link.")
            case .noChannels:     String(localized: "This URL is not a valid channel list")
            case .cancelled:      String(localized: "Cancelled")
            }
        }
    }

    struct Summary: Sendable {
        let playlistID: UUID
        let name: String
        let added: Int
        let skipped: Int
    }

    private let container: ModelContainer
    private let session: URLSession

    nonisolated init(container: ModelContainer) {
        self.container = container
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = ["User-Agent": PlaylistImporter.userAgent]
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    nonisolated static let userAgent = "CarTV/1.0 (iPhone; iOS) AppleWebKit VLC/3.0"

    // MARK: Public

    /// Imports from a classified input. `progress` is called on the main actor.
    func importInput(
        _ input: SubscriptionInput,
        suggestedName: String? = nil,
        progress: @escaping @MainActor @Sendable (Phase) -> Void = { _ in }
    ) async throws -> [Summary] {
        switch input {
        case .remotePlaylist(let url):
            return [try await importRemote(url: url, name: suggestedName, progress: progress)]

        case .inlineM3U(let text):
            let name = suggestedName ?? String(localized: "Pasted List")
            return [try await importText(text, name: name, kind: .pasted, sourceURL: nil, progress: progress)]

        case .singleStream(let url):
            let name = suggestedName ?? url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? url.host ?? "Stream"
            let m3u = "#EXTM3U\n#EXTINF:-1,\(name)\n\(url.absoluteString)"
            return [try await importText(m3u, name: name, kind: .manual, sourceURL: nil, progress: progress)]

        case .xtream(let host, let user, let pass):
            guard let url = SubscriptionInput.xtreamPlaylistURL(host: host, username: user, password: pass) else {
                throw ImportError.invalidURL
            }
            return [try await importRemote(url: url, name: suggestedName ?? host.host, progress: progress)]

        case .multipleURLs(let urls):
            var results: [Summary] = []
            for url in urls {
                if let s = try? await importRemote(url: url, name: nil, progress: progress) { results.append(s) }
            }
            if results.isEmpty { throw ImportError.noChannels }
            return results
        }
    }

    /// Re-downloads a subscription playlist and replaces its channels, preserving favourites by stream URL.
    func refresh(_ playlistID: UUID, progress: @escaping @MainActor @Sendable (Phase) -> Void = { _ in }) async throws -> Summary {
        let context = ModelContext(container)
        guard let playlist = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })).first,
              let url = playlist.sourceURL else {
            throw ImportError.invalidURL
        }
        let name = playlist.name
        await progress(.downloading)
        let text: String
        do {
            // The built-in MyTV+ source is a JSON API, not an M3U file.
            text = url == MyTVService.sourceURL ? try await MyTVService.fetchM3U() : try await download(url)
        } catch {
            playlist.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? context.save()
            await MainActor.run { AppEnvironment.shared.library.bump() }
            throw error
        }
        await progress(.parsing)
        let doc = M3UParser.parse(text)
        try validate(doc)

        // Remember favourites by URL so they survive the replace.
        let oldChannels = try context.fetch(FetchDescriptor<Channel>(predicate: #Predicate { $0.playlistID == playlistID }))
        let favIDs = Set(try context.fetch(FetchDescriptor<Favorite>()).map(\.targetID))
        let favURLs = Set(oldChannels.filter { favIDs.contains($0.id) }.map(\.streamURL))
        let oldByURL = Dictionary(oldChannels.map { ($0.streamURL, $0) }, uniquingKeysWith: { a, _ in a })

        // Replace channels
        try context.delete(model: Channel.self, where: #Predicate { $0.playlistID == playlistID })
        var inserted = 0
        var reFav: [UUID] = []
        for (i, entry) in doc.entries.enumerated() {
            let channel = makeChannel(entry, playlistID: playlistID, index: i)
            // Keep the same UUID for unchanged URLs so history/progress survive.
            if let old = oldByURL[entry.url] { channel.id = old.id }
            if favURLs.contains(entry.url) { reFav.append(channel.id) }
            context.insert(channel)
            inserted += 1
            if inserted % 500 == 0 {
                try context.save()
                await progress(.saving(done: inserted, total: doc.entries.count))
            }
        }
        playlist.channelCount = inserted
        playlist.lastRefreshedAt = .now
        playlist.lastError = nil
        playlist.defaultHeaders = doc.defaultHeaders
        // Re-create favourites whose channel ID changed.
        let existingFavs = Set(try context.fetch(FetchDescriptor<Favorite>()).map(\.targetID))
        for id in reFav where !existingFavs.contains(id) {
            context.insert(Favorite(target: PlayableRef(id: id, kind: .channel)))
        }
        try context.save()
        await MainActor.run {
            AppEnvironment.shared.library.bump()
            AppEnvironment.shared.favorites.reload()
        }
        return Summary(playlistID: playlistID, name: name, added: inserted, skipped: doc.skippedLines)
    }

    // MARK: Internals

    private func importRemote(url: URL, name: String?, progress: @escaping @MainActor @Sendable (Phase) -> Void) async throws -> Summary {
        await progress(.downloading)
        let text = try await download(url)
        let title = name ?? Self.suggestedName(for: url)
        return try await importText(text, name: title, kind: .subscription, sourceURL: url, progress: progress)
    }

    private func importText(
        _ text: String,
        name: String,
        kind: PlaylistKind,
        sourceURL: URL?,
        progress: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> Summary {
        await progress(.parsing)
        let doc = M3UParser.parse(text)
        try validate(doc)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existingCount = try context.fetchCount(FetchDescriptor<Playlist>())
        let playlist = Playlist(name: name, kind: kind, sourceURL: sourceURL, sortOrder: existingCount)
        playlist.defaultHeaders = doc.defaultHeaders
        context.insert(playlist)

        var inserted = 0
        for (i, entry) in doc.entries.enumerated() {
            context.insert(makeChannel(entry, playlistID: playlist.id, index: i))
            inserted += 1
            if inserted % 500 == 0 {
                try context.save()
                await progress(.saving(done: inserted, total: doc.entries.count))
                try Task.checkCancellation()
            }
        }
        playlist.channelCount = inserted
        playlist.lastRefreshedAt = .now
        try context.save()

        let pid = playlist.id
        await MainActor.run { AppEnvironment.shared.library.bump() }
        Log.playlist.info("Imported \(inserted) channels into \(name, privacy: .public)")
        return Summary(playlistID: pid, name: name, added: inserted, skipped: doc.skippedLines)
    }

    private func makeChannel(_ e: M3UEntry, playlistID: UUID, index: Int) -> Channel {
        Channel(
            playlistID: playlistID,
            name: e.name,
            streamURL: e.url,
            logoURL: e.logo,
            groupTitle: e.group,
            tvgID: e.tvgID,
            tvgName: e.tvgName,
            language: e.language,
            country: e.country,
            genre: ChannelGrouper.genre(group: e.group, name: e.name),
            orderIndex: index,
            headers: e.headers
        )
    }

    private func validate(_ doc: M3UDocument) throws {
        if doc.isMediaManifest { throw ImportError.mediaManifest }
        if doc.entries.isEmpty { throw ImportError.noChannels }
    }

    nonisolated private func download(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError {
            throw ImportError.network(Self.friendly(e))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw ImportError.emptyResponse }

        // Detect HTML
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") {
            throw ImportError.htmlPage
        }
        // Try UTF-8, then Windows-1256 (Arabic lists), then Latin-1.
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func friendly(_ e: URLError) -> String {
        switch e.code {
        case .timedOut:                  String(localized: "Connection timed out")
        case .cannotFindHost, .dnsLookupFailed: String(localized: "Can't resolve host")
        case .cannotConnectToHost:       String(localized: "Server refused the connection")
        case .notConnectedToInternet:    String(localized: "Check that Wi‑Fi is on, then try again.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            String(localized: "Secure connection failed")
        case .badURL, .unsupportedURL:   String(localized: "Invalid URL")
        default:                         String(localized: "Can't connect to the server")
        }
    }

    nonisolated static func suggestedName(for url: URL) -> String {
        if let host = url.host {
            let trimmed = host.replacingOccurrences(of: "www.", with: "")
            let file = url.deletingPathExtension().lastPathComponent
            if !file.isEmpty, file != "/", file.lowercased() != "get", file.lowercased() != "playlist", file.count < 30 {
                return "\(file) · \(trimmed)"
            }
            return trimmed
        }
        return String(localized: "Subscription")
    }
}
