import Foundation
import SwiftData
import Observation

@Observable
final class FavoritesStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// In-memory mirror for O(1) heart-state lookups in grids.
    private(set) var favoriteIDs: Set<UUID> = []
    private(set) var revision = 0

    init(container: ModelContainer) {
        self.container = container
        reload()
    }

    func reload() {
        let all = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        favoriteIDs = Set(all.map(\.targetID))
        revision &+= 1
    }

    func isFavorite(_ ref: PlayableRef) -> Bool { favoriteIDs.contains(ref.id) }
    func isFavorite(_ item: PlayableItem) -> Bool { favoriteIDs.contains(item.id) }

    /// Returns true if the item is now a favourite.
    @discardableResult
    func toggle(_ ref: PlayableRef) -> Bool {
        if isFavorite(ref) {
            remove(ref)
            return false
        } else {
            add(ref)
            return true
        }
    }

    func add(_ ref: PlayableRef) {
        guard !isFavorite(ref) else { return }
        context.insert(Favorite(target: ref))
        try? context.save()
        favoriteIDs.insert(ref.id)
        revision &+= 1
    }

    func remove(_ ref: PlayableRef) {
        let id = ref.id
        try? context.delete(model: Favorite.self, where: #Predicate { $0.targetID == id })
        try? context.save()
        favoriteIDs.remove(id)
        revision &+= 1
    }

    func favorites() -> [Favorite] {
        let d = FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    /// Resolved favourites; silently drops references whose target was deleted.
    func favoriteItems() -> [PlayableItem] {
        let library = AppEnvironment.shared.library
        return favorites().compactMap { library.item(for: $0.target) }
    }
}
