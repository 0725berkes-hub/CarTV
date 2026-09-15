import SwiftUI

/// First-launch welcome, built for activation: get the user to a populated Home
/// in under a minute.
///
/// Design: one dark stage, a slow-drifting mesh of the page's colour behind it,
/// and instead of an icon in a square, each feature page shows a miniature of
/// the real product — a channel grid, a YouTube feed, a Continue Watching row,
/// a folder of videos — inside a stylised car display. The last page is a
/// single glass card with two pre-selected switches and one big button.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    let finish: () -> Void

    @State private var page = 0
    @State private var enableMyTV = true
    @State private var wantsYouTube = true
    @State private var heroIn = false

    private let pages: [Page] = [
        .init(kind: .hero, tint: Theme.accent,
              eyebrow: "CarFlix", title: "Your car just\ngot a TV",
              body: "Live channels, YouTube, movies, series and your own videos — on your iPhone and on the CarPlay screen.",
              proof: ["Free", "No account needed", "Works offline"]),
        .init(kind: .channels, tint: Color(hue: 0.60, saturation: 0.65, brightness: 0.98),
              eyebrow: "LIVE TV", title: "360+ channels,\nready now",
              body: "News, sports, kids, music and movies in Kurdish, Arabic and English — sorted for you. Or add any M3U or Xtream playlist.",
              proof: ["Built-in CarFlix+", "One tap to turn on"]),
        .init(kind: .youtube, tint: Color(red: 1.0, green: 0.0, blue: 0.0),
              eyebrow: "YOUTUBE", title: "YouTube on\nthe dash",
              body: "Your subscriptions, Watch Later and playlists, playable in the car. Sign in with Google to see your feed, or just browse.",
              proof: ["Subscriptions", "Watch Later", "Quality picker"]),
        .init(kind: .movies, tint: Color(hue: 0.83, saturation: 0.55, brightness: 0.98),
              eyebrow: "MOVIES & SERIES", title: "Picks up where\nyou stopped",
              body: "12,000+ movies and 8,000+ series. Resume on either screen, exactly where you left it. Subtitles in English, Arabic and Kurdish.",
              proof: ["Continue Watching", "Auto-resume", "CC"]),
        .init(kind: .videos, tint: Theme.amber,
              eyebrow: "YOUR VIDEOS", title: "No signal?\nNo problem",
              body: "Import from Files or Photos. Folders, thumbnails and resume points work offline — long drives, kids in the back, sorted.",
              proof: ["Files", "Photos", "Offline"]),
        .init(kind: .setup, tint: Theme.accent,
              eyebrow: "ONE LAST THING", title: "Set up in\none tap",
              body: "We'll switch on the good stuff. Change any of it later in Settings.",
              proof: []),
    ]

    private var isLast: Bool { page == pages.count - 1 }
    private var current: Page { pages[page] }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.06).ignoresSafeArea()
            MeshBackdrop(tint: current.tint).ignoresSafeArea()

            VStack(spacing: 0) {
                // Top: progress + skip
                HStack {
                    ProgressDots(count: pages.count, index: page)
                    Spacer()
                    if !isLast {
                        Button("Skip") { withAnimation(.snappy(duration: 0.4)) { page = pages.count - 1 } }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, Theme.s6).padding(.top, Theme.s3)
                .frame(height: 44)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        pageView(p, active: page == i).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom: primary + secondary
                VStack(spacing: Theme.s3) {
                    Button {
                        if isLast { complete() } else { withAnimation(.snappy(duration: 0.4)) { page += 1 } }
                    } label: {
                        HStack(spacing: 8) {
                            Text(primaryTitle)
                            if !isLast { Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold)) }
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 54)
                    }
                    .buttonStyle(.glassProminent).tint(current.tint).foregroundStyle(.black)
                    .animation(.easeInOut(duration: 0.4), value: page)
                    .sensoryFeedback(.selection, trigger: page)

                    Button(isLast ? "Start without CarFlix+" : " ") {
                        if isLast { enableMyTV = false; wantsYouTube = false; complete() }
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .opacity(isLast ? 1 : 0).disabled(!isLast)
                    .frame(height: 20)
                }
                .padding(.horizontal, Theme.s6).padding(.bottom, Theme.s5)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(duration: 1.0, bounce: 0.28).delay(0.15)) { heroIn = true } }
        .interactiveDismissDisabled()
    }

    private var primaryTitle: LocalizedStringResource {
        switch page {
        case 0: "Show me"
        case pages.count - 1: enableMyTV ? "Turn on & start watching" : "Start watching"
        default: "Continue"
        }
    }

    // MARK: Page

    @ViewBuilder private func pageView(_ p: Page, active: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Stage
            Group {
                switch p.kind {
                case .hero:     HeroStage(appeared: heroIn, tint: p.tint)
                case .channels: DisplayFrame(tint: p.tint, active: active) { ChannelsMock(active: active) }
                case .youtube:  DisplayFrame(tint: p.tint, active: active) { YouTubeMock(tint: p.tint, active: active) }
                case .movies:   DisplayFrame(tint: p.tint, active: active) { MoviesMock(tint: p.tint, active: active) }
                case .videos:   DisplayFrame(tint: p.tint, active: active) { VideosMock(tint: p.tint, active: active) }
                case .setup:    SetupCard(enableMyTV: $enableMyTV, wantsYouTube: $wantsYouTube, tint: p.tint)
                }
            }
            .frame(height: 300)
            .padding(.horizontal, Theme.s5)

            Spacer(minLength: Theme.s5)

            // Copy
            VStack(alignment: .leading, spacing: Theme.s3) {
                Text(p.eyebrow).font(.system(size: 12, weight: .bold)).tracking(1.6).foregroundStyle(p.tint)
                Text(p.title)
                    .font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .lineSpacing(-2).fixedSize(horizontal: false, vertical: true)
                Text(p.body).font(.system(size: 16)).foregroundStyle(.white.opacity(0.72)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !p.proof.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(p.proof, id: \.self) { ProofPill(text: $0, tint: p.tint) }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.s6)

            Spacer(minLength: Theme.s4)
        }
    }

    private func complete() {
        if enableMyTV, !settings.mytvEnabled {
            settings.mytvEnabled = true
            MyTVService.install(env: env)
        }
        if wantsYouTube, !env.youtube.auth.isSignedIn { env.youtube.pendingSignInPrompt = true }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish()
    }

    struct Page {
        enum Kind { case hero, channels, youtube, movies, videos, setup }
        let kind: Kind
        let tint: Color
        let eyebrow: LocalizedStringResource
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        let proof: [String]
    }
}

