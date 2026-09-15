import SwiftUI

/// Download action for a YouTube video. Picks the destination folder like this:
/// remembered default → the only folder there is → ask once (and remember).
/// Works as a pill (watch page) or a plain menu item (cards' context menu).
struct YTDownloadButton: View {
    @Environment(AppEnvironment.self) private var env
    let video: YTVideo
    var style: Style = .pill
    enum Style { case pill, menuItem }

    @State private var askFolder = false

    private var job: YTDownloadManager.Job? { env.downloads.job(for: video.id) }

    var body: some View {
        Group {
            switch style {
            case .pill:
                Button(action: tap) { pillLabel }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
                    .disabled(job?.isActive == true)
            case .menuItem:
                Button(action: tap) { Label(menuTitle, systemImage: symbol) }
                    .disabled(job?.isActive == true)
            }
        }
        .confirmationDialog("Download to", isPresented: $askFolder, titleVisibility: .visible) {
            ForEach(env.library.folders()) { f in
                Button(f.name) { choose(f.id) }
            }
            Button("Videos (no folder)") { choose(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Next downloads go here too. Change it in Settings.")
        }
    }

    private var symbol: String {
        switch job?.phase {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        case .some(let p) where p != .queued: "arrow.down.circle"
        default: "arrow.down.to.line"
        }
    }
    private var menuTitle: LocalizedStringResource {
        switch job?.phase {
        case .done: "Downloaded"
        case .failed: "Retry download"
        case .some: "Downloading…"
        case .none: "Download"
        }
    }

    private var pillLabel: some View {
        HStack(spacing: 6) {
            if let j = job, j.isActive {
                ProgressView(value: j.progress).progressViewStyle(.circular).controlSize(.small).tint(Theme.accent)
                Text("\(Int(j.progress * 100))%").monospacedDigit()
            } else {
                Image(systemName: symbol)
                Text(job?.phase == .done ? "Saved" : "Download")
            }
        }
        .font(.subheadline.weight(.semibold)).padding(.horizontal, 4).frame(height: 36)
    }

    private func tap() {
        if let j = job, j.isActive { return }
        let folders = env.library.folders()
        if let id = env.settings.downloadFolderID, folders.contains(where: { $0.id == id }) {
            env.downloads.download(video, into: id)
        } else if folders.count == 1 {
            env.settings.downloadFolderID = folders[0].id
            env.downloads.download(video, into: folders[0].id)
        } else if folders.isEmpty {
            env.downloads.download(video, into: nil)
        } else {
            askFolder = true
        }
    }

    private func choose(_ id: UUID?) {
        env.settings.downloadFolderID = id
        env.downloads.download(video, into: id)
    }
}

/// Compact list of in-flight/finished downloads for Settings and the YouTube tab.
struct YTDownloadsList: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        ForEach(env.downloads.jobs) { j in
            HStack(spacing: Theme.s3) {
                RemoteImage(url: j.thumbnailURL, targetSize: CGSize(width: 160, height: 90), contentMode: .fill) { Theme.raised }
                    .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(j.title).font(.subheadline).lineLimit(1)
                    switch j.phase {
                    case .queued: Text("Waiting…").font(.caption).foregroundStyle(Theme.inkMuted)
                    case .downloading: ProgressView(value: j.progress).tint(Theme.accent)
                    case .muxing: Text("Combining video and audio…").font(.caption).foregroundStyle(Theme.inkMuted)
                    case .importing: Text("Adding to library…").font(.caption).foregroundStyle(Theme.inkMuted)
                    case .done: Text("Saved to Videos").font(.caption).foregroundStyle(Theme.accent)
                    case .failed(let e): Text(e).font(.caption).foregroundStyle(Theme.live).lineLimit(2)
                    }
                }
                Spacer()
                if j.isActive {
                    Button { env.downloads.cancel(j.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkMuted) }.buttonStyle(.plain)
                }
            }
        }
    }
}


/// Slim, glass progress strip shown only while a download runs; lingers 2.5s on
/// completion, then slides away. Tap ✕ to cancel.
struct YTDownloadStrip: View {
    @Environment(AppEnvironment.self) private var env
    @State private var lingering: YTDownloadManager.Job?

