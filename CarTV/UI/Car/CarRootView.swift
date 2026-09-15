import SwiftUI

enum CarSection: Hashable, CaseIterable {
    case home, favorites, cast, library
    var title: LocalizedStringResource {
        switch self { case .home: "Home"; case .favorites: "Favorites"; case .cast: "Cast"; case .library: "Library" }
    }
    var symbol: String {
        switch self { case .home: "house.fill"; case .favorites: "heart.fill"; case .cast: "tv.badge.wifi"; case .library: "square.stack.fill" }
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
                CarBackdrop()
                TabView(selection: $section) {
                    Tab("Home", systemImage: "house.fill", value: .home) {
                        CarNavHost(title: "Home") { CarHomeView() }
                    }
                    Tab("Favorites", systemImage: "heart.fill", value: .favorites) {
                        CarNavHost(title: "Favorites") { CarFavoritesView() }
                    }
                    Tab("Cast", systemImage: "tv.badge.wifi", value: .cast) {
                        CarNavHost(title: "Cast") { CarCastView() }
                    }
                    Tab("Library", systemImage: "square.stack.fill", value: .library) {
                        CarNavHost(title: "Library") { CarLibraryView() }
                    }
                }
                .tabViewBottomAccessory(isEnabled: playback.isActive) {
                    CarNowPlayingAccessory { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
                }
                .tint(Theme.accent)

                if env.mirror.state == .mirroring {
                    CarMirrorStage()
                        .transition(.opacity)
                        .zIndex(2)
                } else if showPlayer {
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

/// "< Title" as one wide tap target. Focus ring hugs the pill for knob navigation.
struct CarBackButton: View {
    @Environment(\.carMetrics) private var m
    @Environment(\.isFocused) private var focused
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: m.compact ? 6 : 10) {
                Image(systemName: "chevron.left").font(.system(size: m.compact ? 15 : 19, weight: .bold))
                Text(title).font(Theme.Car.title(m.compact ? 16 : 22)).lineLimit(1)
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, m.compact ? 12 : 16).padding(.trailing, m.compact ? 16 : 22)
            .frame(minHeight: m.compact ? 40 : Theme.Car.minTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(CarPillPressStyle())
        .accessibilityLabel(Text("Back"))
    }
}

private struct CarPillPressStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.10)))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: focused ? 3 : 0))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
                    // The CarPlay idiom draws the system back button and title as one pill
                    // but only the chevron is tappable. Replace it with a single button
                    // that covers the whole "< Title" area.
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            CarBackButton(title: route.title) { _ = path.popLast() }
                        }
                    }
                }
        }
        .scrollContentBackground(.hidden)
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
            HStack(spacing: 8) {
                // Artwork + titles are one big "open the player" button. A real Button
                // (not onTapGesture) so it wins against the siblings and takes knob focus.
                Button(action: open) {
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
                    }
                    .padding(.leading, 12).padding(.vertical, 6)
                    .frame(minHeight: 56)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(CarFocusButtonStyle(radius: 12))
                .accessibilityLabel(Text("Now Playing: \(item.title)"))
                .accessibilityHint(Text("Opens the player"))

                CarCircleButton(symbol: playback.isPlaying ? "pause.fill" : "play.fill", size: 44) { playback.togglePlayPause() }
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                if placement != .inline {
                    CarCircleButton(symbol: "forward.end.fill", size: 44, enabled: playback.hasNext) { playback.next() }
                        .accessibilityLabel("Next")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }
}

/// Press scale + focus ring for knob/touchpad cars, on rectangular targets.
struct CarFocusButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    var radius: CGFloat = Theme.radiusS
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                // Visible press so touch feels acknowledged even on tiles with their own art.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0))
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 3)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
