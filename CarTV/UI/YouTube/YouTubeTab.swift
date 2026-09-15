import SwiftUI
import OSLog

/// YouTube tab root: segmented Home / Subscriptions / Library with search in the bar.
struct YouTubeTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .home
    @State private var query = ""
    @State private var submitted: String?
    @State private var feedReload = 0
    @State private var showSignIn = false
    @State private var path = NavigationPath()

    enum Section: Hashable, CaseIterable { case home, subscriptions, library
        var title: LocalizedStringResource { switch self { case .home: "Home"; case .subscriptions: "Subscriptions"; case .library: "Library" } }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let q = submitted, !q.isEmpty {
                    YTSearchResults(query: q)
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $section) {
                            ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, Theme.s4).padding(.bottom, Theme.s2)
                        Group {
                            switch section {
                            case .home: YTFeedView(feed: .home).id(feedReload)
                            case .subscriptions: YTFeedView(feed: .subscriptions).id(feedReload)
                            case .library: YTLibraryView().id(feedReload)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .background(Theme.ground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { YTDownloadStrip() }
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MoreToolbarMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { env.youtube.invalidateFeeds(); feedReload &+= 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh feed")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSignIn = true } label: {
                        if let url = env.youtube.auth.accountAvatarURL {
                            RemoteImage(url: url, targetSize: CGSize(width: 64, height: 64), contentMode: .fill) { Image(systemName: "person.crop.circle") }
                                .frame(width: 28, height: 28).clipShape(Circle())
                        } else {
                            Image(systemName: env.youtube.auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        }
                    }
                    .accessibilityLabel("Account")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search YouTube"))
            .searchSuggestions { YTSuggestions(query: query) { query = $0; submitted = $0 } }
            .onSubmit(of: .search) { submitted = query }
            .onChange(of: query) { _, q in if q.isEmpty { submitted = nil } }
            .sheet(isPresented: $showSignIn) { YTAccountSheet() }
            .onChange(of: env.youtube.pendingSignInPrompt, initial: true) { _, pending in
                if pending, !env.youtube.auth.isSignedIn {
                    env.youtube.pendingSignInPrompt = false
                    Task { try? await Task.sleep(for: .milliseconds(400)); showSignIn = true }
                }
            }
            .navigationDestination(for: YTVideo.self) { YTWatchView(video: $0) }
            .navigationDestination(for: YTChannel.self) { YTChannelView(channel: $0) }
            .navigationDestination(for: YTPlaylist.self) { YTPlaylistView(playlist: $0) }
        }
    }
}

// MARK: - Feed

struct YTFeedView: View {
    @Environment(AppEnvironment.self) private var env
    let feed: YouTubeService.Feed
    @State private var page: YTPage?
    @State private var loading = false
    @State private var error: String?
    @State private var loadingMore = false

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.s5) {
                        if case .home = feed, !env.youtube.auth.isSignedIn {
                            YTSignInBanner().padding(.horizontal, Theme.s4)
                        }
                        ForEach(page.shelves) { shelf in
                            if let t = shelf.title {
                                ShelfHeader(title: LocalizedStringResource(stringLiteral: t))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: Theme.s3) {
                                        ForEach(shelf.items) { item in
                                            switch item {
                                            case .video(let v): YTVideoCard(video: v, queue: shelf.items.compactMap { if case .video(let x) = $0 { return x } else { return nil } }).frame(width: 260)
                                            case .playlist(let pl): YTPlaylistCard(playlist: pl).frame(width: 260)
                                            case .channel(let c): YTChannelRow(channel: c).frame(width: 260)
                                            }
                                        }
                                        if shelf.continuation != nil {
                                            ProgressView().frame(width: 60, height: 146).task { await loadMore(shelf: shelf) }
                                        }
                                    }
                                    .padding(.horizontal, Theme.s4)
                                }
                            } else {
                                // Rows live directly in the outer lazy stack. A LazyVGrid nested
                                // inside a LazyVStack only *estimates* its height until rows are
                                // realised, and every appended page re-estimates → scroll jumps.
                                let videos = shelf.items.compactMap { if case .video(let x) = $0 { return x } else { return nil } }
                                ForEach(shelf.items) { item in
                                    Group {
                                        switch item {
                                        case .video(let v): YTVideoCard(video: v, queue: videos)
                                        case .channel(let c): YTChannelRow(channel: c)
                                        case .playlist(let p): YTPlaylistCard(playlist: p)
                                        }
                                    }
                                    .padding(.horizontal, Theme.s4)
                                }
                            }
                        }
                        if page.continuation != nil {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 64).task { await loadMore() }
                        }
                    }
                    .padding(.vertical, Theme.s2).padding(.bottom, Theme.s10)
                }
                .refreshable { await load(force: true) }
            } else if loading || (page == nil && error == nil) {
                YTSkeletonFeed()
            } else if let error {
                if error == YTError.signInRequired.errorDescription {
                    YTSignInPrompt()
                } else {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load", message: LocalizedStringResource(stringLiteral: error), actionTitle: "Retry") { Task { await load(force: true) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(feed)-\(env.youtube.auth.isSignedIn)") { await load(force: false) }
    }

    private func load(force: Bool) async {
        if page != nil, !force { return }
        loading = true; error = nil
        do {
            let p = try await env.youtube.fetch(feed)
            Log.network.info("YT feed \(String(describing: feed), privacy: .public): \(p.flatItems.count) items, \(p.shelves.count) shelves")
            if p.flatItems.isEmpty { error = String(localized: "YouTube returned no videos for this feed."); page = nil } else { page = p }
        } catch {
            Log.network.error("YT feed failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription; page = nil
        }
        loading = false
    }

    private func loadMore(shelf: YTShelf) async {
        guard let cont = shelf.continuation, let i = page?.shelves.firstIndex(where: { $0.id == shelf.id }) else { return }
        if let more = try? await env.youtube.more(shelf: cont) {
            let seen = Set(page?.shelves[i].items.map(\.id) ?? [])
            page?.shelves[i].items.append(contentsOf: more.items.filter { !seen.contains($0.id) })
            page?.shelves[i].continuation = more.continuation
        } else {
            page?.shelves[i].continuation = nil
        }
    }

    func refresh() async { await load(force: true) }

    private func loadMore() async {
        guard !loadingMore, let cont = page?.continuation else { return }
        loadingMore = true
        if let more = try? await env.youtube.fetch(feed, continuation: cont) {
            // Grow the existing grid instead of appending new shelves: appending a
            // sibling grid re-lays out the whole stack and throws the scroll position.
            let seen = Set(page?.flatItems.map(\.id) ?? [])
            var loose: [YTItem] = []
            var titled: [YTShelf] = []
            for sh in more.shelves {
                let fresh = sh.items.filter { !seen.contains($0.id) }
                guard !fresh.isEmpty else { continue }
                if sh.title == nil { loose.append(contentsOf: fresh) } else { var t = sh; t.items = fresh; titled.append(t) }
            }
            if !loose.isEmpty {
                if let i = page?.shelves.lastIndex(where: { $0.title == nil }) { page?.shelves[i].items.append(contentsOf: loose) }
                else { page?.shelves.append(YTShelf(title: nil, items: loose)) }
            }
            page?.shelves.append(contentsOf: titled)
            page?.continuation = (loose.isEmpty && titled.isEmpty) ? nil : more.continuation
        } else { page?.continuation = nil }
        loadingMore = false
    }
}

