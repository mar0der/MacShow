import Foundation
import Testing
@testable import MacShowCore

struct AudiobookTests {
    private func book() -> Book {
        var parts = [
            makeItem("/books/Dune/01.mp3", kind: .audiobook, track: 1),
            makeItem("/books/Dune/02.mp3", kind: .audiobook, track: 2),
            makeItem("/books/Dune/03.mp3", kind: .audiobook, track: 3),
        ]
        for index in parts.indices {
            parts[index].id = Int64(index + 1)
            parts[index].duration = 600
        }
        return Book(id: "/books/Dune", title: "Dune", author: nil, artworkKey: nil, parts: parts)
    }

    private func position(_ id: Int64, _ seconds: Double, minutesAgo: Double) -> (Int64, PlaybackPosition) {
        (id, PlaybackPosition(mediaItemId: id, position: seconds, duration: 600, updatedAt: Date(timeIntervalSinceNow: -minutesAgo * 60)))
    }

    @Test func unstartedBook() {
        let progress = BookProgress(book: book(), positions: [:])
        #expect(!progress.isStarted)
        #expect(progress.partIndex == 0)
        #expect(progress.total == 1800)
    }

    @Test func continuesInTheMostRecentFile() {
        let positions = Dictionary(uniqueKeysWithValues: [position(1, 590, minutesAgo: 10), position(2, 120, minutesAgo: 1)])
        let progress = BookProgress(book: book(), positions: positions)
        #expect(progress.partIndex == 1)
        #expect(progress.elapsed == 720)
        #expect(progress.isStarted && !progress.isFinished)
    }

    @Test func movesOnAfterAFinishedFile() {
        let positions = Dictionary(uniqueKeysWithValues: [position(2, 595, minutesAgo: 1)])
        let progress = BookProgress(book: book(), positions: positions)
        #expect(progress.partIndex == 2)
        #expect(progress.elapsed == 1200)
    }

    @Test func lastFileFinishedMeansBookFinished() {
        let positions = Dictionary(uniqueKeysWithValues: [position(3, 598, minutesAgo: 1)])
        #expect(BookProgress(book: book(), positions: positions).isFinished)
    }

    @Test func bookmarksPersist() throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([makeItem("/books/Emma.m4b", kind: .audiobook, chapters: 3)])
        let item = try #require(try database.allItems().first)
        try database.addBookmark(at: 1234, in: item.id!)
        #expect(try database.bookmarks().map(\.position) == [1234])
        try database.deleteItems(paths: [item.path])
        #expect(try database.bookmarks().isEmpty)
    }
}

struct BookAuthorTests {
    @Test func groupsByAuthorWithUnknownLast() {
        func book(_ title: String, _ author: String?) -> Book {
            Book(id: title, title: title, author: author, artworkKey: nil, parts: [])
        }
        let groups = Book.byAuthor([book("Zeta", "Ann"), book("Untitled", nil), book("Alpha", "Ann"), book("Dune", "Frank Herbert"), book("Blank", " ")])
        #expect(groups.map(\.author) == ["Ann", "Frank Herbert", nil])
        #expect(groups[0].books.map(\.title) == ["Alpha", "Zeta"])
        #expect(groups[2].books.map(\.title) == ["Blank", "Untitled"])
    }
}

struct LyricsTests {
    @Test func parsesLRC() {
        let lyrics = Lyrics(lines: Lyrics.parse("[ar: Someone]\n[ti: Song]\n[00:01.50] first\n[00:04.00][00:20.00] chorus\n[00:10.25] second\n"), source: "file")
        #expect(lyrics.lines.map(\.text) == ["first", "chorus", "second", "chorus"])
        #expect(lyrics.lines.map(\.time) == [1.5, 4, 10.25, 20])
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 5) == 1)
        #expect(lyrics.lineIndex(at: 30) == 3)
    }

    @Test func plainTextIsUnsynced() {
        let lyrics = Lyrics(lines: Lyrics.parse("one\ntwo\n\n"), source: "tags")
        #expect(!lyrics.isSynced && lyrics.lines.map(\.text) == ["one", "two"])
        #expect(lyrics.lineIndex(at: 10) == nil)
    }

    @Test func readsLRCLIBAndSidecarFiles() throws {
        let synced = LyricsFinder.fromLRCLIB(Data(#"{"syncedLyrics":"[00:01.00] a\n[00:02.00] b","plainLyrics":"a\nb"}"#.utf8))
        #expect(synced?.isSynced == true && synced?.source == "LRCLIB")
        #expect(LyricsFinder.fromLRCLIB(Data(#"{"instrumental":true}"#.utf8))?.isInstrumental == true)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Lyrics-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("[00:03.00] hello".utf8).write(to: folder.appendingPathComponent("01 Song.lrc"))
        let song = makeItem(folder.appendingPathComponent("01 Song.flac").path)
        #expect(LyricsFinder.local(for: song)?.lines.first?.text == "hello")
    }

    @Test func remembersSongsWithoutLyrics() throws {
        let database = try LibraryDatabase.inMemory()
        #expect(try database.cachedLyrics("/a.mp3") == nil)
        try database.cacheLyrics(nil, path: "/a.mp3")
        #expect(try database.cachedLyrics("/a.mp3") == .some(nil))
    }
}
