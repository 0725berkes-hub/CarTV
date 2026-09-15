import Foundation
import SwiftData

@Model
final class VideoFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var sortOrder: Int

    @Relationship(deleteRule: .cascade, inverse: \LocalVideo.folder)
    var videos: [LocalVideo] = []

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = .now
        self.sortOrder = sortOrder
    }
}

@Model
final class LocalVideo {
    #Index<LocalVideo>([\.normalizedTitle], [\.importedAt])

    @Attribute(.unique) var id: UUID
    var title: String
    var normalizedTitle: String
    /// Path relative to the app's Videos directory (survives container relocation).
    var relativePath: String
    var fileSize: Int64
    var duration: TimeInterval
    var width: Int
    var height: Int
    var importedAt: Date
    var thumbnailRelativePath: String?

    var folder: VideoFolder?

    init(
        id: UUID = UUID(),
        title: String,
        relativePath: String,
        fileSize: Int64,
        duration: TimeInterval,
        width: Int = 0,
        height: Int = 0
    ) {
        self.id = id
        self.title = title
        self.normalizedTitle = title.searchNormalized
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.duration = duration
        self.width = width
        self.height = height
        self.importedAt = .now
    }

    var fileURL: URL { AppPaths.videos.appending(path: relativePath) }
    var thumbnailURL: URL? { thumbnailRelativePath.map { AppPaths.thumbnails.appending(path: $0) } }
}
