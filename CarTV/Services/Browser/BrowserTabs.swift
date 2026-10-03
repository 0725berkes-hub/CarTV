import Foundation
import Observation

/// Each tab owns its WebKit navigation history and page state.
@MainActor
@Observable
final class BrowserTabs {
    private(set) var sessions: [BrowserSession]
    private(set) var selectedID: UUID
    @ObservationIgnored private let usesCarKeyboard: Bool

    init(usesCarKeyboard: Bool = false) {
        self.usesCarKeyboard = usesCarKeyboard
        let first = BrowserSession(usesCarKeyboard: usesCarKeyboard)
        first.destination = .browse
        sessions = [first]
        selectedID = first.id
    }

    var selected: BrowserSession { sessions.first { $0.id == selectedID } ?? sessions[0] }

    func select(_ session: BrowserSession) {
        guard sessions.contains(where: { $0 === session }), selected !== session else { return }
        selected.suspend()
        selectedID = session.id
    }

    @discardableResult
    func add(url: URL = BrowserDestination.browse.homeURL) -> BrowserSession {
        selected.suspend()
        let session = BrowserSession(usesCarKeyboard: usesCarKeyboard)
        session.destination = .browse
        sessions.append(session)
        selectedID = session.id
        session.load(url)
        return session
    }

    func close(_ session: BrowserSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        let wasSelected = selectedID == session.id
        session.reset()
        sessions.remove(at: index)
        if sessions.isEmpty {
            let replacement = BrowserSession(usesCarKeyboard: usesCarKeyboard)
            replacement.destination = .browse
            sessions = [replacement]
            selectedID = replacement.id
            replacement.load(BrowserDestination.browse.homeURL)
        } else if wasSelected {
            selectedID = sessions[min(index, sessions.count - 1)].id
        }
    }

    func reset() {
        sessions.forEach { $0.reset() }
        let replacement = BrowserSession(usesCarKeyboard: usesCarKeyboard)
        replacement.destination = .browse
        sessions = [replacement]
        selectedID = replacement.id
    }
}
