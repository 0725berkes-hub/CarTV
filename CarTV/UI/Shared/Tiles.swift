import SwiftUI

// MARK: - Channel tile (16:9, logo on tinted ground)

struct ChannelTile: View {
    let item: PlayableItem
    var health: SourceHealth = .unknown
    var isFavorite = false
    var isPlaying = false
    var progress: Double? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                TileTint.gradient(for: item.title)
                RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 240, height: 135), contentMode: .fit) {
                    Monogram(text: item.title, size: compact ? 18 : 24)
                }
                .padding(compact ? 10 : 14)

                // Corner marks, no backing shapes — the thumbnail is the surface.
                VStack {
                    HStack(alignment: .top) {
                        if item.isLive { LiveDot() }
                        Spacer(minLength: 0)
                        if isFavorite { Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.live).shadow(radius: 2) }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        if health == .unreachable { Image(systemName: "wifi.slash").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.amber).shadow(radius: 2) }
                    }
                }
                .padding(7)

                if isPlaying {
                    Rectangle().fill(.black.opacity(0.4))
                    EqualizerBars()
                }
                if let progress, progress > 0.02 { VStack { Spacer(); ProgressBar(fraction: progress) } }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            .overlay {
                if isPlaying { RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2) }
            }

            Text(item.title)
                .font(compact ? Theme.Font.caption : Theme.Font.tile)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Video thumb (portrait 3:4, for local videos everywhere)

struct VideoThumbCell: View {
    let item: PlayableItem
    var progress: Double? = nil
    var isFavorite = false
    var isPlaying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                TileTint.gradient(for: item.title)
                RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 240, height: 320), contentMode: .fill) {
                    Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.6))
                }
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                VStack {
                    HStack {
                        Spacer()
                        if isFavorite { Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.live).shadow(radius: 2) }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        if item.duration > 0 {
                            Text(item.duration.clockString).font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(.white).shadow(radius: 2)
                        }
                    }
                }.padding(6)
                if isPlaying { Rectangle().fill(.black.opacity(0.4)); EqualizerBars() }
                if let progress, progress > 0.02 { VStack { Spacer(); ProgressBar(fraction: progress, height: 2.5) } }
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            .overlay {
                if isPlaying { RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2) }
            }
            Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// Landscape 16:9 video card (Continue Watching).
struct VideoCard: View {
    let item: PlayableItem
    var progress: Double? = nil
    var isFavorite = false
    var isPlaying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                TileTint.gradient(for: item.title)
                RemoteImage(url: item.artworkURL, targetSize: CGSize(width: 480, height: 270), contentMode: .fill) {
                    Image(systemName: "play.rectangle").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.6))
                }
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                VStack {
                    HStack { Spacer(); if isFavorite { Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.live).shadow(radius: 2) } }
                    Spacer()
                    HStack {
                        Spacer()
                        if item.duration > 0 { Text(item.duration.clockString).font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(.white).shadow(radius: 2) }
                    }
                }.padding(7)
                if isPlaying { Rectangle().fill(.black.opacity(0.4)); EqualizerBars() }
                if let progress, progress > 0.02 { VStack { Spacer(); ProgressBar(fraction: progress) } }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            .overlay { if isPlaying { RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2) } }
            Text(item.title).font(Theme.Font.tile).foregroundStyle(Theme.ink).lineLimit(1)
            if let sub = item.subtitle { Text(sub).font(Theme.Font.label).foregroundStyle(Theme.inkMuted).lineLimit(1) }
        }
        .contentShape(Rectangle())
    }
}

/// Kept for API compatibility; renders as a VideoThumbCell.
struct PosterCard: View {
    let item: PlayableItem
    var progress: Double? = nil
    var isFavorite = false
    var width: CGFloat = 120
    var body: some View { VideoThumbCell(item: item, progress: progress, isFavorite: isFavorite).frame(width: width) }
}

// MARK: - Bits

struct LiveDot: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text("LIVE").font(.system(size: 9, weight: .heavy)).tracking(0.5).foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}

struct LiveBadge: View {
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text("LIVE").font(.system(size: compact ? 9.5 : 11, weight: .heavy)).tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 3 : 4)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

struct EqualizerBars: View {
    @State private var phase = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 4, height: phase ? [14, 22, 10, 18][i] : [20, 8, 24, 12][i])
            }
        }
        .frame(height: 24)
        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringResource
    var message: LocalizedStringResource? = nil
    var actionTitle: LocalizedStringResource? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: symbol).font(.system(size: 40, weight: .medium)).foregroundStyle(Theme.accent)
            Text(title).font(Theme.Font.title2).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            if let message {
                Text(message).font(Theme.Font.callout).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle).font(Theme.Font.headline).padding(.horizontal, Theme.s4).padding(.vertical, Theme.s2) }
                    .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                    .padding(.top, Theme.s2)
            }
        }
        .padding(Theme.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Section header: title + count, "See all" on the right. No icons, no chrome.
struct ShelfHeader: View {
    let title: LocalizedStringResource
    var subtitle: String? = nil
    var actionTitle: LocalizedStringResource? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
            Text(title).font(Theme.Font.title2).foregroundStyle(Theme.ink).lineLimit(1)
            if let subtitle { Text(subtitle).font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.inkFaint) }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 2) { Text(actionTitle); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .padding(.horizontal, Theme.s4)
    }
}

struct SkeletonTile: View {
    @State private var shimmer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).fill(Theme.raised).aspectRatio(16/9, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(height: 12).frame(maxWidth: 110)
        }
        .opacity(shimmer ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}


// MARK: - End-of-video choices

/// Shown when a video finishes and neither repeat nor shuffle is on.
/// Big glass buttons so it's usable from the driver's seat.
struct UpNextCard: View {
    @Environment(PlaybackController.self) private var playback
    var compact = false
    var body: some View {
        let size: CGFloat = compact ? 56 : 72
        VStack(spacing: compact ? Theme.s3 : Theme.s5) {
            Text("Finished").font(.system(size: compact ? 15 : 20, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    UpNextButton(symbol: "arrow.counterclockwise", title: "Replay", size: size) { playback.replay() }
                    if playback.queue.count > 1 {
                        UpNextButton(symbol: "forward.end.fill", title: "Next", size: size, prominent: true) { playback.next() }
                        UpNextButton(symbol: "shuffle", title: "Random", size: size) { playback.playRandom(origin: .car) }
                    }
                }
            }
        }
        .padding(compact ? Theme.s4 : Theme.s6)
    }
}

struct UpNextButton: View {
    let symbol: String
    let title: LocalizedStringResource
    let size: CGFloat
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(prominent ? Color.black : .white)
                    .frame(width: size, height: size)
                    .glassEffect(prominent ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Circle())
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
    }
}


/// TikTok-style indeterminate loader: a thin bar with a bright segment sweeping across.
struct LoadingLine: View {
    @State private var x: CGFloat = -0.3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: geo.size.width * 0.3)
                    .offset(x: geo.size.width * x)
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 16)
        .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { x = 1.0 } }
    }
}
