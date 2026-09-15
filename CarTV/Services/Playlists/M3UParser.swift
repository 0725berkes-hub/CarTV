import Foundation

/// One entry parsed from an M3U/M3U8 playlist.
struct M3UEntry: Sendable, Hashable {
    var name: String
    var url: URL
    var logo: URL?
    var group: String?
    var tvgID: String?
    var tvgName: String?
    var language: String?
    var country: String?
    var duration: Double        // -1 for live
    var headers: [String: String]
}

struct M3UDocument: Sendable {
    var entries: [M3UEntry]
    /// Playlist-level headers from the first #EXTVLCOPT lines before any #EXTINF.
    var defaultHeaders: [String: String]
    /// True when the input looked like a *media* HLS manifest (segments) rather than a channel list.
    var isMediaManifest: Bool
    var skippedLines: Int
}

/// Fast, forgiving M3U parser. Single pass, no regex; handles:
/// `#EXTINF:-1 tvg-id="…" tvg-logo="…" group-title="…",Name`
/// `#EXTGRP:Group`, `#EXTVLCOPT:http-user-agent=…`, `#KODIPROP:inputstream…`,
/// Xtream `|User-Agent=…` URL suffixes, CRLF, BOM, and missing #EXTM3U headers.
enum M3UParser {

    nonisolated static func parse(_ text: String) -> M3UDocument {
        var entries: [M3UEntry] = []
        entries.reserveCapacity(1024)

        var pendingName: String?
        var pendingAttrs: [Substring: Substring] = [:]
        var pendingDuration: Double = -1
        var pendingGroup: String?
        var pendingHeaders: [String: String] = [:]
        var defaultHeaders: [String: String] = [:]
        var sawExtinf = false
        var isMediaManifest = false
        var skipped = 0

        var body = Substring(text)
        if body.hasPrefix("\u{FEFF}") { body = body.dropFirst() }

        for rawLine in body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    sawExtinf = true
                    let payload = line.dropFirst("#EXTINF:".count)
                    (pendingDuration, pendingAttrs, pendingName) = parseExtinf(payload)
                } else if line.hasPrefix("#EXTGRP:") {
                    pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmed.nilIfEmpty
                } else if line.hasPrefix("#EXTVLCOPT:") {
                    if let (k, v) = parseVLCOpt(line.dropFirst("#EXTVLCOPT:".count)) {
                        if sawExtinf { pendingHeaders[k] = v } else { defaultHeaders[k] = v }
                    }
                } else if line.hasPrefix("#KODIPROP:") {
                    if let (k, v) = parseKodiProp(line.dropFirst("#KODIPROP:".count)) {
                        if sawExtinf { pendingHeaders[k] = v } else { defaultHeaders[k] = v }
                    }
                } else if line.hasPrefix("#EXT-X-TARGETDURATION") || line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") || line.hasPrefix("#EXT-X-STREAM-INF") {
                    isMediaManifest = true
                }
                continue
            }

            // Non-comment line → URL.
            var urlText = String(line)
            var urlHeaders: [String: String] = [:]
            if let pipe = urlText.firstIndex(of: "|") {
                // Xtream/Kodi style: http://…/x.ts|User-Agent=Foo&Referer=Bar
                let suffix = urlText[urlText.index(after: pipe)...]
                urlText = String(urlText[..<pipe])
                for pair in suffix.split(separator: "&") {
                    if let eq = pair.firstIndex(of: "=") {
                        let k = String(pair[..<eq]).trimmed
                        let v = String(pair[pair.index(after: eq)...]).removingPercentEncoding ?? String(pair[pair.index(after: eq)...])
                        urlHeaders[normalizeHeaderName(k)] = v
                    }
                }
            }
            guard let url = URL(string: urlText) ?? URL(string: urlText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
                  url.scheme != nil else {
                skipped += 1
                resetPending()
                continue
            }

            let name = pendingName?.nilIfEmpty
                ?? pendingAttrs["tvg-name"].map(String.init)?.nilIfEmpty
                ?? url.deletingPathExtension().lastPathComponent.nilIfEmpty
                ?? url.host ?? "Stream"

            var headers = pendingHeaders
            urlHeaders.forEach { headers[$0.key] = $0.value }

            entries.append(M3UEntry(
                name: name,
                url: url,
                logo: pendingAttrs["tvg-logo"].flatMap { URL(string: String($0)) },
                group: (pendingAttrs["group-title"].map(String.init) ?? pendingGroup)?.trimmed.nilIfEmpty,
                tvgID: pendingAttrs["tvg-id"].map(String.init)?.nilIfEmpty,
                tvgName: pendingAttrs["tvg-name"].map(String.init)?.nilIfEmpty,
                language: pendingAttrs["tvg-language"].map(String.init)?.nilIfEmpty,
                country: pendingAttrs["tvg-country"].map(String.init)?.nilIfEmpty,
                duration: pendingDuration,
                headers: headers
            ))
            resetPending()

            func resetPending() {
                pendingName = nil
                pendingAttrs = [:]
                pendingDuration = -1
                pendingHeaders = [:]
                // #EXTGRP persists until the next one per spec.
            }
        }

        // A manifest full of .ts segments with no #EXTINF names is media, not channels.
        if !isMediaManifest && !entries.isEmpty && entries.allSatisfy({ $0.duration > 0 && $0.duration < 60 }) {
            isMediaManifest = true
        }

        return M3UDocument(entries: entries, defaultHeaders: defaultHeaders, isMediaManifest: isMediaManifest, skippedLines: skipped)
    }

    // MARK: Helpers

    /// `-1 tvg-id="x" group-title="News",Channel Name`
    nonisolated private static func parseExtinf(_ payload: Substring) -> (Double, [Substring: Substring], String?) {
        var attrs: [Substring: Substring] = [:]
        var i = payload.startIndex

        // Duration
        var durEnd = i
        while durEnd < payload.endIndex, payload[durEnd] != " ", payload[durEnd] != "," { durEnd = payload.index(after: durEnd) }
        let duration = Double(payload[i..<durEnd]) ?? -1
        i = durEnd

        // Attributes key="value" (value may contain commas)
        var name: String?
        while i < payload.endIndex {
            let c = payload[i]
            if c == "," {
                name = String(payload[payload.index(after: i)...]).trimmed
                break
            }
            if c == " " { i = payload.index(after: i); continue }
            // key
            var keyEnd = i
            while keyEnd < payload.endIndex, payload[keyEnd] != "=", payload[keyEnd] != ",", payload[keyEnd] != " " { keyEnd = payload.index(after: keyEnd) }
            guard keyEnd < payload.endIndex, payload[keyEnd] == "=" else {
                // Not an attribute → rest is the name (malformed line).
                name = String(payload[i...]).trimmed
                if let comma = name?.firstIndex(of: ","), let n = name { name = String(n[n.index(after: comma)...]).trimmed }
                break
            }
            let key = payload[i..<keyEnd]
            var valStart = payload.index(after: keyEnd)
            guard valStart < payload.endIndex else { break }
            if payload[valStart] == "\"" {
                valStart = payload.index(after: valStart)
                var valEnd = valStart
                while valEnd < payload.endIndex, payload[valEnd] != "\"" { valEnd = payload.index(after: valEnd) }
                attrs[key.lowercased()[...]] = payload[valStart..<valEnd]
                i = valEnd < payload.endIndex ? payload.index(after: valEnd) : valEnd
            } else {
                var valEnd = valStart
                while valEnd < payload.endIndex, payload[valEnd] != " ", payload[valEnd] != "," { valEnd = payload.index(after: valEnd) }
                attrs[key.lowercased()[...]] = payload[valStart..<valEnd]
                i = valEnd
            }
        }
        return (duration, attrs, name)
    }

    /// `http-user-agent=Foo` / `http-referrer=Bar`
    nonisolated private static func parseVLCOpt(_ s: Substring) -> (String, String)? {
        guard let eq = s.firstIndex(of: "=") else { return nil }
        let key = s[..<eq].lowercased()
        let value = String(s[s.index(after: eq)...]).trimmed
        switch key {
        case "http-user-agent": return ("User-Agent", value)
        case "http-referrer", "http-referer": return ("Referer", value)
        case "http-origin": return ("Origin", value)
        case "http-cookie": return ("Cookie", value)
        default: return nil
        }
    }

    /// `inputstream.adaptive.stream_headers=User-Agent=Foo&Referer=Bar`
    nonisolated private static func parseKodiProp(_ s: Substring) -> (String, String)? {
        guard let eq = s.firstIndex(of: "=") else { return nil }
        let key = s[..<eq].lowercased()
        let value = String(s[s.index(after: eq)...])
        guard key.hasSuffix("stream_headers") || key.hasSuffix("manifest_headers") else { return nil }
        // Only first pair is returned here; the rest are merged by caller if needed.
        guard let first = value.split(separator: "&").first, let eq2 = first.firstIndex(of: "=") else { return nil }
        return (normalizeHeaderName(String(first[..<eq2])), String(first[first.index(after: eq2)...]).removingPercentEncoding ?? String(first[first.index(after: eq2)...]))
    }

    nonisolated private static func normalizeHeaderName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "user-agent", "useragent": "User-Agent"
        case "referer", "referrer": "Referer"
        case "origin": "Origin"
        case "cookie": "Cookie"
        default: raw
        }
    }
}

private extension Substring {
    nonisolated func trimmingCharacters(in set: CharacterSet) -> Substring {
        var s = self
        while let f = s.first, f.unicodeScalars.allSatisfy(set.contains) { s = s.dropFirst() }
        while let l = s.last, l.unicodeScalars.allSatisfy(set.contains) { s = s.dropLast() }
        return s
    }
}
