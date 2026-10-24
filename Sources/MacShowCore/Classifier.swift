import Foundation

/// Turns a file plus its metadata into a library item: picks the kind
/// (music, movie, TV episode, audiobook) and fills fields from tags, falling
/// back to the file and folder names.
public enum Classifier {
    /// Bump when the rules below change, so existing libraries are re-read once.
    public static let version = 4

    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "aac", "flac", "alac", "wav", "aif", "aiff", "ogg", "oga",
        "opus", "wma", "ape", "wv", "dsf", "dff", "mka", "aax", "mpc", "tta",
    ]
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "webm", "flv", "mpg", "mpeg", "ts", "m2ts",
        "mts", "3gp", "ogv", "vob", "divx", "rmvb",
    ]

    public static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    public static func makeItem(
        url: URL, metadata: FileMetadata, fileSize: Int64, modified: Double,
        artworkKey: String?, addedAt: Date = Date()
    ) -> MediaItem {
        let tags = metadata.tags
        let fileName = url.deletingPathExtension().lastPathComponent
        let folders = Array(url.deletingLastPathComponent().pathComponents.reversed())
        var item = MediaItem(
            path: url.path, kind: .music, title: "",
            artist: (tags["artist"] ?? tags["author"]).map(stripTrackPrefix),
            album: tags["album"],
            albumArtist: (tags["album_artist"] ?? tags["albumartist"] ?? tags["album artist"]).map(stripTrackPrefix),
            genre: tags["genre"],
            year: year(tags["date"] ?? tags["year"] ?? tags["originaldate"]),
            trackNumber: leadingNumber(tags["track"] ?? tags["tracknumber"]),
            discNumber: leadingNumber(tags["disc"] ?? tags["discnumber"]),
            duration: metadata.duration,
            chapterCount: metadata.chapters.count,
            isProtected: metadata.isProtected,
            formatInfo: metadata.formatInfo,
            artworkKey: artworkKey,
            fileSize: fileSize, modified: modified, addedAt: addedAt
        )

        if metadata.hasVideo {
            let episode = tags["show"].map { show in
                (show: show, season: leadingNumber(tags["season_number"]) ?? 1, episode: leadingNumber(tags["episode_sort"]) ?? 0)
            } ?? parseEpisode(fileName: fileName, folders: folders)
            if let episode, tags["media_type"] != "9" {
                item.kind = .episode
                item.show = episode.show
                item.season = episode.season
                item.episode = episode.episode
                item.title = tags["title"] ?? "Episode \(episode.episode)"
            } else {
                let parsed = movieName(fileName)
                item.kind = .movie
                // A bare number ("14.mp4") says nothing on its own; prefix the folder name.
                let numbered = parsed.title.allSatisfy(\.isNumber) ? folders.first.map { "\(cleanName($0)) \(parsed.title)" } : nil
                item.title = tags["title"].flatMap { looksLikeFileName($0) ? nil : $0 } ?? numbered ?? parsed.title
                item.year = item.year ?? parsed.year
            }
        } else {
            item.kind = isAudiobook(ext: url.pathExtension, tags: tags, folders: folders) ? .audiobook : .music
            item.title = tags["title"] ?? stripTrackNumber(cleanName(fileName))
            item.trackNumber = item.trackNumber ?? leadingNumber(fileName)
        }
        return item
    }

    static func isAudiobook(ext: String, tags: [String: String], folders: [String]) -> Bool {
        if ["m4b", "aax"].contains(ext.lowercased()) || tags["media_type"] == "2" { return true }
        if let genre = tags["genre"]?.lowercased(), genre.contains("audiobook") || genre.contains("audio book") { return true }
        return folders.contains { ["audiobooks", "audiobook", "audio books"].contains($0.lowercased()) }
    }

    private static let episodePatterns = [
        try! NSRegularExpression(pattern: #"^(.*?)[\s._-]*s(\d{1,2})[\s._-]*e(\d{1,3})"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"^(.*?)[\s._-]*\b(\d{1,2})x(\d{2,3})\b"#, options: .caseInsensitive),
    ]
    private static let seasonFolder = try! NSRegularExpression(pattern: #"^(season|series|s)\s*\d+$"#, options: .caseInsensitive)

    /// "My.Show.S02E05.720p" → ("My Show", 2, 5). An empty show part falls back to the
    /// folder name, skipping a "Season 2"-style folder. `folders` is innermost first.
    static func parseEpisode(fileName: String, folders: [String]) -> (show: String, season: Int, episode: Int)? {
        let range = NSRange(fileName.startIndex..., in: fileName)
        for pattern in episodePatterns {
            guard let match = pattern.firstMatch(in: fileName, range: range),
                  let season = Int(fileName[Range(match.range(at: 2), in: fileName)!]),
                  let episode = Int(fileName[Range(match.range(at: 3), in: fileName)!])
            else { continue }
            var show = cleanName(String(fileName[Range(match.range(at: 1), in: fileName)!]))
            if show.isEmpty {
                let folder = folders.first { seasonFolder.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
                show = folder.map(cleanName) ?? "Unknown Show"
            }
            return (show, season, episode)
        }
        return nil
    }

    private static let releaseJunk = try! NSRegularExpression(
        pattern: #"\b(2160p|1080p|720p|480p|4k|uhd|bluray|blu-ray|brrip|bdrip|web-?dl|webrip|hdtv|dvdrip|x264|x265|h\.?264|h\.?265|hevc|hdr|remux|proper|repack)\b.*$"#,
        options: .caseInsensitive
    )
    private static let yearPattern = try! NSRegularExpression(pattern: #"[(\[]?\b((?:19|20)\d{2})\b[)\]]?"#)

    /// "Some.Movie.2020.1080p.BluRay" → ("Some Movie", 2020).
    static func movieName(_ fileName: String) -> (title: String, year: Int?) {
        var name = cleanName(fileName)
        name = releaseJunk.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        var year: Int?
        if let match = yearPattern.matches(in: name, range: NSRange(name.startIndex..., in: name)).last,
           match.range.location > 0 {
            year = Int(name[Range(match.range(at: 1), in: name)!])
            name = String(name[..<Range(match.range, in: name)!.lowerBound])
        }
        let title = name.trimmingCharacters(in: CharacterSet(charactersIn: " -([")).trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? cleanName(fileName) : title, year)
    }

    /// Release groups often write the file name into the title tag
    /// ("Some.Movie.2006.BDRip…"): dots or underscores between words, or release junk.
    static func looksLikeFileName(_ title: String) -> Bool {
        title.range(of: #"\w[._]\w+[._]\w"#, options: .regularExpression) != nil
            || releaseJunk.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// Dots and underscores to spaces, collapsed and trimmed (keeps "Mr. Robot"-style dots before a space).
    static func cleanName(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: #"[._](?! )"#, with: " ", options: .regularExpression)
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }

    /// "01 - Intro" / "01. Intro" / "1 Intro" → "Intro".
    static func stripTrackNumber(_ name: String) -> String {
        let stripped = name.replacingOccurrences(of: #"^\d{1,3}\s*[-.]?\s+"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? name : stripped
    }

    /// "043. Modern Talking" → "Modern Talking" (some CUE splitters write the track
    /// number into the artist tag). Needs the dot, so "50 Cent" stays.
    static func stripTrackPrefix(_ name: String) -> String {
        let stripped = name.replacingOccurrences(of: #"^\d{1,3}\.\s+"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? name : stripped
    }

    /// "3/10" → 3, "07" → 7.
    static func leadingNumber(_ text: String?) -> Int? {
        guard let digits = text?.trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber), !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// "2024-05-01" → 2024.
    static func year(_ text: String?) -> Int? {
        guard let text, text.count >= 4, let year = Int(text.prefix(4)), (1000...2999).contains(year) else { return nil }
        return year
    }
}
