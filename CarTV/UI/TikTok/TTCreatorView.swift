import SwiftUI

/// A creator's posts as a 3-column grid of covers. Tap plays it (and the rest of
/// the grid as the queue) in the full-screen player.
struct TTCreatorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    let author: TTAuthor

    @State private var videos: [TTVideo] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.s4) {
                header
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(videos) { v in
                        Button { play(v) } label: {
                            ZStack(alignment: .bottomLeading) {
                                RemoteImage(url: v.coverURL, targetSize: CGSize(width: 360, height: 640), contentMode: .fill) { TileTint.gradient(for: v.id) }
                                    .aspectRatio(3/4, contentMode: .fill)
                                    .clipped()
                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                                    Text(v.stats.plays.compact).font(.system(size: 11, weight: .bold))
                                }
                                .foregroundStyle(.white).shadow(radius: 3).padding(6)
                            }
                            .aspectRatio(3/4, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .onAppear { if v.id == videos.last?.id { loadMore() } }
                    }
                }
                if loading { ProgressView().padding() }
                if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.amber).padding() }
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("@\(author.uniqueID)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            videos = env.tiktok.profiles[author.uniqueID] ?? []
            loading = videos.isEmpty
            env.tiktok.loadProfile(author.uniqueID)
            try? await Task.sleep(for: .seconds(12))
            if videos.isEmpty { loading = false; error = String(localized: "Couldn't load this creator's posts") }
        }
        .onChange(of: env.tiktok.profiles[author.uniqueID]?.count ?? 0) { _, _ in
            videos = env.tiktok.profiles[author.uniqueID] ?? []
            loading = false
        }
        .onDisappear { env.tiktok.leaveProfile(backTo: .forYou) }
    }

    private var header: some View {
        VStack(spacing: Theme.s2) {
            ZStack {
                Circle().fill(TileTint.gradient(for: author.uniqueID))
                RemoteImage(url: author.avatarURL, targetSize: CGSize(width: 240, height: 240), contentMode: .fill) { Monogram(text: author.nickname, size: 28) }
                    .frame(width: 96, height: 96).clipShape(Circle())
            }
            .frame(width: 96, height: 96)
            HStack(spacing: 4) {
                Text(author.nickname).font(Theme.Font.title2).foregroundStyle(Theme.ink)
                if author.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(red: 0.16, green: 0.72, blue: 1.0)) }
            }
            Text("@\(author.uniqueID)").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            Button { UIApplication.shared.open(URL(string: "https://www.tiktok.com/@\(author.uniqueID)")!) } label: {
                Label("Open in TikTok", systemImage: "arrow.up.right.square").font(Theme.Font.caption.weight(.semibold))
            }
            .buttonStyle(.glass).controlSize(.small)
        }
        .padding(.top, Theme.s4)
    }

    private func loadMore() { env.tiktok.loadMoreProfile() }

    private func play(_ v: TTVideo) {
        Task { @MainActor in
            let q = await env.tiktok.proxiedQueue(videos)
            guard let item = q.first(where: { $0.id == v.playableID }) else { return }
            playback.play(item, queue: q, origin: .phone, resume: false)
        }
    }
}
