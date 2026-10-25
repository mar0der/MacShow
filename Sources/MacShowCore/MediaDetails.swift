import Foundation
import GRDB

/// What TMDB knows about a movie or show: shown on its page.
public struct MediaDetails: Codable, Hashable, Sendable {
    public struct Person: Codable, Hashable, Sendable {
        public var name: String
        public var role: String?
        public var photo: URL?
    }

    public var title: String
    public var year: Int?
    public var tagline: String?
    public var overview: String?
    public var runtimeMinutes: Int?
    public var seasons: Int?
    /// Out of 10.
    public var rating: Double?
    public var genres: [String] = []
    /// Directors of a movie, creators of a show.
    public var makers: [String] = []
    public var cast: [Person] = []
    public var backdrop: URL?
    public var poster: URL?
    /// A season's episodes (TMDB's season details).
    public var episodes: [Episode]?

    public struct Episode: Codable, Hashable, Sendable {
        public var number: Int
        public var title: String?
        public var overview: String?
        public var still: URL?
        public var runtimeMinutes: Int?
    }
}

extension ArtworkFetcher {
    /// A movie's details, matched by title (and year when known).
    public func movieDetails(title: String, year: Int?) async -> MediaDetails? {
        await details(path: "movie", query: title, yearKey: "year", year: year)
    }

    /// A show's details, matched by name.
    public func showDetails(name: String) async -> MediaDetails? {
        await details(path: "tv", query: name, yearKey: "first_air_date_year", year: nil)
    }

    /// A season's episode names, summaries and stills, the show matched by name.
    public func seasonDetails(name: String, season: Int) async -> MediaDetails? {
        guard let tmdbKey, let id = await tmdbID(path: "tv", query: name, yearKey: "first_air_date_year", year: nil) else { return nil }
        var detail = URLComponents(string: "https://api.themoviedb.org/3/tv/\(id)/season/\(season)")!
        detail.queryItems = [.init(name: "api_key", value: tmdbKey)]
        guard let url = detail.url, let (body, reply) = try? await session.data(from: url), (reply as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.seasonDetails(from: body)
    }

    private func tmdbID(path: String, query: String, yearKey: String, year: Int?) async -> Int? {
        guard let tmdbKey else { return nil }
        var search = URLComponents(string: "https://api.themoviedb.org/3/search/\(path)")!
        search.queryItems = [.init(name: "api_key", value: tmdbKey), .init(name: "query", value: query)]
            + (year.map { [URLQueryItem(name: yearKey, value: String($0))] } ?? [])
        struct Hit: Decodable { var id: Int }
        struct Hits: Decodable { var results: [Hit] }
        guard let url = search.url, let (data, reply) = try? await session.data(from: url), (reply as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Hits.self, from: data))?.results.first?.id
    }

