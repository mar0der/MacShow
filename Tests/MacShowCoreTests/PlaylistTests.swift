import Foundation
import GRDB
import Testing
@testable import MacShowCore

struct PlaylistTests {
    private func insert(_ items: [MediaItem], into database: LibraryDatabase) throws -> [MediaItem] {
        try database.upsert(items)
        return try database.allItems().sorted { $0.path < $1.path }
    }

    private func contents(_ database: LibraryDatabase) throws -> [PlaylistContents] {
        try database.writer.read { db in
            let items = try MediaItem.fetchAll(db)
            return try LibraryDatabase.playlistContents(db, items: Dictionary(uniqueKeysWithValues: items.map { ($0.id!, $0) }))
        }
    }

    @Test func keepsOrderAndRemovesEntries() throws {
        let database = try LibraryDatabase.inMemory()
        let songs = try insert([makeItem("/a.mp3"), makeItem("/b.mp3"), makeItem("/c.mp3")], into: database)
        let playlist = try database.createPlaylist(named: "Road Trip")
        try database.add([songs[2], songs[0]], to: playlist)
        try database.add([songs[1]], to: playlist)
        #expect(try contents(database)[0].items.map(\.path) == ["/c.mp3", "/a.mp3", "/b.mp3"])

        let positions = try contents(database)[0].positions
        try database.removeEntries(positions: [positions[1]], from: playlist)
        #expect(try contents(database)[0].items.map(\.path) == ["/c.mp3", "/b.mp3"])
    }

    @Test func songsLeaveWhenTheirFileIsRemoved() throws {
        let database = try LibraryDatabase.inMemory()
        let songs = try insert([makeItem("/a.mp3"), makeItem("/b.mp3")], into: database)
        let playlist = try database.createPlaylist(named: "Mix")
        try database.add(songs, to: playlist)
        try database.deleteItems(paths: ["/a.mp3"])
        #expect(try contents(database)[0].items.map(\.path) == ["/b.mp3"])
    }

    @Test func artistIncludesSongsOnCompilations() throws {
        let index = LibraryIndex(items: [
            makeItem("/m/Ballads/01.flac", artist: "Rainbow", album: "Ultimate Power Ballads", track: 1),
            makeItem("/m/Ballads/02.flac", artist: "Big Country", album: "Ultimate Power Ballads", track: 2),
        ])
        #expect(index.artists.map(\.name) == ["Big Country", "Rainbow"])
        #expect(index.artists[1].albums.isEmpty)
        #expect(index.artists[1].songs.count == 1)
    }
}
