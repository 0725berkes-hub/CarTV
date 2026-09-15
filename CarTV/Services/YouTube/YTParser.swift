import Foundation
import OSLog

/// Converts InnerTube renderer trees into `YTItem`s. YouTube wraps the same data in
/// a dozen renderer names depending on surface (home vs search vs channel), so we
/// pattern-match on renderer keys and pull common fields.
nonisolated enum YTParser {

    // MARK: Pages

    static func page(_ json: JSONObject) -> YTPage {
        var shelves: [YTShelf] = []
        var continuation: String?

        // Shelves with titles (home / channel tabs)
        let shelfRenderers = json.findAll("shelfRenderer") + json.findAll("richShelfRenderer") + json.findAll("itemSectionRenderer")
        var seenIDs = Set<String>()
        for shelf in shelfRenderers {
            let title = shelf["title"].text ?? shelf["headerRenderer"].find("title").text
            let items = collectItems(shelf).filter { seenIDs.insert($0.id).inserted }
            if !items.isEmpty { shelves.append(YTShelf(title: title, items: items)) }
        }
        // Flat items not inside a titled shelf (home feed rich grid, search results)
        let loose = collectItems(json).filter { seenIDs.insert($0.id).inserted }
        if !loose.isEmpty { shelves.insert(YTShelf(title: nil, items: loose), at: 0) }

        continuation = json.findAll("continuationCommand").compactMap { $0["token"].string }.first
            ?? json.findAll("nextContinuationData").compactMap { $0["continuation"].string }.first
            ?? json.findAll("continuationEndpoint").compactMap { $0["continuationCommand"]["token"].string }.first
        return YTPage(shelves: shelves, continuation: continuation)
    }

    /// Every video / channel / playlist renderer below `node`, in document order.
    static func collectItems(_ node: JSONObject) -> [YTItem] {
        var out: [YTItem] = []
        func walk(_ n: Any?, depth: Int) {
            guard depth < 18 else { return }
            if let d = n as? [String: Any] {
                if let v = d["videoRenderer"] ?? d["compactVideoRenderer"] ?? d["gridVideoRenderer"] ?? d["playlistVideoRenderer"] ?? d["videoWithContextRenderer"] {
                    if let video = video(JSONObject(v)) { out.append(.video(video)) }; return
                }
                if let l = d["lockupViewModel"] {   // new-style home/search cards
                    if let item = lockup(JSONObject(l)) { out.append(item) }; return
                }
                if let t = d["tileRenderer"] {      // TV client cards
                    if let item = tile(JSONObject(t)) { out.append(item) }; return
                }
                if let c = d["channelRenderer"] ?? d["gridChannelRenderer"] {
                    if let ch = channel(JSONObject(c)) { out.append(.channel(ch)) }; return
                }
                if let p = d["playlistRenderer"] ?? d["gridPlaylistRenderer"] ?? d["compactPlaylistRenderer"] {
                    if let pl = playlist(JSONObject(p)) { out.append(.playlist(pl)) }; return
                }
                if d["reelItemRenderer"] != nil || d["shortsLockupViewModel"] != nil { return }   // skip Shorts
                for v in d.values { walk(v, depth: depth + 1) }
            } else if let a = n as? [Any] {
                for v in a { walk(v, depth: depth + 1) }
            }
        }
        walk(node.raw, depth: 0)
        return out
    }

    // MARK: Renderers

    static func video(_ r: JSONObject) -> YTVideo? {
        guard let id = r["videoId"].string else { return nil }
        var v = YTVideo(id: id, title: r["title"].text ?? r["headline"].text ?? "")
        let owner = r["ownerText"].exists ? r["ownerText"] : (r["shortBylineText"].exists ? r["shortBylineText"] : r["longBylineText"])
        v.channelName = owner.text
        v.channelID = owner["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        v.channelAvatarURL = bestThumb(r["channelThumbnailSupportedRenderers"].find("thumbnails")) ?? bestThumb(r["channelThumbnail"]["thumbnails"])
        v.thumbnailURL = bestThumb(r["thumbnail"]["thumbnails"]) ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        v.durationText = r["lengthText"].text ?? r["thumbnailOverlays"].findAll("thumbnailOverlayTimeStatusRenderer").first?["text"].text
        v.durationSeconds = v.durationText.flatMap(parseDuration)
        v.viewsText = r["shortViewCountText"].text ?? r["viewCountText"].text
        v.publishedText = r["publishedTimeText"].text
        v.isLive = r["badges"].findAll("metadataBadgeRenderer").contains { $0["style"].string?.contains("LIVE") == true }
            || r["thumbnailOverlays"].findAll("thumbnailOverlayTimeStatusRenderer").contains { $0["style"].string == "LIVE" }
        if let pct = r["thumbnailOverlays"].findAll("thumbnailOverlayResumePlaybackRenderer").first?["percentDurationWatched"].int {
            v.progressFraction = Double(pct) / 100
        }
        return v
    }

    /// `lockupViewModel` — YouTube's 2024+ card format used on Home and Search.
    static func lockup(_ l: JSONObject) -> YTItem? {
        let contentType = l["contentType"].string ?? ""
        let id = l["contentId"].string ?? ""
        let meta = l["metadata"]["lockupMetadataViewModel"]
        let title = meta["title"]["content"].string ?? ""
        let thumb = l["contentImage"].find("sources").array.last?["url"].string.flatMap(URL.init)
            ?? l["contentImage"].find("image")["sources"].array.last?["url"].string.flatMap(URL.init)
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        let parts = rows.flatMap { $0["metadataParts"].array }.compactMap { $0["text"]["content"].string }

        if contentType.contains("PLAYLIST") {
            return .playlist(YTPlaylist(id: id, title: title, channelName: parts.first, thumbnailURL: thumb, videoCountText: parts.dropFirst().first))
        }
        if contentType.contains("CHANNEL") {
            return .channel(YTChannel(id: id, name: title, avatarURL: thumb, subscribersText: parts.first))
        }
        guard !id.isEmpty else { return nil }
        var v = YTVideo(id: id, title: title)
        v.channelName = parts.first
        v.channelID = rows.first?["metadataParts"][0]["text"]["commandRuns"][0]["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].string
        v.viewsText = parts.dropFirst().first
        v.publishedText = parts.dropFirst(2).first
        v.thumbnailURL = thumb ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        v.channelAvatarURL = meta["image"].find("sources").array.last?["url"].string.flatMap(URL.init)
        let overlays = l["contentImage"].findAll("thumbnailBadgeViewModel")
        if let badge = overlays.first?["text"].string {
            if badge.uppercased() == "LIVE" { v.isLive = true } else { v.durationText = badge; v.durationSeconds = parseDuration(badge) }
        }
        if let pct = l["contentImage"].find("thumbnailBottomOverlayViewModel").find("progressBarViewModel")["startPercent"].int {
            v.progressFraction = Double(pct) / 100
        }
        return .video(v)
    }

    /// `tileRenderer` — TVHTML5's card. Videos, playlists/mixes and channels all use it.
    static func tile(_ t: JSONObject) -> YTItem? {
        let raw = JSONObject(t.raw)
        // Skip ads.
        if !raw.findAll("adBadgeViewModel").isEmpty { return nil }
        let meta = t["metadata"]["tileMetadataRenderer"]
        let header = t["header"]["tileHeaderRenderer"]
        // Title/thumb live in a few places depending on tile style; try them all.
        let title = meta["title"].text
            ?? header["title"].text
            ?? t.find("title").text
            ?? ""
        let thumb = bestThumb(header["thumbnail"]["thumbnails"])
            ?? bestThumb(header.find("thumbnails"))
            ?? bestThumb(t["contentImage"].find("thumbnails"))
            ?? t.find("sources").array.last?["url"].string.flatMap(URL.init)
        let lines = meta["lines"].array.map { line in
            line["lineRenderer"]["items"].array.compactMap { $0["lineItemRenderer"]["text"].text }.filter { $0 != "•" }
        }
        let flat = lines.flatMap { $0 }
        let select = t["onSelectCommand"]
        let watch = select.find("watchEndpoint")
        let browse = select.find("browseEndpoint")

        if let vid = watch["videoId"].string {
            var v = YTVideo(id: vid, title: title)
            v.thumbnailURL = thumb ?? URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")
            v.channelName = lines.first?.first
            v.viewsText = flat.first { $0.localizedCaseInsensitiveContains("view") }
            v.publishedText = flat.first { $0.localizedCaseInsensitiveContains("ago") || $0.localizedCaseInsensitiveContains("Streamed") }
            for o in header["thumbnailOverlays"].array {
                let ts = o["thumbnailOverlayTimeStatusRenderer"]
                if ts.exists {
                    if ts["style"].string == "LIVE" || ts["text"].text?.uppercased() == "LIVE" { v.isLive = true }
                    else if let d = ts["text"].text, let secs = parseDuration(d) { v.durationText = d; v.durationSeconds = secs }
                }
                if let pct = o["thumbnailOverlayResumePlaybackRenderer"]["percentDurationWatched"].int { v.progressFraction = Double(pct) / 100 }
            }
            // A "Mix" tile is a radio playlist; still playable as a video with a playlist context.
            return .video(v)
        }
        // Library shortcut tiles ("History", "Playlists", …) carry no artwork at all; those
        // are navigation rows, not content — drop the ones that aren't playlists/channels.
        if thumb == nil, let bid = browse["browseId"].string, bid.hasPrefix("FE") { return nil }
        if title.isEmpty || thumb == nil {
            // Shape we don't know yet — log a compact outline so it can be added.
            let keys = (t.raw as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "?"
            let headerKeys = (header.raw as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
            let metaKeys = (meta.raw as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
            Log.network.notice("YT tile unparsed title=\(title.isEmpty ? "EMPTY" : "ok", privacy: .public) thumb=\(thumb == nil ? "nil" : "ok", privacy: .public) keys=[\(keys, privacy: .public)] header=[\(headerKeys, privacy: .public)] meta=[\(metaKeys, privacy: .public)] browse=\(browse["browseId"].string ?? "-", privacy: .public)")
        }
        if let bid = browse["browseId"].string {
            if bid.hasPrefix("UC") {
                return .channel(YTChannel(id: bid, name: title, avatarURL: thumb, subscribersText: flat.first))
            }
            let pid = bid.hasPrefix("VL") ? String(bid.dropFirst(2)) : bid
            // Count often sits in a thumbnail overlay ("12 videos") rather than the lines.
            let overlayCount = header["thumbnailOverlays"].array.compactMap { $0.find("text").text }.first { $0.localizedCaseInsensitiveContains("video") }
            // Playlists without a thumbnail: derive from the first video if the tile carries one.
            let fallbackThumb = thumb ?? (watch["videoId"].string ?? t.find("videoId").string).map { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg")! }
            return .playlist(YTPlaylist(id: pid, title: title.nilIfEmpty ?? String(localized: "Playlist"), channelName: lines.first?.first,
                                        thumbnailURL: fallbackThumb, videoCountText: overlayCount ?? flat.first { $0.localizedCaseInsensitiveContains("video") }))
        }
        // Playlist tiles sometimes only carry a playlistId inside a watch/playlist endpoint.
        if let pid = select.find("playlistId").string, watch["videoId"].string == nil {
            return .playlist(YTPlaylist(id: pid, title: title.nilIfEmpty ?? String(localized: "Playlist"), channelName: lines.first?.first, thumbnailURL: thumb, videoCountText: flat.first { $0.localizedCaseInsensitiveContains("video") }))
        }
        return nil
    }

    static func channel(_ r: JSONObject) -> YTChannel? {
        guard let id = r["channelId"].string else { return nil }
        var c = YTChannel(id: id, name: r["title"].text ?? "")
        c.avatarURL = bestThumb(r["thumbnail"]["thumbnails"])
        c.subscribersText = r["subscriberCountText"].text ?? r["videoCountText"].text
        c.description = r["descriptionSnippet"].text
        c.handle = r["subscriberCountText"].text.flatMap { $0.hasPrefix("@") ? $0 : nil }
        return c
    }

    static func playlist(_ r: JSONObject) -> YTPlaylist? {
        guard let id = r["playlistId"].string else { return nil }
        var p = YTPlaylist(id: id, title: r["title"].text ?? "")
        p.channelName = r["shortBylineText"].text ?? r["longBylineText"].text
        p.thumbnailURL = bestThumb(r["thumbnail"]["thumbnails"]) ?? bestThumb(r["thumbnails"][0]["thumbnails"])
        p.videoCountText = r["videoCountText"].text ?? r["videoCountShortText"].text
        return p
    }

    // MARK: Watch page

    struct WatchInfo: Sendable {
        var title: String?
        var channel: YTChannel?
        var viewsText: String?
        var publishedText: String?
        var likesText: String?
        var description: String?
        var isLiked: Bool?
        var isSubscribed: Bool?
        var related: [YTVideo]
        var relatedContinuation: String?
        var commentsContinuation: String?
        var commentCountText: String?
    }

    static func watch(_ json: JSONObject) -> WatchInfo {
        var w = WatchInfo(related: [])
        let primary = json.find("videoPrimaryInfoRenderer")
        let secondary = json.find("videoSecondaryInfoRenderer")
        w.title = primary["title"].text
        w.viewsText = primary["viewCount"].find("shortViewCount").text ?? primary["viewCount"].find("viewCount").text
        w.publishedText = primary["dateText"].text ?? primary["relativeDateText"].text
        let like = primary.find("segmentedLikeDislikeButtonViewModel")
        w.likesText = like.find("likeCountEntity")["likeCountIfLiked"].find("content").string
            ?? like.find("toggleButtonViewModel")["defaultButtonViewModel"]["buttonViewModel"]["title"].string
            ?? primary.findAll("toggleButtonRenderer").first?["defaultText"].text
        w.isLiked = like.find("likeStatusEntity")["likeStatus"].string == "LIKE"
        let owner = secondary["owner"]["videoOwnerRenderer"]
        if let cid = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].string {
            var c = YTChannel(id: cid, name: owner["title"].text ?? "")
            c.avatarURL = bestThumb(owner["thumbnail"]["thumbnails"])
            c.subscribersText = owner["subscriberCountText"].text
            c.isSubscribed = secondary.find("subscribeButtonRenderer")["subscribed"].bool
            w.channel = c
        }
        w.description = secondary["attributedDescription"]["content"].string ?? secondary["description"].text
        // WEB layout: right-hand column. TVHTML5 layout (signed-in): the "pivot" shelves
        // plus the autoplay set, which is exactly what YouTube itself plays next.
        let web = json["contents"]["twoColumnWatchNextResults"]["secondaryResults"]["secondaryResults"]
        var related: [YTVideo] = collectItems(web).compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        var continuation = web.findAll("continuationCommand").first?["token"].string
        if related.isEmpty {
            let tv = json["contents"]["singleColumnWatchNextResults"]
            let autoplayIDs = tv["autoplay"]["autoplay"]["sets"].array.compactMap { $0["autoplayVideoRenderer"].find("watchEndpoint")["videoId"].string }
            let pivot = collectItems(tv["pivot"]).compactMap { if case .video(let v) = $0 { return v } else { return nil } }
            // Autoplay picks first (as stubs if the pivot doesn't list them), then the shelves.
            var seen = Set<String>()
            for id in autoplayIDs where !seen.contains(id) {
                seen.insert(id)
                related.append(pivot.first { $0.id == id } ?? YTVideo(id: id, title: ""))
            }
            for v in pivot where !seen.contains(v.id) { seen.insert(v.id); related.append(v) }
            continuation = tv["pivot"].findAll("continuationCommand").first?["token"].string
        }
        w.related = related
        w.relatedContinuation = continuation
        for section in json.findAll("itemSectionRenderer") where section["sectionIdentifier"].string == "comment-item-section" {
            w.commentsContinuation = section.find("continuationCommand")["token"].string
        }
        w.commentCountText = json.find("commentsEntryPointHeaderRenderer")["commentCount"].text
        return w
    }

    static func comments(_ json: JSONObject) -> (items: [YTComment], continuation: String?) {
        var out: [YTComment] = []
        for c in json.findAll("commentEntityPayload") {
            let props = c["properties"], author = c["author"], toolbar = c["toolbar"]
            guard let id = props["commentId"].string else { continue }
            out.append(YTComment(id: id, author: author["displayName"].string ?? "", avatarURL: author["avatarThumbnailUrl"].string.flatMap(URL.init),
                                 text: props["content"]["content"].string ?? "", likesText: toolbar["likeCountNotliked"].string, publishedText: props["publishedTime"].string,
                                 replyCount: toolbar["replyCount"].string.flatMap(Int.init)))
        }
        if out.isEmpty {   // legacy commentRenderer
            for c in json.findAll("commentRenderer") {
                guard let id = c["commentId"].string else { continue }
                out.append(YTComment(id: id, author: c["authorText"].text ?? "", avatarURL: bestThumb(c["authorThumbnail"]["thumbnails"]), text: c["contentText"].text ?? "",
                                     likesText: c["voteCount"].text, publishedText: c["publishedTimeText"].text, replyCount: c["replyCount"].int))
            }
        }
        let cont = json.findAll("continuationCommand").compactMap { $0["token"].string }.last
        return (out, cont)
    }

    // MARK: Channel page

    static func channelHeader(_ json: JSONObject, id: String) -> YTChannel {
        let h = json["header"]
        let pageHeader = h["pageHeaderRenderer"]["content"]["pageHeaderViewModel"]
        let legacy = h["c4TabbedHeaderRenderer"]
        var c = YTChannel(id: id, name: pageHeader["title"].find("content").string ?? legacy["title"].string ?? json["metadata"]["channelMetadataRenderer"]["title"].string ?? "")
        c.avatarURL = pageHeader["image"].find("sources").array.last?["url"].string.flatMap(URL.init) ?? bestThumb(legacy["avatar"]["thumbnails"])
        c.bannerURL = pageHeader["banner"].find("sources").array.last?["url"].string.flatMap(URL.init) ?? bestThumb(legacy["banner"]["thumbnails"])
        let rows = pageHeader["metadata"]["contentMetadataViewModel"]["metadataRows"].array.flatMap { $0["metadataParts"].array }.compactMap { $0["text"]["content"].string }
        c.handle = rows.first(where: { $0.hasPrefix("@") }) ?? legacy["channelHandleText"].text
        c.subscribersText = rows.first(where: { $0.localizedCaseInsensitiveContains("subscriber") }) ?? legacy["subscriberCountText"].text
        c.videoCountText = rows.first(where: { $0.localizedCaseInsensitiveContains("video") }) ?? legacy["videosCountText"].text
        c.description = json["metadata"]["channelMetadataRenderer"]["description"].string
        c.isSubscribed = json.find("subscribeButtonRenderer")["subscribed"].bool
        return c
    }

    // MARK: Helpers

    static func bestThumb(_ thumbs: JSONObject) -> URL? {
        thumbs.array.last?["url"].string.flatMap { s in URL(string: s.hasPrefix("//") ? "https:" + s : s) }
    }

    static func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
