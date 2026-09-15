import SwiftUI

// MARK: - Continue Watching (car Home)

/// One row: movies mid-way, series with a next/current episode, local videos.
/// Every card is a single tap to resume exactly where you were.
struct CarContinueWatchingShelf: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push

    var body: some View {
        let _ = env.progress.revision
        let _ = env.vod.movies.count
        let movies = env.progress.continueWatching(limit: 12).filter { $0.0.ref.kind != .vod || env.vod.movie(playableID: $0.0.id) != nil }
        let series = env.vod.seriesInProgress(limit: 8)
        if !movies.isEmpty || !series.isEmpty {
            CarShelf(title: "Continue Watching") {
                ForEach(series, id: \.series.id) { s, pos in
                    CarResumeCard(
                        title: s.title,
                        subtitle: episodeLabel(pos),
                        artwork: pos.season.poster ?? s.poster,
                        fraction: pos.isMidEpisode ? (pos.progress?.fraction ?? 0) : 0,
                        symbol: "play.fill"
                    ) { resume(series: s, at: pos) }
                    .contextMenu {
                        Button { push(CarRoute.seriesDetail(s)) } label: { Label("All episodes", systemImage: "list.bullet") }
                    }
                }
                ForEach(movies, id: \.0.id) { item, p in
                    CarResumeCard(
                        title: item.title,
                        subtitle: String(localized: "\((p.duration - p.position).clockString) left"),
                        artwork: item.artworkURL,
                        fraction: p.fraction,
                        symbol: "play.fill"
                    ) { playback.play(item, origin: .car, resume: true) }
                    .contextMenu {
                        Button { playback.play(item, origin: .car, resume: false) } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                        Button(role: .destructive) { env.progress.remove(item.ref) } label: { Label("Remove", systemImage: "xmark") }
                    }
                }
            }
        }
    }

    private func episodeLabel(_ pos: VODService.SeriesPosition) -> String {
        let ep = "S\(pos.season.name) · E\(pos.episode.number)"
        if pos.isMidEpisode, let p = pos.progress {
            return "\(ep) · \((p.duration - p.position).clockString) left"
        }
        return String(localized: "Next: \(ep)")
    }

    /// Mid-episode → resume it. Finished → play the next one in the season (or the
    /// same one again if it was the last). Mirrors what Netflix does on the row tap.
    private func resume(series: VODSeries, at pos: VODService.SeriesPosition) {
        Task {
            let eps = (try? await env.vod.episodes(for: pos.season)) ?? [pos.episode]
            let target: VODEpisode
            if pos.isMidEpisode { target = pos.episode }
            else if let i = eps.firstIndex(where: { $0.id == pos.episode.id }), i + 1 < eps.count { target = eps[i + 1] }
            else { target = pos.episode }
            let queue = eps.map { PlayableItem(episode: $0, series: series, season: pos.season) }
            guard let item = queue.first(where: { $0.id == target.playableID }) else { return }
            env.vod.rememberPlayed(episodes: eps, series: series, season: pos.season)
            playback.play(item, queue: queue, origin: .car, resume: true)
        }
    }
}

/// Wide 16:9 card with a progress bar and a big play glyph — a car-sized target.
struct CarResumeCard: View {
    @Environment(\.carMetrics) private var m
    let title: String
    let subtitle: String
    let artwork: URL?
    let fraction: Double
    let symbol: String
    let action: () -> Void

