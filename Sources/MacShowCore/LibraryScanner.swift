import Foundation

public struct ScanResult: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var removed = 0
}

/// Brings the database in line with what's on disk under a folder.
public final class LibraryScanner: Sendable {
    let database: LibraryDatabase
    let artwork: ArtworkStore
    private let folderArt = FolderArtCache()
    private static let parallelReads = 6
    private static let batchSize = 100

    public init(database: LibraryDatabase, artwork: ArtworkStore) {
        self.database = database
        self.artwork = artwork
    }

    /// Indexes `folder` recursively: reads new and changed files (by size and
    /// modification date) and removes items whose files are gone. A folder that
    /// doesn't exist (an unplugged drive) is left untouched.
    @discardableResult
    public func scan(folder: URL) async -> ScanResult {
        let folder = URL(fileURLWithPath: folder.canonicalPath)
        guard let files = Self.mediaFiles(in: folder) else { return ScanResult() }

        let stamps = (try? database.fileStamps(under: folder.path)) ?? [:]
        var pending: [MediaFile] = []
        var result = ScanResult()
        for file in files {
            if let stamp = stamps[file.url.path], stamp.size == file.size, stamp.modified == file.modified { continue }
            pending.append(file)
            if stamps[file.url.path] == nil { result.added += 1 } else { result.updated += 1 }
        }
        let seen = Set(files.map(\.url.path))

        await withTaskGroup(of: MediaItem?.self) { group in
            var batch: [MediaItem] = []
            var nextIndex = 0
            func startNextRead() {
                guard nextIndex < pending.count else { return }
                let file = pending[nextIndex]
                nextIndex += 1
                group.addTask { self.readItem(file.url, size: file.size, modified: file.modified) }
            }
            for _ in 0..<Self.parallelReads { startNextRead() }
            for await item in group {
                if let item { batch.append(item) }
                if batch.count >= Self.batchSize {
                    try? database.upsert(batch)
                    batch.removeAll()
                }
                startNextRead()
            }
            try? database.upsert(batch)
        }

        let missing = stamps.keys.filter { !seen.contains($0) }
        try? database.deleteItems(paths: missing)
        result.removed = missing.count
        return result
    }

    private typealias MediaFile = (url: URL, size: Int64, modified: Double)

    /// Every media file under `folder`, or nil if it isn't a reachable folder.
    private static func mediaFiles(in folder: URL) -> [MediaFile]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else { return nil }

        var files: [MediaFile] = []
        for case let url as URL in enumerator where Classifier.isMediaFile(url) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return files
    }

    private func readItem(_ url: URL, size: Int64, modified: Double) -> MediaItem? {
        guard let metadata = MetadataReader.read(url) else { return nil }
        let artworkKey = metadata.artwork.flatMap(artwork.store) ?? folderArt.key(for: url.deletingLastPathComponent()) { directory in
            ArtworkStore.folderImage(in: directory).flatMap(self.artwork.store)
        }
        return Classifier.makeItem(url: url, metadata: metadata, fileSize: size, modified: modified, artworkKey: artworkKey)
    }
}

/// Remembers each folder's cover-image artwork key, so a 20-track album reads its
/// cover.jpg once.
private final class FolderArtCache: @unchecked Sendable {
    private var keys: [String: String?] = [:]
    private let lock = NSLock()

    func key(for directory: URL, compute: (URL) -> String?) -> String? {
        if let cached = lock.withLock({ keys[directory.path] }) { return cached }
        let key = compute(directory)
        lock.withLock { keys[directory.path] = key }
        return key
    }
}