    private var shown: YTDownloadManager.Job? { env.downloads.active.first ?? lingering }

    var body: some View {
        Group {
            if let j = shown {
                HStack(spacing: Theme.s3) {
                    RemoteImage(url: j.thumbnailURL, targetSize: CGSize(width: 160, height: 90), contentMode: .fill) { Theme.raised }
                        .frame(width: 48, height: 27).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(j.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        switch j.phase {
                        case .done: Text("Saved to your videos").font(.caption2).foregroundStyle(Theme.accent)
                        case .failed(let e): Text(e).font(.caption2).foregroundStyle(Theme.live).lineLimit(1)
                        case .muxing: Text("Combining…").font(.caption2).foregroundStyle(Theme.inkMuted)
                        case .importing: Text("Adding to library…").font(.caption2).foregroundStyle(Theme.inkMuted)
                        default: ProgressView(value: j.progress).tint(Theme.accent).frame(height: 4)
                        }
                    }
                    if j.isActive {
                        Text("\(Int(j.progress * 100))%").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.inkMuted)
                        Button { env.downloads.cancel(j.id) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 28, height: 28) }
                            .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
                    } else {
                        Image(systemName: j.phase == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(j.phase == .done ? Theme.accent : Theme.live)
                    }
                }
                .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, Theme.s4).padding(.bottom, Theme.s2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: shown?.id)
        .onChange(of: env.downloads.jobs.map { "\($0.id)\($0.phase)" }) { _, _ in
            // When the active one finishes, hold it briefly so the user sees the result.
            if env.downloads.active.isEmpty, let last = env.downloads.jobs.first, !last.isActive {
                lingering = last
                Task { try? await Task.sleep(for: .seconds(2.5)); if env.downloads.active.isEmpty { lingering = nil } }
            }
        }
    }
}


/// Top banner for download results. Attach once per screen root (phone + car).
struct DownloadNoticeBanner: View {
    @Environment(AppEnvironment.self) private var env
    var compact = false
    var body: some View {
        Group {
            if let n = env.downloads.notice {
                HStack(spacing: 10) {
                    Image(systemName: n.ok ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(n.ok ? Theme.accent : Theme.amber)
                    Text(n.text).font(compact ? .subheadline.weight(.semibold) : .footnote.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, Theme.s4).padding(.top, compact ? Theme.s2 : Theme.s1)
                .frame(maxWidth: compact ? 520 : .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(n.id)
            }
        }
        .animation(.snappy, value: env.downloads.notice?.id)
        .allowsHitTesting(false)
    }
}

/// Car-sized download control (same folder rules; falls back to the default folder
/// silently — there's no picker while driving).
struct CarDownloadButton: View {
    @Environment(AppEnvironment.self) private var env
    let item: PlayableItem
    var size: CGFloat = 56
    var onTap: () -> Void = {}

    var body: some View {
        if let vid = YouTubeService.videoID(from: item.ref.id) {
            let job = env.downloads.job(for: vid)
            Button {
                onTap()
                guard job?.isActive != true else { return }
                let folders = env.library.folders()
                let target = folders.first(where: { $0.id == env.settings.downloadFolderID })?.id ?? folders.first?.id
                var v = YTVideo(id: vid, title: item.title); v.channelName = item.subtitle; v.thumbnailURL = item.artworkURL
                env.downloads.download(v, into: target)
            } label: {
                ZStack {
                    if let j = job, j.isActive {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.03, j.progress)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(Int(j.progress * 100))").font(.system(size: size * 0.22, weight: .bold)).foregroundStyle(.white).monospacedDigit()
                    } else {
                        Image(systemName: job?.phase == .done ? "checkmark.circle.fill" : "arrow.down.to.line")
                            .font(.system(size: size * 0.38, weight: .semibold))
                            .foregroundStyle(job?.phase == .done ? Theme.accent : .white)
                    }
                }
                .frame(width: size * 0.5, height: size * 0.5).frame(width: size, height: size)
                .contentShape(Circle())
            }
            .buttonStyle(CarPressStyle())
            .glassEffect(.regular.interactive(), in: Circle())
        }
    }
}
