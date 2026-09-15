import SwiftUI

enum CarSection: Hashable, CaseIterable, Identifiable {
    var id: Self { self }
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
                    .padding(.top, Theme.s3)
                    .padding(.bottom, Theme.s4)

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
/// Route stack without UINavigationController: in the CarPlay idiom UIKit paints an
/// opaque black behind the stack that never matches our ground. We own the header
/// anyway, so a ZStack with the top route + a slide transition is all that's needed.
struct CarNavHost<Root: View>: View {
    @Binding var path: [CarRoute]
    @ViewBuilder let root: () -> Root

    var body: some View {
        ZStack {
            if let route = path.last {
                Group {
                    switch route {
                    case .playlist(let p):     CarPlaylistView(playlist: p)
                    case .genre(let p, let g): CarChannelGridView(playlist: p, genre: g)
                    case .folder(let f):       CarVideosGridView(folder: f)
                    }
                }
                .id(route)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                root()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: path)
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

// MARK: - Header: a plain segmented tab bar, centered. "‹ Title" replaces it when drilled in.

struct CarHeader: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @Binding var section: CarSection
    let route: CarRoute?
    let nowPlaying: PlayableItem?
    let back: () -> Void
    let openPlayer: () -> Void

    private var h: CGFloat { m.compact ? 40 : 48 }
    private var font: Font { .system(size: m.compact ? 15 : 19, weight: .semibold) }

    var body: some View {
        ZStack {
            // Centered segment (or back pill)
            if let route {
                HStack {
                    Button(action: back) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left").font(font.weight(.bold))
                            Text(route.title).font(font).lineLimit(1)
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.leading, 14).padding(.trailing, 20)
                        .frame(height: h)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    Spacer()
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(CarSection.allCases), id: \.self) { (s: CarSection) in
                        let selected = section == s
                        Button { withAnimation(.snappy(duration: 0.25, extraBounce: 0.05)) { section = s } } label: {
                            Text(s.title)
                                .font(font)
                                .foregroundStyle(selected ? Color.black : Theme.ink)
                                .padding(.horizontal, m.compact ? 18 : 28)
                                .frame(height: h)
                                .background {
                                    if selected { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "seg", in: ns) }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glassEffect(.regular.interactive(), in: Capsule())
            }

            // Now Playing pinned right
            if let item = nowPlaying {
                HStack { Spacer(); CarNowPlayingPill(item: item, open: openPlayer) }
            }
        }
        .frame(height: h)
    }

    @Namespace private var ns
}

/// Now Playing chip: circular artwork with an accent ring, title/state, play/pause, stop.
struct CarNowPlayingPill: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let item: PlayableItem
    let open: () -> Void

    var body: some View {
        let art = m.headerHeight - 16
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
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
                                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(playback.isPlaying ? "Now Playing" : "Paused").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 200, alignment: .leading)
                        }
                    }
                    .padding(.leading, 2)
                    .frame(height: m.headerHeight - 12)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)

                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: m.compact ? 15 : 17, weight: .bold))
                        .frame(width: m.headerHeight - 12, height: m.headerHeight - 12)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Button { playback.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: m.compact ? 13 : 15, weight: .bold))
                        .frame(width: m.headerHeight - 12, height: m.headerHeight - 12)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stop")
            }
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

