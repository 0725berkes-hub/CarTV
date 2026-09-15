import SwiftUI

/// First-launch welcome, built for activation: get the user to a populated Home
/// in under a minute. Value first, ask second, one primary action per page,
/// and the setup page pre-selects everything so the default path is the rich one.
///
/// Pages: Welcome → Live TV → YouTube → Movies & Series → Your videos → Set up
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    let finish: () -> Void

    @State private var page = 0
    @State private var enableMyTV = true
    @State private var wantsYouTube = true
    @State private var appeared = false
    @State private var showYouTubeSignIn = false

    private let pages: [Page] = [
        Page(kind: .hero, symbol: "", title: "Your car just got a TV",
             body: "Live channels, YouTube, movies, series and your own videos — on your iPhone and on the CarPlay screen.",
             tint: Theme.accent, proof: "Free · No account needed · Works offline"),
        Page(kind: .feature, symbol: "antenna.radiowaves.left.and.right", title: "360+ live channels, ready now",
             body: "News, sports, kids, music and movies in Kurdish, Arabic and English — sorted for you. Or add any M3U or Xtream playlist you already have.",
             tint: Color(hue: 0.62, saturation: 0.6, brightness: 0.95), proof: "Built-in MyTV+ · One tap to turn on"),
        Page(kind: .feature, symbol: "play.rectangle.fill", title: "YouTube on the dash",
             body: "Your subscriptions, Watch Later and playlists, playable in the car. Sign in with Google to see your feed, or browse without an account.",
             tint: Color(red: 1.0, green: 0.27, blue: 0.27), proof: "Subscriptions · Watch Later · Quality picker"),
        Page(kind: .feature, symbol: "popcorn.fill", title: "Movies & series that remember",
             body: "12,000+ movies and 8,000+ series. Pick up exactly where you stopped, on either screen. Subtitles in English, Arabic and Kurdish.",
             tint: Theme.live, proof: "Continue Watching · Auto-resume · CC"),
        Page(kind: .feature, symbol: "film.stack.fill", title: "Your videos, no signal needed",
             body: "Import from Files or Photos. Folders, thumbnails and resume points work offline — perfect for long drives and kids in the back.",
             tint: Theme.amber, proof: "Files · Photos · Offline"),
        Page(kind: .setup, symbol: "sparkles", title: "Set up in one tap",
             body: "We'll switch on the good stuff. You can change any of this later in Settings.",
             tint: Theme.accent, proof: nil),
    ]

    private var isLast: Bool { page == pages.count - 1 }
    private var current: Page { pages[page] }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            RadialGradient(colors: [current.tint.opacity(0.32), .clear], center: .init(x: 0.5, y: 0.18), startRadius: 10, endRadius: 460)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.55), value: page)

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        pageView(p, index: i).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy(duration: 0.35), value: page)

                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule().fill(i == page ? Theme.ink : Theme.inkFaint)
                            .frame(width: i == page ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(duration: 0.3), value: page)
                .padding(.bottom, Theme.s5)

                // One primary action per page. Copy states the outcome, not the mechanic.
                Button {
                    if isLast { complete() } else { withAnimation(.snappy(duration: 0.35)) { page += 1 } }
                } label: {
                    HStack(spacing: 8) {
                        Text(primaryTitle)
                        if !isLast { Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold)) }
                    }
                    .font(Theme.Font.headline).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .padding(.horizontal, Theme.s6)
                .sensoryFeedback(.selection, trigger: page)

                // Secondary is always available but never competes.
                Button(isLast ? "Start without MyTV+" : "Skip") {
                    if isLast { enableMyTV = false; wantsYouTube = false; complete() } else { withAnimation { page = pages.count - 1 } }
                }
                .font(Theme.Font.callout).foregroundStyle(Theme.inkMuted)
                .padding(.top, Theme.s3).padding(.bottom, Theme.s4)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(0.1)) { appeared = true } }
        .interactiveDismissDisabled()
    }

    private var primaryTitle: LocalizedStringResource {
        switch page {
        case 0: "Show me"
        case pages.count - 1: enableMyTV ? "Turn on & start watching" : "Start watching"
        default: "Next"
        }
    }

    // MARK: Pages

    @ViewBuilder private func pageView(_ p: Page, index i: Int) -> some View {
        VStack(spacing: Theme.s5) {
            Spacer(minLength: 0)
            switch p.kind {
            case .hero:    HeroArtwork(tint: p.tint, appeared: appeared)
            case .feature: FeatureArtwork(symbol: p.symbol, tint: p.tint, active: page == i)
            case .setup:   SetupArtwork(tint: p.tint, active: page == i)
            }
            VStack(spacing: Theme.s3) {
                Text(p.title).font(Theme.Font.largeTitle).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                Text(p.body).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
                    .frame(maxWidth: 340).fixedSize(horizontal: false, vertical: true)
                if let proof = p.proof {
                    Text(proof).font(Theme.Font.caption).foregroundStyle(p.tint).padding(.top, 2)
                }
            }
            if p.kind == .setup { setupCards.padding(.top, Theme.s2) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s6)
    }

    /// Both options default on. The user only has to tap the big button.
    private var setupCards: some View {
        VStack(spacing: Theme.s2) {
            SetupRow(isOn: $enableMyTV, symbol: "tv.badge.wifi", tint: Theme.accent,
                     title: "MyTV+ channels, movies & series", subtitle: "360+ live channels · 12K movies · 8K series")
            SetupRow(isOn: $wantsYouTube, symbol: "play.rectangle.fill", tint: Color(red: 1.0, green: 0.27, blue: 0.27),
                     title: "Sign in to YouTube", subtitle: "Subscriptions and Watch Later in the car — optional")
        }
        .frame(maxWidth: 380)
    }

    private func complete() {
        if enableMyTV, !settings.mytvEnabled {
            settings.mytvEnabled = true
            MyTVService.install(env: env)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if wantsYouTube, !env.youtube.auth.isSignedIn {
            // Hand off to the YouTube tab's sign-in after the cover dismisses.
            env.youtube.pendingSignInPrompt = true
        }
        finish()
    }

    struct Page {
        enum Kind { case hero, feature, setup }
        let kind: Kind
        let symbol: String
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        let tint: Color
        /// Short proof line under the body — concrete numbers beat adjectives.
        let proof: String?
    }
}

private struct SetupRow: View {
    @Binding var isOn: Bool
    let symbol: String
    let tint: Color
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Theme.s3) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .tint(Theme.accent)
        .padding(Theme.s4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Artwork

/// The CarTV mascot (same art as the launch screen), springs in on first appear.
private struct HeroArtwork: View {
    let tint: Color
    let appeared: Bool
    var body: some View {
        Image("LaunchLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 220, height: 220)
            .shadow(color: tint.opacity(0.45), radius: 40, y: 18)
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .rotationEffect(.degrees(appeared ? 0 : -8))
    }
}

/// Feature tile; the symbol bounces when its page becomes active.
private struct FeatureArtwork: View {
    let symbol: String
    let tint: Color
    let active: Bool
    @State private var bounce = 0
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 172, height: 172)
                .shadow(color: tint.opacity(0.45), radius: 40, y: 20)
            Image(systemName: symbol)
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: bounce)
        }
        .onChange(of: active) { _, on in if on { bounce += 1 } }
    }
}

/// Setup page: phone → car, the arrow pulsing while the page is active.
private struct SetupArtwork: View {
    let tint: Color
    let active: Bool
    @State private var pulse = false
    var body: some View {
        HStack(spacing: Theme.s4) {
            Image(systemName: "iphone").font(.system(size: 48, weight: .light)).foregroundStyle(Theme.ink)
            Image(systemName: "arrow.right").font(.system(size: 20, weight: .bold)).foregroundStyle(tint)
                .opacity(pulse ? 1 : 0.35).scaleEffect(pulse ? 1.1 : 0.9)
            Image(systemName: "car.fill").font(.system(size: 48, weight: .light)).foregroundStyle(tint)
        }
        .frame(height: 120)
        .onChange(of: active, initial: true) { _, on in
            guard on else { pulse = false; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
