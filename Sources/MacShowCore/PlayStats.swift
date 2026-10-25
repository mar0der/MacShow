import Foundation
import GRDB

/// How often and when a song was last played.
public struct PlayStat: Codable, Hashable, Sendable, FetchableRecord {
    public var mediaItemId: Int64
    public var playCount: Int
    public var lastPlayedAt: Date
}

/// Playlists that fill themselves from what you play.
public enum SmartList: String, CaseIterable, Sendable {
    case recentlyPlayed, mostPlayed, recentlyAdded, neverPlayed

    public var title: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .mostPlayed: "Most Played"
        case .recentlyAdded: "Recently Added"
        case .neverPlayed: "Never Played"
        }
    }

    public var icon: String {
        switch self {
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .mostPlayed: "flame"
        case .recentlyAdded: "sparkles"
        case .neverPlayed: "circle.dashed"
        }
    }

    /// The songs (and music videos) in this list, best first.
    public func songs(in songs: [MediaItem], stats: [Int64: PlayStat], limit: Int = 100) -> [MediaItem] {
        func stat(_ item: MediaItem) -> PlayStat? { item.id.flatMap { stats[$0] } }
        switch self {
        case .recentlyPlayed:
            return Array(songs.filter { stat($0) != nil }.sorted { stat($0)!.lastPlayedAt > stat($1)!.lastPlayedAt }.prefix(limit))
        case .mostPlayed:
            return Array(songs.filter { stat($0) != nil }.sorted {
                (stat($0)!.playCount, stat($0)!.lastPlayedAt) > (stat($1)!.playCount, stat($1)!.lastPlayedAt)
            }.prefix(limit))
        case .recentlyAdded:
            return Array(songs.sorted { $0.addedAt > $1.addedAt }.prefix(limit))
        case .neverPlayed:
            return songs.filter { stat($0) == nil }
        }
    }
}

extension LibraryDatabase {
    public func playStats() throws -> [Int64: PlayStat] {
        try writer.read { db in
            Dictionary(try PlayStat.fetchAll(db, sql: "SELECT * FROM playStat").map { ($0.mediaItemId, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// One more play of the item, now.
    func recordPlay(of id: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO playStat (mediaItemId, playCount, lastPlayedAt) VALUES (?, 1, ?)
                ON CONFLICT(mediaItemId) DO UPDATE SET playCount = playCount + 1, lastPlayedAt = excluded.lastPlayedAt
                """, arguments: [id, date])
        }
    }

    static func registerPlayStatMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-play-stats") { db in
            try db.create(table: "playStat") { t in
                t.column("mediaItemId", .integer).primaryKey().references("mediaItem", onDelete: .cascade)
                t.column("playCount", .integer).notNull()
                t.column("lastPlayedAt", .datetime).notNull()
            }
        }
    }
}
