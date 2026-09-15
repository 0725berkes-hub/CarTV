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
/// per tab. UIKit's tab bar renders in a compact, untinted style under the CarPlay
/// idiom (no icons, no accent, a scroll-hint dot), so the tabs are our own glass
/// capsule at the top — same look as the phone's bar — over native NavigationStacks.
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

                VStack(spacing: 0) {
                    CarTabBar(section: $section, nowPlaying: playback.isActive ? playback.current : nil) {
                        withAnimation(.easeOut(duration: 0.2)) { showPlayer = true }
                    }
                    .padding(.horizontal, metrics.gutter)
                    .padding(.vertical, Theme.s2)

                    ZStack {
                        switch section {
                        case .home:      CarNavHost(title: "Home") { CarHomeView() }
                        case .favorites: CarNavHost(title: "Favorites") { CarFavoritesView() }
                        case .cast:      CarNavHost(title: "Cast") { CarCastView() }
                        case .library:   CarNavHost(title: "Library") { CarLibraryView() }
                        }
                    }
                    .id(section)
                }

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
                .toolbar(.hidden, for: .navigationBar)
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

// MARK: - Tab bar (glass capsule, mirrors the phone's look)

struct CarTabBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @Binding var section: CarSection
    let nowPlaying: PlayableItem?
    let openPlayer: () -> Void

    var body: some View {
        HStack(spacing: Theme.s2) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(CarSection.allCases, id: \.self) { s in
                        Button { withAnimation(.snappy(duration: 0.22)) { section = s } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: s.symbol).font(.system(size: m.compact ? 13 : 16, weight: .bold))
                                if section == s || !m.compact {
                                    Text(s.title).font(.system(size: m.compact ? 12 : 15, weight: .semibold))
                                }
                            }
                            .foregroundStyle(section == s ? Color.black : Theme.ink)
                            .padding(.horizontal, m.compact ? Theme.s3 : Theme.s4)
                            .frame(height: m.headerHeight - 8)
                            .background(section == s ? Theme.accent : .clear, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(CarFocusButtonStyle())
                    }
                }
                .padding(4)
            }
            .glassEffect(.regular.interactive(), in: Capsule())

            Spacer(minLength: 0)

            if let item = nowPlaying {
                Button(action: openPlayer) {
                    HStack(spacing: 10) {
                        ZStack {
                            TileTint.gradient(for: item.title)
                            RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 96, height: 96), contentMode: item.isLocal ? .fill : .fit) {
                                Monogram(text: item.title, size: 11)
                            }.padding(item.isLocal ? 0 : 4)
                        }
                        .frame(width: m.headerHeight - 16, height: m.headerHeight - 16)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        if !m.compact {
                            Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                        }
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                            .onTapGesture { playback.togglePlayPause() }
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkMuted)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                            .onTapGesture { playback.stop() }
                    }
                    .padding(.leading, 8).padding(.trailing, 6)
                    .frame(height: m.headerHeight)
                }
                .buttonStyle(CarFocusButtonStyle())
                .glassEffect(.regular.tint(Theme.accent.opacity(0.15)).interactive(), in: Capsule())
                .accessibilityLabel("Now Playing, \(item.title)")
            }
        }
        .frame(height: m.headerHeight)
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
