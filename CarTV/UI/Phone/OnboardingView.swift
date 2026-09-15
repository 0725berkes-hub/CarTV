import SwiftUI

/// First-launch welcome. Five pages: a hero, three features, and a setup page
/// where MyTV+ can be switched on without a trip to Settings.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    let finish: () -> Void

    @State private var page = 0
    @State private var enableMyTV = true
    @State private var appeared = false

    private let pages: [Page] = [
        Page(kind: .hero, symbol: "car.side.front.open", title: "Welcome to CarTV",
             body: "Live TV, movies, series and your own videos — on your iPhone and on the CarPlay screen.",
             tint: Theme.accent),
        Page(kind: .feature, symbol: "antenna.radiowaves.left.and.right", title: "Live TV, sorted",
             body: "Paste any M3U link or Xtream login. Channels land in News, Sports, Kids and more automatically — or turn on the built-in MyTV+ channels.",
             tint: Color(hue: 0.62, saturation: 0.6, brightness: 0.95)),
        Page(kind: .feature, symbol: "popcorn.fill", title: "Movies & series that remember",
             body: "Pick up exactly where you left off, on either screen. Subtitles in English, Arabic and Kurdish.",
             tint: Theme.live),
        Page(kind: .feature, symbol: "film.stack.fill", title: "Your videos, offline",
             body: "Import from Files or Photos. Folders, thumbnails and resume points — no signal needed on the road.",
             tint: Theme.amber),
        Page(kind: .setup, symbol: "sparkles", title: "One last thing",
             body: "Switch on MyTV+ to start with 360+ live channels plus movies and series. You can change this any time in Settings.",
             tint: Theme.accent),
    ]

    private var isLast: Bool { page == pages.count - 1 }
    private var current: Page { pages[page] }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()

            // Ambient glow follows the page tint.
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

                // Dots
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule().fill(i == page ? Theme.ink : Theme.inkFaint)
                            .frame(width: i == page ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(duration: 0.3), value: page)
                .padding(.bottom, Theme.s5)

                // Primary
                Button {
                    if isLast { complete() } else { withAnimation(.snappy(duration: 0.35)) { page += 1 } }
                } label: {
                    HStack(spacing: 8) {
                        Text(isLast ? "Get Started" : (page == 0 ? "Continue" : "Next"))
                        if !isLast { Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold)) }
                    }
                    .font(Theme.Font.headline).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .padding(.horizontal, Theme.s6)
                .sensoryFeedback(.selection, trigger: page)

                // Secondary
                Button(isLast ? " " : "Skip") { if !isLast { complete() } }
                    .font(Theme.Font.callout).foregroundStyle(Theme.inkMuted)
                    .padding(.top, Theme.s3).padding(.bottom, Theme.s4)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(0.1)) { appeared = true } }
        .interactiveDismissDisabled()
    }

    // MARK: Pages

    @ViewBuilder private func pageView(_ p: Page, index i: Int) -> some View {
        VStack(spacing: Theme.s6) {
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
            }
            if p.kind == .setup { setupCard.padding(.top, Theme.s2) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s6)
    }

    private var setupCard: some View {
        Toggle(isOn: $enableMyTV) {
            HStack(spacing: Theme.s3) {
                Image(systemName: "tv.badge.wifi").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MyTV+ channels, movies & series").font(Theme.Font.headline).foregroundStyle(Theme.ink)
                    Text("Kurdish, Arabic and international").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .tint(Theme.accent)
        .padding(Theme.s4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).strokeBorder(Theme.hairline))
        .frame(maxWidth: 380)
    }

    private func complete() {
        if enableMyTV, isLast, !settings.mytvEnabled {
            settings.mytvEnabled = true
            MyTVService.install(env: env)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish()
    }

    struct Page {
        enum Kind { case hero, feature, setup }
        let kind: Kind
        let symbol: String
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        let tint: Color
    }
}

// MARK: - Artwork

/// App icon-style tile with a car glyph, springs in on first appear.
private struct HeroArtwork: View {
    let tint: Color
    let appeared: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 48, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 196, height: 196)
                .shadow(color: tint.opacity(0.5), radius: 46, y: 22)
            Image(systemName: "car.side.front.open")
                .font(.system(size: 84, weight: .medium))
                .foregroundStyle(.black.opacity(0.85))
                .symbolRenderingMode(.hierarchical)
        }
        .scaleEffect(appeared ? 1 : 0.6)
        .opacity(appeared ? 1 : 0)
        .rotationEffect(.degrees(appeared ? 0 : -8))
    }
}

/// Feature tile; the symbol gets a subtle bounce when its page becomes active.
private struct FeatureArtwork: View {
    let symbol: String
    let tint: Color
    let active: Bool
    @State private var bounce = 0
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 180, height: 180)
                .shadow(color: tint.opacity(0.45), radius: 40, y: 20)
            Image(systemName: symbol)
                .font(.system(size: 76, weight: .medium))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: bounce)
        }
        .onChange(of: active) { _, on in if on { bounce += 1 } }
    }
}

/// Setup page: a small "phone → car" diagram so the last step feels like a payoff.
private struct SetupArtwork: View {
    let tint: Color
    let active: Bool
    @State private var pulse = false
    var body: some View {
        HStack(spacing: Theme.s4) {
            Image(systemName: "iphone").font(.system(size: 54, weight: .light)).foregroundStyle(Theme.ink)
            Image(systemName: "arrow.right").font(.system(size: 22, weight: .bold)).foregroundStyle(tint)
                .opacity(pulse ? 1 : 0.35).scaleEffect(pulse ? 1.1 : 0.9)
            Image(systemName: "car.fill").font(.system(size: 54, weight: .light)).foregroundStyle(tint)
        }
        .frame(height: 180)
        .onChange(of: active, initial: true) { _, on in
            guard on else { pulse = false; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
