import UniformTypeIdentifiers
import SwiftUI
@preconcurrency import Translation

struct PlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showTracks = false
    @State private var showChannels = false
    @State private var showSubtitleFile = false
    @State private var seekFlash: (Int, Bool)?   // (seconds, forward)
    @State private var isLandscape = UIDevice.current.orientation.isLandscape

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                PhoneVideoSurface()
                    .id("\(playback.videoViewRevision)-\(playback.carIsConnected)")
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                gestureLayer

                stateOverlay

                if controlsVisible { controls(landscape: landscape).zIndex(1) }
            }
            .statusBarHidden(!controlsVisible)
            .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
            .onAppear { scheduleHide() }
            .onChange(of: playback.isPlaying, initial: true) { _, playing in if playing { scheduleHide() } else { show() } }
            .sheet(isPresented: $showTracks) { TracksSheet().presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showChannels) { ChannelDrawer().presentationDetents([.medium, .large]) }
            .fileImporter(isPresented: $showSubtitleFile, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first {
                    let access = u.startAccessingSecurityScopedResource()
                    let dest = AppPaths.subtitles.appending(path: UUID().uuidString + "." + u.pathExtension)
                    try? FileManager.default.copyItem(at: u, to: dest)
                    if access { u.stopAccessingSecurityScopedResource() }
                    playback.loadExternalSubtitle(dest)
                }
            }
            .modifier(SubtitleTranslationHost())
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Layers

    private var gestureLayer: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { skip(-10) }
                .onTapGesture { toggleControls() }
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { skip(10) }
                .onTapGesture { toggleControls() }
        }
        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    if abs(v.translation.height) > abs(v.translation.width), v.translation.height > 80 { close() }
                }
        )
        .overlay {
            if let (secs, fwd) = seekFlash {
                HStack(spacing: 6) {
                    Image(systemName: fwd ? "goforward.10" : "gobackward.10")
                    Text("\(fwd ? "+" : "-")\(secs)s").monospacedDigit()
                }
                .font(Theme.Font.headline).foregroundStyle(.white)
                .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s2)
                .background(.black.opacity(0.6), in: Capsule())
                .transition(.opacity.combined(with: .scale))
            }
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        switch playback.snapshot.state {
        case .loading, .buffering:
            VStack(spacing: Theme.s3) {
                ProgressView().controlSize(.large).tint(.white)
                Text(playback.isFallingBack ? "Switching decoder…" : (playback.snapshot.state == .loading ? "Starting…" : "Loading…"))
                    .font(Theme.Font.caption).foregroundStyle(.white.opacity(0.8))
            }
            .padding(Theme.s5)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            .allowsHitTesting(false)
        case .failed(let failure):
            VStack(spacing: Theme.s3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(Theme.amber)
                Text("Playback Failed").font(Theme.Font.title2).foregroundStyle(.white)
                Text(failure.message).font(Theme.Font.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                HStack(spacing: Theme.s2) {
                    Button { playback.retry() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    Button { playback.switchEngine() } label: { Label(playback.engineKind == .avPlayer ? "Try VLC" : "Try AVPlayer", systemImage: "cpu") }
                    if playback.hasNext { Button { playback.next() } label: { Label("Next", systemImage: "forward.end.fill") } }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.white)
            }
            .padding(Theme.s6).frame(maxWidth: 380)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
        default:
            EmptyView()
        }
    }

    private func controls(landscape: Bool) -> some View {
        ZStack {
            // Scrims so white controls read over any picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top bar
                HStack(alignment: .center, spacing: Theme.s2) {
                    ControlButton(symbol: "chevron.down") { close() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.current?.title ?? "").font(Theme.Font.headline).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: 6) {
                            if playback.current?.isLive == true { LiveBadge(compact: true) }
                            if let sub = playback.current?.subtitle { Text(sub).font(Theme.Font.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                        }
                    }
                    Spacer()
                    if let item = playback.current {
                        ControlButton(symbol: env.favorites.isFavorite(item) ? "heart.fill" : "heart", tint: env.favorites.isFavorite(item) ? Theme.live : .white) {
                            env.favorites.toggle(item.ref); UIImpactFeedbackGenerator(style: .light).impactOccurred(); scheduleHide()
                        }
                    }
                    ControlButton(symbol: playback.gravity.symbol) { playback.cycleGravity(); scheduleHide() }
                    ControlButton(symbol: "ellipsis") { showTracks = true; hideTask?.cancel() }
                    if playback.carIsConnected {
                        Image(systemName: "car.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular, in: Circle())
                            .help("Casting to your car")
                    }
                }
                .padding(.horizontal, Theme.s3).padding(.top, Theme.s1)

                Spacer()

                // Centre transport
                if playback.snapshot.state != .loading {
                    HStack(spacing: landscape ? Theme.s5 : Theme.s4) {
                        if playback.hasPrevious || playback.hasNext {
                            BigButton(symbol: "backward.end.fill", size: 16, enabled: playback.hasPrevious) { playback.previous(); scheduleHide() }
                        }
                        if playback.snapshot.isSeekable {
                            BigButton(symbol: "gobackward.10", size: 22) { skip(-10) }
                        }
                        BigButton(symbol: playback.isPlaying ? "pause.fill" : "play.fill", size: 30, prominent: true) { playback.togglePlayPause(); scheduleHide() }
                        if playback.snapshot.isSeekable {
                            BigButton(symbol: "goforward.10", size: 22) { skip(10) }
                        }
                        if playback.hasPrevious || playback.hasNext {
                            BigButton(symbol: "forward.end.fill", size: 16, enabled: playback.hasNext) { playback.next(); scheduleHide() }
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }

                Spacer()

                // Bottom: slim scrubber for VOD, live pill + channels for TV.
                VStack(spacing: Theme.s2) {
                    if playback.snapshot.isSeekable, playback.snapshot.duration > 0 {
                        scrubber
                    }
                    HStack(spacing: Theme.s2) {
                        Spacer()
                        if playback.current?.ref.kind == .channel {
                            Button { showChannels = true; hideTask?.cancel() } label: {
                                Label("Channels", systemImage: "list.bullet.rectangle").font(Theme.Font.caption.weight(.semibold))
                                    .padding(.horizontal, Theme.s3).frame(height: 36).foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, Theme.s3).padding(.bottom, Theme.s2)
            }
        }
        // Owns every touch inside the controls layer: tap a button → the button;
        // tap empty space → hide. Nothing falls through to the stage's tap gesture.
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .transition(.opacity)
    }

    private var scrubber: some View {
        let dur = max(playback.snapshot.duration, 1)
        let pos = scrubbing ? scrubValue : playback.snapshot.position
        let fraction = min(1, max(0, pos / dur))
        let knob: CGFloat = scrubbing ? 24 : 16
        let track: CGFloat = scrubbing ? 10 : 6
        let font = Theme.Font.caption.monospacedDigit()
        return HStack(spacing: 12) {
            Text(pos.clockString).font(font).foregroundStyle(.white.opacity(0.9))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: track)
                    Capsule().fill(.white.opacity(0.35)).frame(width: geo.size.width * playback.snapshot.bufferedFraction, height: track)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * fraction, height: track)
                    Circle().fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .offset(x: geo.size.width * fraction - knob / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !scrubbing { scrubbing = true; hideTask?.cancel() }
                            scrubValue = min(1, max(0, v.location.x / geo.size.width)) * dur
                        }
                        .onEnded { _ in
                            playback.seek(to: scrubValue)
                            scrubbing = false
                            scheduleHide()
                        }
                )
            }
            .frame(height: 44)
            Text("-" + (dur - pos).clockString).font(font).foregroundStyle(.white.opacity(0.6))
        }
        .animation(.easeOut(duration: 0.12), value: scrubbing)
    }

    // MARK: Actions

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }
    private func show() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, playback.isPlaying, !scrubbing else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
    }
    private func skip(_ delta: TimeInterval) {
        guard playback.snapshot.isSeekable else { return }
        playback.skip(by: delta)
        withAnimation { seekFlash = (Int(abs(delta)), delta > 0) }
        Task { try? await Task.sleep(for: .milliseconds(600)); withAnimation { seekFlash = nil } }
    }
    private func close() {
        // Playback continues; the mini player under the tab bar brings it back.
        playback.isPhonePlayerPresented = false
    }
}

