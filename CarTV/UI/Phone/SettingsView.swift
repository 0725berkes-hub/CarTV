import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCleared = false
    @State private var confirmErase = false
    @State private var confirmEraseAgain = false

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
                                Text("CarFlix+ channels")
                                Text(mytvStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                            }
                        } icon: { Image(systemName: "tv.badge.wifi").foregroundStyle(Theme.accent) }
                    }
                    .onChange(of: settings.mytvEnabled) { _, on in
                        if on { MyTVService.install(env: env) } else { MyTVService.uninstall(env: env) }
                    }
                    Toggle(isOn: $settings.tiktokEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TikTok tab")
                                Text(tiktokStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                            }
                        } icon: { Image(systemName: "music.note").foregroundStyle(Theme.accent) }
                    }
                    if env.tiktok.session.isSignedIn {
                        Button(role: .destructive) { env.tiktok.signOut() } label: { Label("Sign out of TikTok", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                } header: { Text("Built-in sources") } footer: {
                    Text("CarFlix+ adds 360+ live Kurdish, Arabic and international channels, plus movies and series. TikTok shows your own For You page using your tiktok.com login — read-only, nothing is posted or liked.")
                }

                Section {
                    Toggle("Software decoding", isOn: $settings.softwareDecoding)
                    Toggle("Check channel health", isOn: $settings.healthChecks)
                    Toggle("Live previews", isOn: $settings.livePreviews)
                } header: { Text("Playback") } footer: {
                    Text("Software decoding forces VLC for every stream. Turn it on if hardware-decoded video shows artifacts.")
                }

                Section {
                    Picker(selection: Binding(get: { settings.downloadFolderID }, set: { settings.downloadFolderID = $0 })) {
                        Text("Ask every time").tag(UUID?.none)
                        ForEach(env.library.folders()) { f in Text(f.name).tag(Optional(f.id)) }
                    } label: { Label("Download folder", systemImage: "folder") }
                    Picker(selection: Binding(get: { env.downloads.maxHeight ?? 0 }, set: { env.downloads.maxHeight = $0 == 0 ? nil : $0 })) {
                        Text("Best available").tag(0); Text("1080p").tag(1080); Text("720p").tag(720); Text("480p").tag(480); Text("360p").tag(360)
                    } label: { Label("Download quality", systemImage: "arrow.down.circle") }
                    SecureField("RapidAPI key (optional fallback)", text: Binding(get: { settings.rapidAPIKey ?? "" }, set: { settings.rapidAPIKey = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !env.downloads.jobs.isEmpty {
                        YTDownloadsList()
                        Button("Clear finished") { env.downloads.clearFinished() }.disabled(env.downloads.active.count == env.downloads.jobs.count)
                    }
                } header: { Text("YouTube downloads") } footer: {
                    Text("Downloads are saved into your local videos and play offline, in the car too. The RapidAPI key is only used when YouTube refuses a stream.")
                }

                Section("Storage") {
                    LabeledContent("Local videos", value: localVideoSize)
                    Button { ImageLoader.shared.clearDisk(); cacheCleared = true } label: {
                        Label(cacheCleared ? "Cache cleared" : "Clear image cache", systemImage: "trash")
                    }.disabled(cacheCleared)
                }

                Section {
                    Button { AppReset.restartOnboarding(env: env); dismiss() } label: {
                        Label("Show Welcome Tour Again", systemImage: "sparkles")
                    }
                    Button(role: .destructive) { confirmErase = true } label: {
                        Label("Clear All Data…", systemImage: "trash.fill")
                    }
                } header: { Text("Reset") } footer: {
                    Text("Clear All Data removes every playlist, imported video, favorite, watch position and sign-in from this iPhone, then starts over from the welcome tour.")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear all data?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Continue", role: .destructive) { confirmEraseAgain = true }
            } message: {
                Text("This deletes \(localVideoSize) of imported videos, all playlists, favorites and history. It can't be undone.")
            }
            .alert("Really clear everything?", isPresented: $confirmEraseAgain) {
                Button("Clear All Data", role: .destructive) {
                    AppReset.eraseEverything(env: env)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("CarFlix will look like it was just installed.") }
        }
    }

    private var tiktokStatus: String {
        guard settings.tiktokEnabled else { return String(localized: "Off") }
        if case .signedIn(let h) = env.tiktok.session.state { return h.map { "@\($0)" } ?? String(localized: "Signed in") }
        return String(localized: "Not signed in")
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
