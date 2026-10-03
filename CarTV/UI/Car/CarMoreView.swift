import SwiftUI

struct CarMoreView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.carMetrics) private var metrics
    let open: (CarSection) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                Button { open(.youtube) } label: {
                    CarSourceCard(symbol: "play.rectangle.fill", title: "YouTube", subtitle: "Feeds, playlists & downloads", tint: Theme.live, assetName: "YouTubeMark")
                }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                if settings.tiktokEnabled {
                    Button { open(.tiktok) } label: {
                        CarSourceCard(symbol: "music.note", title: "TikTok", subtitle: "Your native video feed", tint: Theme.ink, assetName: "TikTokMark")
                    }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                }
                Button { open(.cast) } label: {
                    CarSourceCard(symbol: "tv.badge.wifi", title: "Cast", subtitle: "Play on your car screen", tint: Theme.accent)
                }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
            }
            .padding(metrics.gutter)
        }
    }
}
