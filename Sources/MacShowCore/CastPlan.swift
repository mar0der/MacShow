import Foundation

/// What happens to each stream of a file sent to an Apple TV: copied bit for
/// bit when the TV can play it, converted only when it can't.
public struct CastPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case copy, convert }

    public var video: Action
    /// nil when the file has no audio.
    public var audio: Action?

    public init(video: Action, audio: Action?) {
        self.video = video
        self.audio = audio
    }

    /// "Direct" when nothing is re-encoded, else what is.
    public var summary: String {
        switch (video, audio) {
        case (.convert, .convert): "Converting video and audio"
        case (.convert, _): "Converting video"
        case (.copy, .convert): "Converting audio"
        default: "Direct"
        }
    }

    /// H.264 and HEVC up to 10-bit 4:2:0 play on an Apple TV; everything else
    /// (AV1, VP9, MPEG-4 Part 2/XviD, MPEG-2, Hi10P H.264, 4:2:2 HEVC…) is
    /// converted to HEVC. Profiles are FFmpeg's numbers for each codec.
    public static func video(codec: String, profile: Int) -> Action {
        switch codec {
        case "h264": profile & 0xFF <= 100 ? .copy : .convert  // up to High; not High 10, 4:2:2 or 4:4:4 (high bits are constraint flags)
        case "hevc": profile <= 2 ? .copy : .convert          // Main and Main 10; not RExt
        default: .convert
        }
    }

    /// AAC, Dolby Digital (Plus, with Atmos) and ALAC play as they are. The
    /// rest (DTS, TrueHD, FLAC, Opus, Vorbis, MP3, PCM…) becomes ALAC, which is
    /// lossless, so nothing beyond the original encoding is lost. (FFmpeg as
    /// linked here has no AC-3/E-AC-3 encoder, and AVPlayer stalls on FLAC in HLS.)
    public static func audio(codec: String) -> Action {
        ["aac", "ac3", "eac3", "alac"].contains(codec) ? .copy : .convert
    }

    /// Text subtitles become WebVTT; picture subtitles (PGS, VobSub, DVB) can't be sent.
    public static func isTextSubtitle(codec: String) -> Bool {
        ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec)
    }

    /// Dolby Vision profiles the Apple TV plays. Others (profile 7 from UHD
    /// discs) still play as their HDR10 base layer, without the Dolby Vision part.
    public static func keepsDolbyVision(profile: Int) -> Bool {
        profile == 5 || profile == 8
    }
}
