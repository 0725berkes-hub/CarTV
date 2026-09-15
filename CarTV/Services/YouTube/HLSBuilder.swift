import Foundation
import OSLog

/// Turns YouTube's DASH adaptive formats into an HLS master + media playlists that
/// AVPlayer streams natively (fMP4 with EXT-X-BYTERANGE). Each variant is one
/// long "segment" list built from the format's SIDX index so seeking is exact.
///
/// Output lives in the caches dir and is served over loopback HTTP by
/// `LocalPlaylistServer` (AVPlayer stalls on file:// playlists with https segments).
nonisolated enum HLSBuilder {

    struct Result: Sendable {
        let masterURL: URL
        let variants: [(height: Int, label: String)]
    }

    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "YouTubeHLS", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Builds playlists. Downloads only the tiny SIDX index boxes (a few KB each).
    static func build(_ resp: YTPlayerResponse, maxHeight: Int = 2160) async throws -> Result {
        let dir = root.appending(path: resp.videoID, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let audio = resp.bestDefaultAudio else { throw YTError.unavailable("No AAC audio stream") }
        let videos = resp.avVideoFormats.filter { ($0.height ?? 0) <= maxHeight }
        guard !videos.isEmpty else { throw YTError.unavailable("No AVC video streams") }

        // Fetch indexes concurrently.
        let audioSegs = try await segments(for: audio)
        var videoSegs: [Int: [Segment]] = [:]
        try await withThrowingTaskGroup(of: (Int, [Segment]).self) { group in
            for v in videos { group.addTask { (v.itag, try await segments(for: v)) } }
            for try await (itag, segs) in group { videoSegs[itag] = segs }
        }

        // Media playlists
        let audioName = "audio-\(audio.itag).m3u8"
        try mediaPlaylist(audio, audioSegs).write(to: dir.appending(path: audioName), atomically: true, encoding: .utf8)
        var variantLines: [String] = []
        var variants: [(Int, String)] = []
        for v in videos {
            guard let segs = videoSegs[v.itag], !segs.isEmpty else { continue }
            let name = "video-\(v.itag).m3u8"
            try mediaPlaylist(v, segs).write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
            let bw = v.bitrate + audio.bitrate
            let codecs = "\(v.codecs),\(audio.codecs)"
            let res = "\(v.width ?? 0)x\(v.height ?? 0)"
            let fr = v.fps.map { ",FRAME-RATE=\($0)" } ?? ""
            variantLines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bw),AVERAGE-BANDWIDTH=\(bw),CODECS=\"\(codecs)\",RESOLUTION=\(res)\(fr),AUDIO=\"aud\"\n\(name)")
            variants.append((v.height ?? 0, v.qualityLabel ?? "\(v.height ?? 0)p"))
        }

        func master(_ lines: [String]) -> String {
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="\(audio.language ?? "Audio")",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioName)"
            \(lines.joined(separator: "\n"))
            """
        }
        // Auto = every variant; plus one single-variant master per height so a manual
        // pick is exact (AVPlayer's preferredMaximumResolution is only an upper bound).
        try master(variantLines).write(to: dir.appending(path: "master.m3u8"), atomically: true, encoding: .utf8)
        for (line, v) in zip(variantLines, variants) {
            try master([line]).write(to: dir.appending(path: "master-\(v.0).m3u8"), atomically: true, encoding: .utf8)
        }
        let base = try await LocalPlaylistServer.shared.start()
        let masterURL = base.appending(path: resp.videoID).appending(path: "master.m3u8")
        Log.player.info("HLS built for \(resp.videoID, privacy: .public): \(variants.count) variants → \(masterURL.absoluteString, privacy: .public)")
        return Result(masterURL: masterURL, variants: variants)
    }

    // MARK: Native master mirroring

    /// Downloads YouTube's own HLS master, keeps the AVC/AAC variants (one per height,
    /// highest bitrate wins), and writes `master.m3u8` (full ladder) plus
    /// `master-<height>.m3u8` (single variant) next to each other. Media playlists
    /// and segments stay on Google's servers — only the tiny master is local.
    static func mirrorNativeMaster(_ remote: URL, videoID: String) async throws -> Result {
        let (data, resp) = try await URLSession.shared.data(from: remote)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw YTError.network("HLS master HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")

        var header: [String] = []          // EXTM3U, version, independent-segments, EXT-X-MEDIA…
        var streams: [(height: Int, bandwidth: Int, codecs: String, inf: String, uri: String)] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.hasPrefix("#EXT-X-STREAM-INF") {
                let uri = i + 1 < lines.count ? lines[i + 1] : ""
                let attrs = l
                func attr(_ k: String) -> String? {
                    guard let r = attrs.range(of: k + "=") else { return nil }
                    var rest = attrs[r.upperBound...]
                    if rest.hasPrefix("\"") { rest = rest.dropFirst(); return String(rest.prefix { $0 != "\"" }) }
                    return String(rest.prefix { $0 != "," })
                }
                let res = attr("RESOLUTION") ?? "0x0"
                let h = Int(res.split(separator: "x").last ?? "") ?? 0
                let bw = Int(attr("BANDWIDTH") ?? "") ?? 0
                let codecs = attr("CODECS") ?? ""
                if codecs.contains("avc1") || codecs.contains("hvc1") || codecs.contains("hev1") || codecs.contains("dvh1") {
                    // Skip VP9/AV1 — AVFoundation can't do them in HLS reliably on all devices.
                    streams.append((h, bw, codecs, l, uri))
                }
                i += 2; continue
            }
            if l.hasPrefix("#") || l.isEmpty { header.append(l) }
            i += 1
        }
        guard !streams.isEmpty else { throw YTError.unavailable("No AVC variants in HLS master") }

        // One variant per height (highest bitrate), ascending.
        var byHeight: [Int: (height: Int, bandwidth: Int, codecs: String, inf: String, uri: String)] = [:]
        for st in streams { if let cur = byHeight[st.height] { if st.bandwidth > cur.bandwidth { byHeight[st.height] = st } } else { byHeight[st.height] = st } }
        let ladder = byHeight.values.sorted { $0.height < $1.height }

        let dir = root.appending(path: videoID, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let head = header.filter { !$0.isEmpty }.joined(separator: "\n")
        func write(_ name: String, _ variants: [(height: Int, bandwidth: Int, codecs: String, inf: String, uri: String)]) throws {
            let body = variants.map { "\($0.inf)\n\($0.uri)" }.joined(separator: "\n")
            try (head + "\n" + body + "\n").write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }
        try write("master.m3u8", ladder)
        for v in ladder { try write("master-\(v.height).m3u8", [v]) }

        let base = try await LocalPlaylistServer.shared.start()
        let masterURL = base.appending(path: videoID).appending(path: "master.m3u8")
        let variants = ladder.map { ($0.height, $0.height >= 2160 ? "4K" : "\($0.height)p") }
        Log.player.info("HLS mirrored for \(videoID, privacy: .public): \(variants.map(\.1).joined(separator: ","), privacy: .public)")
        return Result(masterURL: masterURL, variants: variants)
    }

    // MARK: Segments from SIDX

    struct Segment: Sendable { let offset: Int64; let length: Int64; let duration: Double }

    private static func segments(for f: YTFormat) async throws -> [Segment] {
        guard f.initRange != nil, let idx = f.indexRange else {
            // No index → one segment covering the whole file.
            let dur = Double(f.approxDurationMs ?? 0) / 1000
            return [Segment(offset: 0, length: f.contentLength ?? 0, duration: dur)]
        }
        var req = URLRequest(url: f.url)
        req.setValue("bytes=\(idx.lowerBound)-\(idx.upperBound)", forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let u = f.url.absoluteString
            let keys = u.split(separator: "?").last?.split(separator: "&").map { String($0.split(separator: "=").first ?? "") }.joined(separator: ",") ?? ""
            Log.network.error("YT SIDX itag \(f.itag) HTTP \(http.statusCode) n=\(YTChallengeSolver.nParam(of: f.url) ?? "-", privacy: .public) marker=\(u.contains("__cipher_s")) sig=\(u.contains("&sig=") || u.contains("&signature=")) params=[\(keys, privacy: .public)]")
            throw YTError.network("HTTP \(http.statusCode)")
        }
        let parsed = SIDX.parse(data)
        guard !parsed.isEmpty else {
            let dur = Double(f.approxDurationMs ?? 0) / 1000
            return [Segment(offset: idx.upperBound + 1, length: (f.contentLength ?? 0) - idx.upperBound - 1, duration: dur)]
        }
        // First media byte follows the sidx box.
        var offset = idx.upperBound + 1
        return parsed.map { ref in
            let s = Segment(offset: offset, length: Int64(ref.size), duration: ref.duration)
            offset += Int64(ref.size); return s
        }
    }

    private static func mediaPlaylist(_ f: YTFormat, _ segs: [Segment]) -> String {
        let target = Int(ceil(segs.map(\.duration).max() ?? 10))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(target, 1))", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if let i = f.initRange {
            lines.append("#EXT-X-MAP:URI=\"\(f.url.absoluteString)\",BYTERANGE=\"\(i.upperBound - i.lowerBound + 1)@\(i.lowerBound)\"")
        }
        for s in segs {
            lines.append("#EXTINF:\(String(format: "%.3f", s.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(s.length)@\(s.offset)")
            lines.append(f.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    static func purge(olderThan age: TimeInterval = 6 * 3600) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            if let d = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > age {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}

/// Minimal ISO-BMFF `sidx` parser (ISO/IEC 14496-12 §8.16.3).
nonisolated enum SIDX {
    struct Ref: Sendable { let size: UInt32; let duration: Double }

    static func parse(_ data: Data) -> [Ref] {
        var p = 0
        func u32() -> UInt32 { defer { p += 4 }; return data.subdata(in: p..<p+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian } }
        func u64() -> UInt64 { defer { p += 8 }; return data.subdata(in: p..<p+8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian } }
        func u16() -> UInt16 { defer { p += 2 }; return data.subdata(in: p..<p+2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian } }

        // Find the sidx box (data may start with it directly).
        while p + 8 <= data.count {
            let size = Int(u32()); let type = String(data: data.subdata(in: p..<p+4), encoding: .ascii); p += 4
            if type == "sidx" { break }
            if size < 8 { return [] }
            p += size - 8
        }
        guard p + 12 <= data.count else { return [] }
        let version = data[p]; p += 4          // version + flags
        _ = u32()                              // reference_ID
        let timescale = Double(u32())
        if version == 0 { _ = u32(); _ = u32() } else { _ = u64(); _ = u64() }   // earliest_presentation_time, first_offset
        p += 2                                 // reserved
        let count = Int(u16())
        var refs: [Ref] = []
        refs.reserveCapacity(count)
        for _ in 0..<count {
            guard p + 12 <= data.count else { break }
            let sizeField = u32(); let dur = u32(); _ = u32()   // SAP
            let refSize = sizeField & 0x7FFF_FFFF
            refs.append(Ref(size: refSize, duration: Double(dur) / timescale))
        }
        return refs
    }
}
