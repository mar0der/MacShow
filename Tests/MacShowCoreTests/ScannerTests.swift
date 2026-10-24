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
