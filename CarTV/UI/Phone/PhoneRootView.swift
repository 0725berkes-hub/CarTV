import SwiftUI

enum PhoneTab: Hashable { case home, favorites, youtube, library }

struct PhoneRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(AppSettings.self) private var settings

    @State private var tab: PhoneTab = .home
    @State private var showAddSource = false
    @State private var showOnboarding = false
    @State private var importBanner: ImportBanner?
    @State private var playerShown = false
    @State private var moreSheet: MoreSheet?

    var body: some View {
        // Four tabs: Home, Favorites, YouTube, Library. Cast and Settings are tools
        // you visit, so they're a menu on every tab's toolbar that opens a sheet.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                HomeView(showAddSource: $showAddSource)
            }
            Tab("Favorites", systemImage: "heart.fill", value: .favorites) {
                NavigationStack { FavoritesView() }
            }
            Tab("YouTube", systemImage: "play.rectangle.fill", value: .youtube) {
                YouTubeTab()
            }
            Tab("Library", systemImage: "square.stack.fill", value: .library) {
                LibraryView(showAddSource: $showAddSource)
            }
        }
        .environment(\.openMore, OpenMoreAction { moreSheet = $0 })
        .tabViewBottomAccessory(isEnabled: playback.isActive) {
            MiniPlayerBar()
        }
        .sheet(item: $moreSheet) { which in
            Group {
                switch which {
                case .cast:     CastView()
                case .settings: SettingsView()
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // iOS 26 shrinks the tab bar into a compact glass pill when a list scrolls
        // under it — reads as a stuck half-sheet on a TV app. Keep it full-size.
        .tabBarMinimizeBehavior(.never)
        .tint(Theme.accent)
        .preferredColorScheme(settings.appearance.colorScheme)
        .overlay(alignment: .top) { DownloadNoticeBanner() }
        .fullScreenCover(isPresented: $playerShown) {
            PlayerView()
                .overlay(alignment: .top) { DownloadNoticeBanner() }
                // Clear backing so the swipe-down collapse reveals the app underneath
                // instead of a black slab. PlayerView paints its own dimming layer.
                .presentationBackground(.clear)
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
            OnboardingView {
                settings.hasCompletedOnboarding = true
                showOnboarding = false
                // Opted into YouTube sign-in → land on that tab so the sheet appears right away.
                if env.youtube.pendingSignInPrompt { tab = .youtube }
            }
        }
        .onChange(of: settings.hasCompletedOnboarding, initial: true) { _, done in
            // Fires on launch and whenever Settings resets the flag (tour again / clear all).
            // Small delay so a dismissing Settings sheet finishes before the cover appears.
            if !done {
                Task { try? await Task.sleep(for: .milliseconds(350)); tab = .home; showOnboarding = true }
            }
        }
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

// MARK: - More (Cast, Settings)

enum MoreSheet: String, Identifiable { case cast, settings; var id: String { rawValue } }

/// Any tab's toolbar can open Cast or Settings as a sheet without knowing about the root.
struct OpenMoreAction {
    let run: (MoreSheet) -> Void
    func callAsFunction(_ which: MoreSheet) { run(which) }
}
private struct OpenMoreKey: EnvironmentKey { static let defaultValue = OpenMoreAction { _ in } }
extension EnvironmentValues {
    var openMore: OpenMoreAction { get { self[OpenMoreKey.self] } set { self[OpenMoreKey.self] = newValue } }
}

/// Native `Menu` at the top-leading of every tab: Cast to Car, Settings.
struct MoreToolbarMenu: View {
    @Environment(\.openMore) private var openMore
    @Environment(PlaybackController.self) private var playback
    var body: some View {
        Menu {
            Button { openMore(.cast) } label: {
                Label(playback.carIsConnected ? "Cast to Car" : "Cast", systemImage: "tv.badge.wifi")
            }
            Button { openMore(.settings) } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}
