import SwiftUI

/// YouTube on the car: big thumbnails, three feeds, recent searches (no typing
/// while driving), and playlists. Tapping a video plays it with related as Up Next.
struct CarYouTubeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @State private var feed: YouTubeService.Feed = .home
    @State private var page: YTPage?
    @State private var error: String?

    private struct FeedChip: Identifiable { let id: String; let feed: YouTubeService.Feed; let title: LocalizedStringResource; let symbol: String }
    private let feeds: [FeedChip] = [
        FeedChip(id: "home", feed: .home, title: "Home", symbol: "house.fill"),
        FeedChip(id: "subs", feed: .subscriptions, title: "Subscriptions", symbol: "rectangle.stack.badge.person.crop"),
        FeedChip(id: "wl", feed: .watchLater, title: "Watch Later", symbol: "clock.fill"),
        FeedChip(id: "history", feed: .history, title: "History", symbol: "clock.arrow.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.s2) {
                    ForEach(feeds) { chip in
                        let selected = feed == chip.feed
                        Button { feed = chip.feed } label: {
                            Label(chip.title, systemImage: chip.symbol).font(.system(size: m.compact ? 13 : 15, weight: .semibold))
                                .foregroundStyle(selected ? Color.black : Theme.ink)
                                .padding(.horizontal, m.compact ? Theme.s3 : Theme.s4).frame(height: m.compact ? 36 : 42)
                        }
                        .buttonStyle(CarPressStyle())
                        .glassEffect(selected ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
                    }
                }
                .padding(.horizontal, m.gutter).padding(.vertical, Theme.s2)
            }
            .overlay(alignment: .trailing) {
                // Refresh: drop caches and re-fetch this feed.
                Button { env.youtube.invalidateFeeds(); reload &+= 1 } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: m.compact ? 14 : 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: m.compact ? 36 : 42, height: m.compact ? 36 : 42)
                }
                .buttonStyle(CarPressStyle())
                .glassEffect(.regular.interactive(), in: Circle())
                .padding(.trailing, m.gutter)
                .disabled(page == nil && error == nil)
            }

            Group {
                if let page {
                    var seen = Set<String>()
                    let videos = page.flatItems.compactMap { item -> YTVideo? in
                        guard case .video(let v) = item, seen.insert(v.id).inserted else { return nil }
                        return v
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: m.compact ? 180 : 240), spacing: Theme.s3)], spacing: Theme.s4) {
                            ForEach(videos) { v in CarYTCard(video: v, queue: videos) }
                            // Pull the next page of every shelf that still has one.
                            if page.shelves.contains(where: { $0.continuation != nil }) || page.continuation != nil {
                                ProgressView().frame(maxWidth: .infinity, minHeight: 80).task { await loadMore() }
                            }
                        }
                        .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
                    }
                } else if let error {
                    CarEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load", message: LocalizedStringResource(stringLiteral: error))
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: "\(feed)-\(env.youtube.auth.isSignedIn)-\(reload)") {
            page = nil; error = nil
            do {
                let p = try await env.youtube.fetch(feed)
                if p.flatItems.isEmpty { error = String(localized: "Nothing here yet. Sign in on your iPhone for your feed.") } else { page = p }
            } catch { self.error = error.localizedDescription }
        }
    }

    @State private var reload = 0

    private func loadMore() async {
        guard var p = page else { return }
        var grew = false
        for i in p.shelves.indices {
            guard let c = p.shelves[i].continuation else { continue }
            if let more = try? await env.youtube.more(shelf: c) {
                let seen = Set(p.shelves[i].items.map(\.id))
                let fresh = more.items.filter { !seen.contains($0.id) }
                p.shelves[i].items.append(contentsOf: fresh); p.shelves[i].continuation = more.continuation
                grew = grew || !fresh.isEmpty
            } else { p.shelves[i].continuation = nil }
        }
        if let c = p.continuation {
            if let more = try? await env.youtube.fetch(feed, continuation: c) {
                let seen = Set(p.flatItems.map(\.id))
                let shelves = more.shelves.map { sh in var s = sh; s.items = s.items.filter { !seen.contains($0.id) }; return s }.filter { !$0.items.isEmpty }
                p.shelves.append(contentsOf: shelves); p.continuation = more.continuation
                grew = grew || !shelves.isEmpty
            } else { p.continuation = nil }
        }
        if !grew { p.continuation = nil; for i in p.shelves.indices { p.shelves[i].continuation = nil } }
        page = p
    }
}

