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

struct PlaylistFileTests {
    static let musicExport = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Tracks</key><dict>
      <key>101</key><dict><key>Track ID</key><integer>101</integer><key>Location</key><string>file:///Music/Eminem/01%20Lose%20Yourself.m4a</string></dict>
      <key>102</key><dict><key>Track ID</key><integer>102</integer><key>Location</key><string>file:///Music/Not%20Here.mp3</string></dict>
      <key>103</key><dict><key>Track ID</key><integer>103</integer><key>Name</key><string>Streamed, no file</string></dict>
    </dict>
    <key>Playlists</key><array>
      <dict><key>Name</key><string>Library</string><key>Master</key><true/><key>Playlist Items</key><array><dict><key>Track ID</key><integer>101</integer></dict></array></dict>
      <dict><key>Name</key><string>Music</string><key>Distinguished Kind</key><integer>4</integer></dict>
      <dict><key>Name</key><string>Recently Added</string><key>Smart Info</key><data>AA==</data></dict>
      <dict><key>Name</key><string>Gym</string><key>Playlist Items</key><array>
        <dict><key>Track ID</key><integer>102</integer></dict><dict><key>Track ID</key><integer>101</integer></dict><dict><key>Track ID</key><integer>103</integer></dict>
      </array></dict>
    </array>
    </dict></plist>
    """

    @Test func readsOnlyUserPlaylistsFromMusicExport() throws {
        let lists = try PlaylistFile.musicLibraryPlaylists(Data(Self.musicExport.utf8))
        #expect(lists.map(\.name) == ["Gym"])
        #expect(lists[0].paths == ["/Music/Not Here.mp3", "/Music/Eminem/01 Lose Yourself.m4a"])
    }

    @Test func m3uRoundTrip() {
        let items = [makeItem("/Music/a b.flac", title: "Song", artist: "Band")]
        let text = PlaylistFile.m3u(items)
        #expect(text.hasPrefix("#EXTM3U\n#EXTINF:60,Band - Song\n"))
        #expect(PlaylistFile.m3uPaths(text, relativeTo: URL(fileURLWithPath: "/x")) == ["/Music/a b.flac"])
        #expect(PlaylistFile.m3uPaths("sub/c.mp3\r\n../d.mp3\nfile:///e%20f.mp3", relativeTo: URL(fileURLWithPath: "/Lists")) == ["/Lists/sub/c.mp3", "/d.mp3", "/e f.mp3"])
    }

    @MainActor
    @Test func importCreatesPlaylistsFromLibrarySongs() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([makeItem("/Music/Eminem/01 Lose Yourself.m4a")])
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Library-\(UUID()).xml")
        try Data(Self.musicExport.utf8).write(to: file)

        let result = try library.importPlaylists(from: file)
        #expect(result.playlists == 1 && result.songs == 1 && result.missing == 1)
        let contents = try await database.writer.read { db in try LibraryDatabase.playlistContents(db, items: Dictionary(uniqueKeysWithValues: try MediaItem.fetchAll(db).map { ($0.id!, $0) })) }
        #expect(contents.map(\.playlist.name) == ["Gym"])
        #expect(contents[0].items.map(\.path) == ["/Music/Eminem/01 Lose Yourself.m4a"])
    }
}

struct EqualizerTests {
    @Test func flatHasNoFilter() {
        #expect(Equalizer().mpvFilter == nil)
    }

    @Test func boostsGetHeadroom() {
        var eq = Equalizer()
        eq.gains[0] = 6
        eq.gains[9] = -3.5
        #expect(eq.mpvFilter == "lavfi=[volume=-6dB,equalizer=f=32:t=o:w=1:g=6,equalizer=f=16000:t=o:w=1:g=-3.5]")
    }

    @Test func presetsHaveEveryBand() {
        #expect(Equalizer.presets.allSatisfy { $0.equalizer.gains.count == Equalizer.frequencies.count })
    }
}

struct SmartListTests {
    @Test func listsFillFromPlays() throws {
        let database = try LibraryDatabase.inMemory()
        var songs = [makeItem("/m/a.mp3"), makeItem("/m/b.mp3"), makeItem("/m/c.mp3")]
        try database.upsert(songs)
        songs = try database.allItems().sorted { $0.path < $1.path }
        for (offset, index) in songs.indices.enumerated() { songs[index].addedAt = Date(timeIntervalSince1970: Double(offset)) }
        let a = songs[0].id!, b = songs[1].id!
        try database.recordPlay(of: a, at: Date(timeIntervalSince1970: 100))
        try database.recordPlay(of: b, at: Date(timeIntervalSince1970: 200))
        try database.recordPlay(of: a, at: Date(timeIntervalSince1970: 50))
        let stats = try database.playStats()
        #expect(stats[a]?.playCount == 2 && stats[b]?.playCount == 1)

        func paths(_ list: SmartList) -> [String] { list.songs(in: songs, stats: stats).map(\.path) }
        #expect(paths(.recentlyPlayed) == ["/m/b.mp3", "/m/a.mp3"])
        #expect(paths(.mostPlayed) == ["/m/a.mp3", "/m/b.mp3"])
        #expect(paths(.recentlyAdded) == ["/m/c.mp3", "/m/b.mp3", "/m/a.mp3"])
        #expect(paths(.neverPlayed) == ["/m/c.mp3"])

        // Stats go with the song.
        try database.deleteItems(paths: ["/m/a.mp3"])
        #expect(try database.playStats()[a] == nil)
    }
}
