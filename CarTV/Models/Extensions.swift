import Foundation

nonisolated extension String {
    /// Lower-cased, diacritic-insensitive, whitespace-collapsed form for search & matching.
    nonisolated var searchNormalized: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

nonisolated extension URL {
    /// Accepts bare hosts ("example.com/list.m3u") and upgrades them to https.
    nonisolated static func lenient(_ raw: String) -> URL? {
        let text = raw.trimmed
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil, url.host != nil { return url }
        if let url = URL(string: "https://" + text), url.host != nil { return url }
        return nil
    }

    nonisolated var isHTTP: Bool {
        let s = scheme?.lowercased()
        return s == "http" || s == "https"
    }
}

nonisolated extension TimeInterval {
    /// "1:02:03" or "12:03".
    nonisolated var clockString: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

nonisolated extension Int64 {
    nonisolated var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