// MARK: - Chrome

/// Slow-drifting glow in the page tint.
///
/// Performance: `.blur` on large shapes is re-rasterised every frame it animates,
/// which fought the TabView slide and produced a visible hitch on page change.
/// Radial gradients are GPU-cheap and need no blur pass, and the whole backdrop is
/// flattened with `drawingGroup` so the compositor moves one texture. Colour
/// changes are animated here (not by the caller) so they don't retrigger layout.
private struct MeshBackdrop: View {
    let tint: Color
    @State private var t: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RadialGradient(colors: [tint.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: w * 0.55)
                    .frame(width: w * 1.3, height: w * 1.3)
                    .offset(x: -w * 0.25 + t * 30, y: -h * 0.28 + t * 20)
                RadialGradient(colors: [tint.opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: w * 0.45)
                    .frame(width: w * 1.1, height: w * 1.1)
                    .offset(x: w * 0.35 - t * 25, y: -h * 0.05 - t * 15)
                RadialGradient(colors: [Color.white.opacity(0.05), .clear], center: .center, startRadius: 0, endRadius: w * 0.5)
                    .frame(width: w * 1.2, height: w * 1.2)
                    .offset(x: w * 0.1 + t * 10, y: h * 0.45)
            }
            .frame(width: w, height: h)
            .drawingGroup()
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { t = 1 } }
        .allowsHitTesting(false)
    }
}

