import Foundation
import Observation
import OSLog
import WebKit

/// Your tiktok.com login, lifted from the in-app browser and kept in the Keychain.
///
/// Only cookies — no password ever reaches the app. `msToken` rotates on nearly
/// every response via Set-Cookie; we track it so requests never go stale.
@Observable
final class TTSession {

    enum State: Equatable { case signedOut, signedIn(handle: String?) }
    private(set) var state: State = .signedOut

    /// Cookie name → value for `.tiktok.com`.
    private(set) var cookies: [String: String] = [:]
    var isSignedIn: Bool { cookies["sessionid"] != nil }

    /// Desktop Safari UA: the web API is tuned for it and it's what the cookies were minted under.
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let keychainKey = "tiktok.cookies"
    private static let handleKey = "tiktok.handle"

    init() {
        if let raw = Keychain.read(Self.keychainKey), let data = raw.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: String].self, from: data), map["sessionid"] != nil {
            cookies = map
            state = .signedIn(handle: UserDefaults.standard.string(forKey: Self.handleKey))
        }
    }

    // MARK: Cookie header

    var cookieHeader: String { cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }
    var msToken: String { cookies["msToken"] ?? "" }
    var csrf: String { cookies["tt_csrf_token"] ?? "" }
    var odinID: String? { cookies["multi_sids"]?.components(separatedBy: "%3A").first }

    /// Immutable copy the nonisolated client can carry across a request.
    nonisolated struct Snapshot: Sendable {
        let cookieHeader: String
        let msToken: String
        let odinID: String?
        let isSignedIn: Bool
    }
    var snapshot: Snapshot { Snapshot(cookieHeader: cookieHeader, msToken: msToken, odinID: odinID, isSignedIn: isSignedIn) }

    // MARK: Import from the web view

    /// Called after the login web view sees `sessionid`. Pulls every `.tiktok.com`
    /// cookie out of the shared WebKit store.
    @MainActor
    func adopt(from store: WKHTTPCookieStore) async {
        let all = await store.allCookies()
        var map: [String: String] = [:]
        for c in all where c.domain.hasSuffix("tiktok.com") {
            // Prefer the broad `.tiktok.com` copy when the same name exists host-scoped too.
            if map[c.name] == nil || c.domain == ".tiktok.com" { map[c.name] = c.value }
        }
        guard map["sessionid"] != nil else { return }
        cookies = map
        persist()
        state = .signedIn(handle: UserDefaults.standard.string(forKey: Self.handleKey))
        Log.network.info("TikTok: adopted \(map.count) cookies")
    }

    /// Re-read the shared WebKit cookie store. The hidden engine page rotates
    /// tt_chain_token / msToken as it browses; the CDN wants the *current* ones.
    @MainActor
    func syncFromWebKit() async {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var changed = false
        for c in all where c.domain.hasSuffix("tiktok.com") {
            if cookies[c.name] != c.value { cookies[c.name] = c.value; changed = true }
        }
        if changed { persist() }
    }

    /// Apply Set-Cookie rotations (msToken etc.) from an API response.
    func absorb(_ response: HTTPURLResponse) {
        guard let url = response.url else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { out, kv in
            if let k = kv.key as? String, let v = kv.value as? String { out[k] = v }
        }
        var changed = false
        for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) where c.domain.hasSuffix("tiktok.com") {
            if cookies[c.name] != c.value { cookies[c.name] = c.value; changed = true }
        }
        if changed { persist() }
    }

    func setHandle(_ h: String?) {
        UserDefaults.standard.set(h, forKey: Self.handleKey)
        if isSignedIn { state = .signedIn(handle: h) }
    }

    func signOut() {
        cookies = [:]
        Keychain.delete(Self.keychainKey)
        UserDefaults.standard.removeObject(forKey: Self.handleKey)
        state = .signedOut
        Task { @MainActor in
            let store = WKWebsiteDataStore.default()
            let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("tiktok") })
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cookies), let s = String(data: data, encoding: .utf8) {
            Keychain.write(Self.keychainKey, s)
        }
    }
}
