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
