import AVFoundation
import Foundation
import Libavformat
import Testing
@testable import MacShowCore

struct CastTests {
    private let fixture = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("My.Show.S02E05.720p.mkv")

    @Test func copiesWhatTheTVPlays() {
        #expect(CastPlan.video(codec: "hevc", profile: 2) == .copy)           // Main 10 (HDR10, Dolby Vision)
        #expect(CastPlan.video(codec: "h264", profile: 100) == .copy)         // High
        #expect(CastPlan.video(codec: "h264", profile: 66 | 1 << 9) == .copy) // Constrained Baseline
        for codec in ["aac", "ac3", "eac3", "alac"] {
            #expect(CastPlan.audio(codec: codec) == .copy, "\(codec)")
        }
        #expect(CastPlan.keepsDolbyVision(profile: 5))
        #expect(CastPlan.keepsDolbyVision(profile: 8))
        #expect(CastPlan(video: .copy, audio: .copy).summary == "Direct")
        #expect(CastPlan(video: .copy, audio: nil).summary == "Direct")
    }

    @Test func convertsOnlyWhatItCannot() {
        for codec in ["av1", "vp9", "mpeg4", "mpeg2video", "vc1"] {
            #expect(CastPlan.video(codec: codec, profile: 0) == .convert, "\(codec)")
        }
        #expect(CastPlan.video(codec: "h264", profile: 110) == .convert)  // High 10 (Hi10P)
        #expect(CastPlan.video(codec: "hevc", profile: 4) == .convert)    // 4:2:2 / 4:4:4
        for codec in ["dts", "truehd", "flac", "opus", "vorbis", "mp3", "pcm_s16le"] {
            #expect(CastPlan.audio(codec: codec) == .convert, "\(codec)")
        }
        #expect(!CastPlan.keepsDolbyVision(profile: 7))
        #expect(CastPlan(video: .convert, audio: .copy).summary == "Converting video")
        #expect(CastPlan(video: .copy, audio: .convert).summary == "Converting audio")
        #expect(CastPlan(video: .convert, audio: .convert).summary == "Converting video and audio")
    }

    @Test func textSubtitlesOnly() {
        for codec in ["subrip", "ass", "webvtt", "mov_text"] {
            #expect(CastPlan.isTextSubtitle(codec: codec), "\(codec)")
        }
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"] {
            #expect(!CastPlan.isTextSubtitle(codec: codec), "\(codec)")
        }
    }

    @Test func subtitleText() {
        #expect(WebVTT.text(of: Data("<i>Hello</i>\r\n<font color=\"red\">there</font>".utf8), codec: "subrip") == "<i>Hello</i>\nthere")
        #expect(WebVTT.text(of: Data("12,0,Default,,0,0,0,,{\\an8}Up top\\Nsecond line".utf8), codec: "ass") == "Up top\nsecond line")
        #expect(WebVTT.text(of: Data([0, 5]) + Data("Hi & bye".utf8), codec: "mov_text") == "Hi &amp;")
        #expect(WebVTT.text(of: Data([0, 0]), codec: "mov_text") == nil)
        let file = WebVTT.file([.init(start: 61.5, end: 63, text: "Line")], timestampOffset: 10)
        #expect(file == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n00:01:01.500 --> 00:01:03.000\nLine\n")
    }

    @Test func playlistsForAnMKV() throws {
        let stream = try HLSStream(url: fixture)
        #expect(stream.plan == CastPlan(video: .copy, audio: .copy))

        let master = String(decoding: try #require(try stream.response(for: "master.m3u8")).data, as: UTF8.self)
        #expect(master.hasPrefix("#EXTM3U\n"))
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\""))
        #expect(master.contains("CHANNELS=\"1\",URI=\"audio.m3u8\""))
        #expect(master.contains(#/CODECS="avc1\.[0-9A-F]{6},mp4a\.40\.2"/#))
        #expect(master.contains("RESOLUTION=64x64"))
        #expect(master.contains("VIDEO-RANGE=SDR"))
        #expect(master.hasSuffix("AUDIO=\"audio\"\nvideo.m3u8\n"))

        let video = String(decoding: try #require(try stream.response(for: "video.m3u8")).data, as: UTF8.self)
        #expect(video.contains("#EXT-X-PLAYLIST-TYPE:VOD\n"))
        #expect(video.contains("#EXT-X-MAP:URI=\"video/init.mp4\"\n"))
        #expect(video.contains("#EXTINF:1.023000,\nvideo/0.m4s\n#EXT-X-ENDLIST\n"))
        let audio = String(decoding: try #require(try stream.response(for: "audio.m3u8")).data, as: UTF8.self)
        #expect(audio.contains("audio/0.m4s\n"))
        #expect(try stream.response(for: "video/1.m4s") == nil)
        #expect(try stream.response(for: "subtitles/0.m3u8") == nil)
    }

    /// The segments, put back together, hold exactly the file's packets.
    @Test func copiedStreamsAreUnchanged() throws {
        let stream = try HLSStream(url: fixture)
        for (folder, index) in [("video", 0), ("audio", 1)] {
            let initSegment = try #require(try stream.response(for: "\(folder)/init.mp4")).data
            let segment = try #require(try stream.response(for: "\(folder)/0.m4s")).data
            #expect(String(decoding: initSegment[4..<8], as: UTF8.self) == "ftyp")
            #expect(String(decoding: segment[4..<8], as: UTF8.self) == "moof")

            let joined = FileManager.default.temporaryDirectory.appendingPathComponent("cast-\(UUID()).mp4")
            try (initSegment + segment).write(to: joined)
            defer { try? FileManager.default.removeItem(at: joined) }
            let copied = try packets(of: joined, stream: 0)
            let original = try packets(of: fixture, stream: Int32(index))
            #expect(copied.count == original.count)
            #expect(copied.map(\.data) == original.map(\.data), "\(folder)")
        }
    }

    @Test func avPlayerPlaysTheServedStream() async throws {
        let server = CastServer()
        let url = try await server.publish(try HLSStream(url: fixture))
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        for _ in 0..<100 where item.status == .unknown || player.currentTime().seconds < 0.3 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        #expect(player.currentTime().seconds >= 0.3)
        #expect(item.asset.duration.seconds.rounded() == 1)
        player.pause()
        server.unpublish(url)
    }

    private func packets(of url: URL, stream: Int32) throws -> [(pts: Int64, data: Data)] {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, url.path, nil, nil) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { avformat_close_input(&context) }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var result: [(Int64, Data)] = []
        while av_read_frame(context, packet) >= 0 {
            if packet!.pointee.stream_index == stream {
                result.append((packet!.pointee.pts, Data(bytes: packet!.pointee.data, count: Int(packet!.pointee.size))))
            }
            av_packet_unref(packet)
        }
        return result
    }
}
