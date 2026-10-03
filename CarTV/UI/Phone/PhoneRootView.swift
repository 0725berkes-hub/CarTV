import SwiftUI

enum PhoneTab: Hashable { case home, favorites, browser, library, more }

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
        // Browsing gets its own tab; Cast and Settings are toolbar tools.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                HomeView(showAddSource: $showAddSource)
            }
            Tab("Favorites", systemImage: "heart.fill", value: .favorites) {
                NavigationStack { FavoritesView() }
            }
            Tab("Browser", systemImage: "globe", value: .browser) {
                PhoneBrowserView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: .library) {
                LibraryView(showAddSource: $showAddSource)
            }
            Tab("More", systemImage: "ellipsis", value: .more) {
                PhoneMoreView()
            }
        }
        .environment(\.openMore, OpenMoreAction { moreSheet = $0 })
        .tabViewStyle(.tabBarOnly)
        .tabViewBottomAccessory(isEnabled: playback.isActive) { MiniPlayerBar() }
        .environment(\.openBrowser, OpenBrowserAction { destination in
            env.browser.open(destination, isCar: false)
            tab = .browser
        })
        .sheet(item: $moreSheet) { which in
            Group {
                switch which {
                case .cast:     CastView()
                case .settings: SettingsView()
                case .youtube: YouTubeTab()
                case .tiktok: TTFeedView()
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
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
            if !shown, env.browser.isPresentingPhoneBrowserVideo { env.browser.returnFromPlayer() }
            if playerShown != shown { playerShown = shown }
        }
        .onChange(of: playerShown) { _, shown in
            if !shown, env.browser.isPresentingPhoneBrowserVideo { env.browser.returnFromPlayer() }
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
                if env.youtube.pendingSignInPrompt {
                    tab = .more
                    Task { try? await Task.sleep(for: .milliseconds(350)); moreSheet = .youtube }
                }
            }
        }
        .onChange(of: env.youtube.pendingWatchPage?.id) { _, id in
            if id != nil { tab = .more; moreSheet = .youtube }
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

enum MoreSheet: String, Identifiable { case youtube, tiktok, cast, settings; var id: String { rawValue } }

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
            Button { openMore(.youtube) } label: { Label("YouTube", systemImage: "play.rectangle.fill") }
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

struct PhoneMoreView: View {
    @Environment(\.openMore) private var openMore
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.s3) {
                    row("YouTube", subtitle: "Your feed, downloads and playlists", symbol: "play.rectangle.fill", destination: .youtube)
                    if settings.tiktokEnabled {
                        row("TikTok", subtitle: "Your native video feed", symbol: "music.note", destination: .tiktok)
                    }
                    row("Cast", subtitle: "Play on your car screen", symbol: "tv.badge.wifi", destination: .cast)
                    row("Settings", subtitle: "Make CarTV yours", symbol: "gearshape", destination: .settings)
                }
                .padding(Theme.s4)
            }
            .background(Theme.ground)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, symbol: String, destination: MoreSheet) -> some View {
        Button { openMore(destination) } label: {
            HStack(spacing: Theme.s3) {
                if destination == .youtube {
                    Image("YouTubeMark").resizable().scaledToFit().frame(width: 36, height: 28)
                } else if destination == .tiktok {
                    Image("TikTokMark").resizable().scaledToFit().frame(width: 36, height: 36)
                } else {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 36)
                }
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text(title).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.s4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        }
        .buttonStyle(.plain)
    }
}


struct OpenBrowserAction {
    let run: (BrowserDestination) -> Void
    func callAsFunction(_ destination: BrowserDestination) { run(destination) }
}
private struct OpenBrowserKey: EnvironmentKey { static let defaultValue = OpenBrowserAction { _ in } }
extension EnvironmentValues {
    var openBrowser: OpenBrowserAction { get { self[OpenBrowserKey.self] } set { self[OpenBrowserKey.self] = newValue } }
}

struct BrowserShortcuts: View {
    @Environment(\.openBrowser) private var openBrowser
    var isCar = false
    var body: some View {
        HStack(spacing: Theme.s2) {
            ForEach(BrowserDestination.allCases) { destination in
                Button { openBrowser(destination) } label: {
                    HStack(spacing: 8) {
                        Group {
                            switch destination {
                            case .youtube: Image("YouTubeMark").resizable().scaledToFit()
                            case .tiktok: Image("TikTokMark").resizable().scaledToFit()
                            case .browse: Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(Theme.accent)
                            }
                        }.frame(width: 24, height: 24)
                        Text(destination == .browse ? "Browser" : destination.title)
                            .font(.system(size: isCar ? 15 : 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: isCar ? 56 : 52)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}
