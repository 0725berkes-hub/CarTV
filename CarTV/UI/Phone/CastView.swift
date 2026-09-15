import SwiftUI
import ReplayKit
import PhotosUI
import UniformTypeIdentifiers

/// Cast tab: mirror the iPhone screen to the car, or send a single video (link,
/// file, or Photos item) to play on the car.
struct CastView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback

    @State private var linkText = ""
    @State private var linkError: String?
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importPhase: LocalImporter.Phase = .idle
    @FocusState private var linkFocused: Bool

    private var mirroring: Bool { env.mirror.state == .mirroring }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.s6) {
                    hero
                    mirrorCard
                    linkCard
                    localCard
                    if !playback.carIsConnected {
                        Label("Connect your iPhone to CarPlay to see this on the car screen.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s10)
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Cast to Car")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: LocalImporter.videoTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { castFile(url) }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .videos, photoLibrary: .shared())
            .onChange(of: photoItems) { _, items in
                guard let item = items.first else { return }
                photoItems = []
                Task {
                    importPhase = .importing(done: 0, total: 1, name: String(localized: "Importing…"))
                    if let movie = try? await item.loadTransferable(type: TransferableMovie.self) {
                        let s = await LocalImporter(container: env.modelContainer).importMovieFiles([(movie.url, movie.originalName)], into: nil) { importPhase = $0 }
                        if s.imported > 0, let v = env.library.localVideos(limit: 1).first {
                            playback.play(PlayableItem(video: v), queue: nil, origin: .phone)
                        }
                    }
                    importPhase = .idle
                }
            }
            .onAppear(perform: pickUpClipboard)
        }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(spacing: Theme.s3) {
            HStack(spacing: Theme.s4) {
                Image(systemName: "iphone").font(.system(size: 34, weight: .light))
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.accent)
                Image(systemName: "car.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            }
            .foregroundStyle(Theme.ink)
            .padding(.top, Theme.s6)
            Text("Cast anything to your car").font(Theme.Font.title).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Circle().fill(playback.carIsConnected ? Theme.accent : Theme.inkFaint).frame(width: 8, height: 8)
                Text(playback.carIsConnected ? "Car connected" : "Car not connected").font(.subheadline).foregroundStyle(playback.carIsConnected ? Theme.accent : Theme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.s2)
    }

    private var mirrorCard: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s3) {
                Image(systemName: mirroring ? "rectangle.on.rectangle.badge.record" : "rectangle.on.rectangle")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(mirroring ? Theme.live : Theme.accent).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mirroring ? "Mirroring to the car display" : "Mirror iPhone screen").font(.headline).foregroundStyle(Theme.ink)
                    Text(mirroring
                         ? "Open any app. What's on your iPhone appears on the car screen."
                         : "Show your iPhone's screen on the car display. Works with any app.")
                        .font(.subheadline).foregroundStyle(Theme.inkMuted)
                }
            }
            if mirroring {
                HStack {
                    Label("\(Int(env.mirror.frameSize.width))×\(Int(env.mirror.frameSize.height)) · \(env.mirror.fps) fps", systemImage: "waveform.path")
                        .font(.footnote.monospacedDigit()).foregroundStyle(Theme.inkFaint)
                    Spacer()
                }
            }
            // The system picker is the only sanctioned way to start a broadcast.
            BroadcastPickerButton(isMirroring: mirroring)
                .frame(height: 50)
        }
        .padding(Theme.s4)
        .glassEffect(.regular.tint(mirroring ? Theme.live.opacity(0.12) : nil), in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s3) {
                Image(systemName: "link").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play a link").font(.headline).foregroundStyle(Theme.ink)
                    Text("Paste a direct video or stream URL. Copied links are picked up automatically.").font(.subheadline).foregroundStyle(Theme.inkMuted)
                }
            }
            HStack(spacing: Theme.s2) {
                TextField("https://…", text: $linkText)
                    .textFieldStyle(.plain)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($linkFocused)
                    .submitLabel(.go)
                    .onSubmit(castLink)
                    .padding(.horizontal, Theme.s3).frame(height: 44)
                    .glassEffect(.regular, in: Capsule())
                Button(action: castLink) {
                    Image(systemName: "play.fill").font(.headline).frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .disabled(URL.lenient(linkText) == nil)
                .accessibilityLabel("Play link on car")
            }
            if let linkError { Text(linkError).font(.footnote).foregroundStyle(Theme.amber) }
        }
        .padding(Theme.s4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
    }

    private var localCard: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Local videos").eyebrow().padding(.leading, Theme.s1)
            HStack(spacing: Theme.s2) {
                QuickAction(symbol: "folder", title: "Choose Files") { showFilePicker = true }
                QuickAction(symbol: "photo.on.rectangle.angled", title: "From Photos") { showPhotoPicker = true }
            }
            if case .importing(_, _, let name) = importPhase {
                HStack(spacing: Theme.s2) { ProgressView().controlSize(.small); Text(name).font(.footnote).foregroundStyle(Theme.inkMuted) }
            }
        }
    }

    // MARK: Actions

    private func castLink() {
        linkError = nil
        guard let url = URL.lenient(linkText) else { linkError = String(localized: "Enter a valid http/https URL"); return }
        linkFocused = false
        let title = url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? url.host ?? "Stream"
        playback.play(PlayableItem(castURL: url, title: title, artwork: nil), queue: nil, origin: .phone)
    }

    private func castFile(_ url: URL) {
        Task {
            let s = await LocalImporter(container: env.modelContainer).importFiles([url], into: nil) { importPhase = $0 }
            if s.imported > 0, let v = env.library.localVideos(limit: 1).first {
                playback.play(PlayableItem(video: v), queue: nil, origin: .phone)
            }
        }
    }

    private func pickUpClipboard() {
        guard linkText.isEmpty, UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings else { return }
        if let url = UIPasteboard.general.url ?? UIPasteboard.general.string.flatMap(URL.lenient), url.isHTTP {
            let ext = url.pathExtension.lowercased()
            if ["m3u8", "mp4", "mkv", "ts", "mov", "webm", "avi", "m4v"].contains(ext) || url.path.lowercased().contains("/live/") {
                linkText = url.absoluteString
            }
        }
    }
}

/// Wraps `RPSystemBroadcastPickerView`, styled as a full-width glass button.
struct BroadcastPickerButton: UIViewRepresentable {
    let isMirroring: Bool

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = "kurdsoft.CarTV.ScreenRelay"
        picker.showsMicrophoneButton = false
        style(picker)
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) { style(picker) }

    private func style(_ picker: RPSystemBroadcastPickerView) {
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else { return }
        var config = UIButton.Configuration.prominentGlass()
        config.title = isMirroring ? String(localized: "Stop mirroring") : String(localized: "Start mirroring")
        config.image = UIImage(systemName: isMirroring ? "stop.fill" : "play.rectangle.on.rectangle.fill")
        config.imagePadding = 8
        config.baseBackgroundColor = isMirroring ? UIColor(Theme.live) : UIColor(Theme.accent)
        config.baseForegroundColor = isMirroring ? .white : .black
        config.cornerStyle = .capsule
        button.configuration = config
        button.frame = picker.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picker.backgroundColor = .clear
    }
}
