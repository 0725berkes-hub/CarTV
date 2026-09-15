import SwiftUI

// MARK: - Search

struct YTSuggestions: View {
    @Environment(AppEnvironment.self) private var env
    let query: String
    let pick: (String) -> Void
    @State private var items: [String] = []
    var body: some View {
        ForEach(items, id: \.self) { s in
            Button { pick(s) } label: { Label(s, systemImage: "magnifyingglass") }
        }
        .task(id: query) {
            guard query.count >= 2 else { items = []; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            items = await env.youtube.suggestions(query)
        }
    }
}

struct YTSearchResults: View {
    @Environment(AppEnvironment.self) private var env
    let query: String
    @State private var page: YTPage?
    @State private var error: String?
    @State private var loadingMore = false

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    LazyVStack(spacing: Theme.s4) {
                        ForEach(page.flatItems) { item in
                            switch item {
                            case .video(let v): YTVideoCard(video: v, compact: true).padding(.horizontal, Theme.s4)
                            case .channel(let c): YTChannelRow(channel: c).padding(.horizontal, Theme.s4)
                            case .playlist(let p): YTPlaylistCard(playlist: p).padding(.horizontal, Theme.s4)
                            }
                        }
                        if page.continuation != nil { ProgressView().padding().task { await more() } }
                    }
                    .padding(.vertical, Theme.s2).padding(.bottom, Theme.s10)
                }
            } else if let error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't search", message: LocalizedStringResource(stringLiteral: error))
            } else { YTSkeletonFeed() }
        }
        .task(id: query) {
            page = nil; error = nil
            do { page = try await env.youtube.search(query) } catch { self.error = error.localizedDescription }
        }
    }

    private func more() async {
        guard !loadingMore, let c = page?.continuation else { return }
        loadingMore = true
        if let m = try? await env.youtube.search(query, continuation: c) { page?.shelves.append(contentsOf: m.shelves); page?.continuation = m.continuation } else { page?.continuation = nil }
        loadingMore = false
    }
}

// MARK: - Channel

struct YTChannelView: View {
    @Environment(AppEnvironment.self) private var env
    let channel: YTChannel
    @State private var header: YTChannel?
    @State private var tab: YouTubeService.ChannelTab = .videos
    @State private var subscribed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4) {
                if let banner = (header ?? channel).bannerURL {
                    RemoteImage(url: banner, targetSize: CGSize(width: 1280, height: 360), contentMode: .fill) { Theme.raised }
                        .frame(height: 96).clipped()
                }
                HStack(spacing: Theme.s3) {
                    RemoteImage(url: (header ?? channel).avatarURL, targetSize: CGSize(width: 200, height: 200), contentMode: .fill) { Circle().fill(Theme.raised) }
                        .frame(width: 72, height: 72).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text((header ?? channel).name).font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                        Text([(header ?? channel).handle, (header ?? channel).subscribersText, (header ?? channel).videoCountText].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.s4)

                Button {
                    subscribed.toggle()
                    Task { try? await env.youtube.subscribe(channel.id, undo: !subscribed) }
                } label: {
                    Text(subscribed ? "Subscribed" : "Subscribe").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(subscribed ? AnyButtonStyle(.glass) : AnyButtonStyle(.glassProminent))
                .buttonBorderShape(.capsule)
                .tint(subscribed ? nil : Theme.ink).foregroundStyle(subscribed ? Theme.ink : Theme.ground)
                .padding(.horizontal, Theme.s4)

                Picker("", selection: $tab) {
                    Text("Videos").tag(YouTubeService.ChannelTab.videos)
                    Text("Live").tag(YouTubeService.ChannelTab.live)
                    Text("Playlists").tag(YouTubeService.ChannelTab.playlists)
                }
                .pickerStyle(.segmented).padding(.horizontal, Theme.s4)

                YTFeedView(feed: .channel(channel.id, tab: tab)).id(tab)
                    .frame(minHeight: 400)
            }
            .padding(.bottom, Theme.s10)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if let (h, _) = try? await env.youtube.channel(channel.id) { header = h; subscribed = h.isSubscribed ?? false } }
    }
}

// MARK: - Playlist

