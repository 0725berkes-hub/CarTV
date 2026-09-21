import Foundation
import Observation

struct SubtitleCue: Sendable, Hashable, Identifiable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    var text: String
}

nonisolated struct SubtitleTrack: Sendable, Hashable, Identifiable {
    let name: String
    let languageCode: String
    let url: URL

    var id: String { "\(languageCode):\(url.absoluteString)" }
}

/// Renders external (SRT/VTT) subtitles as an overlay and optionally translates them
/// on-device. Engine-embedded tracks are drawn by the engine itself.
@Observable
final class SubtitleController {
    private(set) var cues: [SubtitleCue] = []
    private(set) var currentText: String?
    private(set) var isExternalActive = false
    private(set) var isTranslating = false
    private(set) var translationTarget: Locale.Language?
    private(set) var loadError: String?
    /// URL of the external track currently shown (for menus to mark the selection).
    private(set) var activeURL: URL?

    private var originalCues: [SubtitleCue] = []
    private var lastIndex = 0
    private var currentItem: PlayableItem?
    private var translateTask: Task<Void, Never>?

    func reset(for item: PlayableItem?) {
        translateTask?.cancel()
        cues = []; originalCues = []
        currentText = nil
        isExternalActive = false
        isTranslating = false
        translationTarget = nil
        loadError = nil
        activeURL = nil
        lastIndex = 0
        currentItem = item
        // Auto-detect sidecar .srt for local files.
        if let item, item.isLocal {
            let srt = item.url.deletingPathExtension().appendingPathExtension("srt")
            let vtt = item.url.deletingPathExtension().appendingPathExtension("vtt")
            if FileManager.default.fileExists(atPath: srt.path) { loadExternal(srt) }
            else if FileManager.default.fileExists(atPath: vtt.path) { loadExternal(vtt) }
        }
        // MyTV+ movies/episodes ship subtitle links; pick the user's language.
        if let item, !item.subtitleLinks.isEmpty,
           let url = item.subtitleLinks.preferred(for: AppEnvironment.shared.settings.subtitleLanguage) {
            loadExternal(url, headers: item.headers)
        }
        if let item, let track = preferredTrack(in: item.subtitleTracks) {
            loadExternal(track.url, headers: item.headers)
        }
    }

    private func preferredTrack(in tracks: [SubtitleTrack]) -> SubtitleTrack? {
        guard !tracks.isEmpty else { return nil }
        let preferred = AppEnvironment.shared.settings.subtitleLanguage
        if let preferred, let track = tracks.first(where: { $0.languageCode == preferred || $0.languageCode.hasPrefix(preferred + "-") }) { return track }
        return tracks.first(where: { $0.languageCode == "en" || $0.languageCode.hasPrefix("en-") }) ?? tracks.first
    }

    func loadExternal(_ url: URL, headers: [String: String] = [:]) {
        loadError = nil
        Task {
            do {
                let data: Data
                if url.isFileURL { data = try Data(contentsOf: url) }
                else {
                    var req = URLRequest(url: url)
                    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                    (data, _) = try await URLSession.shared.data(for: req)
                }
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))) ?? String(decoding: data, as: UTF8.self)
                let parsed = SubtitleParser.parse(text)
                await MainActor.run {
                    guard !parsed.isEmpty else { self.loadError = String(localized: "This subtitle track has no content right now"); return }
                    self.originalCues = parsed
                    self.cues = parsed
                    self.isExternalActive = true
                    self.activeURL = url
                    self.lastIndex = 0
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    func disableExternal() {
        isExternalActive = false
        activeURL = nil
        currentText = nil
        translateTask?.cancel()
        isTranslating = false
        translationTarget = nil
    }

    func tick(position: TimeInterval) {
        guard isExternalActive, !cues.isEmpty else { return }
        // Cues are sorted; resume search from the last index for O(1) amortised lookups.
        var i = min(lastIndex, cues.count - 1)
        if cues[i].start > position { i = 0 }
        while i < cues.count, cues[i].end < position { i += 1 }
        lastIndex = i
        let text = (i < cues.count && cues[i].start <= position) ? cues[i].text : nil
        if text != currentText { currentText = text }
    }

    // MARK: Translation

    func translate(to language: Locale.Language) {
        guard !originalCues.isEmpty else { return }
        translateTask?.cancel()
        isTranslating = true
        translationTarget = language
        let source = originalCues
        translateTask = Task {
            do {
                let translated = try await SubtitleTranslator.translate(source, to: language)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.cues = translated
                    self.isTranslating = false
                }
            } catch {
                await MainActor.run {
                    self.isTranslating = false
                    self.translationTarget = nil
                    self.loadError = (error as? SubtitleTranslator.TranslationError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    func clearTranslation() {
        translateTask?.cancel()
        cues = originalCues
        isTranslating = false
        translationTarget = nil
    }
}

// MARK: - Parser

enum SubtitleParser {
    nonisolated static func parse(_ text: String) -> [SubtitleCue] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let isVTT = body.hasPrefix("WEBVTT")
        let blocks = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var id = 0
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            let parts = timing.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else { continue }
            var textLines = Array(lines[(timingIndex + 1)...])
            if isVTT { textLines = textLines.map(stripVTTTags) } else { textLines = textLines.map(stripHTML) }
            let cueText = textLines.joined(separator: "\n").trimmed
            guard !cueText.isEmpty else { continue }
            cues.append(SubtitleCue(id: id, start: start, end: end, text: cueText))
            id += 1
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345" / "00:01:02.345" / "01:02.345"
    nonisolated private static func parseTime(_ raw: String) -> TimeInterval? {
        let s = raw.trimmed.replacingOccurrences(of: ",", with: ".")
        let comps = s.split(separator: ":").map(String.init)
        guard !comps.isEmpty, comps.count <= 3 else { return nil }
        var seconds: TimeInterval = 0
        for c in comps {
            guard let v = Double(c) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    nonisolated private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "{\\\\[^}]+}", with: "", options: .regularExpression)
    }

    nonisolated private static func stripVTTTags(_ s: String) -> String {
        stripHTML(s).replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
}
