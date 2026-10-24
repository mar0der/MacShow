import Foundation
import GRDB

/// Finds cover art for albums that have none, using the public iTunes Search
/// API (no account or key). Only the album and artist names are sent.
public struct ArtworkFetcher: Sendable {
    struct SearchResult: Decodable, Equatable {
        var collectionName: String
        var artistName: String
        var artworkUrl100: String?
    }

    private struct Response: Decodable {
        var results: [SearchResult]
    }

    let session: URLSession

    /// Ephemeral: no cookies or cache go along with the lookups.
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public enum Lookup: Sendable {
        case found(Data)
        case notFound
        /// No answer (offline, rate-limited): worth trying again later.
        case failed
    }

    /// The album's cover image from the store, if it has a good match.
    public func artwork(artist: String, album: String) async -> Lookup {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        let term = artist == "Various Artists" ? album : "\(artist) \(album)"
        components.queryItems = [
            .init(name: "term", value: term), .init(name: "entity", value: "album"),
            .init(name: "media", value: "music"), .init(name: "limit", value: "10"),
        ]
        guard let url = components.url,
              let (data, reply) = try? await session.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200,
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return .failed }
        guard let match = Self.bestMatch(in: response.results, artist: artist, album: album),
              let small = match.artworkUrl100,
              let large = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
        else { return .notFound }
        guard let (image, imageReply) = try? await session.data(from: large),
              (imageReply as? HTTPURLResponse)?.statusCode == 200
        else { return .failed }
        return .found(image)
    }

    /// Same album name (ignoring case, punctuation and "(Deluxe)"-style suffixes)
    /// and, unless it's a compilation, the same artist.
    static func bestMatch(in results: [SearchResult], artist: String, album: String) -> SearchResult? {
        let wantedAlbum = normalize(album), wantedArtist = normalize(artist)
        let candidates = results.filter { $0.artworkUrl100 != nil && normalize($0.collectionName) == wantedAlbum }
        if artist == "Various Artists" { return candidates.first }
        return candidates.first { normalize($0.artistName).contains(wantedArtist) || wantedArtist.contains(normalize($0.artistName)) }
    }

    /// "The Death of Slim Shady (Coup De Grâce) [Deluxe]" → "thedeathofslimshady".
    static func normalize(_ text: String) -> String {
        let withoutExtras = text.replacingOccurrences(of: #"\s*[(\[][^)\]]*[)\]]"#, with: "", options: .regularExpression)
        return withoutExtras.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension LibraryDatabase {
    /// Albums already looked up, found or not, so each is tried once.
    func artworkLookups() throws -> Set<String> {
        try writer.read { db in Set(try String.fetchAll(db, sql: "SELECT albumId FROM artworkLookup")) }
    }

    func recordArtworkLookup(albumId: String) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO artworkLookup (albumId, attemptedAt) VALUES (?, ?)", arguments: [albumId, Date()])
        }
    }

    func setArtworkKey(_ key: String, forPaths paths: [String]) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE mediaItem SET artworkKey = ? WHERE path IN (\(databaseQuestionMarks(count: paths.count)))",
                           arguments: StatementArguments([key] + paths))
        }
    }

    static func registerArtworkLookupMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-artwork-lookups") { db in
            try db.create(table: "artworkLookup") { t in
                t.primaryKey("albumId", .text)
                t.column("attemptedAt", .datetime).notNull()
            }
        }
    }
}
