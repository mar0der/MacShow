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
    /// A TMDB (themoviedb.org) API key, for movie and show artwork. Without one,
    /// movies and shows are looked up on Wikipedia.
    let tmdbKey: String?
    /// Settings key holding the TMDB API key (kept on this Mac, never in the code).
    public static let tmdbKeyDefault = "tmdbAPIKey"

    /// Ephemeral: no cookies or cache go along with the lookups.
    public init(session: URLSession = URLSession(configuration: .ephemeral), tmdbKey: String? = nil) {
        self.session = session
        self.tmdbKey = tmdbKey?.isEmpty == false ? tmdbKey : nil
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

    /// What to look for when you search for artwork yourself (Get Info).
    public enum SearchKind: Sendable {
        case album, movie, tvShow, musicVideo

        var query: (media: String, entity: String) {
            switch self {
            case .album: ("music", "album")
            case .movie: ("movie", "movie")
            case .tvShow: ("tvShow", "tvSeason")
            case .musicVideo: ("musicVideo", "musicVideo")
            }
        }
    }

    /// Covers and posters matching `term`, to pick from. Albums: Deezer and the
    /// iTunes catalogue. Movies and shows: TMDB (posters and wide backdrops)
    /// when there's a key, the iTunes catalogue for TV seasons, and Wikipedia
    /// (the iTunes search no longer returns movies). Only the search words are sent.
    public func suggestions(for term: String, kind: SearchKind) async -> [ArtworkSuggestion] {
        switch kind {
        case .movie: return await tmdb(term, path: "movie") + wikipedia(term + " film")
        case .tvShow: return await tmdb(term, path: "tv") + iTunes(term, kind: kind) + wikipedia(term + " TV series")
        case .album: return await deezer(term) + iTunes(term, kind: kind)
        case .musicVideo: return await iTunes(term, kind: kind)
        }
    }

    private func tmdb(_ term: String, path: String) async -> [ArtworkSuggestion] {
        guard let tmdbKey else { return [] }
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(path)")!
        var words = term
        var year: String?
        // "Iron Man 2008" → the title, and the year to narrow it down.
        if let match = term.range(of: #"\s(19|20)\d\d$"#, options: .regularExpression) {
            year = String(term[match].dropFirst())
            words = String(term[..<match.lowerBound])
        }
        components.queryItems = [.init(name: "api_key", value: tmdbKey), .init(name: "query", value: words)]
            + (year.map { [URLQueryItem(name: path == "movie" ? "year" : "first_air_date_year", value: $0)] } ?? [])
        guard let url = components.url, let (data, reply) = try? await session.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return Self.tmdbSuggestions(from: data)
    }

    static func tmdbSuggestions(from data: Data) -> [ArtworkSuggestion] {
        struct Result: Decodable {
            var title: String?
            var name: String?
            var release_date: String?
            var first_air_date: String?
            var poster_path: String?
            var backdrop_path: String?
        }
        struct Results: Decodable { var results: [Result] }
        guard let results = try? JSONDecoder().decode(Results.self, from: data).results else { return [] }
        let base = "https://image.tmdb.org/t/p/"
        return results.prefix(8).flatMap { result -> [ArtworkSuggestion] in
            let title = result.title ?? result.name ?? ""
            let year = (result.release_date ?? result.first_air_date).map { String($0.prefix(4)) } ?? ""
            var found: [ArtworkSuggestion] = []
            if let poster = result.poster_path, let thumbnail = URL(string: base + "w342" + poster), let image = URL(string: base + "w780" + poster) {
                found.append(ArtworkSuggestion(title: title, detail: [year, "Poster"].filter { !$0.isEmpty }.joined(separator: " · "), thumbnail: thumbnail, image: image))
            }
            if let backdrop = result.backdrop_path, let thumbnail = URL(string: base + "w300" + backdrop), let image = URL(string: base + "w1280" + backdrop) {
                found.append(ArtworkSuggestion(title: title, detail: [year, "Wide"].filter { !$0.isEmpty }.joined(separator: " · "), thumbnail: thumbnail, image: image))
            }
            return found
        }
    }

    /// Deezer's album search: covers up to 1000 px, no account needed.
    private func deezer(_ term: String) async -> [ArtworkSuggestion] {
        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [.init(name: "q", value: term), .init(name: "limit", value: "20")]
        guard let url = components.url, let (data, reply) = try? await session.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return Self.deezerSuggestions(from: data)
    }

    static func deezerSuggestions(from data: Data) -> [ArtworkSuggestion] {
        struct Artist: Decodable { var name: String }
        struct Album: Decodable {
            var title: String
            var artist: Artist?
            var cover_medium: String?
            var cover_xl: String?
        }
        struct Albums: Decodable { var data: [Album] }
        guard let albums = try? JSONDecoder().decode(Albums.self, from: data).data else { return [] }
        return albums.compactMap { album in
            guard let image = album.cover_xl.flatMap(URL.init(string:)) else { return nil }
            return ArtworkSuggestion(title: album.title, detail: album.artist?.name ?? "Deezer",
                                     thumbnail: album.cover_medium.flatMap(URL.init(string:)) ?? image, image: image)
        }
    }

    private func iTunes(_ term: String, kind: SearchKind) async -> [ArtworkSuggestion] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term), .init(name: "media", value: kind.query.media),
            .init(name: "entity", value: kind.query.entity), .init(name: "limit", value: "30"),
        ]
        guard let url = components.url,
              let (data, reply) = try? await session.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return Self.suggestions(from: data)
    }

    /// The main image of matching Wikipedia articles (a film's or show's poster).
    private func wikipedia(_ term: String) async -> [ArtworkSuggestion] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: term), .init(name: "gsrlimit", value: "12"),
            .init(name: "prop", value: "pageimages|description"), .init(name: "piprop", value: "thumbnail|original"),
            .init(name: "pithumbsize", value: "300"), .init(name: "pilicense", value: "any"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        // Wikimedia asks API clients to say who they are.
        request.setValue("MacShow/1.0 (https://github.com/mar0der/MacShow)", forHTTPHeaderField: "User-Agent")
        guard let (data, reply) = try? await session.data(for: request), (reply as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.wikipediaSuggestions(from: data)
    }

    static func wikipediaSuggestions(from data: Data) -> [ArtworkSuggestion] {
        struct Image: Decodable { var source: String }
        struct Page: Decodable {
            var index: Int
            var title: String
            var description: String?
            var thumbnail: Image?
            var original: Image?
        }
        struct Query: Decodable { var pages: [String: Page] }
        struct Response: Decodable { var query: Query? }
        guard let pages = (try? JSONDecoder().decode(Response.self, from: data))?.query?.pages.values else { return [] }
        return pages.sorted { $0.index < $1.index }.compactMap { page in
            guard let original = page.original.flatMap({ URL(string: $0.source) }),
                  let thumbnail = page.thumbnail.flatMap({ URL(string: $0.source) }) ?? Optional(original)
            else { return nil }
            return ArtworkSuggestion(title: page.title, detail: page.description ?? "Wikipedia", thumbnail: thumbnail, image: original)
        }
    }

    /// The full-size image of a suggestion.
    public func image(_ suggestion: ArtworkSuggestion) async -> Data? {
        var request = URLRequest(url: suggestion.image)
        request.setValue("MacShow/1.0 (https://github.com/mar0der/MacShow)", forHTTPHeaderField: "User-Agent")
        guard let (data, reply) = try? await session.data(for: request),
              (reply as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    static func suggestions(from data: Data) -> [ArtworkSuggestion] {
        struct Result: Decodable {
            var trackName: String?
            var collectionName: String?
            var artistName: String?
            var releaseDate: String?
            var artworkUrl100: String?
        }
        struct Results: Decodable { var results: [Result] }
        guard let results = try? JSONDecoder().decode(Results.self, from: data).results else { return [] }
        var seen = Set<String>()
        return results.compactMap { result in
            guard let small = result.artworkUrl100, let thumbnail = URL(string: small),
                  let image = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")),
                  seen.insert(small).inserted
            else { return nil }
            let detail = [result.artistName, result.releaseDate.map { String($0.prefix(4)) }].compactMap { $0 }.joined(separator: " · ")
            return ArtworkSuggestion(title: result.collectionName ?? result.trackName ?? "", detail: detail, thumbnail: thumbnail, image: image)
        }
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

/// One cover or poster found online.
public struct ArtworkSuggestion: Identifiable, Hashable, Sendable {
    public var title: String
    public var detail: String
    public var thumbnail: URL
    public var image: URL
    public var id: URL { image }
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
