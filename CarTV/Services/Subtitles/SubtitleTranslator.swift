import Foundation
@preconcurrency import Translation

/// Bridges `SubtitleController` to Apple's on-device Translation framework.
/// A `TranslationSession` is only vended to SwiftUI via `.translationTask`, so the
/// player view installs `SubtitleTranslationHost` which performs pending requests.
enum SubtitleTranslator {

    enum TranslationError: LocalizedError {
        case unsupportedPair
        case needsDownload
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupportedPair: String(localized: "Translation isn't available for this language pair")
            case .needsDownload:   String(localized: "Download the language in Settings first")
            case .cancelled:       nil
            }
        }
    }

    /// Request queue consumed by the SwiftUI host.
    struct PendingRequest: Identifiable, Equatable, Sendable {
        let id = UUID()
        let cues: [SubtitleCue]
        let target: Locale.Language
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    @MainActor static var pending: PendingRequest?
    @MainActor private static var continuation: CheckedContinuation<[SubtitleCue], Error>?

    /// Called by `SubtitleController`. Suspends until the SwiftUI host completes the work.
    @MainActor
    static func translate(_ cues: [SubtitleCue], to target: Locale.Language) async throws -> [SubtitleCue] {
        let availability = LanguageAvailability()
        let sample = cues.prefix(20).map(\.text).joined(separator: " ")
        let status = try await availability.status(for: sample, to: target)
        switch status {
        case .unsupported: throw TranslationError.unsupportedPair
        case .supported, .installed: break
        @unknown default: break
        }
        continuation?.resume(throwing: TranslationError.cancelled)
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            pending = PendingRequest(cues: cues, target: target)
        }
    }

    /// Called by the SwiftUI host once it has a session. Runs off the main actor
    /// because `translations(from:)` is @concurrent; results hop back to main.
    nonisolated static func fulfil(_ request: PendingRequest, using session: TranslationSession) async {
        var result = request.cues
        do {
            // Batch in chunks to keep memory bounded on long films.
            let chunk = 200
            var start = 0
            while start < request.cues.count {
                let slice = request.cues[start..<min(start + chunk, request.cues.count)]
                let requests = slice.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
                let responses = try await session.translations(from: requests)
                for r in responses {
                    if let idStr = r.clientIdentifier, let id = Int(idStr), let idx = result.firstIndex(where: { $0.id == id }) {
                        result[idx].text = r.targetText
                    }
                }
                start += chunk
                try Task.checkCancellation()
            }
            let done = result
            await MainActor.run {
                continuation?.resume(returning: done)
                continuation = nil
                if pending == request { pending = nil }
            }
        } catch {
            await MainActor.run {
                continuation?.resume(throwing: error)
                continuation = nil
                if pending == request { pending = nil }
            }
        }
    }

    @MainActor
    static func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        pending = nil
    }
}