    var body: some View {
        let w: CGFloat = m.compact ? 176 : 240
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottom) {
                    ZStack {
                        TileTint.gradient(for: title)
                        RemoteImage(url: artwork, targetSize: CGSize(width: 480, height: 270), contentMode: .fill) {
                            Image(systemName: "film").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.6))
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        Image(systemName: symbol).font(.system(size: m.compact ? 20 : 26, weight: .bold)).foregroundStyle(.white).shadow(radius: 4)
                    }
                    if fraction > 0.01 { ProgressBar(fraction: fraction, height: 3).padding(.horizontal, 6).padding(.bottom, 6) }
                }
                .frame(width: w, height: w * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                Text(title).font(.system(size: m.compact ? 12.5 : 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(.system(size: m.compact ? 10.5 : 12.5, weight: .medium)).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            .frame(width: w)
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

// MARK: - Categories (Movies / Series root)

struct CarVODCategoriesView: View {
    enum Kind { case movies, series }
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push
    let kind: Kind

    var body: some View {
        let vod = env.vod
        let shelves: [(name: String, count: Int)] = kind == .movies
            ? vod.movieShelves.map { ($0.name, $0.items.count) }
            : vod.seriesShelves.map { ($0.name, $0.items.count) }
        if shelves.isEmpty {
            CarEmptyState(symbol: "hourglass", title: "Loading catalogue…", message: "This takes a few seconds the first time.")
                .task { vod.loadIfNeeded() }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: m.cardMin), spacing: Theme.s3)], spacing: Theme.s3) {
                    ForEach(shelves, id: \.name) { s in
                        Button { push(kind == .movies ? .movieCategory(s.name) : .seriesCategory(s.name)) } label: {
                            CarSourceCard(symbol: kind == .movies ? "film.fill" : "tv.fill", title: s.name,
                                          subtitle: kind == .movies ? String(localized: "\(s.count) movies") : String(localized: "\(s.count) series"),
                                          tint: TileTint.color(for: s.name))
                        }.buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                    }
                }
                .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
            }
        }
    }
}

// MARK: - Movie grid

struct CarMovieGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let category: String

    var body: some View {
        let _ = env.progress.revision
        let movies = env.vod.movieShelves.first { $0.name == category }?.items ?? []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.compact ? 104 : 136), spacing: Theme.s3)], spacing: Theme.s3) {
                ForEach(movies) { movie in
                    let item = PlayableItem(movie: movie)
                    let resume = env.progress.resumePosition(for: item.ref)
                    CarPosterButton(title: movie.title, subtitle: movie.year, artwork: movie.poster,
                                    fraction: env.progress.progress(for: item.ref)?.fraction ?? 0,
                                    badge: resume != nil ? String(localized: "Resume") : nil) {
                        playback.play(item, queue: [item], origin: .car, resume: true)
                    }
                    .contextMenu {
                        if resume != nil {
                            Button { playback.play(item, queue: [item], origin: .car, resume: false) } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                        }
                        Button { env.favorites.toggle(item.ref) } label: {
                            Label(env.favorites.isFavorite(item) ? "Remove Favorite" : "Add to Favorites", systemImage: "heart")
                        }
                    }
                }
            }
            .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
        }
    }
}

// MARK: - Series grid

struct CarSeriesGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.carMetrics) private var m
    @Environment(\.carPush) private var push
    let category: String

    var body: some View {
        let _ = env.progress.revision
        let list = env.vod.seriesShelves.first { $0.name == category }?.items ?? []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: m.compact ? 104 : 136), spacing: Theme.s3)], spacing: Theme.s3) {
                ForEach(list) { s in
                    let pos = env.vod.position(in: s)
                    CarPosterButton(title: s.title,
                                    subtitle: pos.map { "S\($0.season.name) · E\($0.episode.number)" } ?? (s.seasons == 1 ? String(localized: "1 season") : String(localized: "\(s.seasons) seasons")),
                                    artwork: s.poster,
                                    fraction: (pos?.isMidEpisode == true) ? (pos?.progress?.fraction ?? 0) : 0,
                                    badge: pos != nil ? String(localized: "Continue") : nil) {
                        push(CarRoute.seriesDetail(s))
                    }
                }
            }
            .padding(.horizontal, m.gutter).padding(.top, Theme.s2).padding(.bottom, m.gutter)
        }
    }
}

