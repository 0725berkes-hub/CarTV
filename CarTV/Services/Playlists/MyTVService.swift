import OSLog
import Foundation
import CommonCrypto

/// Built-in MyTV+ source. Talks to the MyTV+ API *directly from this device* and
/// decrypts the catalogue on-device — no middle server.
///
/// This matters: stream tokens are bound to the IP that fetched the catalogue, so
/// the phone must be the one asking. Anything fetched by a server 406s on the phone.
enum MyTVService {

    /// Sentinel URL stored on the playlist so we can find/refresh/remove it.
    nonisolated static let sourceURL = URL(string: "mytv://builtin")!
    nonisolated static let playlistName = "MyTV+"

    nonisolated private static let api = URL(string: "https://androidapi.appmytv.com/android/v2/channels/getChannelsDetail_local.php")!
    nonisolated private static let userAgent = "And$MyTV"
    nonisolated private static let key = Array("9z_z%C*F-JaNdWgU".utf8)
    nonisolated private static let iv = Array("t2w!W%u&F(J@McWf".utf8)
    nonisolated private static let body = Data(#"{"appVersion":"3.15.1","deviceType":"android","uuid":"58182e46-8a20-443e-9e43-9b63bc44589c","userId":"6414575","country":"IQ"}"#.utf8)

    // MARK: Install / remove

    @MainActor private static var installing = false

    @MainActor
    static func install(env: AppEnvironment) {
        guard !installing, findPlaylist(in: env) == nil else { return }
        installing = true
        Task {
            defer { installing = false }
            do {
                let m3u = try await fetchM3U()
                let importer = PlaylistImporter(container: env.modelContainer)
                let summaries = try await importer.importInput(.inlineM3U(m3u), suggestedName: playlistName)
                if let id = summaries.first?.playlistID, let playlist = env.library.playlist(id: id) {
                    playlist.sourceURL = sourceURL
                    playlist.kind = .subscription
                    env.library.save()
                }
                Log.playlist.info("MyTV+ installed")
            } catch {
                Log.playlist.error("MyTV+ install failed: \(error.localizedDescription)")
                env.settings.mytvEnabled = false
            }
        }
    }

    @MainActor
    static func uninstall(env: AppEnvironment) {
        guard let playlist = findPlaylist(in: env) else { return }
        env.library.delete(playlist)
    }

    @MainActor
    static func findPlaylist(in env: AppEnvironment) -> Playlist? {
        env.library.playlists().first { $0.sourceURL == sourceURL }
    }

    // MARK: Fetch + decrypt (off main actor)

    /// Downloads the encrypted catalogue for *this device's IP*, decrypts it, renders M3U.
    nonisolated static func fetchM3U() async throws -> String {
        var req = URLRequest(url: api, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let json = try decrypt(String(decoding: data, as: UTF8.self).trimmed)
        guard let list = try JSONSerialization.jsonObject(with: json) as? [[String: Any]], list.count > 50 else {
            throw URLError(.cannotParseResponse)
        }

        var out = "#EXTM3U\n#EXTVLCOPT:http-user-agent=\(userAgent)\n"
        out.reserveCapacity(list.count * 400)
        for ch in list {
            guard let link = ch["link"] as? String, !link.isEmpty else { continue }
            let id = ch["id"].map { "\($0)" } ?? ""
            let name = (ch["name"] as? String) ?? (ch["title"] as? String) ?? "Channel"
            let group = (ch["category"] as? String).flatMap(\.nilIfEmpty) ?? "Other"
            let logo = (ch["fullLogoV2"] ?? ch["logoV2"] ?? ch["fullLogo"] ?? ch["logo"]) as? String ?? ""
            out += "#EXTINF:-1 tvg-id=\"\(id)\" tvg-logo=\"\(logo)\" group-title=\"\(clean(group))\",\(clean(name))\n"
            out += "#EXTVLCOPT:http-user-agent=\(userAgent)\n\(link)\n"
        }
        return out
    }

    nonisolated private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }

    /// A rotation digit is spliced into the middle of the base64; it says how far to
    /// rotate the AES key. Strip it, rotate, AES-128-CBC decrypt.
    nonisolated private static func decrypt(_ enc: String) throws -> Data {
        let chars = Array(enc)
        let mid = chars.count / 2
        let rot = Int(String(chars[mid])) ?? 0
        let cleaned = String(chars[..<mid] + chars[(mid + 1)...])
        let rotated = rot > 0 ? Array(key[(key.count - rot)...] + key[..<(key.count - rot)]) : key
        guard let cipher = Data(base64Encoded: cleaned) else { throw URLError(.cannotDecodeRawData) }

        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let status = cipher.withUnsafeBytes { c in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                    rotated, rotated.count, iv,
                    c.baseAddress, cipher.count,
                    &plain, plain.count, &written)
        }
        guard status == kCCSuccess else { throw URLError(.cannotDecodeContentData) }
        return Data(plain[..<written])
    }
}
