import AppKit
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
    /// Resume points by item id. Kept in memory and written through, so saving
    /// a position every few seconds doesn't regroup the whole library.
    public private(set) var positions: [Int64: PlaybackPosition] = [:]
    public private(set) var bookmarks: [Bookmark] = []
    /// Play counts of songs and music videos, by item id.
    public private(set) var playStats: [Int64: PlayStat] = [:]
    /// Loved items, by id.
    public private(set) var favorites: Set<Int64> = []
    public private(set) var folders: [WatchedFolder] = []
    /// Watched folders that can't be reached right now (an unplugged drive).
    /// Their items stay in the library, shown as unavailable.
    public private(set) var offlineFolders: Set<String> = []
    public private(set) var isScanning = false
    /// Goes up each time `index` is replaced; cheap to watch for "the library changed".
    public private(set) var generation = 0
    /// Details changed with Get Info, by path (already applied to `index`).
    public private(set) var edits: [String: ItemEdit] = [:]
    /// Folders and files marked Never Scan, Personal or Adult.
    public private(set) var folderRules: [FolderRule] = []
    /// Whether items in Adult folders are listed (in their own section). Off at
    /// every launch; the app unlocks it.
    public var showingAdult = false {
        didSet { if showingAdult != oldValue { refresh() } }
    }

    public let database: LibraryDatabase
    public let artwork: ArtworkStore
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var changes: AnyCancellable?
    @ObservationIgnored private let refreshQueue = DispatchQueue(label: "MacShow.Library.refresh", qos: .userInitiated)
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var accessedFolders: Set<String> = []
    @ObservationIgnored private let stillQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    @ObservationIgnored private var failedStills: Set<String> = []
    @ObservationIgnored private var unpublishedPositions: [Int64: PlaybackPosition] = [:]
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "MacShow.Library.write", qos: .utility)
    @ObservationIgnored private var refreshRunning = false
    @ObservationIgnored private var refreshPending = false
    /// Watched folders as the file system spells them (what FSEvents reports).
    @ObservationIgnored private var watchedRoots: [String] = []
    /// Updates `watchedRoots`, `offlineFolders`, bookmark access and the watcher.
    /// Runs off the main thread: touching ~/Downloads can wait on a macOS privacy
    /// prompt, and the window must still appear meanwhile.
    @ObservationIgnored private var folderState: Task<Void, Never>?
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Network folders we've tried to reconnect since the last rescan.
    @ObservationIgnored private var reconnectTried: Set<String> = []
    @ObservationIgnored private var networkRescan: Task<Void, Never>?
    /// How often folders on network shares are rescanned: macOS doesn't report
    /// changes another computer makes there.
    nonisolated static let networkRescanInterval: Duration = .seconds(15 * 60)
    @ObservationIgnored private var artworkGeneration = 0

    /// Settings key: download cover art for albums that have none (default on).
    nonisolated public static let fetchArtworkKey = "fetchMissingArtwork"
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
        positions = (try? database.writer.read(LibraryDatabase.positions)) ?? [:]
        bookmarks = (try? database.bookmarks()) ?? []
        playStats = (try? database.playStats()) ?? [:]
        favorites = (try? database.favorites()) ?? []
        folderRules = (try? database.folderRules()) ?? []
        artistImages = (try? database.writer.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT artistId, artworkKey FROM artistImage").map { ($0["artistId"], $0["artworkKey"]) },
                       uniquingKeysWith: { _, last in last })
        }) ?? [:]
        changes = DatabaseRegionObservation(tracking: Table("mediaItem"), Table("playlist"), Table("playlistEntry"), Table("itemEdit"))
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

    /// Reads everything and regroups it off the main thread, then publishes the
    /// result. At most one rebuild runs at a time; requests during one are merged
    /// into a single follow-up, so slow rebuilds can't pile up.
    private func refresh() {
        guard !refreshRunning else {
            refreshPending = true
            return
        }
        refreshRunning = true
        let database = database, rules = FolderRules(folderRules), showingAdult = showingAdult
        refreshQueue.async { [weak self] in
            let snapshot = try? database.writer.read { db -> (LibraryIndex, [PlaylistContents], [String: ItemEdit]) in
                let edits = try LibraryDatabase.itemEdits(db)
                let items = try MediaItem.fetchAll(db).map { item in edits[item.path]?.apply(to: item) ?? item }
                // Playlists keep every copy of a duplicate song, but never adult items.
                let listed = items.filter { rules.kind(for: $0.path).map { $0 == .personal } ?? true }
                let byID = Dictionary(uniqueKeysWithValues: listed.compactMap { item in item.id.map { ($0, item) } })
                let chosenKinds = Set(edits.values.filter { $0.kind != nil }.map(\.path))
                return (LibraryIndex(items: items, rules: rules, showingAdult: showingAdult, chosenKinds: chosenKinds),
                        try LibraryDatabase.playlistContents(db, items: byID), edits)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot {
                    self.index = snapshot.0
                    self.playlists = snapshot.1
                    self.edits = snapshot.2
                    self.generation += 1
                    if !self.isScanning { self.fetchMissingArtwork() }
                }
                self.refreshRunning = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
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
            // Libraries from before this flag already have folders; leave them as they are.
            if (try? database.watchedFolders())?.isEmpty ?? true {
                for url in Self.defaultFolders {
                    try? database.addWatchedFolder(WatchedFolder(path: url.path))
                }
            }
            defaults.set(true, forKey: "didAddDefaultFolders")
        }
        reloadFolders()
        rescanAll()
        // Drives coming and going: refresh what's reachable, index what came back.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesChanged() }
            })
        }
        networkRescan = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.networkRescanInterval)
                self?.rescanNetworkFolders()
            }
        }
    }

    /// Rescans the network folders that are connected, and tries again to
    /// reconnect the ones that aren't.
    private func rescanNetworkFolders() {
        reconnectTried.removeAll()
        for folder in folders where folder.isOnNetworkShare && !offlineFolders.contains(folder.path) {
            enqueue(.scan(folder.path))
        }
        reloadFolders()
    }

    /// Reconnects a network folder's share using its bookmark, quietly: with the
    /// password in the Keychain it mounts; otherwise nothing happens (Settings
    /// has a Connect button). Mounting is noticed like a drive being plugged in.
    private func reconnect(_ folder: WatchedFolder) {
        guard let bookmark = folder.bookmark else { return }
        Task.detached(priority: .utility) {
            var stale = false
            _ = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    private func volumesChanged() {
        Task {
            // Compare against the state after any update still in flight.
            await folderState?.value
            let wasOffline = offlineFolders
            reloadFolders()
            await folderState?.value
            for folder in folders where wasOffline.contains(folder.path) && !offlineFolders.contains(folder.path) {
                enqueue(.scan(folder.path))
            }
        }
    }

    /// False for items on a drive that isn't connected (and with no other copy that is).
    public func isAvailable(_ item: MediaItem) -> Bool {
        playableCopy(of: item) != nil
    }

    /// The item itself if its drive is connected, else a reachable duplicate copy.
    public func playableCopy(of item: MediaItem) -> MediaItem? {
        func reachable(_ copy: MediaItem) -> Bool {
            offlineFolders.isEmpty || !offlineFolders.contains { copy.path.hasPrefix($0 + "/") }
        }
        if reachable(item) { return item }
        return item.id.flatMap { index.copies[$0] }?.first(where: reachable)
    }

    public func rescanAll() {
        reconnectTried.removeAll()
        folders.forEach { enqueue(.scan($0.path)) }
    }

    /// Adds a folder the user picked; `url` must come from an Open panel so the
    /// sandbox lets us bookmark it.
    public func addFolder(_ url: URL) {
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let remount = (try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
        try? database.addWatchedFolder(WatchedFolder(path: url.path, bookmark: bookmark, remountURL: remount?.absoluteString))
        reloadFolders()
        enqueue(.scan(url.path))
    }

    public func removeFolder(_ folder: WatchedFolder) {
        enqueue(.remove(folder))
    }

    private func enqueue(_ job: Job) {
        var job = job
        if case .scan(let raw) = job {
            // FSEvents reports folders with a trailing slash.
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            job = .scan(path)
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
                await folderState?.value
                switch job {
                case .scan(let path):
                    // A folder removed since this was queued must not be re-indexed.
                    let canonical = URL(fileURLWithPath: path).canonicalPath
                    guard watchedRoots.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) else { continue }
                    await scanner.scan(folder: URL(fileURLWithPath: path), excluding: FolderRules(folderRules).excludedPaths)
                case .remove(let folder):
                    // Items another watched folder still covers stay, keeping their
                    // playlist entries and resume points.
                    let database = database
                    let keep = watchedRoots.filter { $0 != URL(fileURLWithPath: folder.path).canonicalPath }
                    await Task.detached { try? database.removeWatchedFolder(path: folder.path, keepingItemsUnder: keep) }.value
                    reloadFolders()
                }
            }
            worker = nil
            isScanning = false
            fetchMissingArtwork()
        }
    }

    private func reloadFolders() {
        folders = (try? database.watchedFolders()) ?? []
        let folders = folders, database = database
        let previous = folderState
        folderState = Task { [weak self] in
            await previous?.value
            // Read after the previous pass, so its bookmark access is counted.
            guard let alreadyAccessed = self?.accessedFolders else { return }
            let state = await Task.detached(priority: .userInitiated) {
                // Start sandbox access for bookmarked folders, refreshing stale bookmarks.
                var accessed: [String] = []
                for folder in folders where !alreadyAccessed.contains(folder.path) {
                    guard let bookmark = folder.bookmark else { continue }
                    // A share that isn't connected: reconnecting can take a while, so it happens on its own (below).
                    if folder.isOnNetworkShare, !FileManager.default.fileExists(atPath: folder.path) { continue }
                    var stale = false
                    guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
                          url.startAccessingSecurityScopedResource()
                    else { continue }
                    accessed.append(folder.path)
                    if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        try? database.updateBookmark(fresh, forFolder: folder.path)
                    }
                }
                // Note the share address of folders added before it was recorded.
                var foundShares = false
                for folder in folders where !folder.isOnNetworkShare {
                    if let remount = (try? URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting {
                        try? database.setRemountURL(remount.absoluteString, forFolder: folder.path)
                        foundShares = true
                    }
                }
                let roots = folders.map { URL(fileURLWithPath: $0.path).canonicalPath }
                let offline = Set(folders.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
                // Creating the stream opens each folder, which can also wait on the prompt.
                let watcher = FolderWatcher(paths: folders.map(\.path)) { [weak self] changed in
                    DispatchQueue.main.async {
                        for path in Set(changed) { self?.enqueue(.scan(path)) }
                    }
                }
                return (accessed, roots, offline, watcher, foundShares)
            }.value
            guard let self else { return }
            accessedFolders.formUnion(state.0)
            watchedRoots = state.1
            offlineFolders = state.2
            watcher = state.3
            if state.4 { self.folders = (try? database.watchedFolders()) ?? self.folders }
            for folder in self.folders where folder.isOnNetworkShare && offlineFolders.contains(folder.path) {
                if reconnectTried.insert(folder.path).inserted { reconnect(folder) }
            }
        }
    }

    /// Marks a folder or file as Never Scan, Personal or Adult (nil clears it).
    public func setRule(_ kind: FolderRule.Kind?, for url: URL) {
        let path = url.canonicalPath
        let wasExcluded = FolderRules(folderRules).kind(for: path) == .excluded
        try? database.setFolderRule(kind, for: path)
        folderRules = (try? database.folderRules()) ?? []
        refresh()
        // Index what an exclusion was hiding.
        if wasExcluded, FolderRules(folderRules).kind(for: path) != .excluded {
            enqueue(.scan(Classifier.isMediaFile(url) ? url.deletingLastPathComponent().canonicalPath : path))
        }
    }

    /// Moves items to a category (nil: back to where MacShow would put them).
    public func setCategory(_ kind: MediaItem.Kind?, for items: [MediaItem]) {
        save(items.map { item in
            var edit = edits[item.path] ?? ItemEdit(path: item.path)
            edit.kind = kind
            return edit
        })
    }

    /// Saves Get Info changes (an edit that changes nothing is removed).
    public func save(_ edits: [ItemEdit]) {
        try? database.save(edits)
    }

    // MARK: Resume points

    /// Saves a resume point. The write happens off the main thread; `publish`
    /// false keeps it out of `positions` too, so the periodic saves during
    /// playback don't re-render every tile that shows progress.
    public func savePosition(_ position: Double, duration: Double, for item: MediaItem, publish: Bool = true) {
        guard let id = item.id, duration > 0 else { return }
        if publish {
            positions[id] = PlaybackPosition(mediaItemId: id, position: position, duration: duration, updatedAt: Date())
        } else {
            unpublishedPositions[id] = PlaybackPosition(mediaItemId: id, position: position, duration: duration, updatedAt: Date())
        }
        let database = database
        writeQueue.async { try? database.savePosition(position, duration: duration, for: id) }
    }

    /// Blocks until queued position writes are on disk (call before quitting).
    public func flushPendingWrites() {
        writeQueue.sync {}
    }

    /// The latest resume point for an item, including saves not yet published.
    public func position(for item: MediaItem) -> PlaybackPosition? {
        guard let id = item.id else { return nil }
        let published = positions[id], pending = unpublishedPositions[id]
        guard let pending, pending.updatedAt > published?.updatedAt ?? .distantPast else { return published }
        return pending
    }

    public func clearPosition(for item: MediaItem) {
        guard let id = item.id else { return }
        positions[id] = nil
        unpublishedPositions[id] = nil
        let database = database
        writeQueue.async { try? database.clearPosition(for: id) }
    }

    // MARK: Play counts

    /// A song was played (most of it): counts toward Recently and Most Played.
    public func recordPlay(of item: MediaItem) {
        guard let id = item.id else { return }
        let now = Date()
        playStats[id] = PlayStat(mediaItemId: id, playCount: (playStats[id]?.playCount ?? 0) + 1, lastPlayedAt: now)
        let database = database
        writeQueue.async { try? database.recordPlay(of: id, at: now) }
    }

    public func songs(in list: SmartList) -> [MediaItem] {
        list.songs(in: index.songs, stats: playStats, favorites: favorites)
    }

    public func isFavorite(_ items: [MediaItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.id.map(favorites.contains) ?? false }
    }

    /// Loves the items, or if they're all loved already, unloves them.
    public func toggleFavorite(_ items: [MediaItem]) {
        let love = !isFavorite(items)
        let ids = items.compactMap(\.id)
        if love { favorites.formUnion(ids) } else { favorites.subtract(ids) }
        try? database.setFavorite(love, ids: ids)
    }

    // MARK: Lyrics

    /// Settings key: look lyrics up on LRCLIB when a song has none (default on).
    nonisolated public static let fetchLyricsKey = "fetchLyrics"

    /// A song's lyrics: from an .lrc beside it, its tags, or LRCLIB. Each song is
    /// looked up once; a song with none isn't asked about again.
    public func lyrics(for item: MediaItem) async -> Lyrics? {
        let database = database
        if case .some(let cached) = try? database.cachedLyrics(item.path) { return cached }
        if let local = await Task.detached(priority: .userInitiated, operation: { LyricsFinder.local(for: item) }).value {
            return local
        }
        guard UserDefaults.standard.object(forKey: Self.fetchLyricsKey) as? Bool ?? true else { return nil }
        // Not cached when the lookup failed (offline): worth trying again.
        guard case .some(let found) = await LyricsFinder.online(for: item) else { return nil }
        try? database.cacheLyrics(found, path: item.path)
        return found
    }

    // MARK: Movie and show details

    /// TMDB details for a movie or a show's episode (nil without a TMDB key, offline,
    /// or not found). Looked up once, then kept.
    public func details(for item: MediaItem) async -> MediaDetails? {
        let isShow = item.kind == .episode
        let key = isShow ? "tv:" + Show.id(for: item) : "movie:\(item.title.lowercased()):\(item.year ?? 0)"
        let database = database
        // Details cached before cast members carried their TMDB id are fetched again once.
        if let cached = try? database.cachedDetails(key), cached.cast.first.map({ $0.id != nil }) ?? true { return cached }
        let fetcher = ArtworkFetcher(tmdbKey: UserDefaults.standard.string(forKey: ArtworkFetcher.tmdbKeyDefault))
        let found = isShow ? await fetcher.showDetails(name: item.show ?? item.title)
                           : await fetcher.movieDetails(title: item.title, year: item.year)
        if let found { try? database.cacheDetails(found, key: key) }
        return found
    }

    /// An actor's or director's TMDB profile (by the id from a cast list), looked up once.
    public func profile(ofPerson id: Int) async -> PersonProfile? {
        let key = "person:\(id)"
        let database = database
        if let cached = try? database.cachedDetails(key, as: PersonProfile.self) { return cached }
        let fetcher = ArtworkFetcher(tmdbKey: UserDefaults.standard.string(forKey: ArtworkFetcher.tmdbKeyDefault))
        let found = await fetcher.personProfile(id: id)
        if let found { try? database.cacheDetails(found, key: key) }
        return found
    }

    /// The movies and shows in this library that are among someone's credits:
    /// same title, and for movies the same year (give or take one) when both are known.
    public func titles(in profile: PersonProfile) -> (movies: [MediaItem], shows: [Show]) {
        func normalized(_ title: String) -> String { title.lowercased().filter { $0.isLetter || $0.isNumber } }
        var movieYears: [String: [Int?]] = [:]
        var shows = Set<String>()
        for credit in profile.credits {
            if credit.isShow { shows.insert(normalized(credit.title)) } else { movieYears[normalized(credit.title), default: []].append(credit.year) }
        }
        let movies = index.movies.filter { movie in
            (movieYears[normalized(movie.title)] ?? []).contains { year in
                guard let year, let own = movie.year else { return true }
                return abs(year - own) <= 1
            }
        }
        return (movies, index.shows.filter { shows.contains(normalized($0.title)) })
    }

    /// A season's episode titles, summaries and stills from TMDB, looked up once.
    public func details(of show: Show, season: Int) async -> MediaDetails? {
        let key = "tv:\(show.id):season:\(season)"
        let database = database
        if let cached = try? database.cachedDetails(key) { return cached }
        let fetcher = ArtworkFetcher(tmdbKey: UserDefaults.standard.string(forKey: ArtworkFetcher.tmdbKeyDefault))
        let found = await fetcher.seasonDetails(name: show.title, season: season)
        if let found { try? database.cacheDetails(found, key: key) }
        return found
    }

    /// Settings key: look up artist bios (Wikipedia) and book details (Open Library), default on.
    nonisolated public static let fetchInfoKey = "fetchArtistAndBookInfo"

    /// The opening of the artist's Wikipedia article. Looked up once, then kept.
    public func bio(of artist: Artist) async -> MediaDetails? {
        await cachedOrFetched("artist:" + artist.id) { await ArtworkFetcher().artistBio(artist.name) }
    }

    /// A book's description, year and cover. A book without a cover gets this
    /// one (you can change it in Get Info).
    public func details(of book: Book) async -> MediaDetails? {
        let details = await cachedOrFetched("book:" + book.id) { await ArtworkFetcher().bookDetails(title: book.title, author: book.author) }
        if book.artworkKey == nil, let poster = details?.poster,
           let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: poster), let key = artwork.store(data) {
            save(book.parts.map { part in
                var edit = edits[part.path] ?? ItemEdit(path: part.path)
                edit.artworkKey = key
                return edit
            })
        }
        return details
    }

    private func cachedOrFetched(_ key: String, fetch: () async -> MediaDetails?) async -> MediaDetails? {
        let database = database
        if let cached = try? database.cachedDetails(key) { return cached }
        guard UserDefaults.standard.object(forKey: Self.fetchInfoKey) as? Bool ?? true, let found = await fetch() else { return nil }
        try? database.cacheDetails(found, key: key)
        return found
    }

    // MARK: Artist pictures

    /// Photos found or chosen for artists, by artist id.
    public private(set) var artistImages: [String: String] = [:]
    public private(set) var findingArtistPictures: (done: Int, total: Int)?

    /// The artist's photo if one was found or chosen, else their newest album cover.
    public func picture(of artist: Artist) -> String? {
        artistImages[artist.id] ?? artist.artworkKey
    }

    public func setPicture(_ artworkKey: String?, for artist: Artist) {
        let database = database
        try? database.writer.write { db in
            if let artworkKey {
                try db.execute(sql: "INSERT OR REPLACE INTO artistImage (artistId, artworkKey) VALUES (?, ?)", arguments: [artist.id, artworkKey])
            } else {
                try db.execute(sql: "DELETE FROM artistImage WHERE artistId = ?", arguments: [artist.id])
            }
        }
        artistImages[artist.id] = artworkKey
    }

    /// Looks up a photo for each artist with no picture at all, picking the
    /// best match itself (Deezer; only names are sent). You can change any later.
    public func findArtistPictures(for artists: [Artist]) {
        let missing = artists.filter { picture(of: $0) == nil }
        guard findingArtistPictures == nil, !missing.isEmpty else { return }
        findingArtistPictures = (0, missing.count)
        Task {
            let fetcher = ArtworkFetcher()
            for (done, artist) in missing.enumerated() {
                findingArtistPictures = (done, missing.count)
                if case .found(let data) = await fetcher.artistPhoto(artist.name), let key = artwork.store(data) {
                    setPicture(key, for: artist)
                }
                try? await Task.sleep(for: .milliseconds(250))  // Deezer allows 50 requests per 5 seconds
            }
            findingArtistPictures = nil
        }
    }

    // MARK: Recaps and credits

    /// Where each show's recap or intro ends and its credits start, marked
    /// while watching. Keyed by show id.
    public private(set) var showMarkers: [String: ShowMarkers] = {
        UserDefaults.standard.data(forKey: "showMarkers").flatMap { try? JSONDecoder().decode([String: ShowMarkers].self, from: $0) } ?? [:]
    }()

    public func markers(for item: MediaItem) -> ShowMarkers? {
        item.kind == .episode ? showMarkers[Show.id(for: item)] : nil
    }

    /// Recap/intro ends at `position` in this show's episodes (nil clears it).
    public func setRecapEnd(_ position: Double?, for item: MediaItem) {
        updateMarkers(for: item) { $0.recapEnd = position }
    }

    /// Credits start `position` into an episode `duration` long: kept as the
    /// time before the end, which carries over to episodes of other lengths.
    public func setCreditsStart(_ position: Double?, duration: Double, for item: MediaItem) {
        updateMarkers(for: item) { $0.creditsLength = position.map { max(0, duration - $0) } }
    }

    private func updateMarkers(for item: MediaItem, _ change: (inout ShowMarkers) -> Void) {
        guard item.kind == .episode else { return }
        let id = Show.id(for: item)
        var markers = showMarkers[id] ?? ShowMarkers()
        change(&markers)
        showMarkers[id] = markers.recapEnd == nil && markers.creditsLength == nil ? nil : markers
        UserDefaults.standard.set(try? JSONEncoder().encode(showMarkers), forKey: "showMarkers")
    }

    /// What to watch after the last episode of `show`: the episode to pick up
    /// in another show you're watching, else the first unwatched episode of
    /// another show.
    public func nextShow(after showID: String) -> MediaItem? {
        if let next = continueWatching.first(where: { $0.kind == .episode && Show.id(for: $0) != showID }) { return next }
        return index.shows.lazy.filter { $0.id != showID }.compactMap { show in
            show.episodes.first { episode in episode.id.flatMap { self.positions[$0] }?.isFinished != true }
        }.first
    }

    /// Items taken off Continue Watching, and when. One comes back once it's
    /// played again (its resume point is newer than this).
    public private(set) var removedFromContinueWatching: [Int64: Date] = {
        let saved = UserDefaults.standard.dictionary(forKey: "removedFromContinueWatching") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in Int64(key).map { ($0, Date(timeIntervalSince1970: value)) } })
    }()

    public func removeFromContinueWatching(_ item: MediaItem) {
        removeFromContinueWatching(parts: [item])
    }

    public func removeFromContinueWatching(_ book: Book) {
        removeFromContinueWatching(parts: book.parts)
    }

    private func removeFromContinueWatching(parts: [MediaItem]) {
        for id in parts.compactMap(\.id) { removedFromContinueWatching[id] = Date() }
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: removedFromContinueWatching.map { (String($0.key), $0.value.timeIntervalSince1970) }),
            forKey: "removedFromContinueWatching"
        )
    }

    /// Movies and episodes to pick up: ones stopped partway, plus the next
    /// episode of a show whose latest episode was finished. Most recent first,
    /// one per show.
    public var continueWatching: [MediaItem] {
        var result: [(item: MediaItem, date: Date)] = []
        for position in positions.values {
            guard let item = index.itemsByID[position.mediaItemId], item.isVideo, item.kind != .musicVideo else { continue }
            if position.isResumable {
                result.append((item, position.updatedAt))
            } else if position.isFinished, item.kind == .episode, let next = item.id.flatMap({ index.nextEpisode[$0] }),
                      positions[next.id ?? -1].map({ !$0.isFinished }) ?? true {
                result.append((next, position.updatedAt))
            }
        }
        result.removeAll { entry in entry.item.id.flatMap { removedFromContinueWatching[$0] }.map { $0 >= entry.date } ?? false }
        // One entry per show: the episode watched most recently.
        var seen = Set<String>()
        return result.sorted { $0.date > $1.date }.map(\.item).filter { item in
            seen.insert(item.kind == .episode ? "show:" + (item.show ?? "").lowercased() : "item:\(item.id ?? -1)").inserted
        }
    }

    /// Books started but not finished, most recently listened first.
    public var booksInProgress: [Book] {
        index.books
            .map { ($0, BookProgress(book: $0, positions: positions)) }
            .filter { book, progress in
                guard progress.isStarted, !progress.isFinished, let listened = progress.lastListened else { return false }
                return !book.parts.contains { part in part.id.flatMap { removedFromContinueWatching[$0] }.map { $0 >= listened } ?? false }
            }
            .sorted { ($0.1.lastListened ?? .distantPast) > ($1.1.lastListened ?? .distantPast) }
            .map(\.0)
    }

    public func progress(of book: Book) -> BookProgress {
        BookProgress(book: book, positions: positions)
    }

    // MARK: Bookmarks

    public func addBookmark(at position: Double, in item: MediaItem) {
        guard let id = item.id, let bookmark = try? database.addBookmark(at: position, in: id) else { return }
        bookmarks.append(bookmark)
    }

    public func deleteBookmark(_ bookmark: Bookmark) {
        try? database.deleteBookmark(bookmark)
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    // MARK: Album artwork

    /// Looks up cover art for albums without any, one album every few seconds,
    /// each album once (unless the lookup failed, e.g. while offline).
    private func fetchMissingArtwork() {
        guard UserDefaults.standard.object(forKey: Self.fetchArtworkKey) as? Bool ?? true, artworkTask == nil else { return }
        artworkGeneration = generation
        let tried = (try? database.artworkLookups()) ?? []
        // Only albums with real tags: a title that fell back to the folder name, or
        // "Unknown Artist", would send folder names to Apple.
        let albums = index.albums.filter { album in
            album.artworkKey == nil && !tried.contains(album.id) && album.artist != "Unknown Artist"
                && album.tracks.contains { $0.album != nil }
        }
        guard !albums.isEmpty else { return }
        let database = database, artwork = artwork
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            let fetcher = ArtworkFetcher()
            var found: [(key: String, paths: [String], albumId: String)] = []
            // One write for several covers, so the library isn't regrouped every few seconds.
            func saveFound() {
                for cover in found {
                    try? database.setArtworkKey(cover.key, forPaths: cover.paths)
                    try? database.recordArtworkLookup(albumId: cover.albumId)
                }
                found.removeAll()
            }
            for album in albums {
                // Turning the setting off stops a run that's under way.
                guard !Task.isCancelled, UserDefaults.standard.object(forKey: Library.fetchArtworkKey) as? Bool ?? true else { break }
                switch await fetcher.artwork(artist: album.artist, album: album.title) {
                case .found(let data):
                    if let key = artwork.store(data) { found.append((key, album.tracks.map(\.path), album.id)) }
                case .notFound:
                    try? database.recordArtworkLookup(albumId: album.id)
                case .failed:
                    break
                }
                if found.count >= 10 { saveFound() }
                try? await Task.sleep(for: .seconds(3))  // the Search API allows about 20 requests a minute
            }
            saveFound()
            await self?.artworkLookupsFinished()
        }
    }

    private func artworkLookupsFinished() {
        artworkTask = nil
        // Albums indexed while this run was going (e.g. a scan's last batch) get their turn.
        if generation != artworkGeneration { fetchMissingArtwork() }
    }

    // MARK: Video stills

    /// The artwork key for a video's still, generating the still first if needed
    /// (two at a time, in the background). Stills live only in the artwork store,
    /// so making one doesn't touch the database or regroup the library. If the
    /// caller is cancelled (its tile scrolled away) before work starts, it's skipped.
    public func still(for item: MediaItem) async -> String? {
        if let key = item.artworkKey { return key }
        let key = ArtworkStore.stillKey(for: item)
        if artwork.contains(key) { return key }
        guard !failedStills.contains(key) else { return nil }

        let cancelled = CancelFlag()
        let artwork = artwork
        let stored = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                stillQueue.addOperation {
                    guard !cancelled.isSet else { return continuation.resume(returning: false) }
                    let ok = artwork.contains(key) || VideoThumbnailer.thumbnail(of: item.url).map { artwork.store($0, key: key) } == true
                    continuation.resume(returning: ok)
                }
            }
        } onCancel: {
            cancelled.set()
        }
        if !stored, !cancelled.isSet { failedStills.insert(key) }
        return stored ? key : nil
    }

    // MARK: Playlists

    @discardableResult
    public func createPlaylist(named name: String, with items: [MediaItem] = []) -> Playlist? {
        guard let playlist = try? database.createPlaylist(named: name) else { return nil }
        try? database.add(items, to: playlist)
        return playlist
    }

    public func add(_ items: [MediaItem], to playlist: Playlist) { try? database.add(items, to: playlist) }

    /// Creates playlists from the Music app's exported Library.xml, or one from
    /// an M3U file. Songs not in this library are skipped, and so are playlists
    /// left with none.
    /// Playlists from the Music app's exported Library.xml (or an M3U), plus
    /// its play counts and loved or 4–5-star songs for the files that are here.
    public func importPlaylists(from url: URL) throws -> (playlists: Int, songs: Int, missing: Int, history: Int, favorites: Int) {
        let data = try Data(contentsOf: url)
        let lists: [(name: String, paths: [String])]
        if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
            let text = String(decoding: data, as: UTF8.self)
            lists = [(url.deletingPathExtension().lastPathComponent, PlaylistFile.m3uPaths(text, relativeTo: url.deletingLastPathComponent()))]
        } else {
            lists = try PlaylistFile.musicLibraryPlaylists(data)
        }
        let rules = FolderRules(folderRules)
        let byPath = Dictionary(((try? database.allItems()) ?? []).filter { rules.kind(for: $0.path) != .adult }.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        var result = (playlists: 0, songs: 0, missing: 0, history: 0, favorites: 0)
        if !["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
            // Plays still being saved must land first, or they'd add to the imported count.
            flushPendingWrites()
            for track in try PlaylistFile.musicLibraryHistory(data) {
                guard let id = (byPath[track.path] ?? byPath[URL(fileURLWithPath: track.path).canonicalPath])?.id else { continue }
                if track.playCount > 0 {
                    try? database.mergePlayHistory(of: id, count: track.playCount, lastPlayed: track.lastPlayed ?? .distantPast)
                    result.history += 1
                }
                if track.isFavorite, !favorites.contains(id) {
                    try? database.setFavorite(true, ids: [id])
                    favorites.insert(id)
                    result.favorites += 1
                }
            }
            playStats = (try? database.playStats()) ?? playStats
        }
        for list in lists {
            let items = list.paths.compactMap { byPath[$0] ?? byPath[URL(fileURLWithPath: $0).canonicalPath] }
            result.missing += list.paths.count - items.count
            guard !items.isEmpty else { continue }
            createPlaylist(named: list.name, with: items)
            result.playlists += 1
            result.songs += items.count
        }
        return result
    }
    public func rename(_ playlist: Playlist, to name: String) { try? database.renamePlaylist(playlist, to: name) }
    public func delete(_ playlist: Playlist) { try? database.deletePlaylist(playlist) }
    public func removeEntries(positions: [Int], from playlist: Playlist) { try? database.removeEntries(positions: positions, from: playlist) }
}

/// Set from a cancellation handler, read from an OperationQueue thread.
private final class CancelFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
