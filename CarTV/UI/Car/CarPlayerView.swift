import SwiftUI

/// Full-screen car player: video stage + oversized controls + slide-in channel drawer.
/// Every dimension scales from `CarMetrics` so it fits 425×255 head units and
/// 1200×600 wide displays alike. When the car reports video is unavailable
/// (driving), shows an audio-only card instead.
struct CarPlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(CarPlayCoordinator.self) private var car
    @Environment(\.carMetrics) private var m
    let close: () -> Void

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var drawerOpen = false

    private var small: CGFloat { m.compact ? 44 : 52 }
    private var mid: CGFloat { m.compact ? 52 : 68 }
    private var big: CGFloat { m.compact ? 68 : 92 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if car.supportsVideoPlayback {
                VideoSurface().id(playback.videoViewRevision).ignoresSafeArea()
                if playback.subtitles.isExternalActive {
                    SubtitleOverlay().padding(.bottom, controlsVisible ? (m.compact ? 56 : 84) : 24)
                }
            } else {
                AudioOnlyStage(item: playback.current)
            }

            // Tap the stage to show/hide controls. Only the stage — the controls
            // layer below swallows its own taps so buttons never fall through.
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture { toggleControls() }

            stateOverlay

            if controlsVisible {
                controls
                    .transition(.opacity)
                    .zIndex(1)
            }

            if drawerOpen {
                HStack(spacing: 0) {
                    Spacer()
                    CarChannelDrawer(close: { withAnimation(.spring(duration: 0.3)) { drawerOpen = false } })
                        .frame(width: m.compact ? 210 : 340)
                        .transition(.move(edge: .trailing))
                }
                .zIndex(2)
            }
        }
        .onAppear { scheduleHide() }
        .onChange(of: playback.isPlaying, initial: true) { _, playing in
            if playing { scheduleHide() } else { withAnimation { controlsVisible = true } }
        }
        .onChange(of: playback.current?.id) { _, _ in withAnimation { controlsVisible = true }; scheduleHide() }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            // Soft scrims top and bottom so white text and buttons always read on any picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: m.compact ? 70 : 100)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: m.compact ? 90 : 130)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top bar
                HStack(alignment: .center, spacing: Theme.s2) {
                    CarCircleButton(symbol: "chevron.left", size: small) { close() }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playback.current?.title ?? "")
                            .font(Theme.Car.title(m.compact ? 14 : 20)).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: 6) {
                            if playback.current?.isLive == true { LiveBadge(compact: true) }
                            if let s = playback.current?.subtitle {
                                Text(s).font(.system(size: m.compact ? 10.5 : 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            if let item = playback.current {
                                CarCircleButton(symbol: env.favorites.isFavorite(item) ? "heart.fill" : "heart", size: small,
                                                tint: env.favorites.isFavorite(item) ? Theme.live : .white) {
                                    env.favorites.toggle(item.ref); bump()
                                }
                            }
                            CarCircleButton(symbol: playback.gravity.symbol, size: small) { playback.cycleGravity(); bump() }
                            if playback.current?.isLive == false {
                                CarCircleButton(symbol: "shuffle", size: small, tint: playback.shuffle ? Theme.accent : .white) { playback.toggleShuffle(); bump() }
                                CarCircleButton(symbol: playback.repeatMode.symbol, size: small, tint: playback.repeatMode == .off ? .white : Theme.accent) { playback.cycleRepeat(); bump() }
                            }
                            if playback.current?.ref.kind == .channel {
                                CarCircleButton(symbol: "list.bullet.rectangle.fill", size: small) {
                                    withAnimation(.spring(duration: 0.3)) { drawerOpen.toggle() }
                                    hideTask?.cancel()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, m.gutter).padding(.vertical, m.compact ? Theme.s2 : Theme.s3)

                Spacer(minLength: 0)

                // Transport — one glass cluster, big targets, generous spacing for driving.
                GlassEffectContainer(spacing: m.compact ? 14 : 20) {
                    HStack(spacing: m.compact ? 14 : 20) {
                        if playback.hasPrevious || playback.hasNext {
                            CarCircleButton(symbol: "backward.end.fill", size: mid, enabled: playback.hasPrevious) { playback.previous(); bump() }
                        }
                        if playback.snapshot.isSeekable {
                            CarCircleButton(symbol: "gobackward.15", size: mid) { playback.skip(by: -15); bump() }
                        }
                        CarCircleButton(symbol: playback.isPlaying ? "pause.fill" : "play.fill", size: big, prominent: true) { playback.togglePlayPause(); bump() }
                        if playback.snapshot.isSeekable {
                            CarCircleButton(symbol: "goforward.15", size: mid) { playback.skip(by: 15); bump() }
                        }
                        if playback.hasPrevious || playback.hasNext {
                            CarCircleButton(symbol: "forward.end.fill", size: mid, enabled: playback.hasNext) { playback.next(); bump() }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Bottom: scrubber for VOD only (live channels show nothing here).
                if playback.snapshot.duration > 0 {
                    CarScrubber(onScrubStart: { hideTask?.cancel() }, onScrubEnd: { scheduleHide() })
                        .padding(.horizontal, m.gutter).padding(.bottom, m.compact ? Theme.s2 : Theme.s3)
                }
            }
        }
        // The controls layer owns every touch inside it. A tap on empty space here
        // hides the controls; a tap on a button runs the button and nothing else.
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
    }

    /// Any control interaction restarts the auto-hide clock.
    private func bump() { scheduleHide() }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    @ViewBuilder private var stateOverlay: some View {
        switch playback.snapshot.state {
        case .loading, .buffering:
            VStack(spacing: Theme.s2) {
                ProgressView().controlSize(m.compact ? .regular : .large).tint(.white)
                Text(playback.isFallingBack ? "Switching decoder…" : "Loading…")
                    .font(.system(size: m.compact ? 11 : 14)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(m.compact ? Theme.s3 : Theme.s5)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            .allowsHitTesting(false)
        case .failed(let f):
            VStack(spacing: Theme.s3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: m.compact ? 24 : 36)).foregroundStyle(Theme.amber)
                Text(f.message).font(.system(size: m.compact ? 13 : 19, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack(spacing: Theme.s2) {
                    CarPillButton(title: "Retry", symbol: "arrow.clockwise") { playback.retry() }
                    if playback.hasNext { CarPillButton(title: "Next", symbol: "forward.end.fill") { playback.next() } }
                    CarPillButton(title: "Back", symbol: "chevron.left") { close() }
                }
            }
            .padding(m.compact ? Theme.s4 : Theme.s6).frame(maxWidth: m.compact ? 320 : 500)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
        case .ended:
            UpNextCard(compact: m.compact)
        default: EmptyView()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, playback.isPlaying, !drawerOpen else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
    }
}

// MARK: - Audio-only stage (driving)

struct AudioOnlyStage: View {
    @Environment(\.carMetrics) private var m
    let item: PlayableItem?
    var body: some View {
        let art: CGFloat = m.compact ? 96 : 180
        ZStack {
            if let item { TileTint.gradient(for: item.title).ignoresSafeArea().opacity(0.6) }
            VStack(spacing: Theme.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).fill(Theme.surface).frame(width: art, height: art)
                    if let item {
                        RemoteImage(url: item.artworkURL, targetSize: CGSize(width: art * 2, height: art * 2), contentMode: .fit) {
                            Monogram(text: item.title, size: art * 0.32)
                        }
                        .padding(Theme.s3).frame(width: art, height: art)
                    }
                }
                Label("Video pauses while driving — audio keeps playing", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: m.compact ? 11.5 : 15, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Controls

struct CarCircleButton: View {
    let symbol: String
    var size: CGFloat = 56
    var tint: Color = .white
    var enabled = true
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(CarPressStyle())
        .glassEffect(prominent ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Circle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(Text(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ")))
    }
}

/// Press scale + circular focus ring for knob/touchpad cars. Glass is applied by the caller.
struct CarPressStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: focused ? 3 : 0))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct CarPillButton: View {
    @Environment(\.carMetrics) private var m
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: m.compact ? 12 : 16, weight: .semibold))
                .padding(.horizontal, m.compact ? Theme.s3 : Theme.s5).frame(height: m.compact ? 36 : Theme.Car.minTarget)
                .foregroundStyle(.white)
        }
        .buttonStyle(CarFocusButtonStyle())
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

// MARK: - Drawer

struct CarChannelDrawer: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let close: () -> Void

    var body: some View {
        let thumbW: CGFloat = m.compact ? 60 : 92
        VStack(spacing: 0) {
            HStack {
                Text("Channels").font(Theme.Car.title(m.compact ? 15 : 20)).foregroundStyle(Theme.ink)
                Spacer()
                CarCircleButton(symbol: "xmark", size: m.compact ? 32 : 44) { close() }
            }
            .padding(m.compact ? Theme.s2 : Theme.s3)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.s1) {
                        ForEach(playback.queue) { item in
                            Button { playback.play(item, queue: playback.queue, origin: .car) } label: {
                                HStack(spacing: Theme.s2) {
                                    ZStack {
                                        TileTint.gradient(for: item.title)
                                        RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 160, height: 90), contentMode: .fit) {
                                            Monogram(text: item.title, size: 12)
                                        }.padding(5)
                                    }
                                    .frame(width: thumbW, height: thumbW * 9 / 16)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    Text(item.title).font(.system(size: m.compact ? 12 : 15, weight: .semibold))
                                        .foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    if playback.current?.id == item.id { EqualizerBars().scaleEffect(m.compact ? 0.6 : 0.85) }
                                }
                                .padding(Theme.s1 + 2)
                                .frame(minHeight: m.compact ? 42 : Theme.Car.minTarget)
                                .background(playback.current?.id == item.id ? Theme.accent.opacity(0.15) : Theme.surface,
                                            in: RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                            }
                            .buttonStyle(CarFocusButtonStyle())
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, Theme.s2).padding(.bottom, Theme.s3)
                }
                .onAppear { if let id = playback.current?.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
        .padding(Theme.s2)
    }
}


// MARK: - Scrubber (touch + knob)

/// Native-feel progress bar sized for a car touchscreen: the whole 56pt row is the
/// hit area, the track thickens while touched (like iOS's media scrubber), and
/// times sit at the ends. Drag anywhere to seek; release commits.
struct CarScrubber: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    var onScrubStart: () -> Void = {}
    var onScrubEnd: () -> Void = {}

    @State private var dragging = false
    @State private var dragFraction: Double = 0

    var body: some View {
        let dur = max(playback.snapshot.duration, 1)
        let pos = dragging ? dragFraction * dur : playback.snapshot.position
        let fraction = min(1, max(0, pos / dur))
        // iOS media scrubber: thin track at rest, grows under the finger. The thumb is
        // a glass pill riding the track so it's grabbable but doesn't read as a knob.
        let track: CGFloat = dragging ? (m.compact ? 14 : 18) : (m.compact ? 7 : 9)
        let thumbW: CGFloat = dragging ? (m.compact ? 22 : 28) : (m.compact ? 14 : 18)
        let font = Font.system(size: m.compact ? 12 : 15, weight: .semibold).monospacedDigit()

        HStack(spacing: m.compact ? 10 : 14) {
            Text(pos.clockString).font(font).foregroundStyle(.white).frame(minWidth: m.compact ? 34 : 44, alignment: .trailing)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.15)).frame(width: w * playback.snapshot.bufferedFraction)
                    Capsule().fill(Theme.accent).frame(width: max(thumbW, w * fraction))
                    Capsule().fill(.white)
                        .frame(width: thumbW, height: track + (dragging ? 8 : 6))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: min(max(0, w * fraction - thumbW / 2), w - thumbW))
                }
                .frame(height: track)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !dragging { dragging = true; onScrubStart(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                            dragFraction = min(1, max(0, v.location.x / w))
                        }
                        .onEnded { _ in
                            playback.seek(to: dragFraction * dur)
                            dragging = false
                            onScrubEnd()
                        }
                )
            }
            .frame(height: 56)
            Text("-" + (dur - pos).clockString).font(font).foregroundStyle(.white.opacity(0.7)).frame(minWidth: m.compact ? 40 : 52, alignment: .leading)
        }
        .padding(.horizontal, m.compact ? Theme.s3 : Theme.s4)
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(.spring(duration: 0.22, bounce: 0.1), value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(pos.clockString)
        .accessibilityAdjustableAction { dir in playback.skip(by: dir == .increment ? 15 : -15) }
    }
}
