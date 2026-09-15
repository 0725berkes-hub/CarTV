import SwiftUI

enum PhoneTab: Hashable { case home, favorites, library, settings }

struct PhoneRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(AppSettings.self) private var settings

    @State private var tab: PhoneTab = .home
    @State private var showAddSource = false
    @State private var showOnboarding = false
    @State private var importBanner: ImportBanner?

    var body: some View {
        @Bindable var playback = playback
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                HomeView(showAddSource: $showAddSource)
            }
            Tab("Favorites", systemImage: "heart.fill", value: .favorites) {
                FavoritesView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: .library) {
                LibraryView(showAddSource: $showAddSource)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
            }
        }
        .tabViewBottomAccessory(isEnabled: playback.isActive) {
            MiniPlayerBar()
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.accent)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: $playback.isPhonePlayerPresented) {
            PlayerView()
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
