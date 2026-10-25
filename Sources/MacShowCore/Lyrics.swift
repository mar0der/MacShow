import Foundation
import GRDB

/// A song's lyrics, timed line by line when they come with timestamps (LRC).
public struct Lyrics: Codable, Hashable, Sendable {
    public struct Line: Codable, Hashable, Sendable {
        /// Seconds into the song, for synced lyrics.
        public var time: Double?
        public var text: String
    }

    public var lines: [Line]
    /// Where they came from: "file" (an .lrc beside the song), "tags" or "LRCLIB".
    public var source: String
    public var isInstrumental = false

    public var isSynced: Bool { lines.contains { $0.time != nil } }

    /// The line being sung at `time` (synced lyrics only).
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        return lines.lastIndex { ($0.time ?? .infinity) <= time + 0.2 }
    }

    /// Lines from LRC ("[01:02.50] words", several times per line allowed;
    /// "[ar: …]" headers skipped) or plain text.
    public static func parse(_ text: String) -> [Line] {
        let stamp = try! Regex(#"\[(\d+):(\d+(?:\.\d+)?)\]"#, as: (Substring, Substring, Substring).self)
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let times = raw.matches(of: stamp).compactMap { match in Double(match.1).flatMap { minutes in Double(match.2).map { minutes * 60 + $0 } } }
            let words = raw.replacing(stamp, with: "").trimmingCharacters(in: .whitespaces)
            if times.isEmpty {
                // Metadata like "[ar: Eminem]" isn't lyrics.
                if words.hasPrefix("["), words.hasSuffix("]") { continue }
                if !words.isEmpty || !lines.isEmpty { lines.append(Line(time: nil, text: words)) }
            } else {
                lines += times.map { Line(time: $0, text: words) }
            }
        }
        if lines.contains(where: { $0.time != nil }) {
            lines = lines.filter { $0.time != nil }.sorted { $0.time! < $1.time! }
        }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines
    }
}

public enum LyricsFinder {
    /// An .lrc file named like the song, or lyrics in its tags.
    public static func local(for item: MediaItem) -> Lyrics? {
        let sidecar = item.url.deletingPathExtension().appendingPathExtension("lrc")
        if let text = try? String(contentsOf: sidecar, encoding: .utf8), !parse(text).isEmpty {
            return Lyrics(lines: parse(text), source: "file")
        }
        let tags = MetadataReader.read(item.url)?.tags ?? [:]
        if let text = tags.first(where: { $0.key.lowercased().contains("lyrics") })?.value, !parse(text).isEmpty {
            return Lyrics(lines: parse(text), source: "tags")
        }
        return nil
    }

    private static func parse(_ text: String) -> [Lyrics.Line] { Lyrics.parse(text) }

    /// LRCLIB (lrclib.net, no account): synced lyrics when it has them. Only
    /// the artist, title, album and length are sent. Nil when unreachable.
    public static func online(for item: MediaItem, session: URLSession = URLSession(configuration: .ephemeral)) async -> Lyrics?? {
        guard let artist = item.artist else { return .some(nil) }
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            .init(name: "artist_name", value: artist), .init(name: "track_name", value: item.title),
            .init(name: "duration", value: String(Int(item.duration.rounded()))),
        ] + (item.album.map { [URLQueryItem(name: "album_name", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("MacShow/1.0 (https://github.com/mar0der/MacShow)", forHTTPHeaderField: "User-Agent")
        guard let (data, reply) = try? await session.data(for: request), let status = (reply as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 404 { return .some(nil) }
        guard status == 200 else { return nil }
        return .some(fromLRCLIB(data))
    }

    static func fromLRCLIB(_ data: Data) -> Lyrics? {
        struct Response: Decodable { var syncedLyrics: String?; var plainLyrics: String?; var instrumental: Bool? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if response.instrumental == true { return Lyrics(lines: [], source: "LRCLIB", isInstrumental: true) }
        let lines = Lyrics.parse(response.syncedLyrics ?? response.plainLyrics ?? "")
        return lines.isEmpty ? nil : Lyrics(lines: lines, source: "LRCLIB")
    }
}

extension LibraryDatabase {
    /// nil: never looked up. .some(nil): looked up, none found.
    func cachedLyrics(_ path: String) throws -> Lyrics?? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT json FROM lyrics WHERE path = ?", arguments: [path]) else { return nil }
            let json: Data? = row["json"]
            return .some(json.flatMap { try? JSONDecoder().decode(Lyrics.self, from: $0) })
        }
    }

    func cacheLyrics(_ lyrics: Lyrics?, path: String) throws {
        let json = try lyrics.map { try JSONEncoder().encode($0) }
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO lyrics (path, json, fetchedAt) VALUES (?, ?, ?)", arguments: [path, json, Date()])
        }
    }

    static func registerLyricsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13-lyrics") { db in
            try db.create(table: "lyrics") { t in
                t.primaryKey("path", .text)
                t.column("json", .blob)
                t.column("fetchedAt", .datetime).notNull()
            }
        }
    }
}
