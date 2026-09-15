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
    @State private var paths: [CarSection: [CarRoute]] = [:]

    private var path: Binding<[CarRoute]> {
        Binding(get: { paths[section] ?? [] }, set: { paths[section] = $0 })
    }

    var body: some View {
        GeometryReader { geo in
            let metrics = CarMetrics(size: geo.size)
            ZStack {
                Theme.ground.ignoresSafeArea()

                VStack(spacing: 0) {
                    CarHeader(
                        section: $section,
                        route: path.wrappedValue.last,
                        nowPlaying: playback.isActive ? playback.current : nil,
                        back: { withAnimation(.easeOut(duration: 0.2)) { _ = path.wrappedValue.popLast() } },
                        openPlayer: { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
                    )
                    .padding(.horizontal, metrics.gutter)
                    .padding(.top, Theme.s2)
                    .padding(.bottom, Theme.s3)

                    ZStack {
                        switch section {
                        case .home:      CarNavHost(path: path) { CarHomeView() }
                        case .favorites: CarNavHost(path: path) { CarFavoritesView() }
                        case .cast:      CarNavHost(path: path) { CarCastView() }
                        case .library:   CarNavHost(path: path) { CarLibraryView() }
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
    @Binding var path: [CarRoute]
    @ViewBuilder let root: () -> Root

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
                    .toolbar(.hidden, for: .navigationBar)
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

// MARK: - Header (tabs at root, "‹ Title" when drilled in, Now Playing trailing)

struct CarHeader: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @Binding var section: CarSection
    let route: CarRoute?
    let nowPlaying: PlayableItem?
    let back: () -> Void
    let openPlayer: () -> Void

    var body: some View {
        HStack(spacing: Theme.s3) {
            if let route {
                // One control: chevron + title, whole capsule is the target.
                Button(action: back) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: m.compact ? 15 : 18, weight: .bold))
                        Text(route.title).font(.system(size: m.compact ? 15 : 18, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.leading, m.compact ? 12 : 14).padding(.trailing, m.compact ? 16 : 20)
                    .frame(height: m.headerHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(CarFocusButtonStyle())
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityLabel("Back")
            } else {
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
            }

            Spacer(minLength: 0)

            if let item = nowPlaying {
                CarNowPlayingPill(item: item, open: openPlayer)
            }
        }
        .frame(height: m.headerHeight)
    }
}

/// Now Playing: circular artwork with a live equaliser ring, title, play/pause, stop.
/// Reads like the system's now-playing chip — no square art, no cramped glyphs.
struct CarNowPlayingPill: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let item: PlayableItem
    let open: () -> Void

    var body: some View {
        let art = m.headerHeight - 12
        HStack(spacing: m.compact ? 8 : 12) {
            Button(action: open) {
                HStack(spacing: m.compact ? 8 : 12) {
                    ZStack {
                        Circle().fill(TileTint.gradient(for: item.title))
                        RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 120, height: 120), contentMode: .fill) {
                            Monogram(text: item.title, size: art * 0.36)
                        }
                        .frame(width: art, height: art).clipShape(Circle())
                        Circle().strokeBorder(playback.isPlaying ? Theme.accent : Theme.inkFaint, lineWidth: 2)
                    }
                    .frame(width: art, height: art)
                    if !m.compact {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(playback.isPlaying ? "Now Playing" : "Paused").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.inkMuted)
                        }
                        .frame(maxWidth: 200, alignment: .leading)
                    }
                }
                .padding(.leading, 6)
                .frame(height: m.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(CarFocusButtonStyle())

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: m.compact ? 15 : 17, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(CarFocusButtonStyle())
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button { playback.stop() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: m.compact ? 13 : 15, weight: .bold)).foregroundStyle(Theme.inkMuted)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(CarFocusButtonStyle())
            .accessibilityLabel("Stop")
            .padding(.trailing, 2)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
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

