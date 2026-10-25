import Foundation

/// An internet radio station from Radio Browser (radio-browser.info), the free,
/// community-kept directory of stations around the world.
public struct RadioStation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var logo: URL?
    public var tags: [String]
    public var countryCode: String?
    public var codec: String?
    public var bitrate: Int?
    public var homepage: URL?

    /// "Pop · MP3 128 kbps"
    public var details: String {
        let quality = [codec, bitrate.flatMap { $0 > 0 ? "\($0) kbps" : nil }].compactMap { $0 }.joined(separator: " ")
        return [tags.first?.capitalized, quality.isEmpty ? nil : quality].compactMap { $0 }.joined(separator: " · ")
    }

    /// 🇧🇬
    public var flag: String { countryCode.map(RadioCountry.flag) ?? "" }
}

public struct RadioCountry: Hashable, Sendable, Identifiable {
    public var id: String { code }
    public var code: String
    public var name: String
    public var stations: Int
    public var flag: String { Self.flag(code) }

    static func flag(_ code: String) -> String {
        String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }
}

/// Radio Browser's public API: no account or key, a few servers serving the same data.
public struct RadioDirectory: Sendable {
    /// Genres to browse. The directory's own tag list is mostly noise ("music",
    /// "fm", place names), so these are chosen, as in car radios.
    public static let genres = ["pop", "rock", "dance", "electronic", "house", "techno", "trance", "hip hop", "r&b", "soul", "funk",
                                "jazz", "blues", "classical", "country", "folk", "chalga", "latin", "reggae", "metal", "oldies",
                                "80s", "90s", "chillout", "lounge", "ambient", "news", "talk", "sports", "kids"]

    private static let servers = ["all.api.radio-browser.info", "de1.api.radio-browser.info", "de2.api.radio-browser.info"]
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// The most played stations everywhere.
    public func popular(limit: Int = 120) async -> [RadioStation] {
        Self.stations(from: await get("/json/stations/topclick/\(limit)", ["hidebroken": "true"]) ?? Data())
    }

    public func stations(country code: String, limit: Int = 300) async -> [RadioStation] {
        Self.stations(from: await get("/json/stations/bycountrycodeexact/\(code)", Self.ordered(limit)) ?? Data())
    }

    public func stations(genre: String, limit: Int = 300) async -> [RadioStation] {
        Self.stations(from: await get("/json/stations/bytagexact/\(genre)", Self.ordered(limit)) ?? Data())
    }

    public func search(_ words: String, limit: Int = 200) async -> [RadioStation] {
        Self.stations(from: await get("/json/stations/search", Self.ordered(limit).merging(["name": words]) { $1 }) ?? Data())
    }

    public func station(id: String) async -> RadioStation? {
        Self.stations(from: await get("/json/stations/byuuid/\(id)", [:]) ?? Data()).first
    }

    public func countries() async -> [RadioCountry] {
        Self.countries(from: await get("/json/countries", [:]) ?? Data())
    }

    /// Tells the directory a station was played: how its popular list is made.
    public func countPlay(of station: RadioStation) async {
        _ = await get("/json/url/\(station.id)", [:])
    }

    private static func ordered(_ limit: Int) -> [String: String] {
        ["order": "clickcount", "reverse": "true", "hidebroken": "true", "limit": String(limit)]
    }

    private func get(_ path: String, _ query: [String: String]) async -> Data? {
        for server in Self.servers {
            var components = URLComponents(string: "https://\(server)")!
            components.percentEncodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("MacShow/1.0 (https://github.com/mar0der/MacShow)", forHTTPHeaderField: "User-Agent")
            if let (data, reply) = try? await session.data(for: request), (reply as? HTTPURLResponse)?.statusCode == 200 { return data }
        }
        return nil
    }

    static func stations(from data: Data) -> [RadioStation] {
        struct Row: Decodable {
            var stationuuid: String
            var name: String?
            var url: String?
            var url_resolved: String?
            var favicon: String?
            var tags: String?
            var countrycode: String?
            var codec: String?
            var bitrate: Int?
            var homepage: String?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        var names = Set<String>()
        return rows.compactMap { row in
            let name = (row.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let address = [row.url_resolved, row.url].compactMap { $0 }.first { !$0.isEmpty }
            guard !name.isEmpty, let address, let url = URL(string: address), url.scheme != nil,
                  names.insert(name.lowercased()).inserted else { return nil }
            // Logos over https: plain http isn't allowed in the app (most sites serve both).
            let logo = row.favicon.flatMap { $0.isEmpty ? nil : URL(string: $0.replacingOccurrences(of: "^http:", with: "https:", options: .regularExpression)) }
            return RadioStation(
                id: row.stationuuid, name: name, url: url, logo: logo,
                tags: (row.tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
                countryCode: row.countrycode.flatMap { $0.isEmpty ? nil : $0.uppercased() },
                codec: row.codec.flatMap { $0.isEmpty ? nil : $0 }, bitrate: row.bitrate,
                homepage: row.homepage.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        }
    }

    /// Countries with stations, most first.
    static func countries(from data: Data) -> [RadioCountry] {
        struct Row: Decodable { var name: String; var iso_3166_1: String; var stationcount: Int }
        return ((try? JSONDecoder().decode([Row].self, from: data)) ?? [])
            .filter { !$0.name.isEmpty && $0.iso_3166_1.count == 2 && $0.stationcount > 0 }
            .sorted { $0.stationcount > $1.stationcount }
            .map { RadioCountry(code: $0.iso_3166_1.uppercased(), name: $0.name, stations: $0.stationcount) }
    }
}

/// Your stations: favorites, and the ones played lately.
@MainActor
@Observable
public final class Radio {
    public private(set) var favorites: [RadioStation] = []
    public private(set) var recents: [RadioStation] = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let favoritesKey = "radioFavorites", recentsKey = "radioRecents"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.load(Self.favoritesKey, defaults)
        recents = Self.load(Self.recentsKey, defaults)
    }

    public func isFavorite(_ station: RadioStation) -> Bool { favorites.contains { $0.id == station.id } }

    public func toggleFavorite(_ station: RadioStation) {
        if isFavorite(station) { favorites.removeAll { $0.id == station.id } } else { favorites.append(station) }
        save(favorites, Self.favoritesKey)
    }

    public func played(_ station: RadioStation) {
        recents.removeAll { $0.id == station.id }
        recents.insert(station, at: 0)
        recents = Array(recents.prefix(24))
        save(recents, Self.recentsKey)
    }

    private static func load(_ key: String, _ defaults: UserDefaults) -> [RadioStation] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RadioStation].self, from: $0) } ?? []
    }

    private func save(_ stations: [RadioStation], _ key: String) {
        defaults.set(try? JSONEncoder().encode(stations), forKey: key)
    }
}
