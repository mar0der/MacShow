import Foundation
import GRDB
import Observation

/// The app's view of the library: every item, kept current from the database,
/// plus the watched folders and the scanning that feeds them.
@MainActor
@Observable
public final class Library {
    public private(set) var items: [MediaItem] = []
    public private(set) var index = LibraryIndex()
    public private(set) var folders: [WatchedFolder] = []
    public private(set) var isScanning = false

    public let database: LibraryDatabase
    public let artwork: ArtworkStore
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scansRunning = 0
    @ObservationIgnored private var started = false

    /// The folders indexed on first launch.
    public static var defaultFolders: [URL] {
        let home = realHomeDirectory
        return ["Music", "Movies", "Downloads"].map { home.appendingPathComponent($0) }
    }

    /// The user's home folder. Inside the sandbox `NSHomeDirectory()` is the app's
    /// container, so ask the user database instead.
    public static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public init(database: LibraryDatabase, artwork: ArtworkStore) {
        self.database = database
        self.artwork = artwork
        self.scanner = LibraryScanner(database: database, artwork: artwork)
        // Grouping runs on GRDB's reader queue, off the main thread.
        observation = ValueObservation
            .tracking { db in
                let items = try MediaItem.fetchAll(db)
                return (items, LibraryIndex(items: items))
            }
            .start(in: database.writer, scheduling: .async(onQueue: .main), onError: { _ in }) { [weak self] items, index in
                MainActor.assumeIsolated {
                    self?.items = items
                    self?.index = index
                }
            }
    }

    /// Opens the library in Application Support (the sandbox container when sandboxed).
    public convenience init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacShow")
        try self.init(
            database: LibraryDatabase(url: support.appendingPathComponent("Library.sqlite")),
            artwork: ArtworkStore(directory: support.appendingPathComponent("Artwork"))
        )
    }

    /// Adds the default folders on first launch, rescans everything and starts watching.
    public func start() {
        guard !started else { return }
        started = true
        if UserDefaults.standard.integer(forKey: "classifierVersion") != Classifier.version {
            try? database.invalidateAllItems()
            UserDefaults.standard.set(Classifier.version, forKey: "classifierVersion")
        }
        if (try? database.watchedFolders())?.isEmpty ?? true {
            for url in Self.defaultFolders {
                try? database.addWatchedFolder(WatchedFolder(path: url.path))
            }
        }
        reloadFolders()
        Task { await rescanAll() }
    }

    public func rescanAll() async {
        for folder in folders {
            await scan(URL(fileURLWithPath: folder.path))
        }
    }

    /// Adds a folder the user picked; `url` must come from an Open panel so the
    /// sandbox lets us bookmark it.
    public func addFolder(_ url: URL) {
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        try? database.addWatchedFolder(WatchedFolder(path: url.path, bookmark: bookmark))
        reloadFolders()
        Task { await scan(url) }
    }

    public func removeFolder(_ folder: WatchedFolder) {
        try? database.removeWatchedFolder(path: folder.path)
        reloadFolders()
    }

    private func scan(_ folder: URL) async {
        scansRunning += 1
        isScanning = true
        await scanner.scan(folder: folder)
        scansRunning -= 1
        isScanning = scansRunning > 0
    }

    private func reloadFolders() {
        folders = (try? database.watchedFolders()) ?? []
        for folder in folders {
            guard let bookmark = folder.bookmark else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
            }
        }
        watcher = FolderWatcher(paths: folders.map(\.path)) { [weak self] changed in
            Task { @MainActor in
                for path in Set(changed) { await self?.scan(URL(fileURLWithPath: path)) }
            }
        }
    }
}
