import Foundation

/// Turns text subtitle packets (SRT, ASS, mov_text…) into a WebVTT file.
public enum WebVTT {
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    /// A WebVTT file. `timestampOffset` is where the video's timestamps put
    /// time zero, so the TV lines the cues up with the picture.
    public static func file(_ cues: [Cue], timestampOffset: Double) -> String {
        var lines = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:\(Int(timestampOffset * 90000)),LOCAL:00:00:00.000", ""]
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            lines += ["\(time(cue.start)) --> \(time(cue.end))", cue.text, ""]
        }
        return lines.joined(separator: "\n")
    }

    /// The cue text of one packet, or nil if it has none (drawings, empty gaps).
    public static func text(of data: Data, codec: String) -> String? {
        var text: String
        switch codec {
        case "mov_text":
            // A 16-bit length, the text, then style boxes.
            guard data.count >= 2 else { return nil }
            let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
            text = String(decoding: data.dropFirst(2).prefix(length), as: UTF8.self)
        case "ass", "ssa":
            // Matroska's ASS packets: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
            let fields = String(decoding: data, as: UTF8.self).split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return nil }
            text = String(fields[8])
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        default:
            text = String(decoding: data, as: UTF8.self)
        }
        // ASS override tags ({\i1}, {\an8}), also found in SRT files.
        text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        // WebVTT knows <i>, <b> and <u>; drop other tags such as <font>.
        text = text.replacingOccurrences(of: #"<(?!/?[ibu]>)[^>]*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "-->", with: "->")
        // A blank line would end the cue.
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func time(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
