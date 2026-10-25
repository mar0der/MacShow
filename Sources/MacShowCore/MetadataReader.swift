import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// What FFmpeg can tell about a file without decoding it.
public struct FileMetadata: Sendable {
    public struct Chapter: Sendable, Equatable {
        public var title: String
        public var start: Double
    }

    /// Container and audio-stream tags, keys lowercased ("title", "album_artist", "track"…).
    public var tags: [String: String] = [:]
    public var duration: Double = 0
    /// A real video stream (embedded cover art doesn't count).
    public var hasVideo = false
    public var artwork: Data?
    public var chapters: [Chapter] = []
    public var isProtected = false
    public var videoCodec: String?
    public var audioCodec: String?
    public var sampleRate: Int?

    /// e.g. "HEVC · AC3 · 48 kHz" or "FLAC · 96 kHz".
    public var formatInfo: String {
        var parts = [videoCodec, audioCodec].compactMap { $0?.uppercased() }
        if let sampleRate, sampleRate > 0 {
            parts.append(String(format: "%g kHz", Double(sampleRate) / 1000))  // "44.1", in every locale
        }
        return parts.joined(separator: " · ")
    }
}

public enum MetadataReader {
    private static let silenceFFmpeg: Void = av_log_set_level(AV_LOG_QUIET)

    /// FourCCs of DRM-protected sample entries: FairPlay audio/video, encrypted
    /// (CENC/cbcs) audio/video, and Audible.
    private static let protectedTags: Set<UInt32> = ["drms", "drmi", "enca", "encv", "aavd"].map(fourCC).reduce(into: []) { $0.insert($1) }

    public static func read(_ url: URL) -> FileMetadata? {
        _ = silenceFFmpeg
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, url.path, nil, nil) == 0, let format = context else { return nil }
        defer { avformat_close_input(&context) }
        if format.pointee.duration <= 0 {
            avformat_find_stream_info(format, nil)
        }

        var meta = FileMetadata()
        collectTags(format.pointee.metadata, into: &meta.tags)
        if format.pointee.duration > 0 {
            meta.duration = Double(format.pointee.duration) / 1_000_000  // AV_TIME_BASE
        }

        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[index], let codec = stream.pointee.codecpar else { continue }
            let name = String(cString: avcodec_get_name(codec.pointee.codec_id))
            if protectedTags.contains(codec.pointee.codec_tag) {
                meta.isProtected = true
            }
            switch codec.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO where stream.pointee.disposition & 0x0400 != 0:  // AV_DISPOSITION_ATTACHED_PIC
                let picture = stream.pointee.attached_pic
                if meta.artwork == nil, let data = picture.data, picture.size > 0 {
                    meta.artwork = Data(bytes: data, count: Int(picture.size))
                }
            case AVMEDIA_TYPE_VIDEO where !meta.hasVideo:
                meta.hasVideo = true
                meta.videoCodec = name
            case AVMEDIA_TYPE_AUDIO where meta.audioCodec == nil:
                meta.audioCodec = name
                meta.sampleRate = Int(codec.pointee.sample_rate)
                collectTags(stream.pointee.metadata, into: &meta.tags)  // Ogg/Opus keep tags on the stream
            default:
                break
            }
        }

        for index in 0..<Int(format.pointee.nb_chapters) {
            guard let chapter = format.pointee.chapters[index]?.pointee else { continue }
            let base = chapter.time_base
            let start = Double(chapter.start) * Double(base.num) / Double(base.den)
            let title = av_dict_get(chapter.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) }
            meta.chapters.append(.init(title: title ?? "Chapter \(index + 1)", start: start))
        }

        if !meta.isProtected, ["m4a", "m4b", "m4p", "m4v", "mp4"].contains(url.pathExtension.lowercased()) {
            meta.isProtected = containsProtectionBox(url)
        }
        return meta
    }

    /// Adds `dictionary`'s entries to `tags` (lowercased keys), keeping values already there.
    private static func collectTags(_ dictionary: OpaquePointer?, into tags: inout [String: String]) {
        var entry: UnsafePointer<AVDictionaryEntry>?
        while let next = av_dict_iterate(dictionary, entry) {
            let key = String(cString: next.pointee.key).lowercased()
            let value = String(cString: next.pointee.value).trimmingCharacters(in: .whitespacesAndNewlines)
            if tags[key] == nil, !value.isEmpty {
                tags[key] = value
            }
            entry = next
        }
    }

    /// Looks for an MP4 protection box ("sinf") in the movie header ("moov"), found by
    /// stepping over the top-level boxes, so only the header is read: a few KB for a
    /// song, which matters on a network share. Catches FairPlay files whose sample
    /// entries FFmpeg reports under their original codec.
    static func containsProtectionBox(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return false }
        func number(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let read = try? handle.read(upToCount: 16), read.count >= 8 else { return false }
            let header = [UInt8](read)
            var size = number(header[0..<4]), headerLength: UInt64 = 8
            if size == 1, header.count == 16 {  // 64-bit size follows the type
                size = number(header[8..<16])
                headerLength = 16
            } else if size == 0 {  // runs to the end of the file
                size = fileSize - offset
            }
            guard size >= headerLength else { return false }
            if header[4..<8].elementsEqual("moov".utf8) {
                guard size <= 64 << 20 else { return false }
                try? handle.seek(toOffset: offset + headerLength)
                guard let body = try? handle.read(upToCount: Int(size - headerLength)) else { return false }
                return hasBox(Data("sinf".utf8), in: body)
            }
            offset += size
        }
        return false
    }

    /// True if `type` appears in `data` preceded by a plausible box size, so random
    /// bytes in compressed media don't count.
    private static func hasBox(_ type: Data, in data: Data) -> Bool {
        var searchStart = data.startIndex
        while let range = data.range(of: type, in: searchStart..<data.endIndex) {
            if range.lowerBound - data.startIndex >= 4 {
                let size = data[(range.lowerBound - 4)..<range.lowerBound].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                if (16...65_536).contains(size) { return true }
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
