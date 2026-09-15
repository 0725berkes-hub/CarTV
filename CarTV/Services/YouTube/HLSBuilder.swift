import Foundation
import OSLog

/// Turns YouTube's DASH adaptive formats into an HLS master + media playlists that
/// AVPlayer streams natively (fMP4 with EXT-X-BYTERANGE). Each variant is one
/// long "segment" list built from the format's SIDX index so seeking is exact.
///
/// Output lives in the caches dir and is served via `file://` — AVPlayer accepts
/// local playlists whose segments point at remote https URLs.
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

        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="\(audio.language ?? "Audio")",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioName)"
        \(variantLines.joined(separator: "\n"))
        """
        let masterURL = dir.appending(path: "master.m3u8")
        try master.write(to: masterURL, atomically: true, encoding: .utf8)
        Log.player.info("HLS built for \(resp.videoID, privacy: .public): \(variants.count) variants")
        return Result(masterURL: masterURL, variants: variants)
    }

    // MARK: Segments from SIDX

    struct Segment: Sendable { let offset: Int64; let length: Int64; let duration: Double }

    private static func segments(for f: YTFormat) async throws -> [Segment] {
        guard let init_ = f.initRange, let idx = f.indexRange else {
            // No index → one segment covering the whole file.
            let dur = Double(f.approxDurationMs ?? 0) / 1000
            return [Segment(offset: 0, length: f.contentLength ?? 0, duration: dur)]
        }
        var req = URLRequest(url: f.url)
        req.setValue("bytes=\(idx.lowerBound)-\(idx.upperBound)", forHTTPHeaderField: "Range")
        let (data, _) = try await URLSession.shared.data(for: req)
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
