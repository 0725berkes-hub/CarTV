import SwiftUI
import UIKit

/// Car "Cast" tab: tells the driver what to do on the phone. Mirroring itself
/// takes over the whole screen via `CarMirrorStage`.
struct CarCastView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m

    var body: some View {
        VStack(spacing: m.compact ? Theme.s3 : Theme.s5) {
            Spacer(minLength: 0)
            Image(systemName: "tv")
                .font(.system(size: m.compact ? 40 : 64, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Cast anything to this screen")
                .font(Theme.Car.title(m.compact ? 20 : 30)).foregroundStyle(Theme.ink)
            Text("On your iPhone, open CarFlix → Cast, then tap Start mirroring or paste a link.")
                .font(.system(size: m.compact ? 13 : 17)).foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 560)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text(UIDevice.current.name).font(.system(size: m.compact ? 14 : 18, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, Theme.s4).frame(height: 40)
            .glassEffect(.regular, in: Capsule())
            if case .error(let msg) = env.mirror.state {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.amber)
            }
            Spacer(minLength: 0)
        }
        .padding(m.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-screen mirror of the iPhone. Tap shows a small "Stop" affordance; stopping
/// is done from the phone (Control Center or CarTV) since the extension owns the session.
struct CarMirrorStage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    @State private var showHUD = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MirrorSurface(view: env.mirror.displayView).ignoresSafeArea()
            if env.mirror.frameSize == .zero {
                VStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Waiting for your iPhone…").font(.system(size: m.compact ? 12 : 15)).foregroundStyle(.white.opacity(0.8))
                }
            }
            if showHUD {
                VStack {
                    HStack {
                        Label("Mirroring iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: m.compact ? 12 : 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, Theme.s3).frame(height: m.compact ? 34 : 40)
                            .glassEffect(.regular, in: Capsule())
                        Spacer()
                        Text("Stop from your iPhone").font(.system(size: m.compact ? 11 : 13)).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, Theme.s3).frame(height: m.compact ? 34 : 40)
                            .glassEffect(.regular, in: Capsule())
                    }
                    .padding(m.gutter)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { showHUD.toggle() }; if showHUD { scheduleHide() } }
        .onAppear { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { withAnimation { showHUD = false } } }
    }
}

private struct MirrorSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> VideoSurfaceContainer { let c = VideoSurfaceContainer(); c.host(view); return c }
    func updateUIView(_ c: VideoSurfaceContainer, context: Context) { if c.hosted !== view { c.host(view) } }
}
