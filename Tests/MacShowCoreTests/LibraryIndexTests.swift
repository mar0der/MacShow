import Foundation
import Testing
@testable import MacShowCore

func makeItem(
    _ path: String, kind: MediaItem.Kind = .music, title: String? = nil, artist: String? = nil,
    album: String? = nil, track: Int? = nil, disc: Int? = nil, show: String? = nil,
    season: Int? = nil, episode: Int? = nil, chapters: Int = 0, year: Int? = nil
) -> MediaItem {
    MediaItem(
        path: path, kind: kind, title: title ?? URL(fileURLWithPath: path).lastPathComponent,
        artist: artist, album: album, year: year, trackNumber: track, discNumber: disc, duration: 60,
        show: show, season: season, episode: episode, chapterCount: chapters, isProtected: false,
        formatInfo: "", fileSize: 1, modified: 0, addedAt: Date()
    )
}

struct LibraryIndexTests {
    @Test func groupsAlbumsAndOrdersTracksByDiscThenTrack() throws {
        let index = LibraryIndex(items: [
            makeItem("/m/a/2-01.flac", artist: "Band", album: "Live", track: 1, disc: 2),
            makeItem("/m/a/1-02.flac", artist: "Band", album: "Live", track: 2, disc: 1),
            makeItem("/m/a/1-01.flac", artist: "band", album: "live", track: 1, disc: 1, year: 2019),
            makeItem("/m/b/x.mp3", artist: "Other", album: "Solo"),
        ])
        #expect(index.albums.map(\.title) == ["Live", "Solo"])
        let live = index.albums[0]
        #expect(live.tracks.map(\.path) == ["/m/a/1-01.flac", "/m/a/1-02.flac", "/m/a/2-01.flac"])
        #expect(live.year == 2019)
        #expect(index.artists.map(\.name) == ["Band", "Other"])
        #expect(index.songs.count == 4)
    }

    @Test func compilationWithoutAlbumArtistStaysOneAlbum() throws {
        let index = LibraryIndex(items: [
            makeItem("/m/Ballads/01.flac", artist: "Rainbow", album: "Ultimate Power Ballads", track: 1),
            makeItem("/m/Ballads/02.flac", artist: "Big Country", album: "Ultimate Power Ballads", track: 2),
            makeItem("/m/Modern Talking part 3/a.mp3", artist: "Modern Talking"),
            makeItem("/m/Modern Talking part 3/b.mp3", artist: "Modern Talking"),
        ])
        #expect(index.albums.count == 2)
        let ballads = try #require(index.albums.first { $0.title == "Ultimate Power Ballads" })
        #expect(ballads.artist == "Various Artists")
        #expect(ballads.tracks.count == 2)
        let untagged = try #require(index.albums.first { $0.title == "Modern Talking part 3" })
        #expect(untagged.artist == "Modern Talking")
    }

    @Test func keepsTheBestCopyOfDuplicateSongs() throws {
        func song(_ path: String, _ title: String, track: Int, format: String) -> MediaItem {
            var item = makeItem(path, title: title, artist: "Billy Idol", album: "Dream Into It", track: track)
            item.albumArtist = "Billy Idol"
            item.formatInfo = format
            return item
        }
        let aac = song("/Music/Music/Media/Billy Idol/77.m4a", "77", track: 2, format: "AAC · 44.1 kHz")
        let flac = song("/Music/Billy Idol [Stereo]/02 77.flac", "77", track: 2, format: "FLAC · 48 kHz")
        let hiRes = song("/Music/Billy Idol [Hi-Res]/02 77.flac", "77", track: 2, format: "FLAC · 96 kHz")
        let other = song("/Music/Billy Idol [Stereo]/03 Too Much Fun.flac", "Too Much Fun", track: 3, format: "FLAC · 48 kHz")

        let index = LibraryIndex(items: [aac, flac, hiRes, other])
        #expect(index.songs.count == 2)
        #expect(index.albums.count == 1)
        #expect(index.albums[0].tracks.map(\.path) == [hiRes.path, other.path])
        #expect(index.duplicates.count == 1)
        #expect(index.duplicates[0].map(\.path) == [hiRes.path, flac.path, aac.path])
    }

    @Test func partlyTaggedCompilationStaysOneAlbum() throws {
        var tagged = makeItem("/m/Rock Legends/01.flac", artist: "AC/DC", album: "Rock Legends", track: 1)
        tagged.albumArtist = "AC/DC"
        let index = LibraryIndex(items: [
            tagged,
            makeItem("/m/Rock Legends/02.flac", artist: "Deep Purple", album: "Rock Legends", track: 2),
            makeItem("/m/Rock Legends/03.flac", artist: "T. Rex", album: "Rock Legends", track: 3),
        ])
        #expect(index.albums.count == 1)
        #expect(index.albums[0].tracks.count == 3)
    }

