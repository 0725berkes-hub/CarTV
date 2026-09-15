import UIKit
import CryptoKit

/// Two-tier (memory + disk) image cache with downsampling. Channel logos are
/// tiny and numerous; posters are big. Both go through here.
/// Runs off the main actor; NSCache and URLSession are thread-safe.
nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory: NSCache<NSString, UIImage>
    private let session: URLSession
    private let inflight = InflightRegistry()
    private let scale: CGFloat

    private init() {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024
        c.countLimit = 2000
        memory = c

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        cfg.httpAdditionalHeaders = ["User-Agent": PlaylistImporter.userAgent]
        session = URLSession(configuration: cfg)
        scale = 3
    }

    func cached(_ url: URL, targetSize: CGSize) -> UIImage? {
        memory.object(forKey: key(url, targetSize))
    }

    func image(for url: URL, targetSize: CGSize) async -> UIImage? {
        let k = key(url, targetSize)
        if let img = memory.object(forKey: k) { return img }

        let keyString = String(k)
        let diskURL = AppPaths.imageCache.appending(path: keyString + ".img")
        if let data = try? Data(contentsOf: diskURL), let img = UIImage(data: data, scale: scale) {
            memory.setObject(img, forKey: k, cost: cost(img))
            return img
        }

        let session = self.session
        let scale = self.scale
        let result = await inflight.run(key: keyString) {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await session.data(from: url).0
            }
            guard let data, let img = ImageLoader.downsample(data, to: targetSize, scale: scale) else { return nil }
            if let out = img.pngData() ?? img.jpegData(compressionQuality: 0.85) {
                try? out.write(to: diskURL, options: .atomic)
            }
            return img
        }
        if let result { memory.setObject(result, forKey: k, cost: cost(result)) }
        return result
    }

    func prefetch(_ urls: [URL], targetSize: CGSize) {
        for url in urls.prefix(24) where memory.object(forKey: key(url, targetSize)) == nil {
            Task.detached(priority: .utility) { [self] in _ = await image(for: url, targetSize: targetSize) }
        }
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: AppPaths.imageCache)
        _ = AppPaths.imageCache
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: Helpers

    private func key(_ url: URL, _ size: CGSize) -> NSString {
        let raw = "\(url.absoluteString)|\(Int(size.width))x\(Int(size.height))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined() as NSString
    }

    private func cost(_ img: UIImage) -> Int {
        Int(img.size.width * img.scale * img.size.height * img.scale * 4)
    }

    static func downsample(_ data: Data, to size: CGSize, scale: CGFloat) -> UIImage? {
        let maxPixel = max(size.width, size.height) * scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel > 0 ? maxPixel : 512),
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

/// De-duplicates concurrent loads for the same key.
private actor InflightRegistry {
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func run(key: String, _ op: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        if let existing = tasks[key] { return await existing.value }
        let task = Task { await op() }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}
