import Foundation

/// How far a scan is: `done` of the `total` new or changed files read, and
/// the name of the one just read.
public struct ScanProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var file: String?
}

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
    /// FFmpeg reads block, so they run here rather than on Swift's cooperative pool.
    private let readQueue = DispatchQueue(label: "MacShow.LibraryScanner.read", qos: .utility, attributes: .concurrent)
    private static let parallelReads = 6
    private static let batchSize = 500
    /// On a slow network share a batch can take an hour; save at least this often
    /// so new items show up as they're read and a quit doesn't lose them.
    private static let saveInterval: Duration = .seconds(5)

    public init(database: LibraryDatabase, artwork: ArtworkStore) {
        self.database = database
        self.artwork = artwork
    }

    /// Indexes `folder` recursively: reads new and changed files (by size and
    /// modification date) and removes items whose files are gone. A folder that
    /// doesn't exist (an unplugged drive), or one whose listing hit an error, has
    /// nothing removed: a partial listing must not look like deleted files.
    /// Nothing under `excluded` (canonical paths of folders or files) is indexed,
    /// and items already indexed there are removed.
    @discardableResult
    public func scan(folder: URL, excluding excluded: [String] = [],
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanResult {
        let folder = URL(fileURLWithPath: folder.canonicalPath)
        guard let (files, unreadable) = Self.mediaFiles(in: folder, excluding: excluded) else { return ScanResult() }

        let stamps = (try? database.fileStamps(under: folder.path)) ?? [:]
        var pending: [MediaFile] = []
        var result = ScanResult()
        for file in files {
            if let stamp = stamps[file.url.path], stamp.size == file.size, stamp.modified == file.modified { continue }
            pending.append(file)
            if stamps[file.url.path] == nil { result.added += 1 } else { result.updated += 1 }
        }
        let seen = Set(files.map(\.url.path))
        progress?(ScanProgress(done: 0, total: pending.count))

        await withTaskGroup(of: MediaItem?.self) { group in
            var batch: [MediaItem] = []
            var lastSave = ContinuousClock.now
            var nextIndex = 0
            func startNextRead() {
                guard nextIndex < pending.count else { return }
                let file = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    await withCheckedContinuation { continuation in
                        self.readQueue.async { continuation.resume(returning: self.readItem(file.url, size: file.size, modified: file.modified)) }
                    }
                }
            }
            for _ in 0..<Self.parallelReads { startNextRead() }
            var done = 0
            for await item in group {
                done += 1
                if let item { batch.append(item) }
                progress?(ScanProgress(done: done, total: pending.count, file: item?.url.lastPathComponent))
                if batch.count >= Self.batchSize || (!batch.isEmpty && lastSave.duration(to: .now) >= Self.saveInterval) {
                    try? database.upsert(batch)
                    batch.removeAll()
                    lastSave = .now
                }
                startNextRead()
            }
            try? database.upsert(batch)
        }

        // Anything under a folder or file we couldn't read is unknown, not gone.
        let missing = stamps.keys.filter { path in
            !seen.contains(path) && !unreadable.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        try? database.deleteItems(paths: missing)
        result.removed = missing.count
        return result
    }

    private typealias MediaFile = (url: URL, size: Int64, modified: Double)

    /// Every media file under `folder`, plus the paths that couldn't be read
    /// (folders the listing failed on, files whose details failed); nil if
    /// `folder` isn't a reachable folder.
    private static func mediaFiles(in folder: URL, excluding excluded: [String]) -> ([MediaFile], unreadable: [String])? {
        func isExcluded(_ path: String) -> Bool { excluded.contains { path == $0 || path.hasPrefix($0 + "/") } }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var isDirectory: ObjCBool = false
        var unreadable: [String] = []
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                  errorHandler: { url, _ in
                      unreadable.append(url.path)
                      return true
                  }
              )
        else { return nil }

        var files: [MediaFile] = []
        if isExcluded(folder.path) { return (files, unreadable) }
        for case let url as URL in enumerator {
            if isExcluded(url.path) {
                enumerator.skipDescendants()
                continue
            }
            guard Classifier.isMediaFile(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                unreadable.append(url.path)
                continue
            }
            guard values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return (files, unreadable)
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