// MARK: - Controls

struct ControlButton: View {
    let symbol: String
    var tint: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .glassEffect(.regular.interactive(), in: Circle())
    }
}

struct BigButton: View {
    let symbol: String
    let size: CGFloat
    var enabled = true
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : .white)
                .frame(width: size + 26, height: size + 26)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleStyle())
        .glassEffect(prominent ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Circle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Subtitles overlay

struct SubtitleOverlay: View {
    @Environment(PlaybackController.self) private var playback
    var body: some View {
        VStack {
            Spacer()
            if let text = playback.subtitles.currentText {
                Text(text)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, Theme.s6)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: playback.subtitles.currentText)
    }
}

/// Installs `.translationTask` so `SubtitleTranslator` can obtain a session.
struct SubtitleTranslationHost: ViewModifier {
    @State private var config: TranslationSession.Configuration?
    func body(content: Content) -> some View {
        content
            .onChange(of: SubtitleTranslator.pending?.id) { _, _ in
                if let p = SubtitleTranslator.pending {
                    config = .init(source: nil, target: p.target)
                } else {
                    config = nil
                }
            }
            .translationTask(config) { session in
                guard let p = await MainActor.run(body: { SubtitleTranslator.pending }) else { return }
                await SubtitleTranslator.fulfil(p, using: session)
            }
    }
}

// MARK: - Tracks sheet

struct TracksSheet: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showFile = false

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    if playback.snapshot.audioTracks.isEmpty { Text("Auto").foregroundStyle(Theme.inkMuted) }
                    ForEach(playback.snapshot.audioTracks) { t in
                        row(t.name, selected: playback.snapshot.selectedAudioTrack == t.id) { playback.selectAudioTrack(t.id) }
                    }
                }
                Section("Subtitles") {
                    row(String(localized: "Off"), selected: playback.snapshot.selectedSubtitleTrack == nil && !playback.subtitles.isExternalActive) {
                        playback.selectSubtitleTrack(nil)
                    }
                    ForEach(playback.snapshot.subtitleTracks) { t in
                        row(t.name, selected: playback.snapshot.selectedSubtitleTrack == t.id) { playback.selectSubtitleTrack(t.id) }
                    }
                    if playback.subtitles.isExternalActive {
                        row(String(localized: "External file"), selected: true) {}
                    }
                    Button { showFile = true } label: { Label("Load subtitle file (.srt / .vtt)", systemImage: "doc.badge.plus") }
                    if let err = playback.subtitles.loadError { Text(err).font(Theme.Font.caption).foregroundStyle(Theme.amber) }
                }
                if playback.subtitles.isExternalActive {
                    Section("Translate") {
                        if playback.subtitles.isTranslating {
                            HStack { ProgressView().controlSize(.small); Text("Translating…") }
                        } else if let target = playback.subtitles.translationTarget {
                            row(String(localized: "Translated to \(Locale.current.localizedString(forLanguageCode: target.languageCode?.identifier ?? "") ?? target.minimalIdentifier)"), selected: true) {}
                            Button("Show original") { playback.subtitles.clearTranslation() }
                        } else {
                            ForEach(Self.targets, id: \.self) { code in
                                Button { playback.subtitles.translate(to: Locale.Language(identifier: code)) } label: {
                                    Label(String(localized: "Translate to \(Locale.current.localizedString(forLanguageCode: code) ?? code)"), systemImage: "translate")
                                }
                            }
                        }
                    }
                }
                Section("Playback") {
                    Toggle("Software decoding", isOn: Binding(get: { settings.softwareDecoding }, set: { settings.softwareDecoding = $0 }))
                    Button { playback.switchEngine() } label: {
                        Label(String(localized: "Switch to \(playback.engineKind == .avPlayer ? "VLC" : "AVPlayer")"), systemImage: "cpu")
                    }
                }
            }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showFile, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first {
                    let access = u.startAccessingSecurityScopedResource()
                    let dest = AppPaths.subtitles.appending(path: UUID().uuidString + "." + u.pathExtension)
                    try? FileManager.default.copyItem(at: u, to: dest)
                    if access { u.stopAccessingSecurityScopedResource() }
                    playback.loadExternalSubtitle(dest)
                }
            }
        }
    }

    private static let targets = [Locale.current.language.languageCode?.identifier ?? "en", "en", "ckb", "ar", "tr", "fa", "de", "fr", "es"].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title).foregroundStyle(Theme.ink); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) } }
        }
    }
}

// MARK: - Channel drawer

struct ChannelDrawer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let items = query.isEmpty ? playback.queue : playback.queue.filter { $0.title.searchNormalized.contains(query.searchNormalized) }
            ScrollViewReader { proxy in
                List(items) { item in
                    Button { playback.play(item, queue: playback.queue, origin: .phone) } label: {
                        HStack(spacing: Theme.s3) {
                            ZStack {
                                TileTint.gradient(for: item.title)
                                RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 120, height: 68), contentMode: .fit) { Monogram(text: item.title, size: 14) }.padding(6)
                            }
                            .frame(width: 72, height: 42).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(item.title).font(Theme.Font.callout).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            if playback.current?.id == item.id { EqualizerBars().scaleEffect(0.7) }
                        }
                    }
                    .id(item.id)
                    .listRowBackground(playback.current?.id == item.id ? Theme.accent.opacity(0.12) : Theme.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.ground)
                .onAppear { if let id = playback.current?.id { proxy.scrollTo(id, anchor: .center) } }
            }
            .searchable(text: $query, prompt: Text("Find a channel"))
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