private struct ProgressDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == index ? .white : .white.opacity(0.28))
                    .frame(width: i == index ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(duration: 0.35), value: index)
    }
}

private struct ProofPill: View {
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Stages

/// The mascot on a soft spotlight.
private struct HeroStage: View {
    let appeared: Bool
    let tint: Color
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 170))
                .frame(width: 340, height: 340).blur(radius: 10)
            Image("LaunchLogo").resizable().interpolation(.high).scaledToFit()
                .frame(width: 230)
                .shadow(color: tint.opacity(0.5), radius: 34, y: 16)
                .scaleEffect(appeared ? 1 : 0.5).opacity(appeared ? 1 : 0)
                .rotationEffect(.degrees(appeared ? 0 : -10))
        }
    }
}

/// A stylised car display: dark glass, subtle bezel, rounded corners, tint glow.
/// Whatever it wraps looks like it's running on the head unit.
private struct DisplayFrame<Content: View>: View {
    let tint: Color
    let active: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            // Glow as a gradient, not a shadow: shadows are blur passes re-run while
            // the frame animates scale. This is one static layer that just fades.
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(RadialGradient(colors: [tint.opacity(0.45), .clear], center: .center, startRadius: 40, endRadius: 260))
                .padding(-30).offset(y: 18)
                .opacity(active ? 1 : 0.4)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.06, green: 0.075, blue: 0.10))
            content()
                .padding(14)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .aspectRatio(16/10, contentMode: .fit)
        .scaleEffect(active ? 1 : 0.96)
        .opacity(active ? 1 : 0.7)
        .animation(.spring(duration: 0.6, bounce: 0.15), value: active)
    }
}

// MARK: Mock UIs — abstract, no real logos, just enough to read as the product

private struct MockTile: View {
    let tint: Color
    var live = false
    var progress: Double? = nil
    var portrait = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if live {
                HStack(spacing: 3) { Circle().fill(Theme.live).frame(width: 5, height: 5); Capsule().fill(.white.opacity(0.7)).frame(width: 14, height: 4) }
                    .padding(6).frame(maxHeight: .infinity, alignment: .top)
            }
            if let progress {
                Capsule().fill(.white.opacity(0.25)).frame(height: 3).padding(6)
                    .overlay(alignment: .leading) { Capsule().fill(Theme.accent).frame(height: 3).padding(6).scaleEffect(x: progress, anchor: .leading) }
            }
        }
        .aspectRatio(portrait ? 2/3 : 16/9, contentMode: .fit)
    }
}

private struct MockRow: View {
    let title: LocalizedStringResource
    var body: some View {
        HStack {
            Text(title).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Capsule().fill(.white.opacity(0.18)).frame(width: 26, height: 5)
        }
    }
}

private struct ChannelsMock: View {
    let active: Bool
    @State private var pulse = 0
    private let hues: [Double] = [0.58, 0.02, 0.36, 0.78, 0.12, 0.62, 0.92, 0.48, 0.28]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(["News", "Sports", "Kids", "Movies"], id: \.self) { g in
                    Text(g).font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(g == "News" ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(g == "News" ? .black : .white.opacity(0.8))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(hues.enumerated()), id: \.offset) { i, h in
                    MockTile(tint: Color(hue: h, saturation: 0.6, brightness: 0.9), live: true)
                        .overlay {
                            if i == 0 && active {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                            }
                        }
                }
            }
        }
    }
}

