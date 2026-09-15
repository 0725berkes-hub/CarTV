import SwiftUI

/// Now-playing strip in the tab bar's bottom accessory, matched to the car's
/// Now Playing pill: circular artwork with a green ring while playing, title
/// over "Now Playing / Paused", glyph play/pause and next. Content only —
/// the accessory supplies the glass.
struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var expanded: Bool { placement != .inline }

    var body: some View {
        if let item = playback.current {
            let art: CGFloat = expanded ? 42 : 32
            HStack(spacing: 0) {
                Button { playback.isPhonePlayerPresented = true } label: {
                    HStack(spacing: expanded ? 12 : 10) {
                        ZStack {
                            Circle().fill(TileTint.gradient(for: item.title))
                            RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 120, height: 120), contentMode: .fill) {
                                Monogram(text: item.title, size: art * 0.36)
                            }
                            .frame(width: art, height: art)
                            .clipShape(Circle())
                            Circle().strokeBorder(playback.isPlaying ? Theme.accent : Theme.inkFaint, lineWidth: 2)
                                .animation(.easeInOut(duration: 0.25), value: playback.isPlaying)
                        }
                        .frame(width: art, height: art)
                        // Stable identity: the ring and artwork never rebuild when the
                        // accessory changes placement — that rebuild was the flicker.
                        .id(item.id)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: expanded ? 15 : 14, weight: .semibold))
                                .lineLimit(1)
                            if expanded {
                                Text(statusLine(item))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .contentTransition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, expanded ? 8 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Now Playing: \(item.title)"))
                .accessibilityHint(Text("Opens the player"))

                HStack(spacing: 0) {
                    glyph(playback.isPlaying ? "pause.fill" : "play.fill", size: expanded ? 18 : 16, loading: isLoading) { playback.togglePlayPause() }
                        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    if expanded {
                        glyph("forward.fill", size: 16) { playback.next() }
                            .disabled(!playback.hasNext)
                            .opacity(playback.hasNext ? 1 : 0.35)
                            .accessibilityLabel("Next")
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(height: expanded ? 60 : 46)
            .foregroundStyle(.primary)
        }
    }

    private var isLoading: Bool { playback.snapshot.state == .loading || playback.snapshot.state == .buffering }

    private func glyph(_ symbol: String, size: CGFloat, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: size, weight: .semibold)).contentTransition(.symbolEffect(.replace)) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func statusLine(_ item: PlayableItem) -> String {
        switch playback.snapshot.state {
        case .loading:   return String(localized: "Starting…")
        case .buffering: return String(localized: "Loading…")
        case .failed(let f): return f.message
        case .paused:    return String(localized: "Paused")
        default:
            if let sub = item.subtitle { return sub }
            return item.isLive ? String(localized: "Live") : String(localized: "Now Playing")
        }
    }
}