/// 2:3 poster with title, optional "Resume"/"Continue" badge and a progress bar.
struct CarPosterButton: View {
    @Environment(\.carMetrics) private var m
    let title: String
    let subtitle: String
    let artwork: URL?
    let fraction: Double
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottom) {
                    ZStack {
                        TileTint.gradient(for: title)
                        RemoteImage(url: artwork, targetSize: CGSize(width: 240, height: 360), contentMode: .fill) {
                            Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if let badge {
                        VStack { HStack { Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(.black).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent, in: Capsule()); Spacer() }; Spacer() }.padding(6)
                    }
                    if fraction > 0.01 { ProgressBar(fraction: fraction, height: 3) }
                }
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                Text(title).font(.system(size: m.compact ? 12 : 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: m.compact ? 10.5 : 12, weight: .medium)).foregroundStyle(Theme.inkMuted).lineLimit(1) }
            }
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        }
        .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

// MARK: - Series detail (seasons + episodes)

struct CarSeriesDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackController.self) private var playback
    @Environment(\.carMetrics) private var m
    let series: VODSeries

    @State private var seasons: [VODSeason] = []
    @State private var season: VODSeason?
    @State private var episodes: [VODEpisode] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        let _ = env.progress.revision
        let pos = env.vod.position(in: series)
        ScrollView {
            VStack(alignment: .leading, spacing: m.compact ? Theme.s3 : Theme.s4) {
                // Hero row: poster + "Continue S2 · E4" as the single big action.
                HStack(alignment: .top, spacing: Theme.s3) {
                    ZStack {
                        TileTint.gradient(for: series.title)
                        RemoteImage(url: season?.poster ?? series.poster, targetSize: CGSize(width: 240, height: 360), contentMode: .fill) { EmptyView() }
                    }
                    .frame(width: m.compact ? 80 : 120, height: (m.compact ? 80 : 120) * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))

                    VStack(alignment: .leading, spacing: Theme.s2) {
                        if let s = season, s.description.nilIfEmpty != nil {
                            Text(s.description).font(.system(size: m.compact ? 11.5 : 13.5)).foregroundStyle(Theme.inkMuted).lineLimit(m.compact ? 3 : 4)
                        }
                        if let pos {
                            Button { resume(pos) } label: {
                                HStack(spacing: Theme.s2) {
                                    Image(systemName: "play.fill")
                                    Text(pos.isMidEpisode ? "Resume S\(pos.season.name) · E\(pos.episode.number)" : "Continue S\(pos.season.name) · E\(pos.episode.number + 1)")
                                    if pos.isMidEpisode, let p = pos.progress {
                                        Text("· \((p.duration - p.position).clockString) left").foregroundStyle(.black.opacity(0.6))
                                    }
                                }
                                .font(.system(size: m.compact ? 13 : 16, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, Theme.s4).frame(height: m.compact ? 40 : Theme.Car.minTarget)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(CarFocusButtonStyle(radius: 100))
                            .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
                        } else if let first = episodes.first, let season {
                            Button { play(first, in: season) } label: {
                                Label("Play S\(season.name) · E\(first.number)", systemImage: "play.fill")
                                    .font(.system(size: m.compact ? 13 : 16, weight: .semibold)).foregroundStyle(.black)
                                    .padding(.horizontal, Theme.s4).frame(height: m.compact ? 40 : Theme.Car.minTarget)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(CarFocusButtonStyle(radius: 100))
                            .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, m.gutter)

                if loading {
                    HStack { ProgressView().tint(Theme.accent); Text("Loading episodes…").font(.system(size: 13)).foregroundStyle(Theme.inkMuted) }.padding(.horizontal, m.gutter)
                } else if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.amber).padding(.horizontal, m.gutter)
                } else {
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.s2) {
                                ForEach(seasons) { s in
                                    Button { select(s) } label: {
                                        Text("Season \(s.name)").font(.system(size: m.compact ? 12 : 14, weight: .semibold))
                                            .padding(.horizontal, Theme.s3).frame(height: m.compact ? 34 : 40)
                                            .foregroundStyle(season?.id == s.id ? .black : Theme.ink)
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(CarFocusButtonStyle(radius: 100))
                                    .glassEffect(season?.id == s.id ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
                                }
                            }
                            .padding(.horizontal, m.gutter)
                        }
                    }
                    LazyVStack(spacing: Theme.s1) {
                        ForEach(episodes) { ep in
                            let ref = PlayableRef(id: ep.playableID, kind: .vod)
                            let p = env.progress.progress(for: ref)
                            CarEpisodeRow(episode: ep, progress: p, isPlaying: playback.current?.id == ep.playableID,
                                          isLastWatched: pos?.episode.id == ep.id) {
                                if let season { play(ep, in: season) }
                            }
                        }
                    }
                    .padding(.horizontal, m.gutter)
                }
            }
            .padding(.top, Theme.s2).padding(.bottom, m.gutter)
        }
        .task { await load(preferring: pos?.season) }
    }

    private func load(preferring preferred: VODSeason?) async {
        loading = true; error = nil
        do {
            seasons = try await env.vod.seasons(for: series)
            let target = preferred.flatMap { p in seasons.first { $0.id == p.id } } ?? seasons.first
            if let target { await select(target) } else { error = String(localized: "No seasons available") }
        } catch { self.error = String(localized: "Couldn't load seasons") }
        loading = false
    }

    private func select(_ s: VODSeason) { Task { await select(s) } }
    private func select(_ s: VODSeason) async {
        season = s
        episodes = (try? await env.vod.episodes(for: s)) ?? []
    }

    private func play(_ ep: VODEpisode, in season: VODSeason) {
        let queue = episodes.map { PlayableItem(episode: $0, series: series, season: season) }
        guard let item = queue.first(where: { $0.id == ep.playableID }) else { return }
        env.vod.rememberPlayed(episodes: episodes, series: series, season: season)
        playback.play(item, queue: queue, origin: .car, resume: true)
    }

    private func resume(_ pos: VODService.SeriesPosition) {
        Task {
            let eps = (try? await env.vod.episodes(for: pos.season)) ?? [pos.episode]
            let target: VODEpisode
            if pos.isMidEpisode { target = pos.episode }
            else if let i = eps.firstIndex(where: { $0.id == pos.episode.id }), i + 1 < eps.count { target = eps[i + 1] }
            else { target = pos.episode }
            if season?.id != pos.season.id { season = pos.season; episodes = eps }
            play(target, in: pos.season)
        }
    }
}

