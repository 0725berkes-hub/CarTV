import SwiftUI

/// Now-playing strip in the tab bar's bottom accessory, matched to Music/Podcasts:
/// artwork with a soft shadow · title (+ subtitle when expanded) · play/pause · next.
/// The accessory supplies the glass; we add nothing but content.
struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var expanded: Bool { placement != .inline }

    var body: some View {
        if let item = playback.current {
            HStack(spacing: 0) {
                Button { playback.isPhonePlayerPresented = true } label: {
                    HStack(spacing: 12) {
                        artwork(item)
                            .frame(width: expanded ? 44 : 34, height: expanded ? 44 : 34)
                            .clipShape(RoundedRectangle(cornerRadius: expanded ? 8 : 6, style: .continuous))
                            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(expanded ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                                .lineLimit(1)
                            if expanded, let sub = subtitle(item) {
                                Text(sub)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, expanded ? 12 : 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Now Playing: \(item.title)"))
                .accessibilityHint(Text("Opens the player"))

                // Transport: system-sized symbols, play/pause dominant, generous targets.
                HStack(spacing: expanded ? 4 : 0) {
                    Button { playback.togglePlayPause() } label: {
                        Group {
                            if playback.snapshot.state == .loading || playback.snapshot.state == .buffering {
                                ProgressView().controlSize(.regular)
                            } else {
                                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: expanded ? 22 : 19, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                    if expanded {
                        Button { playback.next() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!playback.hasNext)
                        .opacity(playback.hasNext ? 1 : 0.35)
                        .accessibilityLabel("Next")
                    }
                }
                .padding(.trailing, expanded ? 6 : 2)
            }
            .frame(height: expanded ? 64 : 48)
            .foregroundStyle(.primary)
        }
    }

    private func artwork(_ item: PlayableItem) -> some View {
        ZStack {
            TileTint.gradient(for: item.title)
            RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 88, height: 88),
                        contentMode: (item.isLocal || item.ref.kind != .channel) ? .fill : .fit) {
                Monogram(text: item.title, size: 11)
            }
            .padding(item.ref.kind == .channel ? 4 : 0)
        }
    }

    private func subtitle(_ item: PlayableItem) -> String? {
        switch playback.snapshot.state {
        case .loading:   return String(localized: "Starting…")
        case .buffering: return String(localized: "Loading…")
        case .failed(let f): return f.message
        default: return item.subtitle ?? (item.isLive ? String(localized: "Live") : nil)
        }
    }
}
