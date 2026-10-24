import Foundation
import GRDB

/// Where playback stopped in a movie, episode or audiobook file.
public struct PlaybackPosition: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "playbackPosition"

    public var mediaItemId: Int64
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    /// Within the last 30 seconds (or 98%) counts as watched to the end.
    public var isFinished: Bool { duration > 0 && (position >= duration - 30 || position / duration >= 0.98) }

    /// Worth resuming: past the first few seconds and not finished.
    public var isResumable: Bool { position >= 10 && !isFinished }
    public var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }
    public var remaining: Double { max(duration - position, 0) }
}

extension LibraryDatabase {
    public func savePosition(_ position: Double, duration: Double, for itemId: Int64) throws {
        try writer.write { db in
            try PlaybackPosition(mediaItemId: itemId, position: position, duration: duration, updatedAt: Date()).upsert(db)
        }
    }

    public func clearPosition(for itemId: Int64) throws {
        _ = try writer.write { db in try PlaybackPosition.deleteOne(db, key: itemId) }
    }

    static func positions(_ db: Database) throws -> [Int64: PlaybackPosition] {
        Dictionary(uniqueKeysWithValues: try PlaybackPosition.fetchAll(db).map { ($0.mediaItemId, $0) })
    }

    static func registerPositionMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-positions") { db in
            try db.create(table: "playbackPosition") { t in
                t.primaryKey("mediaItemId", .integer).references("mediaItem", onDelete: .cascade)
                t.column("position", .double).notNull()
                t.column("duration", .double).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        }
    }
}
