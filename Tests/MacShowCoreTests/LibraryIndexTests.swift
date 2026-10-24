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
