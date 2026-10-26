import Foundation
import GRDB

/// Videos worth converting to HEVC: old formats where it saves real space, and
/// movies split into parts (CD1, CD2…) from the days of burning them to CDs.
public enum Modernize {
    public struct Candidate: Hashable, Identifiable, Sendable {
        public var id: String { items[0].path }
        public var title: String
        /// The file, or a movie's parts in order.
        public var items: [MediaItem]
        /// What it's in now ("DivX 3").
        public var codec: String
        public var size: Int64
        public var estimatedSize: Int64
        /// The video bitrate to encode at (bits a second).
        public var videoBitrate: Int
        public var joinsParts: Bool { items.count > 1 }
        public var duration: Double { items.reduce(0) { $0 + $1.duration } }
    }

    /// Codecs (FFmpeg's names) worth replacing, their display names, and how much
    /// of their video bitrate HEVC needs for about the same picture.
    static let oldCodecs: [String: (name: String, factor: Double)] = [
        "msmpeg4v1": ("DivX 3", 0.5), "msmpeg4v2": ("DivX 3", 0.5), "msmpeg4v3": ("DivX 3", 0.5),
        "mpeg4": ("MPEG-4 (DivX, XviD)", 0.5), "h263": ("H.263", 0.5), "flv1": ("Flash Video", 0.5),
        "wmv1": ("Windows Media", 0.5), "wmv2": ("Windows Media", 0.5), "wmv3": ("Windows Media", 0.5), "vc1": ("VC-1", 0.45),
        "rv10": ("RealVideo", 0.5), "rv20": ("RealVideo", 0.5), "rv30": ("RealVideo", 0.5), "rv40": ("RealVideo", 0.5),
        "vp6": ("VP6", 0.5), "vp6f": ("VP6", 0.5), "vp6a": ("VP6", 0.5), "theora": ("Theora", 0.5), "svq3": ("Sorenson", 0.5),
        "indeo5": ("Indeo", 0.5), "cinepak": ("Cinepak", 0.5),
        "mpeg1video": ("MPEG-1", 0.4), "mpeg2video": ("MPEG-2", 0.4),
        "dvvideo": ("DV", 0.12), "mjpeg": ("Motion JPEG", 0.12),
    ]
    private static let audioBitrate = 128_000.0
    private static let minimumVideoBitrate = 300_000.0

    /// What in `videos` is worth converting, biggest saving first.
    public static func candidates(in videos: [MediaItem]) -> [Candidate] {
        var groups: [String: [(part: Int, item: MediaItem)]] = [:]
        var singles: [MediaItem] = []
        for item in videos {
            // Two-part TV episodes are separate episodes, never one file.
            if item.kind != .episode, let part = part(of: item) {
                groups[item.url.deletingLastPathComponent().path + "/" + part.base, default: []].append((part.number, item))
            } else {
                singles.append(item)
            }
        }
        var found: [Candidate] = []
        for (key, parts) in groups {
            // Parts 1, 2… once each; anything else is a coincidence of names.
            let sorted = parts.sorted { $0.part < $1.part }
            guard sorted.count > 1, Set(sorted.map(\.part)).count == sorted.count else {
                singles += parts.map(\.item)
                continue
            }
            let first = sorted[0].item
            let title = withoutPart(first.title) ?? withoutPart(first.url.deletingPathExtension().lastPathComponent) ?? first.title
            found.append(candidate(title: title, items: sorted.map(\.item)))
        }
        for item in singles {
            let candidate = candidate(title: item.title, items: [item])
            let saving = candidate.size - candidate.estimatedSize
            if oldCodecs[codecName(of: item)] != nil, saving * 4 >= candidate.size, saving >= 100 * 1_048_576 {
                found.append(candidate)
            }
        }
        return found.sorted { $0.size - $0.estimatedSize > $1.size - $1.estimatedSize }
    }

    private static func candidate(title: String, items: [MediaItem]) -> Candidate {
        let size = items.reduce(0) { $0 + $1.fileSize }
        let duration = max(items.reduce(0) { $0 + $1.duration }, 1)
        let codec = codecName(of: items[0])
        // A modern format being joined keeps about its bitrate.
        let factor = oldCodecs[codec]?.factor ?? 0.9
        let total = Double(size) * 8 / duration
        let video = max(total - audioBitrate, total / 2)
        let newVideo = max(video * factor, minimumVideoBitrate)
        return Candidate(title: title, items: items, codec: oldCodecs[codec]?.name ?? codec.uppercased(), size: size,
                         estimatedSize: Int64((newVideo + audioBitrate) * duration / 8 * 1.01), videoBitrate: Int(newVideo))
    }

