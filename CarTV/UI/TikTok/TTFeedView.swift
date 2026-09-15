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
    /// Remembered position per feed, so switching Saved → For You → Saved comes back where you were.
    @State private var indices: [TikTokService.Feed: Int] = [:]
    @State private var showCreator: TTAuthor?
    @State private var muted = false

    private var index: Binding<Int> {
        Binding(get: { indices[feed] ?? 0 }, set: { indices[feed] = $0 })
    }

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
        let idx = index
        return GeometryReader { geo in
            if items.isEmpty {
                emptyState(tt, feed: feed)
            } else {
                // UIKit vertical paging scroll view: page size == its own bounds, which we
                // pin to the full screen. No rotation tricks, no safe-area drift.
                VerticalPager(count: items.count, index: idx, onRefresh: { refreshFeed(tt) }) { i in
                    TTPage(video: items[i], isCurrent: i == idx.wrappedValue, size: geo.size, muted: $muted,
                           onCreator: { showCreator = items[i].author })
                        // UIHostingController pages don't inherit the SwiftUI environment.
                        .environment(env)
                        .environment(playback)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .id(feed)   // fresh scroll view per feed; each keeps its own remembered index
                .transition(.opacity)
                .onChange(of: idx.wrappedValue, initial: true) { _, i in
                    guard items.indices.contains(i) else { return }
                    tt.playInline(items[i], from: feed, queue: items)
                    tt.prefetchIfNeeded(feed, index: i)
                }
                .onChange(of: items.count) { _, _ in
                    let i = idx.wrappedValue
                    if playback.current?.ref.kind != .tiktok, items.indices.contains(i) { tt.playInline(items[i], from: feed, queue: items) }
                }
                .onChange(of: playback.current?.id) { _, id in
                    // Player moved (car Next / auto-advance) → follow it in the pager.
                    guard let id, let i = items.firstIndex(where: { $0.playableID == id }), i != idx.wrappedValue else { return }
                    idx.wrappedValue = i
                    tt.prefetchForPlayer()
                }
            }
        }
        .ignoresSafeArea()
    }

    private func emptyState(_ tt: TikTokService, feed: TikTokService.Feed) -> some View {
        VStack(spacing: Theme.s3) {
            if let err = tt.error {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text(err).font(Theme.Font.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 300)
                Button("Retry") { tt.loadMore(feed) }.buttonStyle(.glass)
            } else if !tt.loading.contains(feed), feed == .saved || feed == .liked {
                Image(systemName: feed == .saved ? "bookmark" : "heart").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text(feed == .saved ? "Nothing saved yet" : "No liked videos yet").font(Theme.Font.headline).foregroundStyle(.white)
                Text(feed == .liked ? "Liked videos are private on TikTok unless you make them visible in your privacy settings." : "Videos you save on TikTok show up here, newest first.")
                    .font(Theme.Font.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 300)
            } else {
                LoadingLine().frame(width: 120)
                Text("Loading \(String(localized: feed.title))…").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chrome (segments + settings)

    private func overlayChrome(_ tt: TikTokService) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    ForEach(TikTokService.Feed.allCases) { f in
                        Button {
                            guard f != feed else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.snappy(duration: 0.22)) { feed = f }
                            if tt.items(for: f).isEmpty { tt.loadMore(f) }
                        } label: {
                            Text(f.title)
                                .font(.system(size: 15.5, weight: feed == f ? .bold : .semibold))
                                .foregroundStyle(feed == f ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .overlay(alignment: .bottom) {
                                    if feed == f { Capsule().fill(.white).frame(width: 22, height: 2.5).offset(y: 2).matchedGeometryEffect(id: "ttseg", in: segNS) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .overlay(alignment: .leading) {
                // Refresh: a fresh batch for this feed, back to the top.
                Button { refreshFeed(tt) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .rotationEffect(.degrees(refreshSpin))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(tt.loading.contains(feed) && tt.items(for: feed).isEmpty)
                .padding(.leading, Theme.s2)
            }
            .overlay(alignment: .trailing) {
                Menu {
                    if case .signedIn(let h) = tt.session.state, let h { Text("@\(h)") }
                    Button { refreshFeed(tt) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Toggle(isOn: $muted) { Label("Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2") }
                    Divider()
                    Button(role: .destructive) { tt.signOut(); playback.stop() } label: { Label("Sign out of TikTok", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .padding(.trailing, Theme.s2)
            }
            .padding(.top, 54)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).ignoresSafeArea(), alignment: .top)
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
    @Namespace private var segNS
    @State private var refreshSpin: Double = 0

    private func refreshFeed(_ tt: TikTokService) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
        indices[feed] = 0
        Task { await tt.refresh(feed) }
    }
}

// MARK: - One page

/// Video (hosted from the shared engine when current, cover otherwise) + the
/// TikTok-style right rail and bottom caption. Tap pauses, double-tap saves,
/// long-press opens the actions sheet.
private struct TTPage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let video: TTVideo
    let isCurrent: Bool
    let size: CGSize
    @Binding var muted: Bool
    let onCreator: () -> Void
    @State private var showPauseGlyph = false
    @State private var heartBurst: CGPoint?
    @State private var expandCaption = false
    @State private var showActions = false

    private var showsVideo: Bool { isCurrent && playback.snapshot.state != .loading }

    var body: some View {
        ZStack {
            // Cover always underneath — instant paint while the MP4 buffers, and what
            // the non-current pages show. Blurred fill behind so a landscape clip sits on
            // its own colours, not black.
            RemoteImage(url: video.coverURL, targetSize: CGSize(width: 540, height: 960), contentMode: .fill) { Color.black }
                .frame(width: size.width, height: size.height).clipped()
                .blur(radius: 30).opacity(0.7)
            RemoteImage(url: video.coverURL, targetSize: CGSize(width: 720, height: 1280), contentMode: .fit) { Color.clear }
                .frame(width: size.width, height: size.height)

            if isCurrent {
                PhoneVideoSurface()
                    .id("tt-\(playback.videoViewRevision)")
                    .frame(width: size.width, height: size.height)
                    // Cover shows through until the first frame; no black gap.
                    .opacity(showsVideo ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showsVideo)
                if playback.snapshot.state == .loading || playback.snapshot.state == .buffering {
                    VStack { LoadingLine().padding(.top, 58); Spacer() }.allowsHitTesting(false).transition(.opacity)
                }
            }

            // Gestures: single tap pause, double tap save (heart burst), long press actions.
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { p in
                    let item = env.tiktok.playable(video)
                    if !env.favorites.isFavorite(item) { env.favorites.toggle(item.ref) }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(duration: 0.3, bounce: 0.4)) { heartBurst = p }
                    Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(.easeOut(duration: 0.25)) { heartBurst = nil } }
                }
                .onTapGesture(count: 1) {
                    playback.togglePlayPause()
                    withAnimation(.easeOut(duration: 0.15)) { showPauseGlyph = true }
                    Task { try? await Task.sleep(for: .milliseconds(600)); withAnimation { showPauseGlyph = false } }
                }
                .onLongPressGesture(minimumDuration: 0.45) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    showActions = true
                }
            if let p = heartBurst {
                Image(systemName: "heart.fill").font(.system(size: 92, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.17, blue: 0.33)).shadow(radius: 12)
                    .rotationEffect(.degrees(Double.random(in: -14...14)))
                    .position(p).transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if showPauseGlyph || (isCurrent && playback.snapshot.state == .paused) {
                Image(systemName: playback.snapshot.state == .paused ? "play.fill" : "pause.fill")
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
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 360), alignment: .bottom)
            }

            // Thin progress line at the very bottom
            if isCurrent, playback.snapshot.duration > 0 {
                VStack { Spacer(); ProgressBar(fraction: playback.snapshot.position / playback.snapshot.duration, height: 2).padding(.bottom, 84) }
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .confirmationDialog("@\(video.author.uniqueID)", isPresented: $showActions, titleVisibility: .visible) { actionButtons }
        .onChange(of: muted, initial: true) { _, m in if isCurrent { playback.setMuted(m) } }
        .onChange(of: isCurrent) { _, cur in if cur { playback.setMuted(muted) } }
    }

    @ViewBuilder private var actionButtons: some View {
        let item = env.tiktok.playable(video)
        let fav = env.favorites.isFavorite(item)
        Button(fav ? "Remove from Saved" : "Save to Favorites") { env.favorites.toggle(item.ref) }
        Button("Save video to Library") { env.tiktok.saveToLibrary(video, from: video.downloadURL ?? video.playURL) }
        Button("Copy link") { UIPasteboard.general.url = video.webURL }
        Button("Open in TikTok") { UIApplication.shared.open(video.webURL) }
        Button("View @\(video.author.uniqueID)") { onCreator() }
        Button("Cancel", role: .cancel) {}
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onCreator) {
                HStack(spacing: 5) {
                    Text("@\(video.author.uniqueID)").font(.system(size: 16, weight: .bold))
                    if video.author.verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(Color(red: 0.16, green: 0.72, blue: 0.96)) }
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if !video.desc.isEmpty {
                Text(video.desc).font(.system(size: 14.5)).foregroundStyle(.white)
                    .lineLimit(expandCaption ? 12 : 2)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { expandCaption.toggle() } }
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
                        .contentTransition(.symbolEffect(.replace))
                    Text(fav ? "Saved" : "Save").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            Button { showActions = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
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
///
/// Feel: the index flips the moment the finger lifts (from the projected landing
/// page), so the next video is already starting while the page glides into place.
/// Over-scrolling past the first page pulls to refresh.
struct VerticalPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    var onRefresh: (() -> Void)? = nil
    @ViewBuilder let page: (Int) -> Page

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ vc: Controller, context: Context) {
        vc.makePage = { i in AnyView(page(i)) }
        vc.onIndexChange = { i in if index != i { index = i } }
        vc.onRefresh = onRefresh
        // Only touch the scroll view when the data or the target actually changed;
        // SwiftUI re-runs this on every playback tick.
        vc.apply(count: count, index: index)
    }

    final class Controller: UIViewController, UIScrollViewDelegate {
        var makePage: ((Int) -> AnyView)?
        var onIndexChange: ((Int) -> Void)?
        var onRefresh: (() -> Void)?

        private let scroll = UIScrollView()
        private var hosts: [Int: UIHostingController<AnyView>] = [:]
        private var count = 0
        private var current = 0
        private var lastLaidOutHeight: CGFloat = 0
        private var refreshArmed = false
        private let refreshSpinner = UIActivityIndicatorView(style: .medium)

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            scroll.isPagingEnabled = true
            scroll.showsVerticalScrollIndicator = false
            scroll.contentInsetAdjustmentBehavior = .never   // the whole point: page == bounds
            scroll.bounces = true
            scroll.alwaysBounceVertical = true
            scroll.decelerationRate = .fast
            scroll.delaysContentTouches = false
            scroll.delegate = self
            scroll.frame = view.bounds
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scroll)
            refreshSpinner.color = .white
            refreshSpinner.hidesWhenStopped = true
            view.addSubview(refreshSpinner)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let h = view.bounds.height
            scroll.contentSize = CGSize(width: view.bounds.width, height: h * CGFloat(count))
            refreshSpinner.center = CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + 70)
            if h != lastLaidOutHeight {
                lastLaidOutHeight = h
                for (i, host) in hosts { host.view.frame = frame(for: i) }
                scroll.setContentOffset(CGPoint(x: 0, y: h * CGFloat(current)), animated: false)
            }
        }

        func apply(count newCount: Int, index target: Int) {
            let countChanged = newCount != count
            count = newCount
            let h = view.bounds.height
            if countChanged { scroll.contentSize = CGSize(width: view.bounds.width, height: h * CGFloat(count)) }
            if target != current, h > 0 {
                current = target
                // Programmatic jump (car Next, feed switch): a short slide, not a teleport.
                if !scroll.isTracking, !scroll.isDecelerating {
                    scroll.setContentOffset(CGPoint(x: 0, y: h * CGFloat(target)), animated: false)
                }
                realise(around: current)
            } else if countChanged {
                realise(around: current)
            } else if hosts.isEmpty, count > 0 {
                realise(around: current)
            }
            if countChanged { refreshSpinner.stopAnimating() }
        }

        private func frame(for i: Int) -> CGRect {
            CGRect(x: 0, y: view.bounds.height * CGFloat(i), width: view.bounds.width, height: view.bounds.height)
        }

        /// Keep pages i-1…i+1 mounted; drop the rest. Re-render the mounted ones so
        /// `isCurrent` flips.
        private func realise(around i: Int) {
            guard count > 0 else {
                for (_, host) in hosts { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
                hosts.removeAll(); return
            }
            let want = Set((max(0, i - 1)...min(count - 1, i + 1)))
            for (k, host) in hosts where !want.contains(k) {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                hosts.removeValue(forKey: k)
            }
            for k in want.sorted() {
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

        // MARK: Scroll delegate

        func scrollViewDidScroll(_ sv: UIScrollView) {
            // Pull past the top on the first page → arm refresh.
            if current == 0, sv.isTracking {
                let pulled = -sv.contentOffset.y
                if pulled > 90, !refreshArmed { refreshArmed = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                if pulled < 10 { refreshArmed = false }
            }
        }

        func scrollViewWillEndDragging(_ sv: UIScrollView, withVelocity v: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let h = sv.bounds.height
            guard h > 0 else { return }
            if refreshArmed, current == 0, onRefresh != nil {
                refreshArmed = false
                refreshSpinner.startAnimating()
                onRefresh?()
            }
            // Commit to the page we'll land on now, so the video starts during the glide.
            let target = max(0, min(count - 1, Int((targetContentOffset.pointee.y / h).rounded())))
            if target != current {
                current = target
                onIndexChange?(target)
                realise(around: target)
            }
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) { settle() }
        func scrollViewDidEndScrollingAnimation(_ sv: UIScrollView) { settle() }
        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }

        private func settle() {
            let h = scroll.bounds.height
            guard h > 0, count > 0 else { return }
            let i = max(0, min(count - 1, Int((scroll.contentOffset.y / h).rounded())))
            if i != current { current = i; onIndexChange?(i) }
            realise(around: i)
        }
    }
}
