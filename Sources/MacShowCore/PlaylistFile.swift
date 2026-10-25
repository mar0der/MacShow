import Foundation

/// Playlists to and from other players: the Music app's exported library
/// (File › Library › Export Library…, a Library.xml) and M3U files.
public enum PlaylistFile {
    /// Each playlist's name and file paths, in order. Leaves out the whole
    /// library, smart playlists, folders and the Music app's built-in lists.
    public static func musicLibraryPlaylists(_ data: Data) throws -> [(name: String, paths: [String])] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracks = plist["Tracks"] as? [String: [String: Any]],
              let playlists = plist["Playlists"] as? [[String: Any]]
        else { throw CocoaError(.fileReadCorruptFile) }
        let paths = tracks.compactMapValues { ($0["Location"] as? String).flatMap(URL.init(string:)).map(\.path) }
        return playlists.compactMap { playlist in
            guard let name = playlist["Name"] as? String,
                  playlist["Master"] == nil, playlist["Distinguished Kind"] == nil,
                  playlist["Smart Info"] == nil, playlist["Folder"] == nil
            else { return nil }
            let items = playlist["Playlist Items"] as? [[String: Any]] ?? []
            return (name, items.compactMap { ($0["Track ID"] as? Int).flatMap { paths[String($0)] } })
        }
    }

    /// What the Music app knows about each file: plays, last played, and
    /// whether it's loved or rated 4–5 stars.
    public struct TrackHistory: Equatable, Sendable {
        public var path: String
        public var playCount: Int
        public var lastPlayed: Date?
        public var isFavorite: Bool
    }

    public static func musicLibraryHistory(_ data: Data) throws -> [TrackHistory] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracks = plist["Tracks"] as? [String: [String: Any]]
        else { throw CocoaError(.fileReadCorruptFile) }
        return tracks.values.compactMap { track in
            guard let path = (track["Location"] as? String).flatMap(URL.init(string:))?.path else { return nil }
            let loved = track["Loved"] as? Bool == true || track["Favorited"] as? Bool == true
            let rating = (track["Rating"] as? Int ?? 0) >= 80 && track["Rating Computed"] as? Bool != true
            let history = TrackHistory(path: path, playCount: track["Play Count"] as? Int ?? 0,
                                       lastPlayed: track["Play Date UTC"] as? Date, isFavorite: loved || rating)
            return history.playCount > 0 || history.isFavorite ? history : nil
        }
    }

    /// The files an M3U lists, with relative entries resolved against `folder`.
    public static func m3uPaths(_ text: String, relativeTo folder: URL) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { return nil }
            if let url = URL(string: entry), url.isFileURL { return url.path }
            return entry.hasPrefix("/") ? entry : folder.appendingPathComponent(entry).standardizedFileURL.path
        }
    }

    /// An extended M3U (UTF-8) of `items`, with absolute paths.
    public static func m3u(_ items: [MediaItem]) -> String {
        var lines = ["#EXTM3U"]
        for item in items {
            lines.append("#EXTINF:\(Int(item.duration.rounded())),\([item.artist, item.title].compactMap { $0 }.joined(separator: " - "))")
            lines.append(item.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
