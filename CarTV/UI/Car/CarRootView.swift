import SwiftUI

enum CarSection: Hashable, CaseIterable {
    case home, favorites, library
    var title: LocalizedStringResource {
        switch self { case .home: "Home"; case .favorites: "Favorites"; case .library: "Library" }
    }
    var symbol: String {
        switch self { case .home: "house.fill"; case .favorites: "heart.fill"; case .library: "square.stack.fill" }
    }
}

enum CarRoute: Hashable {
    case playlist(Playlist)
    case genre(Playlist, Genre?)
    case folder(VideoFolder)

    var title: String {
        switch self {
        case .playlist(let p): p.name
        case .genre(let p, let g): g.map { String(localized: $0.title) } ?? p.name
        case .folder(let f): f.name
        }
    }
}

/// Root of the car UI. System `TabView` (Liquid Glass tab bar) + `NavigationStack`
/// per tab, with the system bottom accessory for Now Playing — the same native
/// chrome as the phone, so it inherits appearance, focus, and knob navigation.
struct CarRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(CarPlayCoordinator.self) private var car
    @Environment(AppSettings.self) private var settings

    @State private var section: CarSection = .home
    @State private var showPlayer = false

    var body: some View {
        GeometryReader { geo in
            let metrics = CarMetrics(size: geo.size)
            ZStack {
                TabView(selection: $section) {
                    Tab("Home", systemImage: "house.fill", value: .home) {
                        CarNavHost(title: "Home") { CarHomeView() }
                    }
                    Tab("Favorites", systemImage: "heart.fill", value: .favorites) {
                        CarNavHost(title: "Favorites") { CarFavoritesView() }
                    }
                    Tab("Library", systemImage: "square.stack.fill", value: .library) {
                        CarNavHost(title: "Library") { CarLibraryView() }
                    }
                }
                .tabViewBottomAccessory(isEnabled: playback.isActive) {
                    CarNowPlayingAccessory { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
                }
                .tint(Theme.accent)

                if showPlayer {
                    CarPlayerView { withAnimation(.easeOut(duration: 0.2)) { showPlayer = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environment(\.carMetrics, metrics)
        }
        .preferredColorScheme(settings.appearance.colorScheme ?? (car.contentStyle == .light ? .light : .dark))
        .onChange(of: playback.current?.id) { old, new in
            if new != nil, old != new { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
            if new == nil { withAnimation { showPlayer = false } }
        }
        .onChange(of: playback.isActive) { _, active in
            if active, !showPlayer { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
        }
        .onAppear { if playback.isActive { showPlayer = true } }
    }
}

/// A `NavigationStack` with the routes the car browse views push.
struct CarNavHost<Root: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let root: () -> Root
    @State private var path: [CarRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationTitle(Text(title))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: CarRoute.self) { route in
                    Group {
                        switch route {
                        case .playlist(let p):     CarPlaylistView(playlist: p)
                        case .genre(let p, let g): CarChannelGridView(playlist: p, genre: g)
                        case .folder(let f):       CarVideosGridView(folder: f)
                        }
                    }
                    .navigationTitle(route.title)
                    .navigationBarTitleDisplayMode(.inline)
                }
        }
        .background(Theme.ground)
        .environment(\.carPush, CarPush { path.append($0) })
    }
}

struct CarPush {
    let push: (CarRoute) -> Void
    func callAsFunction(_ r: CarRoute) { push(r) }
}
private struct CarPushKey: EnvironmentKey { static let defaultValue = CarPush { _ in } }
extension EnvironmentValues {
    var carPush: CarPush { get { self[CarPushKey.self] } set { self[CarPushKey.self] = newValue } }
}

// MARK: - Now Playing accessory (system bottom accessory)

struct CarNowPlayingAccessory: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let open: () -> Void

    var body: some View {
        if let item = playback.current {
            HStack(spacing: 12) {
                ZStack {
                    TileTint.gradient(for: item.title)
                    RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 96, height: 96), contentMode: item.isLocal ? .fill : .fit) {
                        Monogram(text: item.title, size: 11)
                    }.padding(item.isLocal ? 0 : 4)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline, let sub = item.subtitle ?? (item.isLive ? String(localized: "Live") : nil) {
                        Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .font(.title3).frame(width: 44, height: 44)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                if placement != .inline {
                    Button { playback.next() } label: { Image(systemName: "forward.fill") }
                        .font(.title3).frame(width: 44, height: 44)
                        .disabled(!playback.hasNext)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Press scale + focus ring for knob/touchpad cars, on rectangular targets.
struct CarFocusButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(Theme.accent, lineWidth: 3)
                }
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
