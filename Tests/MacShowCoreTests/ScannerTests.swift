import Foundation
import Testing
@testable import MacShowCore

/// Copies the fixtures into a fresh temporary folder per test.
struct TempLibrary {
    let folder: URL
    let database: LibraryDatabase
    let artwork: ArtworkStore
    let scanner: LibraryScanner

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacShowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path) {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        database = try LibraryDatabase.inMemory()
        artwork = ArtworkStore(directory: folder.appendingPathComponent(".artwork"))
        scanner = LibraryScanner(database: database, artwork: artwork)
    }

    func item(named name: String) throws -> MediaItem {
        try #require(try database.allItems().first { $0.url.lastPathComponent == name })
    }
}

struct MetadataReaderTests {
    let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    @Test func readsFlacTagsAndCover() throws {
        let meta = try #require(MetadataReader.read(fixtures.appendingPathComponent("song.flac")))
        #expect(meta.tags["title"] == "Test Song")
        #expect(meta.tags["album_artist"] == "Test Artist")
        #expect(meta.artwork != nil)
        #expect(!meta.hasVideo)
        #expect(meta.formatInfo == "FLAC · 44.1 kHz")
        #expect(!meta.isProtected)
    }

    @Test func readsAudiobookChapters() throws {
        let meta = try #require(MetadataReader.read(fixtures.appendingPathComponent("book.m4b")))
        #expect(meta.chapters.map(\.title) == ["Opening", "Ending"])
        #expect(abs(meta.chapters[1].start - 1.5) < 0.01)
        #expect(!meta.isProtected)
    }

    @Test func readsVideo() throws {
        let meta = try #require(MetadataReader.read(fixtures.appendingPathComponent("My.Show.S02E05.720p.mkv")))
        #expect(meta.hasVideo)
        #expect(meta.videoCodec == "h264")
        #expect(meta.duration > 0.9)
    }

    @Test func unreadableFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-media-\(UUID()).mp3")
        try Data("hello".utf8).write(to: url)
        #expect(MetadataReader.read(url) == nil)
    }
}

struct ScannerTests {
    @Test func indexesAndClassifiesFiles() async throws {
        let library = try TempLibrary()
        let result = await library.scanner.scan(folder: library.folder)
        #expect(result == ScanResult(added: 3, updated: 0, removed: 0))

        let song = try library.item(named: "song.flac")
        #expect(song.kind == .music)
        #expect(song.title == "Test Song")
        #expect(song.album == "Test Album")
        #expect(song.trackNumber == 3)
        #expect(song.discNumber == 1)
        #expect(song.year == 2024)
        #expect(song.artworkKey != nil)
        #expect(FileManager.default.fileExists(atPath: library.artwork.url(for: song.artworkKey!).path))

        let book = try library.item(named: "book.m4b")
        #expect(book.kind == .audiobook)
        #expect(book.chapterCount == 2)

        let episode = try library.item(named: "My.Show.S02E05.720p.mkv")
        #expect(episode.kind == .episode)
        #expect(episode.show == "My Show")
        #expect(episode.season == 2)
        #expect(episode.episode == 5)
    }

