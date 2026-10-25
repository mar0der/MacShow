import Foundation

/// Subtitle files that probably belong to a video: next to it or in a
/// subtitles folder beside it ("Subs", "Subtitles"), best match first.
public enum SubtitleFinder {
    public static let extensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "txt"]
    static let folders = ["Subs", "subs", "Subtitles", "subtitles", "Sub", "sub"]

    public static func candidates(for video: URL) -> [URL] {
        let folder = video.deletingLastPathComponent()
        let name = video.deletingPathExtension().lastPathComponent.lowercased()
        let places = [folder] + folders.map { folder.appendingPathComponent($0) } + folders.map { folder.appendingPathComponent($0).appendingPathComponent(video.deletingPathExtension().lastPathComponent) }
        var seen = Set<String>()
        let files = places.flatMap { place in
            (try? FileManager.default.contentsOfDirectory(at: place, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        .filter { file in
            let ext = file.pathExtension.lowercased()
            // A loose .txt only counts when it's named after the video.
            return extensions.contains(ext) && (ext != "txt" || file.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(name))
        }
        .filter { seen.insert($0.standardizedFileURL.path).inserted }
        return files.sorted { score($0, name: name, folder: folder) > score($1, name: name, folder: folder) }
    }

    /// Same name scores highest, then names sharing the video's words, then files beside it.
    static func score(_ file: URL, name: String, folder: URL) -> Int {
        let base = file.deletingPathExtension().lastPathComponent.lowercased()
        var score = 0
        if base == name { score += 100 }
        if base.hasPrefix(name) { score += 50 }  // "movie.en", "movie.forced"
        let words = Set(name.split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 1 }.map(String.init))
        let shared = words.intersection(base.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        score += min(shared.count, 10) * 3
        if file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { score += 5 }
        return score
    }
}
