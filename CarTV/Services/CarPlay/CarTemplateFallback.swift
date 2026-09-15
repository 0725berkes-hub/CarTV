import UIKit
import CarPlay
import SwiftData

/// Template-based CarPlay UI used only when the head unit does not hand us a
/// drawable window. Browsing works via CPTabBar/CPList; playback is presented
/// by the system video player (via `CPPlaybackConfiguration(.video)`) or Now Playing.
final class CarTemplateFallback: NSObject {
    private let interfaceController: CPInterfaceController
    private let playback: PlaybackController
    private let env = AppEnvironment.shared

    init(interfaceController: CPInterfaceController, playback: PlaybackController) {
        self.interfaceController = interfaceController
        self.playback = playback
        super.init()
        interfaceController.delegate = self
    }

    func installRoot() {
        let home = CPListTemplate(title: String(localized: "Home"), sections: homeSections())
        home.tabImage = UIImage(systemName: "house.fill")
        home.emptyViewTitleVariants = [String(localized: "Your library is empty")]
        home.emptyViewSubtitleVariants = [String(localized: "Add sources on your iPhone first")]

        let favorites = CPListTemplate(title: String(localized: "Favorites"), sections: favoriteSections())
        favorites.tabImage = UIImage(systemName: "heart.fill")
        favorites.emptyViewTitleVariants = [String(localized: "Nothing saved yet")]

        let library = CPListTemplate(title: String(localized: "Library"), sections: librarySections())
        library.tabImage = UIImage(systemName: "square.stack.fill")

        let tabBar = CPTabBarTemplate(templates: [home, favorites, library])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    func presentNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        if #available(iOS 27.0, *) { nowPlaying.allowsMiniPlayer = true }
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    // MARK: Sections

    private func homeSections() -> [CPListSection] {
        var sections: [CPListSection] = []
        let recents = env.progress.recentItems(limit: 12)
        if !recents.isEmpty {
            sections.append(CPListSection(items: recents.map(listItem), header: String(localized: "History"), sectionIndexTitle: nil))
        }
        for playlist in env.library.playlists() {
            let items = env.library.channels(in: playlist, limit: 40).map { PlayableItem(channel: $0, playlistName: playlist.name) }
            guard !items.isEmpty else { continue }
            sections.append(CPListSection(items: items.map(listItem), header: playlist.name, sectionIndexTitle: nil))
        }
        return sections
    }

    private func favoriteSections() -> [CPListSection] {
        let items = env.favorites.favoriteItems()
        guard !items.isEmpty else { return [] }
        return [CPListSection(items: items.map(listItem))]
    }

    private func librarySections() -> [CPListSection] {
        var sections: [CPListSection] = []
        let playlists = env.library.playlists()
        if !playlists.isEmpty {
            let items = playlists.map { playlist -> CPListItem in
                let item = CPListItem(text: playlist.name, detailText: String(localized: "\(playlist.channelCount) channels"), image: UIImage(systemName: "list.bullet.rectangle.fill"))
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.pushChannels(of: playlist)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: String(localized: "My Sources"), sectionIndexTitle: nil))
        }
        let videos = env.library.localVideos(limit: 60).map(PlayableItem.init(video:))
        if !videos.isEmpty {
            sections.append(CPListSection(items: videos.map(listItem), header: String(localized: "Videos"), sectionIndexTitle: nil))
        }
        return sections
    }

    private func pushChannels(of playlist: Playlist) {
        let grouped = env.library.channelsByGenre(in: playlist)
        let sections = grouped.map { genre, channels in
            CPListSection(
                items: channels.prefix(80).map { listItem(PlayableItem(channel: $0, playlistName: playlist.name)) },
                header: String(localized: genre.title),
                sectionIndexTitle: nil
            )
        }
        let template = CPListTemplate(title: playlist.name, sections: sections)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func listItem(_ item: PlayableItem) -> CPListItem {
        let listItem = CPListItem(
            text: item.title,
            detailText: item.subtitle,
            image: UIImage(systemName: item.isLive ? "dot.radiowaves.left.and.right" : "play.rectangle.fill")
        )
        listItem.isPlaying = playback.current?.id == item.id
        listItem.playingIndicatorLocation = .trailing
        if #available(iOS 26.4, *) {
            listItem.playbackConfiguration = CPPlaybackConfiguration(
                preferredPresentation: .video,
                playbackAction: .play,
                elapsedTime: .zero,
                duration: item.duration > 0 ? CMTime(seconds: item.duration, preferredTimescale: 600) : .zero
            )
        }
        listItem.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            self.playback.play(item, origin: .car)
            self.presentNowPlaying()
            completion()
        }
        return listItem
    }
}

extension CarTemplateFallback: CPInterfaceControllerDelegate {}
