import SwiftUI

struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0

    private let pages: [Page] = [
        Page(symbol: "car.side.front.open", title: "Your videos, on the dash", body: "CarTV puts IPTV channels and your own videos on the CarPlay screen — big tiles, big buttons, built for the cabin.", tint: Theme.accent),
        Page(symbol: "antenna.radiowaves.left.and.right", title: "Add any M3U playlist", body: "Paste a link, scan a QR code or sign in with Xtream. Channels are sorted into News, Sports, Kids, Movies and more automatically.", tint: Color(hue: 0.62, saturation: 0.6, brightness: 0.95)),
        Page(symbol: "film.stack", title: "Bring your own videos", body: "Import from Files or Photos. Thumbnails, resume points and folders — everything works offline on the road.", tint: Theme.amber),
        Page(symbol: "play.rectangle.on.rectangle", title: "Plays anywhere", body: "Start on iPhone, keep watching in the car. Hardware decoding for HLS and MP4, VLC for everything else. Video pauses to audio when you drive.", tint: Theme.live),
    ]

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            RadialGradient(colors: [pages[page].tint.opacity(0.35), .clear], center: .top, startRadius: 20, endRadius: 420)
                .ignoresSafeArea().animation(.easeInOut(duration: 0.5), value: page)

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        VStack(spacing: Theme.s6) {
                            Spacer()
                            OnboardingArtwork(symbol: p.symbol, tint: p.tint)
                            VStack(spacing: Theme.s3) {
                                Text(p.title).font(Theme.Font.largeTitle).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                                Text(p.body).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center).frame(maxWidth: 340)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.s6)
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule().fill(i == page ? Theme.ink : Theme.inkFaint).frame(width: i == page ? 22 : 7, height: 7)
                            .animation(.spring(duration: 0.3), value: page)
                    }
                }
                .padding(.bottom, Theme.s6)

                Button {
                    if page < pages.count - 1 { withAnimation { page += 1 } } else { finish() }
                } label: {
                    Text(page < pages.count - 1 ? "Next" : "Try it now")
                        .font(Theme.Font.headline).frame(maxWidth: .infinity).padding(.vertical, Theme.s4)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.accent).foregroundStyle(.black)
                .padding(.horizontal, Theme.s6)

                Button("Skip") { finish() }.font(Theme.Font.callout).foregroundStyle(Theme.inkMuted).padding(.top, Theme.s3).padding(.bottom, Theme.s4)
                    .opacity(page < pages.count - 1 ? 1 : 0)
            }
        }
        .preferredColorScheme(.dark)
    }

    struct Page { let symbol: String; let title: LocalizedStringResource; let body: LocalizedStringResource; let tint: Color }
}

struct OnboardingArtwork: View {
    let symbol: String
    let tint: Color
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
        }
    }
}
