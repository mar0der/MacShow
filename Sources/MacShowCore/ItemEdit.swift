import Foundation
import GRDB

/// Details you changed in MacShow (Get Info). Kept in the database and laid
/// over the file's own tags, never written to the file, so rescans and other
/// apps can't undo them. A nil field keeps the file's value.
public struct ItemEdit: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "itemEdit"

    public var path: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var show: String?
    public var season: Int?
    public var episode: Int?
    public var artworkKey: String?
    /// The category you moved it to (Movies, Home Videos, Music Videos…).
    public var kind: MediaItem.Kind?

    public init(path: String) {
        self.path = path
    }

    public var isEmpty: Bool { self == ItemEdit(path: path) }

    public func apply(to item: MediaItem) -> MediaItem {
        var item = item
        item.title = title ?? item.title
        item.artist = artist ?? item.artist
        item.album = album ?? item.album
        item.albumArtist = albumArtist ?? item.albumArtist
        item.genre = genre ?? item.genre
        item.year = year ?? item.year
        item.show = show ?? item.show
        item.season = season ?? item.season
        item.episode = episode ?? item.episode
        item.artworkKey = artworkKey ?? item.artworkKey
        item.kind = kind ?? item.kind
        return item
    }
}

extension LibraryDatabase {
    public func itemEdits() throws -> [String: ItemEdit] {
        try writer.read { db in try Self.itemEdits(db) }
    }

    static func itemEdits(_ db: Database) throws -> [String: ItemEdit] {
        Dictionary(try ItemEdit.fetchAll(db).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Saves each edit, or removes it when it no longer changes anything.
    public func save(_ edits: [ItemEdit]) throws {
        try writer.write { db in
            for edit in edits {
                if edit.isEmpty {
                    _ = try ItemEdit.deleteOne(db, key: edit.path)
                } else {
                    try edit.save(db)
                }
            }
        }
    }

    static func registerItemEditMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-item-edits") { db in
            try db.create(table: "itemEdit") { t in
                t.primaryKey("path", .text)
                t.column("title", .text)
                t.column("artist", .text)
                t.column("album", .text)
                t.column("albumArtist", .text)
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("show", .text)
                t.column("season", .integer)
                t.column("episode", .integer)
                t.column("artworkKey", .text)
            }
        }
        migrator.registerMigration("v10-item-edit-kind") { db in
            try db.alter(table: "itemEdit") { t in t.add(column: "kind", .text) }
        }
    }
}