private struct YouTubeMock: View {
    let tint: Color
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image("YouTubeMark").resizable().scaledToFit().frame(height: 12)
                ForEach(["Home", "Subscriptions", "Library"], id: \.self) { g in
                    Text(g).font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(g == "Subscriptions" ? tint : Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(g == "Subscriptions" ? .white : .white.opacity(0.8))
                }
                Spacer()
                Circle().fill(.white.opacity(0.25)).frame(width: 14, height: 14)
            }
            HStack(spacing: 8) {
                MockTile(tint: tint).frame(width: 118)
                    .overlay { Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) }
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(.white.opacity(0.8)).frame(width: 90, height: 6)
                    Capsule().fill(.white.opacity(0.4)).frame(width: 60, height: 5)
                    HStack(spacing: 4) {
                        Text("1080p").font(.system(size: 8, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(.white.opacity(0.12), in: Capsule())
                        Text("CC").font(.system(size: 8, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(.white.opacity(0.12), in: Capsule())
                    }.foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    MockTile(tint: Color(hue: 0.02 + Double(i) * 0.17, saturation: 0.55, brightness: 0.85))
                }
            }
        }
    }
}

private struct MoviesMock: View {
    let tint: Color
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MockRow(title: "Continue Watching")
            HStack(spacing: 6) {
                MockTile(tint: tint, progress: 0.62).overlay(alignment: .center) { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                MockTile(tint: Color(hue: 0.62, saturation: 0.5, brightness: 0.85), progress: 0.25)
            }
            HStack(spacing: 5) {
                Text("S2 · E4").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.accent)
                Text("· 31:07 left").font(.system(size: 8.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            MockRow(title: "English Movies")
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    MockTile(tint: Color(hue: 0.83 - Double(i) * 0.12, saturation: 0.5, brightness: 0.85), portrait: true)
                }
            }
        }
    }
}

private struct VideosMock: View {
    let tint: Color
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(tint)
                Text("Road Trip").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "wifi.slash").font(.system(size: 8, weight: .bold))
                    Text("Offline").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(tint).padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.15), in: Capsule())
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    MockTile(tint: Color(hue: 0.10 + Double(i) * 0.05, saturation: 0.55, brightness: 0.85), progress: i == 0 ? 0.4 : nil)
                        .overlay(alignment: .bottomTrailing) {
                            Text(["12:40", "1:02:15", "8:31", "24:09"][i]).font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white).padding(5)
                        }
                }
            }
        }
    }
}

// MARK: - Setup

private struct SetupCard: View {
    @Binding var enableMyTV: Bool
    @Binding var wantsYouTube: Bool
    let tint: Color
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s4) {
                Image(systemName: "iphone").font(.system(size: 30, weight: .light))
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
                Image(systemName: "car.fill").font(.system(size: 30, weight: .light)).foregroundStyle(tint)
            }
            .foregroundStyle(.white)
            .padding(.top, Theme.s5).padding(.bottom, Theme.s4)

            VStack(spacing: 1) {
                SetupSwitch(isOn: $enableMyTV, symbol: "tv.badge.wifi", tint: Theme.accent,
                            title: "CarFlix+ channels, movies & series", subtitle: "360+ live · 12K movies · 8K series")
                Divider().overlay(.white.opacity(0.08)).padding(.horizontal, Theme.s4)
                SetupSwitch(isOn: $wantsYouTube, brandImage: "YouTubeMark", tint: Color(red: 1.0, green: 0.0, blue: 0.0),
                            title: "Sign in to YouTube", subtitle: "Subscriptions & Watch Later — optional")
            }
            .padding(.bottom, Theme.s2)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        .frame(maxWidth: 400)
    }
}

private struct SetupSwitch: View {
    @Binding var isOn: Bool
    var symbol: String? = nil
    var brandImage: String? = nil     // asset name; real third-party mark
    let tint: Color
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Theme.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(brandImage == nil ? tint.opacity(0.18) : .white).frame(width: 36, height: 36)
                    if let brandImage {
                        Image(brandImage).resizable().scaledToFit().frame(width: 22, height: 22)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
    }
}
