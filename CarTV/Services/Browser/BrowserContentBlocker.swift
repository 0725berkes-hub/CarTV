import Foundation
import OSLog
import WebKit

/// Compile the bundled rules before the first request, including on a cold launch.
@MainActor
final class BrowserContentBlocker {
    static let shared = BrowserContentBlocker()
    private var compilation: Task<WKContentRuleList?, Never>?

    func rules() async -> WKContentRuleList? {
        if let compilation { return await compilation.value }
        let task = Task<WKContentRuleList?, Never> {
            let store = WKContentRuleListStore.default()!
            let identifier = "CarTV.Browser.Ads.v2"
            let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                    continuation.resume(returning: list)
                }
            }
            if let cached { return cached }
            guard let file = Bundle.main.url(forResource: "browser-ad-rules", withExtension: "json")
                    ?? Bundle.main.url(forResource: "browser-ad-rules", withExtension: "json", subdirectory: "Browser"),
                  let json = try? String(contentsOf: file, encoding: .utf8) else {
                Log.network.error("Browser ad rules resource is missing")
                return nil
            }
            return await withCheckedContinuation { continuation in
                store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: json
                ) { list, error in
                    if let error { Log.network.error("Browser ad rules: \(error.localizedDescription)") }
                    continuation.resume(returning: list)
                }
            }
        }
        compilation = task
        return await task.value
    }
}
