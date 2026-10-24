import Combine
import Foundation
import GRDB
import Observation

/// The app's view of the library, kept current from the database, plus the
/// watched folders and the scanning that feeds them.
@MainActor
@Observable
public final class Library {
    public private(set) var index = LibraryIndex()
    public private(set) var playlists: [PlaylistContents] = []
    public private(set) var folders: [WatchedFolder] = []
    public private(set) var isScanning = false

    public let database: LibraryDatabase
    public let artwork: ArtworkStore
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var changes: AnyCancellable?
    @ObservationIgnored private let refreshQueue = DispatchQueue(label: "MacShow.Library.refresh", qos: .userInitiated)
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var accessedFolders: Set<String> = []
    @ObservationIgnored private var started = false

    /// Scans and folder removals run one at a time, in order, so two scans never
    /// work from conflicting snapshots of the same folder.
    private enum Job: Equatable {
        case scan(String)
        case remove(WatchedFolder)
    }
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

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
        // Re-read at most about once a second while a scan is writing batches.
        changes = DatabaseRegionObservation(tracking: .fullDatabase)
            .publisher(in: database.writer)
            .map { _ in () }
            .catch { _ in Empty() }
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.refresh() }
        refresh()
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

    /// Reads everything and regroups it off the main thread, then publishes the result.
    private func refresh() {
        let database = database
        refreshQueue.async { [weak self] in
            guard let snapshot = try? database.writer.read({ db -> (LibraryIndex, [PlaylistContents]) in
                let items = try MediaItem.fetchAll(db)
                let byID = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.id.map { ($0, item) } })
                return (LibraryIndex(items: items), try LibraryDatabase.playlistContents(db, items: byID))
            }) else { return }
            DispatchQueue.main.async {
                self?.index = snapshot.0
                self?.playlists = snapshot.1
            }
        }
    }

    // MARK: Folders and scanning

    /// Adds the default folders on first launch, rescans everything and starts watching.
    public func start() {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "classifierVersion") != Classifier.version {
            try? database.invalidateAllItems()
            defaults.set(Classifier.version, forKey: "classifierVersion")
        }
        if !defaults.bool(forKey: "didAddDefaultFolders") {
            for url in Self.defaultFolders {
                try? database.addWatchedFolder(WatchedFolder(path: url.path))
            }
            defaults.set(true, forKey: "didAddDefaultFolders")
        }
        reloadFolders()
        rescanAll()
    }

    public func rescanAll() {
        folders.forEach { enqueue(.scan($0.path)) }
    }

    /// Adds a folder the user picked; `url` must come from an Open panel so the
    /// sandbox lets us bookmark it.
    public func addFolder(_ url: URL) {
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
        try? database.addWatchedFolder(WatchedFolder(path: url.path, bookmark: bookmark))
        reloadFolders()
        enqueue(.scan(url.path))
    }

    public func removeFolder(_ folder: WatchedFolder) {
        enqueue(.remove(folder))
    }

    private func enqueue(_ job: Job) {
        if case .scan(let path) = job {
            // Skip if this folder or one containing it is already waiting; drop waiting subfolders.
            let pending = jobs.compactMap { if case .scan(let p) = $0 { p } else { nil } }
            if pending.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return }
            jobs.removeAll { if case .scan(let p) = $0 { p.hasPrefix(path + "/") } else { false } }
        }
        jobs.append(job)
        guard worker == nil else { return }
        isScanning = true
        worker = Task {
            while !jobs.isEmpty {
                let job = jobs.removeFirst()
                switch job {
                case .scan(let path):
                    await scanner.scan(folder: URL(fileURLWithPath: path))
                case .remove(let folder):
                    try? database.removeWatchedFolder(path: folder.path)
                    reloadFolders()
                    // A remaining folder may still contain what was just removed.
                    for remaining in folders where folder.path.hasPrefix(remaining.path + "/") {
                        jobs.append(.scan(remaining.path))
                    }
                }
            }
            worker = nil
            isScanning = false
        }
    }

    private func reloadFolders() {
        folders = (try? database.watchedFolders()) ?? []
        for folder in folders where !accessedFolders.contains(folder.path) {
            guard let bookmark = folder.bookmark else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource()
            else { continue }
            accessedFolders.insert(folder.path)
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                try? database.updateBookmark(fresh, forFolder: folder.path)
            }
        }
        watcher = FolderWatcher(paths: folders.map(\.path)) { [weak self] changed in
            DispatchQueue.main.async {
                for path in Set(changed) { self?.enqueue(.scan(path)) }
            }
        }
    }

    // MARK: Playlists

    @discardableResult
    public func createPlaylist(named name: String, with items: [MediaItem] = []) -> Playlist? {
        guard let playlist = try? database.createPlaylist(named: name) else { return nil }
        try? database.add(items, to: playlist)
        return playlist
    }

    public func add(_ items: [MediaItem], to playlist: Playlist) { try? database.add(items, to: playlist) }
    public func rename(_ playlist: Playlist, to name: String) { try? database.renamePlaylist(playlist, to: name) }
    public func delete(_ playlist: Playlist) { try? database.deletePlaylist(playlist) }
    public func removeEntries(at offsets: IndexSet, from playlist: Playlist) { try? database.removeEntries(at: offsets, from: playlist) }
}
