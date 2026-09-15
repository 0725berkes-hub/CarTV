import Foundation
import SwiftUI

/// User preferences persisted in UserDefaults. Observable so views update live.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    enum Appearance: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .system: "Follow System"
            case .dark:   "Dark"
            case .light:  "Light"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .dark:   .dark
            case .light:  .light
            }
        }
    }

    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            onAppearanceChanged?()
        }
    }
    var onAppearanceChanged: (() -> Void)?
    /// Force VLC software decoding (helps with broken hardware-decoded streams).
    var softwareDecoding: Bool {
        didSet { defaults.set(softwareDecoding, forKey: Keys.softwareDecoding) }
    }
    /// Show live snapshot previews in channel grids (uses data).
    var livePreviews: Bool {
        didSet { defaults.set(livePreviews, forKey: Keys.livePreviews) }
    }
    /// Probe channel reachability in the background.
    var healthChecks: Bool {
        didSet { defaults.set(healthChecks, forKey: Keys.healthChecks) }
    }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }
    /// BCP-47 override, nil = follow system.
    var languageOverride: String? {
        didSet { defaults.set(languageOverride, forKey: Keys.language) }
    }
    /// Preferred subtitle language for auto-selection and translation target.
    var subtitleLanguage: String? {
        didSet { defaults.set(subtitleLanguage, forKey: Keys.subtitleLanguage) }
    }
    /// Built-in MyTV+ channels (367 live channels).
    var mytvEnabled: Bool {
        didSet { defaults.set(mytvEnabled, forKey: Keys.mytv) }
    }
    /// TikTok tab (personal For You via your own tiktok.com session).
    var tiktokEnabled: Bool {
        didSet { defaults.set(tiktokEnabled, forKey: Keys.tiktok) }
    }
    /// Folder YouTube downloads land in. nil = ask (or the only folder, if there is one).
    var downloadFolderID: UUID? {
        didSet { defaults.set(downloadFolderID?.uuidString, forKey: Keys.downloadFolder) }
    }
    /// Optional RapidAPI key for the "youtube-media-downloader" fallback source.
    var rapidAPIKey: String? {
        didSet { defaults.set(rapidAPIKey?.nilIfEmpty, forKey: Keys.rapidAPIKey) }
    }

    init() {
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        softwareDecoding = defaults.bool(forKey: Keys.softwareDecoding)
        livePreviews = defaults.object(forKey: Keys.livePreviews) as? Bool ?? true
        healthChecks = defaults.object(forKey: Keys.healthChecks) as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        languageOverride = defaults.string(forKey: Keys.language)
        subtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage)
        mytvEnabled = defaults.bool(forKey: Keys.mytv)
        downloadFolderID = defaults.string(forKey: Keys.downloadFolder).flatMap(UUID.init)
        rapidAPIKey = defaults.string(forKey: Keys.rapidAPIKey)
    }

    /// Re-read every value after the defaults domain was wiped (Clear All Data).
    /// Assigning through the properties re-persists them, which is what we want:
    /// the live object and the store agree on the fresh defaults.
    func reloadFromDefaults() {
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        softwareDecoding = defaults.bool(forKey: Keys.softwareDecoding)
        livePreviews = defaults.object(forKey: Keys.livePreviews) as? Bool ?? true
        healthChecks = defaults.object(forKey: Keys.healthChecks) as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        languageOverride = defaults.string(forKey: Keys.language)
        subtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage)
        mytvEnabled = defaults.bool(forKey: Keys.mytv)
        downloadFolderID = defaults.string(forKey: Keys.downloadFolder).flatMap(UUID.init)
        rapidAPIKey = defaults.string(forKey: Keys.rapidAPIKey)
    }

    private enum Keys {
        static let appearance = "settings.appearance"
        static let softwareDecoding = "settings.softwareDecoding"
        static let livePreviews = "settings.livePreviews"
        static let healthChecks = "settings.healthChecks"
        static let onboarding = "settings.onboardingDone"
        static let language = "settings.language"
        static let subtitleLanguage = "settings.subtitleLanguage"
        static let mytv = "settings.mytvEnabled"
        static let tiktok = "settings.tiktokEnabled"
        static let downloadFolder = "settings.downloadFolderID"
        static let rapidAPIKey = "settings.rapidAPIKey"
    }
}
