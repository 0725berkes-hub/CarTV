import SwiftUI

/// The TikTok tab. Signed out → a sign-in card. Signed in → full-screen vertical
/// pager over For You / Following, one video per page, swipe up for the next.
///
/// Playback goes through the app's single PlaybackController, so the car screen,
/// the mini bar, the lock screen and Siri all see the same video. The pager's
/// job is just to say which item is current and keep the buffer topped up.
struct TTFeedView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @State private var feed: TikTokService.Feed = .forYou
    @State private var showSignIn = false
    @State private var index = 0
    @State private var showCreator: TTAuthor?

    var body: some View {
        let tt = env.tiktok
        ZStack {
            Color.black.ignoresSafeArea()
            if !tt.session.isSignedIn {
                signedOut
            } else {
                pager(tt)
                overlayChrome(tt)
            }
        }
        // Pages must be sized to the whole screen, not the tab-bar-inset area; the
        // tab bar floats over the bottom of the video like TikTok's own.
        .ignoresSafeArea()
        .sheet(isPresented: $showSignIn) { TTSignInView() }
        .sheet(item: $showCreator) { a in NavigationStack { TTCreatorView(author: a) } }
        .onChange(of: tt.pendingSignInPrompt, initial: true) { _, p in
            if p, !tt.session.isSignedIn { tt.pendingSignInPrompt = false; showSignIn = true }
        }
        .task(id: tt.session.isSignedIn) {
            if tt.session.isSignedIn, tt.forYou.isEmpty { tt.loadMore(.forYou) }
        }
        .statusBarHidden(tt.session.isSignedIn)
        .preferredColorScheme(.dark)
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(spacing: Theme.s5) {
            Spacer()
            TikTokMark(size: 72)
            Text("Your For You page, in CarFlix").font(Theme.Font.title).foregroundStyle(.white).multilineTextAlignment(.center)
            Text("Sign in to tiktok.com once. CarFlix keeps the session and shows your personal feed — on the phone and on the car screen. Nothing is posted or liked on your behalf.")
                .font(Theme.Font.body).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button { showSignIn = true } label: {
                Label("Sign in to TikTok", systemImage: "person.crop.circle").font(Theme.Font.headline)
                    .frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.glassProminent).tint(.white).foregroundStyle(.black)
            .frame(maxWidth: 340)
            Spacer(); Spacer()
        }
        .padding(Theme.s6)
    }

    // MARK: Pager

    private func pager(_ tt: TikTokService) -> some View {
        let items = tt.items(for: feed)
        return GeometryReader { geo in
            if items.isEmpty {
                VStack(spacing: Theme.s3) {
                    ProgressView().tint(.white)
                    Text(tt.error ?? String(localized: "Loading your feed…")).font(Theme.Font.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    if tt.error != nil {
                        Button("Retry") { tt.loadMore(feed) }.buttonStyle(.glass)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // UIKit vertical paging scroll view: page size == its own bounds, which we
                // pin to the full screen. No rotation tricks, no safe-area drift.
                VerticalPager(count: items.count, index: $index) { i in
                    TTPage(video: items[i], isCurrent: i == index, size: geo.size, onCreator: { showCreator = items[i].author })
                        // UIHostingController pages don't inherit the SwiftUI environment.
                        .environment(env)
                        .environment(playback)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: index, initial: true) { _, i in
                    guard items.indices.contains(i) else { return }
                    play(items[i], queue: items, tt: tt)
                    tt.prefetchIfNeeded(feed, index: i)
                }
                .onChange(of: items.count) { _, _ in
                    if playback.current?.ref.kind != .tiktok, items.indices.contains(index) { play(items[index], queue: items, tt: tt) }
                }
                .onChange(of: playback.current?.id) { _, id in
                    // Player moved (car Next / auto-advance) → follow it in the pager.
                    guard let id, let i = items.firstIndex(where: { $0.playableID == id }), i != index else { return }
                    index = i
                    tt.prefetchForPlayer()
                }
            }
        }
        .ignoresSafeArea()
    }

    private func play(_ v: TTVideo, queue: [TTVideo], tt: TikTokService) {
        guard playback.current?.id != v.playableID else { return }
        Task { @MainActor in
            // Queue = the whole loaded feed, so car next/prev and auto-advance walk the same list.
            let q = await tt.proxiedQueue(queue)
            guard let item = q.first(where: { $0.id == v.playableID }), playback.current?.id != item.id else { return }
            tt.playerStarted(feed: feed)
            playback.play(item, queue: q, origin: .phone, resume: false, presentPlayer: false)
        }
    }

    // MARK: Chrome (segments + settings)

    private func overlayChrome(_ tt: TikTokService) -> some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 0) {
                    ForEach(TikTokService.Feed.allCases) { f in
                        Button { withAnimation(.snappy(duration: 0.25)) { feed = f; index = 0 }; if tt.items(for: f).isEmpty { tt.loadMore(f) } } label: {
                            Text(f.title)
                                .font(.system(size: 15, weight: feed == f ? .bold : .semibold))
                                .foregroundStyle(feed == f ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(alignment: .bottom) {
                                    if feed == f { Capsule().fill(.white).frame(width: 24, height: 2.5).offset(y: 2) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Menu {
                    if case .signedIn(let h) = tt.session.state, let h { Text("@\(h)") }
                    Button(role: .destructive) { tt.signOut(); playback.stop() } label: { Label("Sign out of TikTok", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).contentShape(Circle())
                }
                .padding(.trailing, Theme.s3)
            }
            .padding(.top, 54)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140).ignoresSafeArea(), alignment: .top)
            // If the hidden page isn't logged in, this is TikTok's generic feed, not yours.
            if tt.engine.isReady, tt.pageUser == nil {
                Button { showSignIn = true } label: {
                    Label("Not signed in on TikTok — this isn't your For You. Tap to sign in.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.amber, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            Spacer()
        }
        .ignoresSafeArea()
    }
}

// MARK: - One page

/// Video (hosted from the shared engine when current, cover otherwise) + the
/// TikTok-style right rail and bottom caption. Tap toggles pause.
private struct TTPage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let video: TTVideo
    let isCurrent: Bool
    let size: CGSize
    let onCreator: () -> Void
    @State private var showPauseGlyph = false

    var body: some View {
        ZStack {
            // Cover always underneath — instant paint while the MP4 buffers, and what
            // the non-current pages show.
            RemoteImage(url: video.coverURL, targetSize: CGSize(width: 720, height: 1280), contentMode: .fill) { Color.black }
                .frame(width: size.width, height: size.height).clipped()

            if isCurrent {
                PhoneVideoSurface()
                    .id("tt-\(playback.videoViewRevision)")
                    .frame(width: size.width, height: size.height)
                    // Cover shows through until the first frame; no black gap.
                    .opacity(playback.snapshot.state == .loading ? 0 : 1)
                    .animation(.easeOut(duration: 0.25), value: playback.snapshot.state == .loading)
                if playback.snapshot.state == .loading || playback.snapshot.state == .buffering {
                    VStack { LoadingLine().padding(.top, 58); Spacer() }.allowsHitTesting(false)
                }
            }

            // Tap to pause/resume with a fading glyph, like the real thing.
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    playback.togglePlayPause()
                    withAnimation(.easeOut(duration: 0.15)) { showPauseGlyph = true }
                    Task { try? await Task.sleep(for: .milliseconds(700)); withAnimation { showPauseGlyph = false } }
                }
            if showPauseGlyph || (isCurrent && playback.snapshot.state == .paused) {
                Image(systemName: playback.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 64, weight: .bold)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 12)
                    .transition(.scale.combined(with: .opacity))
            }

            // Bottom scrim + caption + right rail
            VStack(spacing: 0) {
                Spacer()
                HStack(alignment: .bottom, spacing: Theme.s3) {
                    caption
                    Spacer(minLength: 0)
                    rail
                }
                .padding(.horizontal, Theme.s3)
                .padding(.bottom, 96)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 320), alignment: .bottom)
            }

            // Thin progress line at the very bottom
            if isCurrent, playback.snapshot.duration > 0 {
                VStack { Spacer(); ProgressBar(fraction: playback.snapshot.position / playback.snapshot.duration, height: 2).padding(.bottom, 84) }
            }
        }
        .clipped()
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onCreator) {
                Text("@\(video.author.uniqueID)").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if !video.desc.isEmpty {
                Text(video.desc).font(.system(size: 14.5)).foregroundStyle(.white).lineLimit(3)
            }
            if let m = video.music {
                HStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                    Text(m.original ? "Original sound · \(m.authorName)" : "\(m.title) · \(m.authorName)").lineLimit(1)
                }
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    private var rail: some View {
        VStack(spacing: Theme.s4) {
            Button(action: onCreator) {
                ZStack {
                    Circle().fill(TileTint.gradient(for: video.author.uniqueID))
                    RemoteImage(url: video.author.avatarURL, targetSize: CGSize(width: 120, height: 120), contentMode: .fill) { Monogram(text: video.author.nickname, size: 14) }
                        .frame(width: 46, height: 46).clipShape(Circle())
                    Circle().strokeBorder(.white, lineWidth: 1.5)
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)

            railStat("heart.fill", video.stats.likes)
            railStat("bubble.right.fill", video.stats.comments)
            railStat("arrowshape.turn.up.right.fill", video.stats.shares)

            let item = env.tiktok.playable(video)
            let fav = env.favorites.isFavorite(item)
            Button {
                env.favorites.toggle(item.ref)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: fav ? "bookmark.fill" : "bookmark").font(.system(size: 26, weight: .semibold)).foregroundStyle(fav ? Theme.accent : .white)
                    Text(fav ? "Saved" : "Save").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button { UIPasteboard.general.url = video.webURL } label: { Label("Copy link", systemImage: "link") }
                Button { UIApplication.shared.open(video.webURL) } label: { Label("Open in TikTok", systemImage: "arrow.up.right.square") }
                if let dl = video.downloadURL ?? Optional(video.playURL) {
                    Button { env.tiktok.saveToLibrary(video, from: dl) } label: { Label("Save to Videos", systemImage: "arrow.down.circle") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 40)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    private func railStat(_ symbol: String, _ n: Int) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            Text(n.compact).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

// MARK: - Bits

struct TikTokMark: View {
    var size: CGFloat = 40
    var body: some View {
        // Simplified note glyph in the brand's cyan/red offset — no trademark asset needed.
        ZStack {
            Image(systemName: "music.note").font(.system(size: size, weight: .black)).foregroundStyle(Color(red: 0.16, green: 0.96, blue: 0.93)).offset(x: -2, y: -2)
            Image(systemName: "music.note").font(.system(size: size, weight: .black)).foregroundStyle(Color(red: 1.0, green: 0.17, blue: 0.33)).offset(x: 2, y: 2)
            Image(systemName: "music.note").font(.system(size: size, weight: .black)).foregroundStyle(.white)
        }
    }
}

extension Int {
    /// 12_300 → "12.3K", 4_500_000 → "4.5M"
    var compact: String {
        switch self {
        case ..<1_000: return "\(self)"
        case ..<1_000_000: return String(format: "%.1fK", Double(self) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        default: return String(format: "%.1fM", Double(self) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}

// MARK: - Vertical pager (UIKit)

/// Full-bleed vertical paging, the way TikTok does it: a UIScrollView with
/// isPagingEnabled whose page height is exactly its own bounds. Only the current
/// page and its two neighbours are realised; the rest are recycled.
struct VerticalPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    @ViewBuilder let page: (Int) -> Page

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ vc: Controller, context: Context) {
        vc.count = count
        vc.makePage = { i in AnyView(page(i)) }
        vc.onIndexChange = { i in if index != i { index = i } }
        vc.reload(scrollTo: index)
    }

    final class Controller: UIViewController, UIScrollViewDelegate {
        var count = 0
        var makePage: ((Int) -> AnyView)?
        var onIndexChange: ((Int) -> Void)?

        private let scroll = UIScrollView()
        private var hosts: [Int: UIHostingController<AnyView>] = [:]
        private var current = 0
        private var lastLaidOutHeight: CGFloat = 0

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            scroll.isPagingEnabled = true
            scroll.showsVerticalScrollIndicator = false
            scroll.contentInsetAdjustmentBehavior = .never   // the whole point: page == bounds
            scroll.bounces = true
            scroll.delegate = self
            scroll.frame = view.bounds
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scroll)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let h = view.bounds.height
            scroll.contentSize = CGSize(width: view.bounds.width, height: h * CGFloat(count))
            if h != lastLaidOutHeight {
                lastLaidOutHeight = h
                for (i, host) in hosts { host.view.frame = frame(for: i) }
                scroll.setContentOffset(CGPoint(x: 0, y: h * CGFloat(current)), animated: false)
            }
        }

        func reload(scrollTo target: Int) {
            let h = view.bounds.height
            scroll.contentSize = CGSize(width: view.bounds.width, height: h * CGFloat(count))
            if target != current, h > 0 {
                current = target
                scroll.setContentOffset(CGPoint(x: 0, y: h * CGFloat(target)), animated: false)
            }
            realise(around: current)
        }

        private func frame(for i: Int) -> CGRect {
            CGRect(x: 0, y: view.bounds.height * CGFloat(i), width: view.bounds.width, height: view.bounds.height)
        }

        /// Keep pages i-1…i+1 mounted; drop the rest. Re-render the mounted ones.
        private func realise(around i: Int) {
            let want = Set((max(0, i - 1)...min(count - 1, i + 1)).filter { $0 < count })
            for (k, host) in hosts where !want.contains(k) {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                hosts.removeValue(forKey: k)
            }
            for k in want {
                guard let make = makePage else { continue }
                if let host = hosts[k] {
                    host.rootView = make(k)
                } else {
                    let host = UIHostingController(rootView: make(k))
                    host.view.backgroundColor = .black
                    host.view.frame = frame(for: k)
                    addChild(host); scroll.addSubview(host.view); host.didMove(toParent: self)
                    hosts[k] = host
                }
            }
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) { settle() }
        func scrollViewDidEndScrollingAnimation(_ sv: UIScrollView) { settle() }
        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }

        private func settle() {
            let h = scroll.bounds.height
            guard h > 0 else { return }
            let i = Int((scroll.contentOffset.y / h).rounded())
            let clamped = max(0, min(count - 1, i))
            if clamped != current { current = clamped; onIndexChange?(clamped) }
            realise(around: clamped)
        }
    }
}
