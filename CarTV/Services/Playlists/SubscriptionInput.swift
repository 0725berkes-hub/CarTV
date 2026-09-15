import Foundation

/// Classifies whatever the user typed / pasted / scanned into something we can import.
enum SubscriptionInput: Sendable, Equatable {
    /// Remote playlist to fetch and refresh later.
    case remotePlaylist(URL)
    /// Raw M3U text (pasted).
    case inlineM3U(String)
    /// A single direct stream URL (not a list) — becomes a one-channel manual playlist.
    case singleStream(URL)
    /// Xtream Codes credentials → we build the get.php M3U URL.
    case xtream(host: URL, username: String, password: String)
    /// Many URLs pasted at once (one per line).
    case multipleURLs([URL])

    enum Failure: LocalizedError, Sendable {
        case empty
        case notALink
        case unsupported

        var errorDescription: String? {
            switch self {
            case .empty:       String(localized: "Enter a valid http/https URL")
            case .notALink:    String(localized: "No usable link found")
            case .unsupported: String(localized: "Invalid source")
            }
        }
    }

    nonisolated static func detect(_ raw: String) -> Result<SubscriptionInput, Failure> {
        let text = raw.trimmed
        guard !text.isEmpty else { return .failure(.empty) }

        // Pasted playlist body?
        if text.hasPrefix("#EXTM3U") || text.contains("\n#EXTINF") || text.hasPrefix("#EXTINF") {
            return .success(.inlineM3U(text))
        }

        // JSON list of {name,url}? (some sharing tools export this)
        if text.hasPrefix("[") || text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let m3u = jsonToM3U(data) {
            return .success(.inlineM3U(m3u))
        }

        // Multiple lines → many URLs or "name,url" pairs
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }
        if lines.count > 1 {
            var urls: [URL] = []
            var m3uLines = ["#EXTM3U"]
            var pairs = 0
            for line in lines {
                if let comma = line.lastIndex(of: ","), let url = URL.lenient(String(line[line.index(after: comma)...])), url.isHTTP || url.scheme?.hasPrefix("rt") == true {
                    let name = String(line[..<comma]).trimmed
                    m3uLines.append("#EXTINF:-1,\(name)")
                    m3uLines.append(url.absoluteString)
                    pairs += 1
                } else if let url = URL.lenient(line), url.isHTTP {
                    urls.append(url)
                }
            }
            if pairs > 0 { return .success(.inlineM3U(m3uLines.joined(separator: "\n"))) }
            if urls.count > 1 { return .success(.multipleURLs(urls)) }
            if let one = urls.first { return classify(url: one) }
            return .failure(.notALink)
        }

        // Xtream "host|user|pass" or "host user pass"
        let parts = text.split(whereSeparator: { $0 == "|" || $0 == " " }).map(String.init)
        if parts.count == 3, let host = URL.lenient(parts[0]), host.isHTTP {
            return .success(.xtream(host: host, username: parts[1], password: parts[2]))
        }

        guard let url = URL.lenient(text) else { return .failure(.notALink) }
        return classify(url: url)
    }

    nonisolated private static func classify(url: URL) -> Result<SubscriptionInput, Failure> {
        guard url.isHTTP || url.scheme?.lowercased().hasPrefix("rt") == true || url.isFileURL else {
            return .failure(.notALink)
        }
        let ext = url.pathExtension.lowercased()
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""

        // Xtream get.php / player_api
        if path.hasSuffix("get.php") || path.contains("player_api.php") || query.contains("type=m3u") {
            return .success(.remotePlaylist(url))
        }
        if ext == "m3u" || ext == "m3u8" && !path.contains("/live/") && !query.contains("token") {
            // Could still be a media manifest — importer resolves after fetch.
            return .success(.remotePlaylist(url))
        }
        if ext == "m3u8" { return .success(.singleStream(url)) }
        if ["ts", "mp4", "mkv", "avi", "mov", "flv"].contains(ext) || url.scheme?.hasPrefix("rt") == true {
            return .success(.singleStream(url))
        }
        if ext == "txt" || ext == "json" || ext.isEmpty {
            return .success(.remotePlaylist(url))
        }
        return .success(.remotePlaylist(url))
    }

    /// Build the M3U URL for Xtream credentials.
    nonisolated static func xtreamPlaylistURL(host: URL, username: String, password: String) -> URL? {
        var comps = URLComponents(url: host, resolvingAgainstBaseURL: false)
        comps?.path = "/get.php"
        comps?.queryItems = [
            .init(name: "username", value: username),
            .init(name: "password", value: password),
            .init(name: "type", value: "m3u_plus"),
            .init(name: "output", value: "m3u8"),
        ]
        return comps?.url
    }

    nonisolated private static func jsonToM3U(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var items: [[String: Any]] = []
        if let arr = obj as? [[String: Any]] { items = arr }
        else if let dict = obj as? [String: Any] {
            for key in ["channels", "items", "list", "streams", "data"] {
                if let arr = dict[key] as? [[String: Any]] { items = arr; break }
            }
        }
        guard !items.isEmpty else { return nil }
        var lines = ["#EXTM3U"]
        for it in items {
            guard let urlString = (it["url"] ?? it["stream_url"] ?? it["link"] ?? it["src"]) as? String else { continue }
            let name = (it["name"] ?? it["title"] ?? it["channel"]) as? String ?? "Stream"
            var attrs = ""
            if let logo = (it["logo"] ?? it["tvg_logo"] ?? it["icon"]) as? String { attrs += " tvg-logo=\"\(logo)\"" }
            if let group = (it["group"] ?? it["category"] ?? it["group_title"]) as? String { attrs += " group-title=\"\(group)\"" }
            lines.append("#EXTINF:-1\(attrs),\(name)")
            lines.append(urlString)
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }
}
