import Foundation
import GRDB

public struct Playlist: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist"

    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public init(name: String, createdAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One song in a playlist. Entries go away with their song (foreign-key cascade).
struct PlaylistEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlistEntry"

    var playlistId: Int64
    var mediaItemId: Int64
    var position: Int
}

/// A playlist with its songs resolved, in order.
public struct PlaylistContents: Identifiable, Hashable, Sendable {
    public var playlist: Playlist
    public var items: [MediaItem]
    /// Each item's stored position, for removing exactly that entry.
    public var positions: [Int]
    public var id: Int64? { playlist.id }
}

extension LibraryDatabase {
    public func createPlaylist(named name: String) throws -> Playlist {
        try writer.write { db in
            var playlist = Playlist(name: name)
            try playlist.insert(db)
            return playlist
        }
    }

    public func renamePlaylist(_ playlist: Playlist, to name: String) throws {
        try writer.write { db in
            var playlist = playlist
            playlist.name = name
            try playlist.update(db)
        }
    }

    public func deletePlaylist(_ playlist: Playlist) throws {
        _ = try writer.write { db in try playlist.delete(db) }
    }

    /// Appends `items` to the end of the playlist, skipping any whose file has
    /// since left the library.
    public func add(_ items: [MediaItem], to playlist: Playlist) throws {
        guard let playlistId = playlist.id else { return }
        try writer.write { db in
            var position = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM playlistEntry WHERE playlistId = ?", arguments: [playlistId]) ?? -1
            for itemId in items.compactMap(\.id) where try MediaItem.exists(db, key: itemId) {
                position += 1
                try PlaylistEntry(playlistId: playlistId, mediaItemId: itemId, position: position).insert(db)
            }
        }
    }

    /// Removes entries by their stored position (`PlaylistContents.positions`),
    /// which stays right even if the list on screen is a moment old.
    public func removeEntries(positions: [Int], from playlist: Playlist) throws {
        guard let playlistId = playlist.id else { return }
        try writer.write { db in
            for position in positions {
                try db.execute(sql: "DELETE FROM playlistEntry WHERE playlistId = ? AND position = ?", arguments: [playlistId, position])
            }
        }
    }

    /// Every playlist with its songs, by name.
    static func playlistContents(_ db: Database, items: [Int64: MediaItem]) throws -> [PlaylistContents] {
        let playlists = try Playlist.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        let entries = try PlaylistEntry.order(Column("position")).fetchAll(db)
        let byPlaylist = Dictionary(grouping: entries, by: \.playlistId)
        return playlists.map { playlist in
            let entries = (byPlaylist[playlist.id ?? -1] ?? []).compactMap { entry in items[entry.mediaItemId].map { (entry.position, $0) } }
            return PlaylistContents(playlist: playlist, items: entries.map(\.1), positions: entries.map(\.0))
        }
    }

    static func registerPlaylistMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-playlists") { db in
            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "playlistEntry") { t in
                t.column("playlistId", .integer).notNull().references("playlist", onDelete: .cascade)
                t.column("mediaItemId", .integer).notNull().references("mediaItem", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistId", "position"])
            }
        }
        // Without it, every song deletion scans the whole table for the cascade.
        migrator.registerMigration("v4-playlist-entry-index") { db in
            try db.create(index: "playlistEntry_mediaItemId", on: "playlistEntry", columns: ["mediaItemId"])
        }
    }
}