struct CarYTCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let video: YTVideo
    let queue: [YTVideo]
    @State private var resolving = false

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear.overlay { RemoteImage(url: video.thumbnailURL, targetSize: CGSize(width: 640, height: 360), contentMode: .fill) { Theme.raised } }.clipped()
                    if resolving {
                        Rectangle().fill(.black.opacity(0.4)); ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if playback.current?.ref.id == YouTubeService.uuid(for: video.id) { Rectangle().fill(.black.opacity(0.4)); EqualizerBars().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if video.isLive { Text("LIVE").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3).background(Theme.live, in: RoundedRectangle(cornerRadius: 4)).padding(6) }
                    else if let d = video.durationText { Text(d).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).padding(6) }
                    if let p = video.progressFraction, p > 0.02 { VStack { Spacer(); ProgressBar(fraction: p, height: 3) } }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                Text(video.title).font(.system(size: m.compact ? 12.5 : 14.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(video.channelName ?? "").font(.system(size: m.compact ? 11 : 12.5)).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CarFocusButtonStyle())
    }

    private func play() {
        guard !resolving else { return }
        resolving = true
        queue.forEach { env.youtube.remember($0) }
        Task {
            defer { resolving = false }
            guard let r = try? await env.youtube.resolve(video) else { return }
            let rest = queue.filter { $0.id != video.id }.compactMap { env.youtube.cachedStub($0.id) }
            playback.play(r.item, queue: [r.item] + rest, origin: .car)
        }
    }
}


/// Car watch page: big thumbnail + Play/Resume, title, channel, and Up next
/// (YouTube's own recommendations for this video) as a grid.
struct CarYTWatchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push
    let video: YTVideo
    @State private var info: YTParser.WatchInfo?

    private var isCurrent: Bool { playback.current?.ref.id == YouTubeService.uuid(for: video.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                HStack(alignment: .top, spacing: Theme.s4) {
                    Button { if isCurrent { playback.requestCarPlayer() } else { play() } } label: {
                        ZStack {
                            RemoteImage(url: video.thumbnailURL, targetSize: CGSize(width: 1280, height: 720), contentMode: .fill) { Theme.raised }
                            Image(systemName: isCurrent ? "waveform" : "play.fill").font(.system(size: m.compact ? 28 : 40, weight: .bold)).foregroundStyle(.white)
                                .padding(m.compact ? 14 : 20).background(.black.opacity(0.45), in: Circle())
                        }
                        .frame(width: m.compact ? 220 : 340).aspectRatio(16/9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                    }
                    .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))

                    VStack(alignment: .leading, spacing: Theme.s2) {
                        Text(info?.title ?? video.title).font(Theme.Car.title(m.compact ? 16 : 22)).foregroundStyle(Theme.ink).lineLimit(3)
                        Text([info?.channel?.name ?? video.channelName, info?.viewsText ?? video.viewsText, info?.publishedText ?? video.publishedText].compactMap { $0?.nilIfEmpty }.joined(separator: " · "))
                            .font(.system(size: m.compact ? 12 : 15)).foregroundStyle(Theme.inkMuted).lineLimit(2)
                        HStack(spacing: Theme.s2) {
                            CarPillButton(title: isCurrent ? "Now playing" : "Play", symbol: isCurrent ? "waveform" : "play.fill") {
                                if isCurrent { playback.requestCarPlayer() } else { play() }
                            }
                            let ref = PlayableRef(id: YouTubeService.uuid(for: video.id), kind: .youtube)
                            CarPillButton(title: env.favorites.isFavorite(ref) ? "Favorited" : "Favorite", symbol: env.favorites.isFavorite(ref) ? "heart.fill" : "heart") { env.favorites.toggle(ref) }
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let related = info?.related, !related.isEmpty {
                    Text("Up next").font(Theme.Car.title(m.compact ? 14 : 18)).foregroundStyle(Theme.ink)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: m.compact ? 180 : 240), spacing: Theme.s3)], spacing: Theme.s4) {
                        ForEach(related) { v in CarYTCard(video: v, queue: related) }
                    }
                } else if info == nil {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.horizontal, m.gutter).padding(.vertical, Theme.s3)
        }
        .task(id: video.id) { info = try? await env.youtube.watch(video.id) }
    }

    private func play() {
        env.youtube.remember(video)
        let rest = (info?.related ?? [])
        rest.forEach { env.youtube.remember($0) }
        Task {
            guard let r = try? await env.youtube.resolve(video) else { return }
            playback.play(r.item, queue: [r.item] + rest.compactMap { env.youtube.cachedStub($0.id) }, origin: .car)
        }
    }
}