    /// "msmpeg4v3", from `formatInfo` ("MSMPEG4V3 · MP3 · 48 kHz").
    static func codecName(of item: MediaItem) -> String {
        (item.formatInfo.components(separatedBy: " · ").first ?? "").lowercased()
    }

    private static let partPattern = try! NSRegularExpression(pattern: #"(?:\bpart|\bcd|\bdisc|\bdisk)[\s._-]*(\d{1,2})\b"#, options: .caseInsensitive)

    /// Which part of a movie an item is ("Gandhi – Part 2", "gandhi-cd2.avi"), and
    /// the name without it, to group the parts by.
    static func part(of item: MediaItem) -> (number: Int, base: String)? {
        for text in [item.title, item.url.deletingPathExtension().lastPathComponent] {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = partPattern.firstMatch(in: text, range: range), let number = Int(text[Range(match.range(at: 1), in: text)!]),
                  let base = withoutPart(text) else { continue }
            return (number, base.lowercased())
        }
        return nil
    }

    /// "Gandhi" from "Gandhi – Part 2", "Race" from "Race, Part 1"; nil without a part.
    static func withoutPart(_ text: String) -> String? {
        guard let match = partPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let rest = (text as NSString).replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._,-–()[]"))
        return rest.isEmpty ? nil : rest
    }
}

extension LibraryDatabase {
    /// Moves what MacShow keeps about `originals` (a converted file, or a movie's
    /// parts) to `converted`, before the originals leave the library: resume point,
    /// favorite, play count, playlist entries, details changed with Get Info, picture.
    func carryOver(from originals: [MediaItem], to converted: MediaItem) throws {
        guard let newID = converted.id, !originals.isEmpty else { return }
        let ids = originals.compactMap(\.id)
        let marks = databaseQuestionMarks(count: ids.count)
        try writer.write { db in
            // Resume point: parts add up (20 minutes into part 2 is part 1 plus 20 minutes).
            var offset = 0.0, latest = Date.distantPast
            var resume: Double?
            for item in originals {
                if let id = item.id, let saved = try PlaybackPosition.fetchOne(db, key: id), saved.updatedAt > latest {
                    latest = saved.updatedAt
                    resume = offset + saved.position
                }
                offset += item.duration
            }
            if let resume {
                try PlaybackPosition(mediaItemId: newID, position: resume, duration: max(offset, converted.duration), updatedAt: latest).upsert(db)
            }
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite WHERE mediaItemId IN (\(marks))", arguments: StatementArguments(ids)) ?? 0 > 0 {
                try db.execute(sql: "INSERT OR IGNORE INTO favorite (mediaItemId, addedAt) VALUES (?, ?)", arguments: [newID, Date()])
            }
            // Watching every part once is watching the movie once.
            if let row = try Row.fetchOne(db, sql: "SELECT MAX(playCount) AS count, MAX(lastPlayedAt) AS last FROM playStat WHERE mediaItemId IN (\(marks))",
                                          arguments: StatementArguments(ids)),
               let count: Int = row["count"], let last: Date = row["last"] {
                try db.execute(sql: "INSERT OR REPLACE INTO playStat (mediaItemId, playCount, lastPlayedAt) VALUES (?, ?, ?)", arguments: [newID, count, last])
            }
            try db.execute(sql: "UPDATE playlistEntry SET mediaItemId = ? WHERE mediaItemId IN (\(marks))", arguments: StatementArguments([newID] + ids))
            if originals.count > 1 {
                // The parts were listed together: once is enough.
                try db.execute(sql: """
                    DELETE FROM playlistEntry AS entry WHERE mediaItemId = ? AND position >
                        (SELECT MIN(position) FROM playlistEntry WHERE playlistId = entry.playlistId AND mediaItemId = ?)
                    """, arguments: [newID, newID])
            }
            if var edit = try ItemEdit.fetchOne(db, key: originals[0].path) {
                edit.path = converted.path
                if originals.count > 1, let title = edit.title { edit.title = Modernize.withoutPart(title) ?? title }
                try edit.save(db)
            }
            if let picture = try String.fetchOne(db, sql: "SELECT artworkKey FROM mediaItem WHERE id = ?", arguments: [ids[0]]) {
                try db.execute(sql: "UPDATE mediaItem SET artworkKey = ? WHERE id = ? AND artworkKey IS NULL", arguments: [picture, newID])
            }
        }
    }
}
