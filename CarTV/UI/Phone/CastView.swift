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
            List {
                statusSection
                mirrorSection
                linkSection
                localSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Cast")
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

    // MARK: Sections — same grouped-list language as Settings.

    private var statusSection: some View {
        Section {
            HStack(spacing: Theme.s3) {
                ZStack {
                    Circle().fill(playback.carIsConnected ? Theme.accent.opacity(0.18) : Theme.raised).frame(width: 44, height: 44)
                    Image(systemName: "car.fill").foregroundStyle(playback.carIsConnected ? Theme.accent : Theme.inkMuted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.carIsConnected ? "Car connected" : "CarPlay not connected").font(Theme.Font.headline)
                    Text(playback.carIsConnected ? "Anything you cast plays on the car screen." : "Connect your iPhone to CarPlay to cast to the car.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private var mirrorSection: some View {
        Section {
            HStack(spacing: Theme.s3) {
                Image(systemName: mirroring ? "record.circle" : "rectangle.on.rectangle")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(mirroring ? Theme.live : Theme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mirroring ? "Mirroring to the car" : "Mirror iPhone screen").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                    Text(mirroring
                         ? "\(Int(env.mirror.frameSize.width))×\(Int(env.mirror.frameSize.height)) · \(env.mirror.fps) fps"
                         : "Show whatever is on your iPhone on the car display.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            // The system picker is the only sanctioned way to start a broadcast; it stays
            // prominent glass because it's the one primary action on this screen.
            BroadcastPickerButton(isMirroring: mirroring)
                .frame(height: 48)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
        } header: { Text("Screen") }
    }

    private var linkSection: some View {
        Section {
            HStack(spacing: Theme.s2) {
                Image(systemName: "link").foregroundStyle(Theme.inkMuted)
                TextField("Paste a video or stream URL", text: $linkText)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($linkFocused)
                    .submitLabel(.go)
                    .onSubmit(castLink)
                if !linkText.isEmpty {
                    Button { linkText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkFaint) }
                        .buttonStyle(.plain)
                }
            }
            Button(action: castLink) {
                Label("Play on car", systemImage: "play.fill")
            }
            .disabled(URL.lenient(linkText) == nil)
            if let linkError { Text(linkError).font(Theme.Font.caption).foregroundStyle(Theme.amber) }
        } header: { Text("Link") } footer: {
            Text("Copied links are picked up automatically when you open this tab.")
        }
    }

    private var localSection: some View {
        Section {
            Button { showFilePicker = true } label: { Label("Choose a file", systemImage: "folder") }
            Button { showPhotoPicker = true } label: { Label("From Photos", systemImage: "photo.on.rectangle.angled") }
            if case .importing(_, _, let name) = importPhase {
                HStack(spacing: Theme.s2) { ProgressView().controlSize(.small); Text(name).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted) }
            }
        } header: { Text("Video from this iPhone") }
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