struct YTPlaylistView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let playlist: YTPlaylist
    @State private var page: YTPage?

    private var videos: [YTVideo] { page?.flatItems.compactMap { if case .video(let v) = $0 { return v } else { return nil } } ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s4) {
                HStack(spacing: Theme.s2) {
                    Button { playAll(shuffle: false) } label: { Label("Play all", systemImage: "play.fill").font(.subheadline.weight(.semibold)).frame(height: 40).padding(.horizontal, 8) }
                        .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Theme.accent).foregroundStyle(.black)
                    Button { playAll(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").font(.subheadline.weight(.semibold)).frame(height: 40).padding(.horizontal, 8) }
                        .buttonStyle(.glass).buttonBorderShape(.capsule)
                    Spacer()
                    Text(playlist.videoCountText ?? "").font(.footnote).foregroundStyle(Theme.inkMuted)
                }
                .padding(.horizontal, Theme.s4)
                .disabled(videos.isEmpty)

                ForEach(videos) { v in YTVideoCard(video: v, queue: videos, compact: true).padding(.horizontal, Theme.s4) }
                if page?.continuation != nil { ProgressView().padding().task { await more() } }
            }
            .padding(.vertical, Theme.s2).padding(.bottom, Theme.s10)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(page?.shelves.first?.title ?? playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { page = try? await env.youtube.fetch(.playlist(playlist.id)) }
        .overlay { if page == nil { YTSkeletonFeed() } }
    }

    private func playAll(shuffle: Bool) {
        let list = shuffle ? videos.shuffled() : videos
        guard let first = list.first else { return }
        list.forEach { env.youtube.remember($0) }
        Task {
            if let r = try? await env.youtube.resolve(first) {
                let rest = list.dropFirst().compactMap { env.youtube.cachedStub($0.id) }
                playback.play(r.item, queue: [r.item] + rest, origin: .phone)
                if shuffle { playback.shuffle = true }
            }
        }
    }

    private func more() async {
        guard let c = page?.continuation, let m = try? await env.youtube.fetch(.playlist(playlist.id), continuation: c) else { page?.continuation = nil; return }
        page?.shelves.append(contentsOf: m.shelves); page?.continuation = m.continuation
    }
}

// MARK: - Library

struct YTLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        if !env.youtube.auth.isSignedIn {
            YTSignInPrompt()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s5) {
                    VStack(spacing: 0) {
                        libraryRow("clock.arrow.circlepath", "History", .history)
                        Divider().padding(.leading, 56)
                        libraryRow("clock", "Watch Later", .watchLater)
                        Divider().padding(.leading, 56)
                        libraryRow("hand.thumbsup", "Liked videos", .liked)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                    .padding(.horizontal, Theme.s4)

                    ShelfHeader(title: "Playlists")
                    YTFeedView(feed: .library).frame(minHeight: 200)
                }
                .padding(.vertical, Theme.s2)
            }
        }
    }

    private func libraryRow(_ symbol: String, _ title: LocalizedStringResource, _ feed: YouTubeService.Feed) -> some View {
        NavigationLink { YTFeedView(feed: feed).navigationTitle(Text(title)).background(Theme.ground.ignoresSafeArea()) } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 32)
                Text(title).font(.body).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, Theme.s3).frame(height: 48)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account / sign-in

struct YTSignInPrompt: View {
    @State private var show = false
    var body: some View {
        EmptyState(symbol: "person.crop.circle.badge.checkmark", title: "Sign in to YouTube",
                   message: "See your subscriptions, playlists, history and personalised recommendations.",
                   actionTitle: "Sign in") { show = true }
            .sheet(isPresented: $show) { YTAccountSheet() }
    }
}

struct YTAccountSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.s6) {
                let auth = env.youtube.auth
                switch auth.state {
                case .signedIn:
                    if let url = auth.accountAvatarURL {
                        RemoteImage(url: url, targetSize: CGSize(width: 200, height: 200), contentMode: .fill) { Circle().fill(Theme.raised) }
                            .frame(width: 88, height: 88).clipShape(Circle())
                    } else { Image(systemName: "person.crop.circle.fill").font(.system(size: 72)).foregroundStyle(Theme.inkMuted) }
                    Text(auth.accountName ?? "Signed in").font(.title2.weight(.semibold))
                    Button(role: .destructive) { auth.signOut(); dismiss() } label: { Text("Sign out").frame(maxWidth: .infinity).frame(height: 44) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)

                case .awaitingCode(let code, let url):
                    Text("Go to").font(.subheadline).foregroundStyle(.secondary)
                    Text(url.host ?? "google.com/device").font(.title3.weight(.semibold))
                    Text("and enter this code").font(.subheadline).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).tracking(4)
                        .padding(.horizontal, Theme.s5).padding(.vertical, Theme.s3)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                    HStack(spacing: Theme.s2) {
                        Button { UIPasteboard.general.string = code } label: { Label("Copy code", systemImage: "doc.on.doc").frame(height: 44).padding(.horizontal, 8) }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                        Button { openURL(url) } label: { Label("Open in browser", systemImage: "safari").frame(height: 44).padding(.horizontal, 8) }
                            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Theme.accent).foregroundStyle(.black)
                    }
                    ProgressView().padding(.top)
                    Text("Waiting for you to approve…").font(.footnote).foregroundStyle(.secondary)

                case .signedOut:
                    Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundStyle(Theme.live)
                    Text("Sign in with Google").font(.title2.weight(.semibold))
                    Text("You'll get a short code to enter on any browser. No password is typed here.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let e = auth.error { Text(e).font(.footnote).foregroundStyle(Theme.amber) }
                    Button { auth.beginSignIn() } label: { Text("Get code").frame(maxWidth: .infinity).frame(height: 48) }
                        .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Theme.accent).foregroundStyle(.black)
                }
            }
            .padding(Theme.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("YouTube Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { env.youtube.auth.cancelSignIn(); dismiss() } } }
            .onChange(of: env.youtube.auth.state) { _, s in if s == .signedIn { dismiss() } }
        }
        .presentationDetents([.large])
    }
}
