import Foundation
import Testing
@testable import MacShowCore

struct ModernizeTests {
    func video(_ path: String, title: String, codec: String, megabytes: Double, minutes: Double, id: Int64) -> MediaItem {
        var item = makeItem(path, kind: .movie, title: title)
        item.formatInfo = "\(codec) · MP3 · 48 kHz"
        item.fileSize = Int64(megabytes * 1_048_576)
        item.duration = minutes * 60
        item.id = id
        return item
    }

    @Test func offersOldFormatsThatSaveSpace() throws {
        let mind = video("/NAS/Movies/A Beautiful Mind (2001).avi", title: "A Beautiful Mind", codec: "MSMPEG4V3", megabytes: 700, minutes: 135, id: 1)
        let modern = video("/NAS/Movies/Avatar.mkv", title: "Avatar", codec: "H264", megabytes: 4000, minutes: 162, id: 2)
        // Already squeezed: an old format at a low bitrate leaves little to save.
        let tiny = video("/NAS/Movies/Tiny.avi", title: "Tiny", codec: "MPEG4", megabytes: 90, minutes: 100, id: 3)
        let found = Modernize.candidates(in: [mind, modern, tiny])
        #expect(found.map(\.title) == ["A Beautiful Mind"])
        let candidate = try #require(found.first)
        #expect(candidate.codec == "DivX 3" && candidate.items == [mind] && !candidate.joinsParts)
        #expect(candidate.size == mind.fileSize)
        #expect(candidate.estimatedSize < mind.fileSize * 7 / 10 && candidate.estimatedSize > mind.fileSize / 5)
    }

    @Test func joinsMoviesSplitIntoParts() throws {
        let part2 = video("/NAS/Movies/Gandhi/gandhi-cd2-ewdp.avi", title: "Gandhi – Part 2", codec: "MPEG4", megabytes: 700, minutes: 101, id: 2)
        let part1 = video("/NAS/Movies/Gandhi/gandhi-cd1-ewdp.avi", title: "Gandhi – Part 1", codec: "MPEG4", megabytes: 700, minutes: 88, id: 1)
        let cd1 = video("/NAS/Movies/Amadeus/nep-amadeus-xvid-cd1.avi", title: "nep-amadeus-xvid-cd1", codec: "MPEG4", megabytes: 700, minutes: 88, id: 3)
        let cd2 = video("/NAS/Movies/Amadeus/nep-amadeus-xvid-cd2.avi", title: "nep-amadeus-xvid-cd2", codec: "MPEG4", megabytes: 700, minutes: 85, id: 4)
        let found = Modernize.candidates(in: [part2, cd2, part1, cd1])
        #expect(found.count == 2)
        let gandhi = try #require(found.first { $0.title == "Gandhi" })
        #expect(gandhi.items == [part1, part2] && gandhi.joinsParts && gandhi.size == part1.fileSize + part2.fileSize)
        let amadeus = try #require(found.first { $0.items.first == cd1 })
        #expect(amadeus.items == [cd1, cd2] && amadeus.joinsParts)
    }

    @Test func joinsPartsEvenWhenLittleIsSaved() {
        // Merging is worth it on its own.
        let one = video("/m/Film/film cd1.avi", title: "Film – Part 1", codec: "MPEG4", megabytes: 90, minutes: 100, id: 1)
        let two = video("/m/Film/film cd2.avi", title: "Film – Part 2", codec: "MPEG4", megabytes: 90, minutes: 100, id: 2)
        #expect(Modernize.candidates(in: [one, two]).map(\.items) == [[one, two]])
        // Parts in a modern format are joined too.
        let a = video("/m/Show/show part1.mkv", title: "Show – Part 1", codec: "H264", megabytes: 900, minutes: 60, id: 3)
        let b = video("/m/Show/show part2.mkv", title: "Show – Part 2", codec: "H264", megabytes: 900, minutes: 60, id: 4)
        #expect(Modernize.candidates(in: [a, b]).first?.joinsParts == true)
        // The title keeps its case and loses ", Part 1".
        let r1 = video("/f1/F1 Malaysia Race Part 1.mpg", title: "2011 Malaysian Grand Prix – Race, Part 1", codec: "MPEG2VIDEO", megabytes: 900, minutes: 60, id: 7)
        let r2 = video("/f1/F1 Malaysia Race Part 2.mpg", title: "2011 Malaysian Grand Prix – Race, Part 2", codec: "MPEG2VIDEO", megabytes: 900, minutes: 60, id: 8)
        #expect(Modernize.candidates(in: [r1, r2]).first?.title == "2011 Malaysian Grand Prix – Race")
        // Two-part TV episodes are separate episodes.
        var e1 = video("/tv/Show/Show S01E01 Part 1.mpg", title: "Pilot – Part 1", codec: "MPEG2VIDEO", megabytes: 900, minutes: 45, id: 5)
        var e2 = video("/tv/Show/Show S01E02 Part 2.mpg", title: "Pilot – Part 2", codec: "MPEG2VIDEO", megabytes: 900, minutes: 45, id: 6)
        e1.kind = .episode
        e2.kind = .episode
        #expect(Modernize.candidates(in: [e1, e2]).allSatisfy { !$0.joinsParts })
    }
}