private struct CarEpisodeRow: View {
    @Environment(\.carMetrics) private var m
    let episode: VODEpisode
    let progress: WatchProgress?
    let isPlaying: Bool
    let isLastWatched: Bool
    let action: () -> Void

    var body: some View {
        let watched = progress?.completed == true
        let mid = (progress?.completed == false) && (progress?.position ?? 0) > 5
        Button(action: action) {
            HStack(spacing: Theme.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isPlaying ? Theme.accent.opacity(0.2) : (isLastWatched ? Theme.accent.opacity(0.12) : Theme.raised))
                        .frame(width: m.compact ? 40 : 48, height: m.compact ? 40 : 48)
                    if isPlaying { EqualizerBars().scaleEffect(m.compact ? 0.55 : 0.7) }
                    else if watched { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent) }
                    else { Text("\(episode.number)").font(.system(size: m.compact ? 15 : 18, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Episode \(episode.number)").font(.system(size: m.compact ? 13 : 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        if isLastWatched && !isPlaying {
                            Text(mid ? "Resume" : "Last watched").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if mid, let p = progress {
                            ProgressBar(fraction: p.fraction, height: 2.5).frame(width: m.compact ? 60 : 90)
                            Text("\((p.duration - p.position).clockString) left").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkMuted)
                        } else if watched {
                            Text("Watched").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.inkMuted)
                        }
                        if !episode.subtitles.isEmpty {
                            Text("CC").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent).padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.s2)
            .frame(minHeight: m.compact ? 48 : Theme.Car.minTarget)
            .background(isPlaying ? Theme.accent.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
        }
        .buttonStyle(CarFocusButtonStyle())
    }
}