    private func details(path: String, query: String, yearKey: String, year: Int?) async -> MediaDetails? {
        guard let tmdbKey, let id = await tmdbID(path: path, query: query, yearKey: yearKey, year: year) else { return nil }
        var detail = URLComponents(string: "https://api.themoviedb.org/3/\(path)/\(id)")!
        detail.queryItems = [.init(name: "api_key", value: tmdbKey), .init(name: "append_to_response", value: "credits")]
        guard let detailURL = detail.url, let (body, detailReply) = try? await session.data(from: detailURL),
              (detailReply as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.mediaDetails(from: body)
    }

    static func mediaDetails(from data: Data) -> MediaDetails? {
        struct Named: Decodable { var name: String }
        struct CastMember: Decodable { var name: String; var character: String?; var profile_path: String? }
        struct CrewMember: Decodable { var name: String; var job: String? }
        struct Credits: Decodable { var cast: [CastMember]?; var crew: [CrewMember]? }
        struct Response: Decodable {
            var title: String?
            var name: String?
            var release_date: String?
            var first_air_date: String?
            var tagline: String?
            var overview: String?
            var runtime: Int?
            var episode_run_time: [Int]?
            var number_of_seasons: Int?
            var vote_average: Double?
            var genres: [Named]?
            var created_by: [Named]?
            var credits: Credits?
            var backdrop_path: String?
            var poster_path: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let title = response.title ?? response.name else { return nil }
        let image = "https://image.tmdb.org/t/p/"
        func text(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let directors = (response.credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
        return MediaDetails(
            title: title,
            year: (response.release_date ?? response.first_air_date).flatMap { Int($0.prefix(4)) },
            tagline: text(response.tagline),
            overview: text(response.overview),
            runtimeMinutes: response.runtime ?? response.episode_run_time?.first,
            seasons: response.number_of_seasons,
            rating: response.vote_average.flatMap { $0 > 0 ? $0 : nil },
            genres: (response.genres ?? []).map(\.name),
            makers: response.created_by.map { $0.map(\.name) } ?? directors,
            cast: (response.credits?.cast ?? []).prefix(12).map { member in
                MediaDetails.Person(name: member.name, role: text(member.character),
                                    photo: member.profile_path.flatMap { URL(string: image + "w185" + $0) })
            },
            backdrop: response.backdrop_path.flatMap { URL(string: image + "w1280" + $0) },
            poster: response.poster_path.flatMap { URL(string: image + "w500" + $0) }
        )
    }

    static func seasonDetails(from data: Data) -> MediaDetails? {
        struct Episode: Decodable { var episode_number: Int; var name: String?; var overview: String?; var still_path: String?; var runtime: Int? }
        struct Response: Decodable { var name: String?; var overview: String?; var episodes: [Episode]? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let episodes = response.episodes else { return nil }
        func text(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        return MediaDetails(
            title: response.name ?? "", overview: text(response.overview),
            episodes: episodes.map { episode in
                MediaDetails.Episode(number: episode.episode_number, title: text(episode.name), overview: text(episode.overview),
                                     still: episode.still_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) },
                                     runtimeMinutes: episode.runtime)
            }
        )
    }
}

extension ArtworkFetcher {
    /// The opening of the artist's Wikipedia article (an article about a band or
    /// musician, not an album or discography). Only the name is sent.
    public func artistBio(_ name: String) async -> MediaDetails? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: name + " music"), .init(name: "gsrlimit", value: "5"),
            .init(name: "prop", value: "extracts|description"), .init(name: "exintro", value: "1"),
            .init(name: "explaintext", value: "1"), .init(name: "exsentences", value: "5"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("MacShow/1.0 (https://github.com/mar0der/MacShow)", forHTTPHeaderField: "User-Agent")
        guard let (data, reply) = try? await session.data(for: request), (reply as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.artistBio(from: data, name: name)
    }

    static func artistBio(from data: Data, name: String) -> MediaDetails? {
        struct Page: Decodable { var index: Int; var title: String; var description: String?; var extract: String? }
        struct Query: Decodable { var pages: [String: Page] }
        struct Response: Decodable { var query: Query? }
        guard let pages = (try? JSONDecoder().decode(Response.self, from: data))?.query?.pages.values else { return nil }
        let musical = ["band", "singer", "rapper", "musician", "group", "duo", "songwriter", "composer", "dj", "producer", "vocalist", "guitarist"]
        let wanted = normalize(name)
        let page = pages.sorted { $0.index < $1.index }.first { page in
            let description = (page.description ?? "").lowercased()
            let notAWork = !description.contains("album") && !description.contains("song by") && !description.contains("discography")
            // "Lamb of God (band)" → "lambofgod"
            return normalize(page.title) == wanted && notAWork && musical.contains { description.contains($0) }
        }
        guard let page, let extract = page.extract, !extract.isEmpty else { return nil }
        return MediaDetails(title: page.title, overview: extract, genres: page.description.map { [$0] } ?? [])
    }

    /// A book's description, first year and cover from Open Library (no account).
    public func bookDetails(title: String, author: String?) async -> MediaDetails? {
        var search = URLComponents(string: "https://openlibrary.org/search.json")!
        search.queryItems = [.init(name: "title", value: title), .init(name: "limit", value: "1"),
                             .init(name: "fields", value: "key,title,author_name,cover_i,first_publish_year")]
            + (author.map { [URLQueryItem(name: "author", value: $0)] } ?? [])
        struct Doc: Decodable { var key: String; var title: String; var author_name: [String]?; var cover_i: Int?; var first_publish_year: Int? }
        struct Docs: Decodable { var docs: [Doc] }
        guard let url = search.url, let (data, reply) = try? await session.data(from: url), (reply as? HTTPURLResponse)?.statusCode == 200,
              let doc = try? JSONDecoder().decode(Docs.self, from: data).docs.first
        else { return nil }
        var details = MediaDetails(title: doc.title, year: doc.first_publish_year, makers: doc.author_name ?? [],
                                   poster: doc.cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") })
        if let workURL = URL(string: "https://openlibrary.org\(doc.key).json"),
           let (work, workReply) = try? await session.data(from: workURL), (workReply as? HTTPURLResponse)?.statusCode == 200 {
            details.overview = Self.bookDescription(from: work)
        }
        return details
    }

    /// Open Library's description is either text or {"value": text}.
    static func bookDescription(from data: Data) -> String? {
        guard let work = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (work["description"] as? String) ?? ((work["description"] as? [String: Any])?["value"] as? String)
        // Drop the "----------\nSee also…" tails Open Library descriptions often carry.
        return text.map { $0.components(separatedBy: "\n----------").first ?? $0 }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LibraryDatabase {
    func cachedDetails(_ key: String) throws -> MediaDetails? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM mediaDetails WHERE key = ?", arguments: [key])
        }.flatMap { try? JSONDecoder().decode(MediaDetails.self, from: $0) }
    }

    func cacheDetails(_ details: MediaDetails, key: String) throws {
        let json = try JSONEncoder().encode(details)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO mediaDetails (key, json, fetchedAt) VALUES (?, ?, ?)", arguments: [key, json, Date()])
        }
    }

    static func registerDetailsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12-media-details") { db in
            try db.create(table: "mediaDetails") { t in
                t.primaryKey("key", .text)
                t.column("json", .blob).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }
    }
}
