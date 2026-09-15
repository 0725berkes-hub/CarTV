import SwiftUI

/// Compact now-playing strip shown as the tab bar accessory.
struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let item = playback.current {
            HStack(spacing: Theme.s3) {
                ZStack {
                    TileTint.gradient(for: item.title)
                    RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 96, height: 96), contentMode: item.isLocal ? .fill : .fit) {
                        Monogram(text: item.title, size: 12)
                    }.padding(item.isLocal ? 0 : 5)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(Theme.Font.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        if item.isLive { Circle().fill(Theme.live).frame(width: 6, height: 6) }
                        Text(stateText).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if placement != .inline {
                    if playback.snapshot.isSeekable {
                        Button { playback.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                    }
                }
                Button { playback.togglePlayPause() } label: {
                    Group {
                        if playback.snapshot.state == .loading || playback.snapshot.state == .buffering { ProgressView().controlSize(.small) }
                        else { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                    }
                    .frame(width: 24, height: 24)
                }
                .font(.system(size: 18, weight: .semibold))
                Button(role: .close) { playback.stop() } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.s3)
            .contentShape(Rectangle())
            .onTapGesture { playback.isPhonePlayerPresented = true }
            .overlay(alignment: .bottom) {
                if playback.snapshot.duration > 0 {
                    ProgressBar(fraction: playback.snapshot.position / playback.snapshot.duration, height: 2).padding(.horizontal, Theme.s3)
                }
            }
        }
    }

    private var stateText: String {
        switch playback.snapshot.state {
        case .loading: String(localized: "Starting…")
        case .buffering: String(localized: "Loading…")
        case .failed(let f): f.message
        case .paused: String(localized: "Paused")
        default: playback.current?.subtitle ?? (playback.current?.isLive == true ? String(localized: "Live") : "")
        }
    }
}
