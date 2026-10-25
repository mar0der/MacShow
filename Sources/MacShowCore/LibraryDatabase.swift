import Foundation
import GRDB

/// A folder the library indexes and watches. `bookmark` is a security-scoped
/// bookmark for folders outside the ones the sandbox grants by entitlement.
public struct WatchedFolder: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "watchedFolder"

    public var id: Int64?
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The SQLite index of everything MacShow knows about.
public final class LibraryDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the database file at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(writer: DatabasePool(path: url.path))
    }

    /// An in-memory database, for tests.
    public static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "mediaItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("kind", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("albumArtist", .text)
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .double).notNull()
                t.column("show", .text)
                t.column("season", .integer)
                t.column("episode", .integer)
                t.column("chapterCount", .integer).notNull()
                t.column("isProtected", .boolean).notNull()
                t.column("formatInfo", .text).notNull()
                t.column("artworkKey", .text)
                t.column("fileSize", .integer).notNull()
                t.column("modified", .double).notNull()
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "watchedFolder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob)
            }
        }
        registerPlaylistMigration(&migrator)
        registerPositionMigration(&migrator)
        registerBookmarkMigration(&migrator)
        registerArtworkLookupMigration(&migrator)
        registerFolderRuleMigration(&migrator)
        registerItemEditMigration(&migrator)
        return migrator
    }

    // MARK: Items

    public func allItems() throws -> [MediaItem] {
        try writer.read { db in try MediaItem.fetchAll(db) }
    }

    /// Path → (size, modified) for every item under `folder`, used to skip unchanged files.
    func fileStamps(under folder: String) throws -> [String: (size: Int64, modified: Double)] {
        let inside = Self.inside(folder)
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, fileSize, modified FROM mediaItem WHERE \(inside.sql)", arguments: inside.arguments)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"], (size: $0["fileSize"], modified: $0["modified"])) })
        }
    }

    /// Inserts or updates items by path, keeping each existing item's id and `addedAt`.
    func upsert(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        try writer.write { db in
            for var item in items {
                if let existing = try MediaItem.filter(Column("path") == item.path).fetchOne(db) {
                    item.id = existing.id
                    item.addedAt = existing.addedAt
                    // Keep downloaded cover art when the file itself still has none.
                    item.artworkKey = item.artworkKey ?? existing.artworkKey
                    try item.update(db)
                } else {
                    try item.insert(db)
                }
            }
        }
    }

    /// Makes the next scan re-read every file, e.g. after the classifier changes.
    public func invalidateAllItems() throws {
        try writer.write { db in try db.execute(sql: "UPDATE mediaItem SET modified = -1") }
    }

    func deleteItems(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try writer.write { db in
            _ = try MediaItem.filter(paths.contains(Column("path"))).deleteAll(db)
        }
    }

    // MARK: Watched folders

    public func watchedFolders() throws -> [WatchedFolder] {
        try writer.read { db in try WatchedFolder.order(Column("path")).fetchAll(db) }
    }

    public func addWatchedFolder(_ folder: WatchedFolder) throws {
        try writer.write { db in
            var folder = folder
            try folder.insert(db, onConflict: .ignore)
        }
    }

    public func updateBookmark(_ bookmark: Data, forFolder path: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE watchedFolder SET bookmark = ? WHERE path = ?", arguments: [bookmark, path])
        }
    }

    /// Removes the folder and the items indexed under it, except those inside
    /// `keepingItemsUnder` (other watched folders that overlap it).
    public func removeWatchedFolder(path: String, keepingItemsUnder kept: [String] = []) throws {
        let inside = Self.inside(URL(fileURLWithPath: path).canonicalPath)
        var sql = "DELETE FROM mediaItem WHERE \(inside.sql)"
        var arguments = inside.arguments
        for folder in kept {
            let other = Self.inside(folder)
            sql += " AND NOT (\(other.sql))"
            arguments += other.arguments
        }
        try writer.write { db in
            _ = try WatchedFolder.filter(Column("path") == path).deleteAll(db)
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    /// A condition matching item paths inside `folder`. Compares the prefix exactly:
    /// LIKE ignores ASCII case, which mixes up "Rock/" and "rock/" on case-sensitive drives.
    static func inside(_ folder: String) -> (sql: String, arguments: StatementArguments) {
        let directory = folder.hasSuffix("/") ? folder : folder + "/"
        return ("substr(path, 1, ?) = ?", [directory.unicodeScalars.count, directory])
    }
}
