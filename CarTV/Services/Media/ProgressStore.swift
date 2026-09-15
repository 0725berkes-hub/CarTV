import Foundation
import SwiftData
import Observation

/// Watch history + resume positions.
@Observable
final class ProgressStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private(set) var revision = 0

    init(container: ModelContainer) {
        self.container = container
    }

    func progress(for ref: PlayableRef) -> WatchProgress? {
        let id = ref.id
        var d = FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.targetID == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// Resume position if the user stopped somewhere meaningful (>5s in, <95% through).
    func resumePosition(for ref: PlayableRef) -> TimeInterval? {
        guard let p = progress(for: ref), !p.completed, p.position > 5 else { return nil }
        return p.position
    }

    func record(_ ref: PlayableRef, position: TimeInterval, duration: TimeInterval) {
        if let existing = progress(for: ref) {
            existing.position = position
            existing.duration = duration
            existing.lastWatchedAt = .now
            existing.completed = duration > 0 && position / duration > 0.95
        } else {
            context.insert(WatchProgress(target: ref, position: position, duration: duration))
        }
        try? context.save()
        revision &+= 1
    }

    /// Mark as watched without a position (live channels) so it appears in History.
    func touch(_ ref: PlayableRef) {
        record(ref, position: progress(for: ref)?.position ?? 0, duration: progress(for: ref)?.duration ?? 0)
    }

    func recent(limit: Int = 30) -> [WatchProgress] {
        var d = FetchDescriptor<WatchProgress>(sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    func recentItems(limit: Int = 30) -> [PlayableItem] {
        let library = AppEnvironment.shared.library
        return recent(limit: limit).compactMap { library.item(for: $0.target) }
    }

    /// Items with a meaningful resume point (VOD only).
    func continueWatching(limit: Int = 12) -> [(PlayableItem, WatchProgress)] {
        let library = AppEnvironment.shared.library
        return recent(limit: 60).compactMap { p in
            guard !p.completed, p.duration > 0, p.position > 5, let item = library.item(for: p.target) else { return nil }
            return (item, p)
        }.prefix(limit).map { $0 }
    }

    func clearHistory() {
        try? context.delete(model: WatchProgress.self)
        try? context.save()
        revision &+= 1
    }

    func remove(_ ref: PlayableRef) {
        let id = ref.id
        try? context.delete(model: WatchProgress.self, where: #Predicate { $0.targetID == id })
        try? context.save()
        revision &+= 1
    }
}
