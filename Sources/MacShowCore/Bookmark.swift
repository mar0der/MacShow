import Foundation
import GRDB

/// A saved spot in an audiobook file.
public struct Bookmark: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookmark"

    public var id: Int64?
    public var mediaItemId: Int64
    public var position: Double
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension LibraryDatabase {
    @discardableResult
    public func addBookmark(at position: Double, in itemId: Int64) throws -> Bookmark {
        try writer.write { db in
            var bookmark = Bookmark(mediaItemId: itemId, position: position, createdAt: Date())
            try bookmark.insert(db)
            return bookmark
        }
    }

    public func deleteBookmark(_ bookmark: Bookmark) throws {
        _ = try writer.write { db in try bookmark.delete(db) }
    }

    public func bookmarks() throws -> [Bookmark] {
        try writer.read { db in try Bookmark.order(Column("createdAt")).fetchAll(db) }
    }

    static func registerBookmarkMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-bookmarks") { db in
            try db.create(table: "bookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mediaItemId", .integer).notNull().indexed().references("mediaItem", onDelete: .cascade)
                t.column("position", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
    }
}

/// How far into a book you are, across all of its files.
public struct BookProgress: Equatable, Sendable {
    /// The file to continue in.
    public var partIndex: Int
    public var elapsed: Double
    public var total: Double
    public var lastListened: Date?

    public var fraction: Double { total > 0 ? min(elapsed / total, 1) : 0 }
    public var remaining: Double { max(total - elapsed, 0) }
    public var isStarted: Bool { lastListened != nil }
    public var isFinished: Bool { total > 0 && remaining <= PlaybackPosition.finishMargin(total) }

    /// Progress from saved file positions: the book continues in the most
    /// recently listened file (or the next one, if that file was finished).
    public init(book: Book, positions: [Int64: PlaybackPosition]) {
        let saved = book.parts.map { $0.id.flatMap { positions[$0] } }
        total = book.duration
        let latest = saved.indices.filter { saved[$0] != nil }.max { saved[$0]!.updatedAt < saved[$1]!.updatedAt }
        guard let latest, let position = saved[latest] else {
            partIndex = 0
            elapsed = 0
            lastListened = nil
            return
        }
        lastListened = position.updatedAt
        let before = book.parts[..<latest].reduce(0) { $0 + $1.duration }
        if position.isFinished, latest + 1 < book.parts.count {
            partIndex = latest + 1
            elapsed = before + book.parts[latest].duration
        } else {
            partIndex = latest
            elapsed = before + (position.isFinished ? book.parts[latest].duration : position.position)
        }
    }
}
