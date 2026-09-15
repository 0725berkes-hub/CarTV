import SwiftUI

/// Watch page: starts playback, then title · channel row · actions · description ·
/// related videos · comments — the YouTube layout.
struct YTWatchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let video: YTVideo

    @State private var info: YTParser.WatchInfo?
    @State private var comments: [YTComment] = []
    @State private var commentsCont: String?
    @State private var showDescription = false
    @State private var resolveError: String?
    @State private var liked = false
    @State private var subscribed = false
    @State private var showComments = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4) {
                // Inline player surface when the phone player isn't full-screen
                playerSurface

                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text(info?.title ?? video.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text([info?.viewsText ?? video.viewsText, info?.publishedText ?? video.publishedText].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.inkMuted)
                }
                .padding(.horizontal, Theme.s4)

                channelRow.padding(.horizontal, Theme.s4)
                actions
                if let d = info?.description ?? video.title.nilIfEmpty { descriptionCard(d).padding(.horizontal, Theme.s4) }
                if let count = info?.commentCountText ?? (commentsCont != nil ? "" : nil) { commentsCard(count) .padding(.horizontal, Theme.s4) }

                if let related = info?.related, !related.isEmpty {
                    ShelfHeader(title: "Up next")
                    LazyVStack(spacing: Theme.s3) {
                        ForEach(related) { v in YTVideoCard(video: v, queue: related, compact: true).padding(.horizontal, Theme.s4) }
                    }
                }
            }
            .padding(.bottom, Theme.s10)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: video.watchURL) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task(id: video.id) {
            env.youtube.remember(video)
            await startPlayback()
            if let w = try? await env.youtube.watch(video.id) {
                info = w; liked = w.isLiked ?? false; subscribed = w.channel?.isSubscribed ?? false
                commentsCont = w.commentsContinuation
                // Up Next = related videos, as lazy stubs that resolve when reached.
                w.related.forEach { env.youtube.remember($0) }
                if let cur = playback.current, cur.ref.id == YouTubeService.uuid(for: video.id) {
                    playback.setQueue([cur] + w.related.compactMap { env.youtube.cachedStub($0.id) })
                }
            }
        }
        .sheet(isPresented: $showComments) { YTCommentsSheet(comments: $comments, continuation: $commentsCont) }
    }

    // MARK: Pieces

    @ViewBuilder private var playerSurface: some View {
        ZStack {
            Color.black
            if playback.current?.ref.id == YouTubeService.uuid(for: video.id) {
                PhoneVideoSurface()
                    .id("\(playback.videoViewRevision)")
                if playback.snapshot.state == .loading || playback.snapshot.state == .buffering {
                    ProgressView().tint(.white)
                }
            } else {
                RemoteImage(url: video.thumbnailURL, targetSize: CGSize(width: 1280, height: 720), contentMode: .fill) { Theme.raised }
                if let e = resolveError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                        Text(e).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                        Button("Retry") { Task { await startPlayback() } }.buttonStyle(.glass)
                    }.padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { if playback.current != nil { playback.isPhonePlayerPresented = true } }
    }

    private var channelRow: some View {
        HStack(spacing: Theme.s3) {
            if let ch = info?.channel {
                NavigationLink(value: ch) {
                    HStack(spacing: Theme.s3) {
                        RemoteImage(url: ch.avatarURL, targetSize: CGSize(width: 96, height: 96), contentMode: .fill) { Circle().fill(Theme.raised) }
                            .frame(width: 40, height: 40).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ch.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            if let s = ch.subscribersText { Text(s).font(.caption).foregroundStyle(Theme.inkMuted) }
                        }
                    }
                }.buttonStyle(.plain)
                Spacer()
                Button {
                    subscribed.toggle()
                    Task { try? await env.youtube.subscribe(ch.id, undo: !subscribed) }
                } label: {
                    Text(subscribed ? "Subscribed" : "Subscribe").font(.subheadline.weight(.semibold)).padding(.horizontal, 4)
                }
                .buttonStyle(subscribed ? AnyButtonStyle(.glass) : AnyButtonStyle(.glassProminent))
                .buttonBorderShape(.capsule)
                .tint(subscribed ? nil : Theme.ink)
                .foregroundStyle(subscribed ? Theme.ink : Theme.ground)
            } else {
                HStack(spacing: Theme.s3) {
                    Circle().fill(Theme.raised).frame(width: 40, height: 40)
                    Text(video.channelName ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s2) {
                pill(liked ? "hand.thumbsup.fill" : "hand.thumbsup", info?.likesText ?? "Like", active: liked) {
                    liked.toggle(); Task { try? await env.youtube.like(video.id, undo: !liked) }
                }
                pill("hand.thumbsdown", "", active: false) { Task { try? await env.youtube.dislike(video.id) } }
                pill("clock", "Watch later", active: false) { Task { try? await env.youtube.watchLater(video.id) } }
                pill(env.favorites.isFavorite(PlayableRef(id: YouTubeService.uuid(for: video.id), kind: .youtube)) ? "heart.fill" : "heart", "Favorite", active: false) {
                    env.favorites.toggle(PlayableRef(id: YouTubeService.uuid(for: video.id), kind: .youtube))
                }
                YTDownloadButton(video: video)
                ShareLink(item: video.watchURL) { Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold)).padding(.horizontal, 4).frame(height: 36) }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
            .padding(.horizontal, Theme.s4)
        }
    }

    private func pill(_ symbol: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if !title.isEmpty { Text(title) }
            }
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 4).frame(height: 36)
        }
        .buttonStyle(.glass).buttonBorderShape(.capsule)
        .tint(active ? Theme.accent : nil)
    }

    private func descriptionCard(_ text: String) -> some View {
        Button { withAnimation(.snappy) { showDescription.toggle() } } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote).foregroundStyle(Theme.ink).lineLimit(showDescription ? nil : 3).multilineTextAlignment(.leading)
                Text(showDescription ? "Show less" : "…more").font(.footnote.weight(.semibold)).foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.s3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func commentsCard(_ count: String) -> some View {
        Button { showComments = true } label: {
            HStack {
                Text("Comments").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(count).font(.footnote).foregroundStyle(Theme.inkMuted)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold)).foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.s3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func startPlayback() async {
        if playback.current?.ref.id == YouTubeService.uuid(for: video.id) { return }
        resolveError = nil
        do {
            let r = try await env.youtube.resolve(video)
            // Open the full-screen player right away — a tap on a video should play
            // it, not show a page you then have to tap again.
            playback.play(r.item, queue: [r.item], origin: .phone)
        } catch { resolveError = error.localizedDescription }
    }
}

struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Comments

struct YTCommentsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var comments: [YTComment]
    @Binding var continuation: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(comments) { c in
                    HStack(alignment: .top, spacing: Theme.s3) {
                        RemoteImage(url: c.avatarURL, targetSize: CGSize(width: 72, height: 72), contentMode: .fill) { Circle().fill(Theme.raised) }
                            .frame(width: 36, height: 36).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(c.author).font(.caption.weight(.semibold))
                                if let t = c.publishedText { Text(t).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(c.text).font(.subheadline)
                            HStack(spacing: 12) {
                                if let l = c.likesText { Label(l, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary) }
                                if let r = c.replyCount, r > 0 { Text("\(r) replies").font(.caption).foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                if continuation != nil {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear).task { await loadMore() }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .task { if comments.isEmpty { await loadMore() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func loadMore() async {
        guard !loading, let cont = continuation else { return }
        loading = true
        if let r = try? await env.youtube.comments(continuation: cont) {
            comments.append(contentsOf: r.items); continuation = r.continuation
        } else { continuation = nil }
        loading = false
    }
}