    @Test func groupsEpisodesIntoShows() {
        let index = LibraryIndex(items: [
            makeItem("/tv/s2e1.mkv", kind: .episode, show: "Severance", season: 2, episode: 1),
            makeItem("/tv/s1e2.mkv", kind: .episode, show: "Severance", season: 1, episode: 2),
            makeItem("/tv/s1e1.mkv", kind: .episode, show: "Severance", season: 1, episode: 1),
        ])
        #expect(index.shows.count == 1)
        #expect(index.shows[0].episodes.map(\.path) == ["/tv/s1e1.mkv", "/tv/s1e2.mkv", "/tv/s2e1.mkv"])
        #expect(index.shows[0].seasons == [1, 2])
    }

    @Test func folderOfFilesIsOneBookAndChapteredFileIsItsOwn() {
        let index = LibraryIndex(items: [
            makeItem("/books/Dune/02 Part.mp3", kind: .audiobook, artist: "Frank Herbert", track: 2),
            makeItem("/books/Dune/01 Part.mp3", kind: .audiobook, artist: "Frank Herbert", track: 1),
            makeItem("/books/Emma.m4b", kind: .audiobook, title: "Emma", chapters: 55),
        ])
        #expect(index.books.map(\.title) == ["Dune", "Emma"])
        #expect(index.books[0].parts.map(\.path) == ["/books/Dune/01 Part.mp3", "/books/Dune/02 Part.mp3"])
        #expect(index.books[0].author == "Frank Herbert")
    }
}

struct ArtworkFetcherTests {
    private let results = [
        ArtworkFetcher.SearchResult(collectionName: "Kamikaze", artistName: "Eminem", artworkUrl100: "https://example.com/a/100x100bb.jpg"),
        ArtworkFetcher.SearchResult(collectionName: "The Death of Slim Shady (Coup De Grâce)", artistName: "Eminem", artworkUrl100: "https://example.com/b/100x100bb.jpg"),
        ArtworkFetcher.SearchResult(collectionName: "Kamikaze", artistName: "Some Tribute Band", artworkUrl100: "https://example.com/c/100x100bb.jpg"),
    ]

    @Test func matchesAlbumAndArtistIgnoringPunctuationAndExtras() {
        #expect(ArtworkFetcher.bestMatch(in: results, artist: "Eminem", album: "Kamikaze")?.artworkUrl100?.contains("/a/") == true)
        #expect(ArtworkFetcher.bestMatch(in: results, artist: "Eminem", album: "The Death of Slim Shady [Deluxe]")?.artworkUrl100?.contains("/b/") == true)
    }

    @Test func noMatchForADifferentArtist() {
        #expect(ArtworkFetcher.bestMatch(in: results, artist: "Metallica", album: "Kamikaze") == nil)
    }

    @Test func normalizes() {
        #expect(ArtworkFetcher.normalize("Hardwired…To Self-Destruct (Deluxe)") == "hardwiredtoselfdestruct")
        #expect(ArtworkFetcher.normalize("Coup De Grâce") == "coupdegrace")
    }
}

struct DuplicateRulesTests {
    @Test func untaggedSongsWithTheSameNameAreNotMerged() {
        let a = makeItem("/Music/Rip A/Track 01.wav", title: "Track 01")
        let b = makeItem("/Music/Rip B/Track 01.wav", title: "Track 01")
        let index = LibraryIndex(items: [a, b])
        #expect(index.songs.count == 2)
        #expect(index.duplicates.isEmpty)
    }

    @Test func copiesAcrossALengthBoundaryAreMergedButDifferentDiscsAreNot() {
        var first = makeItem("/a/05.flac", title: "Song", artist: "Band", album: "Live", track: 5, disc: 1)
        first.duration = 179.98
        var second = makeItem("/b/05.m4a", title: "Song", artist: "Band", album: "Live", track: 5, disc: 1)
        second.duration = 180.03
        var otherDisc = makeItem("/a/2-05.flac", title: "Song", artist: "Band", album: "Live", track: 5, disc: 2)
        otherDisc.duration = 180
        let index = LibraryIndex(items: [first, second, otherDisc])
        #expect(index.songs.count == 2)
        #expect(index.duplicates.count == 1)
    }

