import Foundation
import GRDB

/// One playable file in the library.
public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case music, movie, episode, audiobook
        /// Set by the library (short videos, Personal, Sports and Documentaries folders)
        /// or by you, never by the scanner.
        case homeVideo, musicVideo, sport, documentary
    }

    public var id: Int64?
    public var path: String
    public var kind: Kind
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var show: String?
    public var season: Int?
    public var episode: Int?
    public var chapterCount: Int
    public var isProtected: Bool
    public var formatInfo: String
    public var artworkKey: String?
    public var fileSize: Int64
    public var modified: Double
    public var addedAt: Date

    /// Saying it's a file keeps Foundation from asking the disk, which on a network
    /// share is a round trip each time (and the index sorts by `url` parts).
    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }

    /// Songs and music videos: no resume points, and they sit in Songs.
    public var isMusic: Bool { kind == .music || kind == .musicVideo }

    /// Movies, episodes, home videos and music videos.
    public var isVideo: Bool { [.movie, .episode, .homeVideo, .musicVideo, .sport, .documentary].contains(kind) }

    /// The drive or network share the file is on ("Media"), or nil for this Mac's own disk.
    public var source: String? {
        let parts = path.split(separator: "/")
        return parts.count > 2 && parts[0] == "Volumes" ? String(parts[1]) : nil
    }

    /// The name albums are grouped and listed under.
    public var albumArtistOrArtist: String { albumArtist ?? artist ?? "Unknown Artist" }
}

extension MediaItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mediaItem"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
