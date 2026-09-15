import SwiftUI

/// Now-playing strip, modelled on Music's tab-bar accessory: artwork · title ·
/// play/pause · next. Tap anywhere to reopen the full player. Nothing custom —
/// system fonts, system button styles, the accessory's own glass.
struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let item = playback.current {
            HStack(spacing: 12) {
                artwork(item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if placement != .inline, let sub = subtitle(item) {
                        Text(sub)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { playback.togglePlayPause() } label: {
                    if playback.snapshot.state == .loading || playback.snapshot.state == .buffering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .font(.title3)
                .frame(width: 44, height: 44)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                if placement != .inline {
                    Button { playback.next() } label: { Image(systemName: "forward.fill") }
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .disabled(!playback.hasNext)
                        .accessibilityLabel("Next")
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .onTapGesture { playback.isPhonePlayerPresented = true }
            .accessibilityAddTraits(.isButton)
        }
    }

    private func artwork(_ item: PlayableItem) -> some View {
        ZStack {
            TileTint.gradient(for: item.title)
            RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 88, height: 88), contentMode: item.isLocal ? .fill : .fit) {
                Monogram(text: item.title, size: 11)
            }
            .padding(item.isLocal ? 0 : 4)
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func subtitle(_ item: PlayableItem) -> String? {
        switch playback.snapshot.state {
        case .loading:  return String(localized: "Starting…")
        case .buffering: return String(localized: "Loading…")
        case .failed(let f): return f.message
        default: return item.subtitle ?? (item.isLive ? String(localized: "Live") : nil)
        }
    }
}
