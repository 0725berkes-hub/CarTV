import Foundation
import Observation
import OSLog

/// Google OAuth via the "TV and limited-input" device-code flow used by YouTube on
/// TVs. The user reads a short code here and types it at google.com/device on any
/// browser. Refresh token is kept in the Keychain; access tokens auto-renew.
@Observable
final class YTAuth {
    enum State: Equatable { case signedOut, awaitingCode(userCode: String, verificationURL: URL), signedIn }
    private(set) var state: State = .signedOut
    private(set) var accountName: String?
    private(set) var accountAvatarURL: URL?
    private(set) var error: String?

    // Public client used by YouTube for TVs (well known; same as SmartTube / NewPipe).
    private static let clientID = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    private static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    // Device flow accepts only these; youtube.force-ssl is rejected with invalid_scope.
    private static let scope = "https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/userinfo.profile"

    private var accessToken: String?
    private var accessExpiry: Date = .distantPast
    private var refreshToken: String? {
        get { Keychain.read("yt.refreshToken") }
        set { if let v = newValue { Keychain.write("yt.refreshToken", v) } else { Keychain.delete("yt.refreshToken") } }
    }
    private var pollTask: Task<Void, Never>?

    init() {
        if refreshToken != nil {
            state = .signedIn
            accountName = UserDefaults.standard.string(forKey: "yt.accountName")
            accountAvatarURL = UserDefaults.standard.url(forKey: "yt.accountAvatar")
        }
    }

    var isSignedIn: Bool { state == .signedIn }

    /// Valid bearer token, refreshing if needed. nil when signed out.
    func token() async -> String? {
        guard refreshToken != nil else { return nil }
        if let t = accessToken, accessExpiry > Date().addingTimeInterval(60) { return t }
        do { try await refresh() } catch {
            Log.network.error("YT token refresh failed: \(error.localizedDescription)")
            if case YTError.unauthorized = error { signOut() }
            return nil
        }
        return accessToken
    }

    // MARK: Sign in

    func beginSignIn() {
        error = nil
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dev = try await Self.post("https://oauth2.googleapis.com/device/code", [
                    "client_id": Self.clientID, "scope": Self.scope
                ])
                guard let deviceCode = dev["device_code"] as? String, let userCode = dev["user_code"] as? String,
                      let verify = (dev["verification_url"] as? String).flatMap(URL.init) else { throw YTError.parse("device code") }
                let interval = (dev["interval"] as? Double) ?? 5
                let expires = Date().addingTimeInterval((dev["expires_in"] as? Double) ?? 1800)
                self.state = .awaitingCode(userCode: userCode, verificationURL: verify)

                while Date() < expires, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    let tok = try await Self.post("https://oauth2.googleapis.com/token", [
                        "client_id": Self.clientID, "client_secret": Self.clientSecret,
                        "device_code": deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                    ], allowErrors: true)
                    if let err = tok["error"] as? String {
                        if err == "authorization_pending" || err == "slow_down" { continue }
                        throw YTError.network(tok["error_description"] as? String ?? err)
                    }
                    guard let access = tok["access_token"] as? String, let refresh = tok["refresh_token"] as? String else { continue }
                    self.accessToken = access
                    self.accessExpiry = Date().addingTimeInterval((tok["expires_in"] as? Double) ?? 3600)
                    self.refreshToken = refresh
                    self.state = .signedIn
                    await self.loadProfile()
                    return
                }
                if !Task.isCancelled { self.state = .signedOut; self.error = String(localized: "The code expired. Try again.") }
            } catch {
                self.state = .signedOut
                self.error = error.localizedDescription
            }
        }
    }

    func cancelSignIn() { pollTask?.cancel(); state = refreshToken == nil ? .signedOut : .signedIn }

    func signOut() {
        pollTask?.cancel()
        accessToken = nil; refreshToken = nil
        accountName = nil; accountAvatarURL = nil
        UserDefaults.standard.removeObject(forKey: "yt.accountName")
        UserDefaults.standard.removeObject(forKey: "yt.accountAvatar")
        state = .signedOut
    }

    // MARK: Internals

    private func refresh() async throws {
        guard let rt = refreshToken else { throw YTError.unauthorized }
        let tok = try await Self.post("https://oauth2.googleapis.com/token", [
            "client_id": Self.clientID, "client_secret": Self.clientSecret,
            "refresh_token": rt, "grant_type": "refresh_token"
        ], allowErrors: true)
        if let err = tok["error"] as? String {
            if err == "invalid_grant" { throw YTError.unauthorized }
            throw YTError.network(tok["error_description"] as? String ?? err)
        }
        guard let access = tok["access_token"] as? String else { throw YTError.parse("token") }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((tok["expires_in"] as? Double) ?? 3600)
    }

    private func loadProfile() async {
        guard let t = accessToken else { return }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: req), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accountName = obj["name"] as? String
            accountAvatarURL = (obj["picture"] as? String).flatMap(URL.init)
            UserDefaults.standard.set(accountName, forKey: "yt.accountName")
            UserDefaults.standard.set(accountAvatarURL, forKey: "yt.accountAvatar")
        }
    }

    nonisolated private static func post(_ url: String, _ form: [String: String], allowErrors: Bool = false) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if !allowErrors, let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YTError.network(obj["error_description"] as? String ?? "HTTP \(http.statusCode)")
        }
        return obj
    }
}

/// Minimal Keychain wrapper for small secrets.
nonisolated enum Keychain {
    private static let service = "kurdsoft.CarTV"
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
