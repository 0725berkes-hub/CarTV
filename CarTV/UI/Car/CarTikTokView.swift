import SwiftUI

/// TikTok on the car: a grid of covers from your For You / Following, big
/// targets, one tap to start. Playback runs in the normal car player; because
/// the queue is the whole feed, the player auto-advances and next/prev walk the
/// feed. The letterboxing for 9:16 video lives in the player's video surface.
struct CarTikTokView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @State private var feed: TikTokService.Feed = .forYou

    var body: some View {
        let tt = env.tiktok
        if !tt.session.isSignedIn {
            CarEmptyState(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in on your iPhone",
                          message: "Open the TikTok tab in CarFlix on your phone and sign in once. Your feed appears here.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: Theme.s2) {
                    ForEach(TikTokService.Feed.allCases) { f in
                        let selected = feed == f
                        Button { feed = f; if tt.items(for: f).isEmpty { tt.loadMore(f) } } label: {
                            Text(f.title).font(.system(size: m.compact ? 13 : 15, weight: .semibold))
                                .foregroundStyle(selected ? Color.black : Theme.ink)
                                .padding(.horizontal, m.compact ? Theme.s3 : Theme.s4).frame(height: m.compact ? 36 : 42)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(CarPressStyle())
                        .glassEffect(selected ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
                    }
                    Spacer()
                    Button { Task { await tt.refresh(feed) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: m.compact ? 36 : 42, height: m.compact ? 36 : 42).contentShape(Circle())
                    }
                    .buttonStyle(CarPressStyle())
                    .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.horizontal, m.gutter).padding(.vertical, Theme.s2)

                let items = tt.items(for: feed)
                if items.isEmpty {
                    if let e = tt.error {
                        CarEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load", message: LocalizedStringResource(stringLiteral: e))
                    } else {
                        CarEmptyState(symbol: "hourglass", title: "Loading your feed…")
                            .task { tt.loadMore(feed) }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: m.compact ? 120 : 150), spacing: Theme.s3)], spacing: Theme.s3) {
                            ForEach(items) { v in
                                CarTikTokCard(video: v) {
                                    Task { @MainActor in
                                        let q = await tt.proxiedQueue(items, forCar: true)
                                        if let item = q.first(where: { $0.id == v.playableID }) {
                                            tt.playerStarted(feed: feed)
                                            playback.play(item, queue: q, origin: .car, resume: false)
                                        }
                                    }
                                }
                                .onAppear { if let i = items.firstIndex(where: { $0.id == v.id }) { tt.prefetchIfNeeded(feed, index: i) } }
                            }
                        }
                        .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
                    }
                }
            }
        }
    }
}

private struct CarTikTokCard: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let video: TTVideo
    let action: () -> Void
    var body: some View {
        let playing = playback.current?.id == video.playableID
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: video.coverURL, targetSize: CGSize(width: 360, height: 640), contentMode: .fill) { TileTint.gradient(for: video.id) }
                        .aspectRatio(9/16, contentMode: .fill)
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    HStack(spacing: 4) {
                        Image(systemName: playing ? "waveform" : "play.fill").font(.system(size: 10, weight: .bold))
                        Text(playing ? "Playing" : "\(video.duration)s").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white).padding(7)
                    if playing { Rectangle().strokeBorder(Theme.accent, lineWidth: 2.5) }
                }
                .aspectRatio(9/16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                Text("@\(video.author.uniqueID)").font(.system(size: m.compact ? 12 : 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if !video.desc.isEmpty {
                    Text(video.desc).font(.system(size: m.compact ? 10.5 : 12)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
            }
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}
