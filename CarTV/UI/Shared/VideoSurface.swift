import SwiftUI
import UIKit

/// Car-side surface. Always shows video; the car is the primary screen.
struct VideoSurface: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        HostedVideoView(view: playback.carVideoView(), key: "car-\(playback.videoViewRevision)")
            .onAppear { playback.isCarPlayerPresented = true }
            .onDisappear { playback.isCarPlayerPresented = false }
    }
}

/// Phone-side surface. AVPlayer mirrors; for VLC the phone shows video whenever the
/// car player isn't on screen, otherwise artwork + "Playing on car".
struct PhoneVideoSurface: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        if let view = playback.phoneVideoView() {
            HostedVideoView(view: view, key: "phone-\(playback.videoViewRevision)-\(playback.carIsConnected)-\(playback.isCarPlayerPresented)")
        } else {
            YieldedSurfaceCard(item: playback.current, text: "Playing on your car screen")
        }
    }
}

/// Re-parents a UIKit view. The same UIView can be hosted by only one container at a
/// time; hosting it here removes it from wherever it was.
private struct HostedVideoView: UIViewRepresentable {
    let view: UIView
    let key: String
    func makeUIView(context: Context) -> VideoSurfaceContainer {
        let c = VideoSurfaceContainer(); c.host(view); c.key = key; return c
    }
    func updateUIView(_ c: VideoSurfaceContainer, context: Context) {
        if c.key != key || c.hosted !== view { c.host(view); c.key = key }
    }
    static func dismantleUIView(_ c: VideoSurfaceContainer, coordinator: ()) {
        // Give the drawable back so the other surface can pick it up.
        c.hosted?.removeFromSuperview()
    }
}

struct YieldedSurfaceCard: View {
    let item: PlayableItem?
    let text: LocalizedStringResource
    var body: some View {
        ZStack {
            if let item { TileTint.gradient(for: item.title).opacity(0.5) }
            VStack(spacing: Theme.s3) {
                if let item {
                    RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 320, height: 320), contentMode: .fit) {
                        Monogram(text: item.title, size: 40)
                    }
                    .frame(width: 140, height: 140)
                }
                Label(text, systemImage: "car.fill").font(Theme.Font.headline).foregroundStyle(Theme.ink)
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
        if hosted === view, view.superview === self { return }
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