    @Test func reportsProgressAsItReads() async throws {
        final class Updates: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [ScanProgress] = []
            func append(_ update: ScanProgress) { lock.withLock { list.append(update) } }
            var all: [ScanProgress] { lock.withLock { list } }
        }
        let library = try TempLibrary()
        let updates = Updates()
        await library.scanner.scan(folder: library.folder) { updates.append($0) }
        let all = updates.all
        // Once listed: none of 3 read; then each file as it's read.
        #expect(all.first?.done == 0 && all.first?.total == 3 && all.first?.file == nil)
        #expect(all.last?.done == 3 && all.last?.total == 3)
        #expect(Set(all.compactMap(\.file)) == ["song.flac", "book.m4b", "My.Show.S02E05.720p.mkv"])
    }

    @Test func rescanOnlyReadsChangesAndDropsMissingFiles() async throws {
        let library = try TempLibrary()
        await library.scanner.scan(folder: library.folder)
        let firstID = try library.item(named: "song.flac").id

        #expect(await library.scanner.scan(folder: library.folder) == ScanResult())

        let song = library.folder.appendingPathComponent("song.flac")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: song.path)
        try FileManager.default.removeItem(at: library.folder.appendingPathComponent("book.m4b"))
        #expect(await library.scanner.scan(folder: library.folder) == ScanResult(added: 0, updated: 1, removed: 1))
        #expect(try library.item(named: "song.flac").id == firstID)
    }

    @Test func unreadableFolderKeepsOnlyItsOwnItems() async throws {
        let library = try TempLibrary()
        let locked = library.folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library.folder.appendingPathComponent("song.flac"), to: locked.appendingPathComponent("song.flac"))
        await library.scanner.scan(folder: library.folder)
        #expect(try library.database.allItems().count == 3)

        // The locked folder becomes unreadable and a file outside it is deleted.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        try FileManager.default.removeItem(at: library.folder.appendingPathComponent("book.m4b"))

        #expect(await library.scanner.scan(folder: library.folder).removed == 1)
        #expect(try library.database.allItems().map(\.url.lastPathComponent).sorted() == ["My.Show.S02E05.720p.mkv", "song.flac"])
    }

    @Test func removingAFolderKeepsItemsAnotherFolderCovers() throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([makeItem("/Movies/film.mkv"), makeItem("/Movies/TV/s1e1.mkv")])
        try database.removeWatchedFolder(path: "/Movies", keepingItemsUnder: ["/Movies/TV"])
        #expect(try database.allItems().map(\.path) == ["/Movies/TV/s1e1.mkv"])
    }

    @Test func missingFolderKeepsItsItems() async throws {
        let library = try TempLibrary()
        await library.scanner.scan(folder: library.folder)
        #expect(await library.scanner.scan(folder: library.folder.appendingPathComponent("gone")) == ScanResult())
        #expect(try library.database.allItems().count == 3)
    }

    @Test func folderPrefixDoesNotMatchSiblingFolders() {
        let database = try! LibraryDatabase.inMemory()
        try! database.upsert([makeItem("/Music/a.mp3"), makeItem("/Music Videos/b.mp4"), makeItem("/music/c.mp3"), makeItem("/My_Music/d.mp3")])
        #expect(Set(try! database.fileStamps(under: "/Music").keys) == ["/Music/a.mp3"])
        #expect(Set(try! database.fileStamps(under: "/My_Music").keys) == ["/My_Music/d.mp3"])
    }
}

struct FolderWatcherTests {
    @Test func reportsNewFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacShowWatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let changed = AsyncStream.makeStream(of: [String].self)
        let watcher = FolderWatcher(paths: [folder.path], latency: 0.2) { changed.continuation.yield($0) }

        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: folder.appendingPathComponent("new.mp3"))

        let paths = await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await changed.stream.first { _ in true } }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        _ = watcher
        let reported = try #require(paths)
        #expect(reported.contains { $0.hasPrefix(folder.canonicalPath) })
    }
}

struct FolderRuleTests {
    @Test func excludedFolderIsNotIndexedAndItsItemsGo() async throws {
        let library = try TempLibrary()
        let hidden = library.folder.appendingPathComponent("X")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library.folder.appendingPathComponent("song.flac"), to: hidden.appendingPathComponent("song.flac"))
        await library.scanner.scan(folder: library.folder)
        #expect(try library.database.allItems().count == 3)

        try library.database.setFolderRule(.excluded, for: hidden.canonicalPath)
        #expect(try library.database.allItems().count == 2)
        let excluded = FolderRules(try library.database.folderRules()).excludedPaths
        #expect(await library.scanner.scan(folder: library.folder, excluding: excluded) == ScanResult())
        // Scanning inside the excluded folder (a file system event there) adds nothing.
        await library.scanner.scan(folder: hidden, excluding: excluded)
        #expect(try library.database.allItems().map(\.url.lastPathComponent).sorted() == ["My.Show.S02E05.720p.mkv", "book.m4b"])

