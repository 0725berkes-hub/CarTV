import SwiftUI

// MARK: - Hub (Movies / Series segmented, shelves by category)

struct VODHubView: View {
    @Environment(AppEnvironment.self) private var env
    enum Mode: String, CaseIterable, Identifiable { case movies, series; var id: String { rawValue } }
    @State private var mode: Mode = .movies
    @State private var query = ""

    var body: some View {
        let vod = env.vod
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s5) {
                Picker("", selection: $mode) {
                    Text("Movies").tag(Mode.movies)
                    Text("Series").tag(Mode.series)
                }
                .pickerStyle(.segmented).padding(.horizontal, Theme.s4)

                if !query.isEmpty {
                    searchResults
                } else {
                    switch vod.phase {
                    case .loading where vod.movies.isEmpty:
                        loadingShelves
                    case .failed(let msg) where vod.movies.isEmpty:
                        EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load MyTV+", message: LocalizedStringResource(stringLiteral: msg),
                                   actionTitle: "Retry") { vod.loadIfNeeded(force: true) }
                    default:
                        if mode == .movies {
                            ForEach(vod.movieShelves, id: \.name) { shelf in
                                Shelf(title: shelf.name, count: shelf.items.count) {
                                    ForEach(shelf.items.prefix(30)) { m in
                                        NavigationLink(value: m) { MoviePoster(movie: m) }.buttonStyle(.plain)
                                    }
                                } seeAll: { VODGridView(title: shelf.name, movies: shelf.items) }
                            }
                        } else {
                            ForEach(vod.seriesShelves, id: \.name) { shelf in
                                Shelf(title: shelf.name, count: shelf.items.count) {
                                    ForEach(shelf.items.prefix(30)) { s in
                                        NavigationLink(value: s) { SeriesPoster(series: s) }.buttonStyle(.plain)
                                    }
                                } seeAll: { VODGridView(title: shelf.name, series: shelf.items) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Theme.s3)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("MyTV+")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search movies and series"))
        .navigationDestination(for: VODMovie.self) { MovieDetailView(movie: $0) }
        .navigationDestination(for: VODSeries.self) { SeriesDetailView(series: $0) }
        .refreshable { vod.loadIfNeeded(force: true) }
        .task { vod.loadIfNeeded() }
    }

    @ViewBuilder private var searchResults: some View {
        let r = env.vod.search(query)
        if r.movies.isEmpty && r.series.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No results")
        } else {
            if !r.movies.isEmpty {
                Text("Movies").eyebrow().padding(.horizontal, Theme.s4)
                PosterGrid { ForEach(r.movies) { m in NavigationLink(value: m) { MoviePoster(movie: m) }.buttonStyle(.plain) } }
            }
            if !r.series.isEmpty {
                Text("Series").eyebrow().padding(.horizontal, Theme.s4)
                PosterGrid { ForEach(r.series) { s in NavigationLink(value: s) { SeriesPoster(series: s) }.buttonStyle(.plain) } }
            }
        }
    }

    private var loadingShelves: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.s2) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.raised).frame(width: 140, height: 18).padding(.horizontal, Theme.s4)
                    ScrollView(.horizontal) {
                        HStack(spacing: Theme.s3) { ForEach(0..<6, id: \.self) { _ in SkeletonTile().frame(width: 118) } }.padding(.horizontal, Theme.s4)
                    }.scrollDisabled(true)
                }
            }
            HStack { Spacer(); ProgressView(); Text("Loading catalogue…").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted); Spacer() }
        }
    }
}

/// Horizontal shelf with header + "See all".
private struct Shelf<Content: View, SeeAll: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: () -> Content
    @ViewBuilder let seeAll: () -> SeeAll
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                Text(title).font(Theme.Font.title2).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(count)").font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.inkFaint)
                Spacer()
                NavigationLink { seeAll() } label: {
                    HStack(spacing: 2) { Text("See all"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.horizontal, Theme.s4)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.s3) { content() }.padding(.horizontal, Theme.s4)
            }
        }
    }
}

private struct PosterGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 140), spacing: Theme.s3)], alignment: .leading, spacing: Theme.s4) { content() }
            .padding(.horizontal, Theme.s4)
    }
}

// MARK: - Grid ("See all")

