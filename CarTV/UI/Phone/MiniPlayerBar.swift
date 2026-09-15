import SwiftUI

/// Now-playing strip, modelled on Music's tab-bar accessory: artwork · title ·
/// play/pause · next. Tap anywhere to reopen the full player. Nothing custom —
/// system fonts, system button styles, the accessory's own glass.
struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let item = playback.current {
            HStack(spacing: 8) {
                // Artwork + titles: one real Button that opens the player. A Button (not a
                // tap gesture on the row) so it never fights the play/next siblings.
                Button { playback.isPhonePlayerPresented = true } label: {
                    HStack(spacing: 12) {
                        artwork(item)
                            .frame(width: 48, height: 48)

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
                    }
                    .padding(.leading, 12).padding(.vertical, 6)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Now Playing: \(item.title)"))
                .accessibilityHint(Text("Opens the player"))

                Button { playback.togglePlayPause() } label: {
                    if playback.snapshot.state == .loading || playback.snapshot.state == .buffering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .font(.title2)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