        try library.database.setFolderRule(nil, for: hidden.canonicalPath)
        #expect(await library.scanner.scan(folder: library.folder).added == 1)
    }

    @Test func innermostRuleWins() {
        let rules = FolderRules([FolderRule(path: "/Movies/X", kind: .adult), FolderRule(path: "/Movies/X/Keep", kind: .excluded)])
        #expect(rules.kind(for: "/Movies/X/a.mp4") == .adult)
        #expect(rules.kind(for: "/Movies/X/Keep/b.mp4") == .excluded)
        #expect(rules.kind(for: "/Movies/Xmas.mp4") == nil)
    }

    @Test func adultAndPersonalFoldersStayApart() {
        let items = [
            makeItem("/Movies/Film.mkv", kind: .movie),
            makeItem("/Movies/Family/Birthday.mov", kind: .movie),
            makeItem("/Movies/X/clip.mp4", kind: .movie),
        ].enumerated().map { offset, item in var item = item; item.id = Int64(offset + 1); item.duration = 3600; return item }
        let rules = FolderRules([FolderRule(path: "/Movies/Family", kind: .personal), FolderRule(path: "/Movies/X", kind: .adult)])

        let locked = LibraryIndex(items: items, rules: rules)
        #expect(locked.movies.map(\.title) == ["Film.mkv"])
        #expect(locked.homeVideos.map(\.title) == ["Birthday.mov"])
        #expect(locked.adult.isEmpty)
        #expect(!locked.recentlyAdded.contains { $0.path.hasPrefix("/Movies/X/") })
        #expect(locked.itemsByID[3] == nil)

        let unlocked = LibraryIndex(items: items, rules: rules, showingAdult: true)
        #expect(unlocked.adult.map(\.title) == ["clip.mp4"])
        #expect(unlocked.movies.map(\.title) == ["Film.mkv"])
        #expect(!unlocked.recentlyAdded.contains { $0.path.hasPrefix("/Movies/X/") })
    }
}

struct NetworkFolderTests {
    @Test func remembersTheShareAddress() throws {
        let database = try LibraryDatabase.inMemory()
        try database.addWatchedFolder(WatchedFolder(path: "/Volumes/Media/Music", remountURL: "smb://nas.local/Media"))
        try database.addWatchedFolder(WatchedFolder(path: "/Volumes/Media/Movies"))
        try database.setRemountURL("smb://nas.local/Media", forFolder: "/Volumes/Media/Movies")
        try database.addWatchedFolder(WatchedFolder(path: "/Users/me/Music"))

        let folders = try database.watchedFolders()
        #expect(folders.filter(\.isOnNetworkShare).map(\.path) == ["/Volumes/Media/Movies", "/Volumes/Media/Music"])
        #expect(folders.first { $0.path == "/Users/me/Music" }?.remountURL == nil)
    }

    @Test func localFoldersHaveNoShareAddress() throws {
        let folder = FileManager.default.temporaryDirectory
        #expect((try folder.resourceValues(forKeys: [.volumeURLForRemountingKey])).volumeURLForRemounting == nil)
    }
}

struct SourceDetectionTests {
    @Test func volumesMountsAreDetected() {
        let item = makeItem("/Volumes/Media/Movies/film.mkv")
        #expect(item.source == "Media")
    }
    
    @Test func localFilesHaveNoSource() {
        let local = makeItem("/Users/me/Movies/film.mkv")
        #expect(local.source == nil)
    }
    
    @Test func rootFilesHaveNoSource() {
        let root = makeItem("/tmp/test.mkv")
        #expect(root.source == nil)
    }
    
    @Test func sourceIsConsistentForSameMountPoint() {
        // Items on the same mount should have the same source.
        let item1 = makeItem("/Volumes/Media/Movies/a.mkv")
        let item2 = makeItem("/Volumes/Media/TV/b.mkv")
        #expect(item1.source == item2.source)
    }
    
    @Test func localFilesNotMisattributedToNearbyShare() {
        // Local files under /Users/<user>/Music should not get the source
        // from a share mounted at /Users/<user>/NAS/media.
        // Both paths start with /Users/<user>/ but have different mount points.
        let local1 = makeItem("/Users/test/Music/song.mp3")
        let local2 = makeItem("/Users/test/Downloads/video.mp4")
        #expect(local1.source == nil)
        #expect(local2.source == nil)
    }
}