struct VODGridView: View {
    let title: String
    var movies: [VODMovie] = []
    var series: [VODSeries] = []
    var body: some View {
        ScrollView {
            PosterGrid {
                ForEach(movies) { m in NavigationLink(value: m) { MoviePoster(movie: m) }.buttonStyle(.plain) }
                ForEach(series) { s in NavigationLink(value: s) { SeriesPoster(series: s) }.buttonStyle(.plain) }
            }
            .padding(.vertical, Theme.s3)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Posters

struct MoviePoster: View {
    @Environment(AppEnvironment.self) private var env
    let movie: VODMovie
    var width: CGFloat = 118
    var body: some View {
        let progress = env.progress.progress(for: PlayableRef(id: movie.playableID, kind: .vod))?.fraction
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                TileTint.gradient(for: movie.title)
                RemoteImage(url: movie.poster, targetSize: CGSize(width: 240, height: 360), contentMode: .fill) {
                    Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.6))
                }
                if movie.rating.nilIfEmpty != nil {
                    VStack { HStack { Spacer(); RatingBadge(text: movie.rating) }; Spacer() }.padding(6)
                }
                if let progress, progress > 0.02 { VStack { Spacer(); ProgressBar(fraction: progress, height: 2.5) } }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            Text(movie.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if movie.year.nilIfEmpty != nil {
                Text(movie.year).font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

struct SeriesPoster: View {
    let series: VODSeries
    var width: CGFloat = 118
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                TileTint.gradient(for: series.title)
                RemoteImage(url: series.poster, targetSize: CGSize(width: 240, height: 360), contentMode: .fill) {
                    Image(systemName: "tv").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.6))
                }
                if series.rating.nilIfEmpty != nil {
                    VStack { HStack { Spacer(); RatingBadge(text: series.rating) }; Spacer() }.padding(6)
                }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            Text(series.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(series.seasons == 1 ? "1 season" : "\(series.seasons) seasons").font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

private struct RatingBadge: View {
    let text: String
    var body: some View {
        HStack(spacing: 2) { Image(systemName: "star.fill").font(.system(size: 8, weight: .bold)); Text(text).font(.system(size: 10, weight: .bold)).monospacedDigit() }
            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Movie detail

struct MovieDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let movie: VODMovie

    private var item: PlayableItem { PlayableItem(movie: movie) }
    private var resume: TimeInterval? { env.progress.resumePosition(for: item.ref) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text(movie.title).font(Theme.Font.title).foregroundStyle(Theme.ink)
                    metaRow
                    playRow
                    if movie.description.nilIfEmpty != nil {
                        Text(movie.description).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).lineSpacing(3)
                    }
                    credits
                }
                .padding(Theme.s4)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { env.favorites.toggle(item.ref) } label: {
                    Image(systemName: env.favorites.isFavorite(item) ? "heart.fill" : "heart").foregroundStyle(env.favorites.isFavorite(item) ? Theme.live : Theme.ink)
                }
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: movie.backdrop ?? movie.poster, targetSize: CGSize(width: 900, height: 500), contentMode: .fill) { TileTint.gradient(for: movie.title) }
                .frame(height: 260).frame(maxWidth: .infinity).clipped()
            LinearGradient(colors: [.clear, Theme.ground.opacity(0.6), Theme.ground], startPoint: .top, endPoint: .bottom).frame(height: 140)
        }
    }

    private var metaRow: some View {
        HStack(spacing: Theme.s2) {
            if movie.year.nilIfEmpty != nil { MetaChip(movie.year) }
            if let mins = Double(movie.duration), mins > 0 { MetaChip((mins * 60).clockString) }
            if movie.rating.nilIfEmpty != nil { MetaChip("★ \(movie.rating)") }
            if movie.age.nilIfEmpty != nil { MetaChip(movie.age) }
            if !movie.subtitles.isEmpty { MetaChip("CC", accent: true) }
        }
    }

    private var playRow: some View {
        HStack(spacing: Theme.s2) {
            Button { play(resume: true) } label: {
                Label(resume != nil ? "Resume" : "Play", systemImage: "play.fill")
                    .font(Theme.Font.headline).frame(maxWidth: .infinity).frame(height: 48)
            }
            .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
            if resume != nil {
                Button { play(resume: false) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .semibold)).frame(width: 48, height: 48)
                }
                .buttonStyle(.glass)
            }
            if let trailer = movie.trailer {
                Button { playTrailer(trailer) } label: {
                    Image(systemName: "film").font(.system(size: 17, weight: .semibold)).frame(width: 48, height: 48)
                }
                .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder private var credits: some View {
        if movie.director.nilIfEmpty != nil || movie.stars.nilIfEmpty != nil {
            VStack(alignment: .leading, spacing: Theme.s1) {
                if movie.director.nilIfEmpty != nil { CreditLine(label: "Director", value: movie.director) }
                if movie.stars.nilIfEmpty != nil { CreditLine(label: "Cast", value: movie.stars) }
            }
        }
    }

    private func play(resume: Bool) {
        playback.play(item, queue: [item], origin: .phone, resume: resume)
    }

    private func playTrailer(_ url: URL) {
        let t = PlayableItem(trailer: url, of: item)
        playback.play(t, queue: [t], origin: .phone, resume: false)
    }
}

// MARK: - Series detail

struct SeriesDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    let series: VODSeries

    @State private var seasons: [VODSeason] = []
    @State private var season: VODSeason?
    @State private var episodes: [VODEpisode] = []
    @State private var loadingSeasons = true
    @State private var loadingEpisodes = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text(series.title).font(Theme.Font.title).foregroundStyle(Theme.ink)
                    HStack(spacing: Theme.s2) {
                        if series.rating.nilIfEmpty != nil { MetaChip("★ \(series.rating)") }
                        if series.age.nilIfEmpty != nil { MetaChip(series.age) }
                        MetaChip(series.seasons == 1 ? "1 season" : "\(series.seasons) seasons")
                    }
                    if let s = season, s.description.nilIfEmpty != nil {
                        Text(s.description).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).lineSpacing(3)
                    }
                    if let s = season, s.actors.nilIfEmpty != nil { CreditLine(label: "Cast", value: s.actors) }

                    if loadingSeasons {
                        HStack { ProgressView().controlSize(.small); Text("Loading seasons…").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted) }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.amber)
                    } else {
                        seasonPicker
                        episodeList
                    }
                }
                .padding(Theme.s4)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await loadSeasons() }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: season?.poster ?? series.poster, targetSize: CGSize(width: 900, height: 500), contentMode: .fill) { TileTint.gradient(for: series.title) }
                .frame(height: 260).frame(maxWidth: .infinity).clipped()
            LinearGradient(colors: [.clear, Theme.ground.opacity(0.6), Theme.ground], startPoint: .top, endPoint: .bottom).frame(height: 140)
        }
    }

    @ViewBuilder private var seasonPicker: some View {
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.s2) {
                    ForEach(seasons) { s in
                        Button { select(s) } label: {
                            Text("Season \(s.name)").font(Theme.Font.caption.weight(.semibold))
                                .padding(.horizontal, Theme.s3).padding(.vertical, 8)
                                .background(season?.id == s.id ? Theme.accent : Theme.raised, in: Capsule())
                                .foregroundStyle(season?.id == s.id ? .black : Theme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var episodeList: some View {
        if loadingEpisodes {
            HStack { ProgressView().controlSize(.small); Text("Loading episodes…").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted) }
        } else if episodes.isEmpty {
            Text("No episodes in this season yet").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
        } else {
            VStack(spacing: Theme.s1) {
                ForEach(episodes) { ep in
                    EpisodeRow(episode: ep,
                               progress: env.progress.progress(for: PlayableRef(id: ep.playableID, kind: .vod))?.fraction,
                               isPlaying: playback.current?.id == ep.playableID) { play(ep) }
                }
            }
        }
    }

    private func loadSeasons() async {
        loadingSeasons = true; error = nil
        do {
            seasons = try await env.vod.seasons(for: series)
            loadingSeasons = false
            if let first = seasons.first { await select(first) } else { error = String(localized: "No seasons available") }
        } catch {
            loadingSeasons = false
            self.error = String(localized: "Couldn't load seasons")
        }
    }

    private func select(_ s: VODSeason) { Task { await select(s) } }
    private func select(_ s: VODSeason) async {
        season = s; loadingEpisodes = true; episodes = []
        episodes = (try? await env.vod.episodes(for: s)) ?? []
        loadingEpisodes = false
    }

    private func play(_ ep: VODEpisode) {
        guard let season else { return }
        let queue = episodes.map { PlayableItem(episode: $0, series: series, season: season) }
        guard let item = queue.first(where: { $0.id == ep.playableID }) else { return }
        playback.play(item, queue: queue, origin: .phone)
    }
}

private struct EpisodeRow: View {
    let episode: VODEpisode
    let progress: Double?
    let isPlaying: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isPlaying ? Theme.accent.opacity(0.18) : Theme.raised).frame(width: 44, height: 44)
                    if isPlaying { EqualizerBars().scaleEffect(0.6) }
                    else { Text("\(episode.number)").font(Theme.Font.headline).monospacedDigit().foregroundStyle(Theme.ink) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Episode \(episode.number)").font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        if !episode.subtitles.isEmpty { MetaChip("CC", accent: true, small: true) }
                        if let progress, progress > 0.02 {
                            ProgressBar(fraction: progress, height: 2).frame(width: 60)
                        }
                    }
                }
                Spacer()
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.s2)
            .background(isPlaying ? Theme.accent.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bits

private struct MetaChip: View {
    let text: String
    var accent = false
    var small = false
    init(_ text: String, accent: Bool = false, small: Bool = false) { self.text = text; self.accent = accent; self.small = small }
    var body: some View {
        Text(text).font(.system(size: small ? 9.5 : 11.5, weight: .bold)).monospacedDigit()
            .padding(.horizontal, small ? 5 : 8).padding(.vertical, small ? 2 : 4)
            .background(accent ? Theme.accent.opacity(0.18) : Theme.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(accent ? Theme.accent : Theme.inkMuted)
    }
}

private struct CreditLine: View {
    let label: LocalizedStringResource
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.inkFaint).frame(width: 60, alignment: .leading)
            Text(value).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
        }
    }
}