    @Test func aiffCountsAsLossless() {
        var aiff = makeItem("/a/x.aiff")
        aiff.formatInfo = "PCM_S16BE · 44.1 kHz"
        var aac = makeItem("/b/x.m4a")
        aac.formatInfo = "AAC · 48 kHz"
        #expect(LibraryIndex.isBetterCopy(aiff, aac))
    }
}

struct ItemEditTests {
    @MainActor
    @Test func editsShowInTheLibraryAndOutliveRescans() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([makeItem("/m/a.mp3", title: "trck01", artist: "Unknown", album: "x")])
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        var edit = ItemEdit(path: "/m/a.mp3")
        edit.title = "Lose Yourself"
        edit.artist = "Eminem"
        library.save([edit])
        for _ in 0..<100 where library.index.songs.first?.title != "Lose Yourself" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(library.index.songs.first?.title == "Lose Yourself")
        #expect(library.index.songs.first?.artist == "Eminem")
        #expect(library.index.songs.first?.album == "x")

        // The scanner re-reading the file's tags doesn't undo it.
        try database.upsert([makeItem("/m/a.mp3", title: "trck01", artist: "Unknown", album: "x")])
        #expect(try database.itemEdits()["/m/a.mp3"]?.title == "Lose Yourself")

        // An edit set back to nothing is removed.
        library.save([ItemEdit(path: "/m/a.mp3")])
        #expect(try database.itemEdits().isEmpty)
    }
}

struct ArtistCreditTests {
    let solo: Set<String> = ["eminem", "big sean"]

    @Test func splitsDuetsLedByAKnownArtist() {
        #expect(LibraryIndex.credits("Eminem & Jelly Roll", soloArtists: solo) == ["Eminem", "Jelly Roll"])
        #expect(LibraryIndex.credits("Eminem, Big Sean & Babytron", soloArtists: solo) == ["Eminem", "Big Sean", "Babytron"])
    }

    @Test func featAlwaysSplits() {
        #expect(LibraryIndex.credits("Joyner Lucas feat. Eminem", soloArtists: []) == ["Joyner Lucas", "Eminem"])
        #expect(LibraryIndex.credits("Eminem (ft. Royce da 5'9\" & JID)", soloArtists: solo) == ["Eminem", "Royce da 5'9\"", "JID"])
    }

    @Test func guestsInTitles() {
        #expect(LibraryIndex.featuredInTitle("Lucky You (feat. Joyner Lucas)") == ["Joyner Lucas"])
        #expect(LibraryIndex.featuredInTitle("Not Alike [ft. Royce da 5'9\"]") == ["Royce da 5'9\""])
        #expect(LibraryIndex.featuredInTitle("Featuring Nobody") == [])
    }

    @Test func bandNamesStayWhole() {
        #expect(LibraryIndex.credits("Emerson, Lake & Palmer", soloArtists: solo) == ["Emerson, Lake & Palmer"])
        #expect(LibraryIndex.credits("Simon & Garfunkel", soloArtists: solo) == ["Simon & Garfunkel"])
        #expect(LibraryIndex.credits("Earth, Wind & Fire feat. The Emotions", soloArtists: solo) == ["Earth, Wind & Fire", "The Emotions"])
    }

    @Test func duetsGoToTheMainArtistAndFeaturedArtistsGetAppearances() {
        var album = [
            makeItem("/m/sd/1.m4a", artist: "Eminem", album: "The Death of Slim Shady"),
            makeItem("/m/sd/2.m4a", artist: "Eminem & Jelly Roll", album: "The Death of Slim Shady"),
            makeItem("/m/sd/3.m4a", artist: "Eminem, Big Sean & Babytron", album: "The Death of Slim Shady"),
        ]
        for index in album.indices { album[index].albumArtist = "Eminem" }
        let index = LibraryIndex(items: album + [makeItem("/m/bs/1.m4a", artist: "Big Sean", album: "Detroit")])

        #expect(index.artists.map(\.name) == ["Babytron", "Big Sean", "Eminem", "Jelly Roll"])
        let eminem = try! #require(index.artists.first { $0.name == "Eminem" })
        #expect(eminem.songs.count == 3 && eminem.albums.count == 1)
        let jelly = try! #require(index.artists.first { $0.name == "Jelly Roll" })
        #expect(jelly.isFeaturedOnly && jelly.appearances.count == 1 && jelly.appearsWith == "Eminem")
        let bigSean = try! #require(index.artists.first { $0.name == "Big Sean" })
        #expect(!bigSean.isFeaturedOnly && bigSean.appearances.count == 1)
    }
}