struct SourceNameParsingTests {
    @Test func smbPathWithIPAddress() {
        // SMB mount from IP should keep the full IP address, not truncate at first dot.
        let source = MediaItem.SourceCache.testSourceNameFromMount(
            mountPoint: "/Users/user/NAS/media",
            fromName: "//petar@192.168.0.202/media"
        )
        #expect(source == "media@192.168.0.202")
    }
    
    @Test func smbPathWithHostname() {
        // SMB mount from hostname should shorten to first component.
        let source = MediaItem.SourceCache.testSourceNameFromMount(
            mountPoint: "/Volumes/Media",
            fromName: "//macshow@dspeter.taild48c09.ts.net/Media"
        )
        #expect(source == "Media@dspeter")
    }
    
    @Test func nfsPathWithIPAddress() {
        // NFS mount from IP should keep the full IP address.
        let source = MediaItem.SourceCache.testSourceNameFromMount(
            mountPoint: "/mnt/backup",
            fromName: "10.0.1.50:/export/backup"
        )
        #expect(source == "backup@10.0.1.50")
    }
    
    @Test func nfsPathWithHostname() {
        // NFS mount from hostname should shorten to first component.
        let source = MediaItem.SourceCache.testSourceNameFromMount(
            mountPoint: "/mnt/share",
            fromName: "server.local.lan:/export/share"
        )
        #expect(source == "share@server")
    }
    
    @Test func volumesMountPoint() {
        // /Volumes/<name> should just return the name.
        let source = MediaItem.SourceCache.testSourceNameFromMount(
            mountPoint: "/Volumes/Backup",
            fromName: "//server/Backup"
        )
        #expect(source == "Backup")
    }
    
    @Test func ipv4AddressRecognition() {
        #expect(MediaItem.SourceCache.testShortHostname("192.168.0.202") == "192.168.0.202")
        #expect(MediaItem.SourceCache.testShortHostname("10.0.1.1") == "10.0.1.1")
        #expect(MediaItem.SourceCache.testShortHostname("8.8.8.8") == "8.8.8.8")
    }
    
    @Test func hostnameShortening() {
        #expect(MediaItem.SourceCache.testShortHostname("dspeter.taild48c09.ts.net") == "dspeter")
        #expect(MediaItem.SourceCache.testShortHostname("server.local") == "server")
        #expect(MediaItem.SourceCache.testShortHostname("nas") == "nas")
    }
    
    @Test func edgeCaseHostnames() {
        // Not a valid IP (wrong number of components or non-numeric).
        #expect(MediaItem.SourceCache.testShortHostname("192.168.0") == "192")
        #expect(MediaItem.SourceCache.testShortHostname("192.168.0.202.extra") == "192")
        #expect(MediaItem.SourceCache.testShortHostname("host-192.168.0.1") == "host-192")
    }
}

struct ProtectionBoxTests {
    /// An MP4 box: 4-byte big-endian size, type, payload.
    func box(_ type: String, _ payload: Data = Data()) -> Data {
        let size = UInt32(8 + payload.count)
        return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]) + Data(type.utf8) + payload
    }

    func file(_ boxes: Data...) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protection-\(UUID()).m4a")
        try boxes.reduce(Data(), +).write(to: url)
        return url
    }

    @Test func findsTheProtectionBoxInTheMovieHeaderWhereverItIs() throws {
        let media = box("mdat", Data(count: 3 << 20))
        let protected = box("moov", box("trak", box("sinf", box("frma", Data("mp4a".utf8)))))
        // Header between two large boxes: neither the first nor the last 2 MB.
        #expect(MetadataReader.containsProtectionBox(try file(box("ftyp", Data("M4A ".utf8)), media, protected, box("free", Data(count: 3 << 20)))))
        #expect(MetadataReader.containsProtectionBox(try file(box("ftyp"), protected, media)))
    }

    @Test func ignoresProtectionLookalikesInTheMedia() throws {
        // "sinf" with a plausible size inside the audio data is not a protection box.
        let media = box("mdat", Data(count: 1000) + box("sinf", Data(count: 12)) + Data(count: 1000))
        #expect(!MetadataReader.containsProtectionBox(try file(box("ftyp"), box("moov", box("trak")), media)))
    }
}