// MARK: - Item grid (YouTube card layout)

struct YTItemGrid: View {
    let items: [YTItem]
    var body: some View {
        // Queue = this grid's videos. Computed once per grid, not per card, so an
        // appended page doesn't rebuild every card above it.
        let videos = items.compactMap { if case .video(let x) = $0 { return x } else { return nil } }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.s4)], alignment: .leading, spacing: Theme.s5) {
            ForEach(items) { item in
                switch item {
                case .video(let v): YTVideoCard(video: v, queue: videos)
                case .channel(let c): YTChannelRow(channel: c)
                case .playlist(let p): YTPlaylistCard(playlist: p)
                }
            }
        }
        .padding(.horizontal, Theme.s4)
    }
}

struct YTVideoCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let video: YTVideo
    var queue: [YTVideo] = []
    var compact = false

    var body: some View {
        NavigationLink(value: video) {
            if compact { compactBody } else { fullBody }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { play() } label: { Label("Play", systemImage: "play.fill") }
            if let cid = video.channelID {
                NavigationLink(value: YTChannel(id: cid, name: video.channelName ?? "")) { Label("Go to channel", systemImage: "person.crop.circle") }
            }
            Button { Task { try? await env.youtube.watchLater(video.id) } } label: { Label("Save to Watch Later", systemImage: "clock") }
            YTDownloadButton(video: video, style: .menuItem)
            Button { UIPasteboard.general.url = video.watchURL } label: { Label("Copy Link", systemImage: "link") }
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            thumb.aspectRatio(16/9, contentMode: .fit)
            HStack(alignment: .top, spacing: Theme.s3) {
                avatar(36)
                VStack(alignment: .leading, spacing: 3) {
                    // Reserve two lines always so every row has the same height; lazy
                    // stacks estimate off-screen rows from realised ones, and variable
                    // heights make the estimate drift → position jumps while loading.
                    Text(video.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2, reservesSpace: true)
                    Text(meta).font(.footnote).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            thumb.frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                Text(video.channelName ?? "").font(.footnote).foregroundStyle(Theme.inkMuted).lineLimit(1)
                Text([video.viewsText, video.publishedText].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var thumb: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.overlay {
                RemoteImage(url: video.thumbnailURL, targetSize: CGSize(width: 640, height: 360), contentMode: .fill) { Theme.raised }
            }
            .clipped()
            if video.isLive {
                Text("LIVE").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.live, in: RoundedRectangle(cornerRadius: 4)).padding(6)
            } else if let d = video.durationText {
                Text(d).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).padding(6)
            }
            if let p = video.progressFraction, p > 0.02 { VStack { Spacer(); ProgressBar(fraction: p, height: 3).tint(Theme.live) } }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }

    private func avatar(_ size: CGFloat) -> some View {
        Group {
            if let url = video.channelAvatarURL {
                RemoteImage(url: url, targetSize: CGSize(width: 96, height: 96), contentMode: .fill) { Circle().fill(Theme.raised) }
            } else {
                Circle().fill(TileTint.color(for: video.channelName ?? "")).overlay(Monogram(text: video.channelName ?? "?", size: size * 0.4))
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }

    private var meta: String {
        [video.channelName, video.viewsText, video.publishedText].compactMap { $0 }.joined(separator: " · ")
    }

    private func play() {
        env.youtube.remember(video)
        Task {
            if let r = try? await env.youtube.resolve(video) { playback.play(r.item, queue: nil, origin: .phone) }
        }
    }
}

struct YTChannelRow: View {
    let channel: YTChannel
    var body: some View {
        NavigationLink(value: channel) {
            HStack(spacing: Theme.s3) {
                RemoteImage(url: channel.avatarURL, targetSize: CGSize(width: 160, height: 160), contentMode: .fill) { Circle().fill(Theme.raised) }
                    .frame(width: 64, height: 64).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.headline).foregroundStyle(Theme.ink)
                    Text([channel.handle, channel.subscribersText].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.inkFaint)
            }
        }
        .buttonStyle(.plain)
    }
}

struct YTPlaylistCard: View {
    let playlist: YTPlaylist
    var body: some View {
        NavigationLink(value: playlist) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear.overlay {
                        RemoteImage(url: playlist.thumbnailURL, targetSize: CGSize(width: 640, height: 360), contentMode: .fill) {
                            ZStack { TileTint.gradient(for: playlist.title); Image(systemName: "play.square.stack").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.7)) }
                        }
                    }.clipped()
                    HStack(spacing: 4) { Image(systemName: "list.bullet"); Text(playlist.videoCountText ?? "") }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                }
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                Text(playlist.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                if let c = playlist.channelName { Text(c).font(.footnote).foregroundStyle(Theme.inkMuted).lineLimit(1) }
            }
        }
        .buttonStyle(.plain)
    }
}

struct YTSkeletonFeed: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.s5) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Theme.s3) {
                        RoundedRectangle(cornerRadius: Theme.radiusM).fill(Theme.raised).aspectRatio(16/9, contentMode: .fit)
                        HStack(spacing: Theme.s3) {
                            Circle().fill(Theme.raised).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(height: 14)
                                RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(width: 160, height: 12)
                            }
                        }
                    }
                }
            }
            .padding(Theme.s4)
        }
        .redacted(reason: .placeholder)
    }
}


struct YTSignInBanner: View {
    @State private var show = false
    var body: some View {
        Button { show = true } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in for your recommendations").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Subscriptions, history, playlists and a Home feed that's yours.").font(.footnote).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(Theme.s3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) { YTAccountSheet() }
    }
}
