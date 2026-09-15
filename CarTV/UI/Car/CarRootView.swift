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

/// Where the stage is. A tiny explicit stack instead of NavigationStack so we
/// own the header (UINavigationBar misbehaves in the CarPlay idiom).
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

/// Root of the car UI: a floating glass tab bar at the top (same tabs as the
/// phone), content below. Playback takes the whole screen.
struct CarRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(CarPlayCoordinator.self) private var car

    @State private var section: CarSection = .home
    @State private var stack: [CarRoute] = []
    @State private var showPlayer = false

    var body: some View {
        GeometryReader { geo in
            let metrics = CarMetrics(size: geo.size)
            ZStack(alignment: .top) {
                Theme.ground.ignoresSafeArea()

                stage
                    .id(stack.last)
                    .safeAreaPadding(.top, metrics.headerHeight + Theme.s2 + Theme.s4)
                    .transition(.opacity)

                CarTopBar(
                    section: $section,
                    route: stack.last,
                    nowPlaying: playback.isActive ? playback.current : nil,
                    back: { withAnimation(.easeOut(duration: 0.18)) { _ = stack.popLast() } },
                    openPlayer: { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
                )
                .padding(.horizontal, metrics.gutter)
                .padding(.top, Theme.s2)

                if showPlayer {
                    CarPlayerView { withAnimation(.easeOut(duration: 0.2)) { showPlayer = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environment(\.carMetrics, metrics)
            .environment(\.carPush, CarPush { route in withAnimation(.easeOut(duration: 0.18)) { stack.append(route) } })
        }
        .preferredColorScheme(car.contentStyle == .light ? .light : .dark)
        .onChange(of: playback.current?.id) { old, new in
            // A new item started anywhere (phone or car) → the car shows it.
            if new != nil, old != new { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
            if new == nil { withAnimation { showPlayer = false } }
        }
        .onChange(of: playback.isActive) { _, active in
            if active, !showPlayer { withAnimation(.easeOut(duration: 0.2)) { showPlayer = true } }
        }
        .onAppear { if playback.isActive { showPlayer = true } }
        .onChange(of: section) { _, _ in stack = [] }
    }

    @ViewBuilder private var stage: some View {
        switch stack.last {
        case .playlist(let p):     CarPlaylistView(playlist: p)
        case .genre(let p, let g): CarChannelGridView(playlist: p, genre: g)
        case .folder(let f):       CarVideosGridView(folder: f)
        case nil:
            switch section {
            case .home: CarHomeView()
            case .favorites: CarFavoritesView()
            case .library: CarLibraryView()
            }
        }
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

// MARK: - Top bar

/// One glass capsule: [back + title] when drilled in, otherwise the three tabs.
struct CarTopBar: View {
    @Environment(\.carMetrics) private var m
    @Environment(PlaybackController.self) private var playback
    @Binding var section: CarSection
    let route: CarRoute?
    let nowPlaying: PlayableItem?
    let back: () -> Void
    let openPlayer: () -> Void

    var body: some View {
        HStack(spacing: Theme.s2) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 4) {
                    if let route {
                        Button(action: back) {
                            Image(systemName: "chevron.left").font(.system(size: m.compact ? 15 : 18, weight: .bold))
                                .frame(width: m.headerHeight - 8, height: m.headerHeight - 8)
                        }
                        .buttonStyle(CarFocusButtonStyle())
                        Text(route.title).font(Theme.Car.title(m.titleSize)).foregroundStyle(Theme.ink).lineLimit(1)
                            .padding(.trailing, Theme.s3)
                    } else {
                        ForEach(CarSection.allCases, id: \.self) { s in
                            CarTab(title: s.title, symbol: s.symbol, selected: section == s) {
                                withAnimation(.snappy(duration: 0.22)) { section = s }
                            }
                        }
                    }
                }
                .padding(4)
            }
            .glassEffect(.regular, in: Capsule())

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
                        .frame(width: m.headerHeight - 14, height: m.headerHeight - 14)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        if !m.compact {
                            Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
                        }
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                            .onTapGesture { playback.togglePlayPause() }
                    }
                    .padding(.leading, 7).padding(.trailing, 6)
                    .frame(height: m.headerHeight)
                }
                .buttonStyle(CarFocusButtonStyle())
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityLabel("Now Playing, \(item.title)")
            }
        }
        .frame(height: m.headerHeight)
    }
}

struct CarTab: View {
    @Environment(\.carMetrics) private var m
    let title: LocalizedStringResource
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: m.compact ? 13 : 16, weight: .bold))
                if selected || !m.compact {
                    Text(title).font(.system(size: m.compact ? 12 : 15, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.black : Theme.ink)
            .padding(.horizontal, m.compact ? Theme.s3 : Theme.s4)
            .frame(height: m.headerHeight - 8)
            .background(selected ? Theme.accent : .clear, in: Capsule())
        }
        .buttonStyle(CarFocusButtonStyle())
        .animation(.snappy(duration: 0.22), value: selected)
    }
}

// MARK: - Focus / press style for knobs & touch

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
