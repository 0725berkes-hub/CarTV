import SwiftUI
import UIKit

/// Hosts the engine's primary video view (the car when connected, else the phone).
/// Re-parents the same UIView so switching surfaces never rebuilds the decoder.
struct VideoSurface: UIViewRepresentable {
    @Environment(PlaybackController.self) private var playback

    func makeUIView(context: Context) -> VideoSurfaceContainer {
        let container = VideoSurfaceContainer()
        container.host(playback.videoView)
        return container
    }

    func updateUIView(_ container: VideoSurfaceContainer, context: Context) {
        if container.hosted !== playback.videoView { container.host(playback.videoView) }
    }
}

/// Phone-side surface. When the car owns the primary view, AVPlayer gives us a
/// mirror layer; VLC can't, so we show the artwork "playing on car" card.
struct PhoneVideoSurface: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        if let view = playback.phoneVideoView() {
            PhoneMirrorSurface(view: view, key: "\(playback.videoViewRevision)-\(playback.carIsConnected)")
        } else {
            PlayingOnCarCard(item: playback.current)
        }
    }
}

private struct PhoneMirrorSurface: UIViewRepresentable {
    let view: UIView
    let key: String
    func makeUIView(context: Context) -> VideoSurfaceContainer {
        let c = VideoSurfaceContainer(); c.host(view); c.key = key; return c
    }
    func updateUIView(_ c: VideoSurfaceContainer, context: Context) {
        if c.key != key || c.hosted !== view { c.host(view); c.key = key }
    }
}

struct PlayingOnCarCard: View {
    let item: PlayableItem?
    var body: some View {
        ZStack {
            if let item { TileTint.gradient(for: item.title).opacity(0.5) }
            VStack(spacing: Theme.s4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).fill(Theme.surface).frame(width: 160, height: 160)
                    if let item {
                        RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 320, height: 320), contentMode: .fit) {
                            Monogram(text: item.title, size: 48)
                        }.padding(Theme.s4).frame(width: 160, height: 160)
                    }
                }
                Label("Playing on your car screen", systemImage: "car.fill")
                    .font(Theme.Font.headline).foregroundStyle(Theme.ink)
                Text("Controls here work too.").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

final class VideoSurfaceContainer: UIView {
    private(set) weak var hosted: UIView?
    var key = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func host(_ view: UIView) {
        if hosted === view { return }
        hosted?.removeFromSuperview()
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosted = view
    }
}
