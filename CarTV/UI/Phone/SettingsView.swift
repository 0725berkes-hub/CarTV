import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @State private var cacheCleared = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Theme.s3) {
                        Image(systemName: "car.fill").font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(playback.carIsConnected ? Theme.accent : Theme.inkMuted).frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playback.carIsConnected ? "Car connected" : "CarPlay not connected").font(Theme.Font.headline)
                            Text(playback.carIsConnected
                                 ? (env.carPlay.supportsVideoPlayback ? "Video playback available" : "Audio only while driving")
                                 : "Connect your iPhone to CarPlay to watch on the car screen.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }

                Section("General") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    NavigationLink { LanguagePickerView() } label: {
                        LabeledContent("Language", value: languageName)
                    }
                }

                Section {
                    Toggle(isOn: $settings.mytvEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MyTV+ channels")
                                Text(mytvStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                            }
                        } icon: { Image(systemName: "tv.badge.wifi").foregroundStyle(Theme.accent) }
                    }
                    .onChange(of: settings.mytvEnabled) { _, on in
                        if on { MyTVService.install(env: env) } else { MyTVService.uninstall(env: env) }
                    }
                } header: { Text("Built-in sources") } footer: {
                    Text("Adds 360+ live Kurdish, Arabic and international channels as a playlist. Turn off to remove them.")
                }

                Section {
                    Toggle("Software decoding", isOn: $settings.softwareDecoding)
                    Toggle("Check channel health", isOn: $settings.healthChecks)
                    Toggle("Live previews", isOn: $settings.livePreviews)
                } header: { Text("Playback") } footer: {
                    Text("Software decoding forces VLC for every stream. Turn it on if hardware-decoded video shows artifacts.")
                }

                Section("Storage") {
                    LabeledContent("Local videos", value: localVideoSize)
                    Button { ImageLoader.shared.clearDisk(); cacheCleared = true } label: {
                        Label(cacheCleared ? "Cache cleared" : "Clear image cache", systemImage: "trash")
                    }.disabled(cacheCleared)
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://kurdsoft.dev/cartv/privacy")!) { Label("Privacy Policy", systemImage: "hand.raised") }
                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) { Label("Terms of Use (EULA)", systemImage: "doc.text") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }

    private var mytvStatus: String {
        guard settings.mytvEnabled else { return String(localized: "Off") }
        if let p = MyTVService.findPlaylist(in: env) {
            return String(localized: "\(p.channelCount) channels")
        }
        return String(localized: "Loading…")
    }

    private var languageName: String {
        if let code = settings.languageOverride { return Locale.current.localizedString(forIdentifier: code) ?? code }
        return String(localized: "Follow System")
    }

    private var localVideoSize: String {
        let total = env.library.localVideos().reduce(Int64(0)) { $0 + $1.fileSize }
        return total.byteCountString
    }
}

struct LanguagePickerView: View {
    @Environment(AppSettings.self) private var settings
    @State private var query = ""

    private static let supported = ["en", "ckb", "ar", "tr", "fa", "de", "es", "fr", "ku"]

    var body: some View {
        List {
            Section {
                row(nil, title: String(localized: "Follow System"))
            }
            Section {
                ForEach(filtered, id: \.self) { code in
                    row(code, title: Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized ?? code)
                }
            } footer: {
                Text("The language will take effect after you reopen the app")
            }
        }
        .searchable(text: $query, prompt: Text("Find a language"))
        .navigationTitle("Language")
    }

    private var filtered: [String] {
        guard !query.isEmpty else { return Self.supported }
        return Self.supported.filter { (Locale.current.localizedString(forIdentifier: $0) ?? $0).localizedCaseInsensitiveContains(query) }
    }

    private func row(_ code: String?, title: String) -> some View {
        Button {
            settings.languageOverride = code
            UserDefaults.standard.set(code.map { [$0] }, forKey: "AppleLanguages")
        } label: {
            HStack { Text(title).foregroundStyle(Theme.ink); Spacer(); if settings.languageOverride == code { Image(systemName: "checkmark").foregroundStyle(Theme.accent) } }
        }
    }
}
