import SwiftUI

enum PhoneTab: Hashable { case home, favorites, youtube, cast, library }

struct PhoneRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(AppSettings.self) private var settings

    @State private var tab: PhoneTab = .home
    @State private var showAddSource = false
    @State private var showOnboarding = false
    @State private var importBanner: ImportBanner?
    @State private var playerShown = false
    @State private var showSettings = false

    var body: some View {
        // Five tabs: Home, Favorites, YouTube, Cast, Library. iOS shows a "More" tab
        // past five, so Settings is a sheet from the toolbar instead — it's a place
        // you visit, not a place you live.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                HomeView(showAddSource: $showAddSource)
            }
            Tab("Favorites", systemImage: "heart.fill", value: .favorites) {
                FavoritesView()
            }
            Tab("YouTube", systemImage: "play.rectangle.fill", value: .youtube) {
                YouTubeTab()
            }
            Tab("Cast", systemImage: "tv.badge.wifi", value: .cast) {
                CastView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: .library) {
                LibraryView(showAddSource: $showAddSource)
            }
        }
        .environment(\.openSettings, OpenSettingsAction { showSettings = true })
        .tabViewBottomAccessory(isEnabled: playback.isActive) {
            MiniPlayerBar()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // iOS 26 shrinks the tab bar into a compact glass pill when a list scrolls
        // under it — reads as a stuck half-sheet on a TV app. Keep it full-size.
        .tabBarMinimizeBehavior(.never)
        .tint(Theme.accent)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: $playerShown) {
            PlayerView()
        }
        .onChange(of: playback.isPhonePlayerPresented, initial: true) { _, shown in
            if playerShown != shown { playerShown = shown }
        }
        .onChange(of: playerShown) { _, shown in
            // Swipe-down / system dismissal → keep the controller in sync.
            if playback.isPhonePlayerPresented != shown { playback.isPhonePlayerPresented = shown }
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceSheet()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { settings.hasCompletedOnboarding = true; showOnboarding = false }
        }
        .onAppear { if !settings.hasCompletedOnboarding { showOnboarding = true } }
        .onChange(of: env.library.pendingExternalImports) { _, urls in
            guard let url = urls.first else { return }
            env.library.pendingExternalImports.removeAll()
            Task { await importExternal(url) }
        }
        .overlay(alignment: .top) {
            if let banner = importBanner {
                BannerView(banner: banner).transition(.move(edge: .top).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(3)); withAnimation { importBanner = nil } }
            }
        }
    }

    private func importExternal(_ url: URL) async {
        let importer = PlaylistImporter(container: env.modelContainer)
        do {
            let input: SubscriptionInput
            if url.isFileURL {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                input = .inlineM3U(text)
            } else {
                input = .remotePlaylist(url)
            }
            let summaries = try await importer.importInput(input, suggestedName: url.deletingPathExtension().lastPathComponent)
            let total = summaries.reduce(0) { $0 + $1.added }
            withAnimation { importBanner = ImportBanner(text: String(localized: "Found \(total) channels"), isError: false) }
            tab = .library
        } catch {
            withAnimation { importBanner = ImportBanner(text: error.localizedDescription, isError: true) }
        }
    }
}

struct ImportBanner: Equatable {
    let text: String
    let isError: Bool
}

struct BannerView: View {
    let banner: ImportBanner
    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Theme.amber : Theme.accent)
            Text(banner.text).font(Theme.Font.callout).foregroundStyle(Theme.ink).lineLimit(2)
        }
        .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
        .glassEffect(.regular, in: Capsule())
        .padding(.top, Theme.s2)
        .padding(.horizontal, Theme.s4)
    }
}

// MARK: - Settings presentation

/// Any tab's toolbar can open Settings as a sheet without knowing about the root.
struct OpenSettingsAction {
    let run: () -> Void
    func callAsFunction() { run() }
}
private struct OpenSettingsKey: EnvironmentKey { static let defaultValue = OpenSettingsAction { } }
extension EnvironmentValues {
    var openSettings: OpenSettingsAction { get { self[OpenSettingsKey.self] } set { self[OpenSettingsKey.self] = newValue } }
}

/// The gear that lives at the top-leading of every tab.
struct SettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button { openSettings() } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
    }
}