struct CarryOverTests {
    @Test func movesWhatMacShowKnowsToTheNewFile() throws {
        let database = try LibraryDatabase.inMemory()
        var part1 = makeItem("/m/Gandhi/gandhi-cd1.avi", kind: .movie)
        part1.duration = 5280
        var part2 = makeItem("/m/Gandhi/gandhi-cd2.avi", kind: .movie)
        part2.duration = 6060
        var joined = makeItem("/m/Gandhi/Gandhi.mp4", kind: .movie)
        joined.duration = 11340
        try database.upsert([part1, part2, joined])
        let byPath = Dictionary(uniqueKeysWithValues: try database.allItems().map { ($0.path, $0) })
        let one = try #require(byPath[part1.path]), two = try #require(byPath[part2.path]), new = try #require(byPath[joined.path])

        try database.savePosition(1200, duration: 6060, for: two.id!)
        try database.setFavorite(true, ids: [one.id!])
        try database.recordPlay(of: one.id!)
        try database.recordPlay(of: two.id!)
        let list = try database.createPlaylist(named: "Oscars")
        try database.add([one, two], to: list)
        var edit = ItemEdit(path: one.path)
        edit.title = "Gandhi – Part 1"
        edit.year = 1982
        try database.save([edit])

        try database.carryOver(from: [one, two], to: new)

        let id = try #require(new.id)
        let position = try database.writer.read { db in try LibraryDatabase.positions(db)[id] }
        // 20 minutes into part 2 is part 1's length plus 20 minutes into the whole.
        #expect(position?.position == 6480.0)
        #expect(try database.favorites().contains(id))
        // Watching both parts once is watching the movie once.
        #expect(try database.playStats()[id]?.playCount == 1)
        let entries = try database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT mediaItemId FROM playlistEntry WHERE playlistId = ? ORDER BY position", arguments: [list.id])
        }
        #expect(entries == [id])
        let moved = try database.itemEdits()[new.path]
        #expect(moved?.title == "Gandhi" && moved?.year == 1982)
    }
}

struct AdoptConversionTests {
    @MainActor
    @Test func convertedFileTakesTheOriginalsPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = Bundle.module.url(forResource: "Fixtures/My.Show.S02E05.720p", withExtension: "mkv")!
        let original = folder.appendingPathComponent("Old Film.mkv")
        try FileManager.default.copyItem(at: clip, to: original)
        let library = Library(database: try LibraryDatabase.inMemory(), artwork: ArtworkStore(directory: folder.appendingPathComponent("art")))
        library.addFolder(folder)
        for _ in 0..<250 where library.index.itemsByID.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let old = try #require(library.index.itemsByID.values.first)
        library.savePosition(0.5, duration: 1, for: old)
        #expect(Library.canWrite(in: folder))

        let output = folder.appendingPathComponent("Old Film.mp4")
        try VideoConverter.convert([original], to: output, videoBitrate: 500_000) { _ in }
        let converted = try #require(await library.adoptConversion(of: [old], output: output))

        #expect(converted.path == output.canonicalPath)
        #expect(library.positions[try #require(converted.id)]?.position == 0.5)
        // The original leaves the library but stays on disk until removed.
        for _ in 0..<50 where library.index.itemsByID.values.contains(where: { $0.path == old.path }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!library.index.itemsByID.values.contains { $0.path == old.path })
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(library.removeOriginals([old.path]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!library.folderRules.contains { $0.path == old.path })
    }

    @Test func noWritingWhereTheFolderIsMissing() {
        #expect(!Library.canWrite(in: URL(fileURLWithPath: "/nonexistent-\(UUID())")))
    }
}
