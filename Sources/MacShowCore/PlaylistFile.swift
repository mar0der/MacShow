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
