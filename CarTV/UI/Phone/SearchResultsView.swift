import SwiftUI

struct SearchResultsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let query: String

    @State private var channels: [Channel] = []
    @State private var videos: [LocalVideo] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s6) {
                if channels.isEmpty && videos.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matches")
                        .frame(minHeight: 320)
                }
                if !channels.isEmpty {
                    ShelfHeader(title: "Channels", subtitle: String(localized: "\(channels.count) channels"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.s3)], spacing: Theme.s4) {
                        ForEach(channels) { channel in
                            let item = PlayableItem(channel: channel, playlistName: channel.playlist?.name)
                            Button { playback.play(item, queue: channels.map { PlayableItem(channel: $0, playlistName: $0.playlist?.name) }, origin: .phone) } label: {
                                ChannelTile(item: item, health: channel.health, isFavorite: env.favorites.isFavorite(item), isPlaying: playback.current?.id == item.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, Theme.s4)
                }
                if !videos.isEmpty {
                    ShelfHeader(title: "Videos", subtitle: String(localized: "\(videos.count) videos"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.s3)], spacing: Theme.s4) {
                        ForEach(videos) { video in
                            let item = PlayableItem(video: video)
                            Button { playback.play(item, queue: videos.map(PlayableItem.init(video:)), origin: .phone) } label: {
                                VideoCard(item: item, progress: env.progress.progress(for: item.ref)?.fraction, isFavorite: env.favorites.isFavorite(item))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                    .padding(.horizontal, Theme.s4)
                }
            }
            .padding(.vertical, Theme.s4)
        }
        .onChange(of: query, initial: true) { _, q in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(180))   // debounce
                guard !Task.isCancelled else { return }
                channels = env.library.searchChannels(q)
                videos = env.library.searchLocalVideos(q)
            }
        }
    }
}
