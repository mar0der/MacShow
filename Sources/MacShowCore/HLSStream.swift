import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale

/// A media file served as HLS with fragmented-MP4 segments, made on demand
/// from the file as the TV asks for each one. Streams the TV can play are
/// copied packet for packet (HDR10 and Dolby Vision included); the rest is
/// converted, video to HEVC with VideoToolbox and audio to ALAC (see `CastPlan`).
///
/// Video and audio are separate renditions sharing the same segment times, so
/// each is copied or converted on its own. Segments start on the file's
/// keyframes (copied video can only be cut there, and converted video then
/// decodes each frame once), or every six seconds for converted video in a
/// file without an index.
///
/// Paths: master.m3u8, video.m3u8, video/init.mp4, video/N.m4s, audio.m3u8,
/// audio/init.mp4, audio/N.m4s, subtitles/S.m3u8, subtitles/S.vtt.
public final class HLSStream: @unchecked Sendable {
    public enum StreamError: Error {
        case cannotOpen
        case noVideo
        case ffmpeg(String, Int32)
    }

    public struct Subtitle: Sendable {
        public let index: Int32
        let codec: String
        let language: String?
        let name: String
    }

    /// Where the file's time zero lands in the output timestamps: room for
    /// B-frames' decode times before the first picture.
    static let timestampOffset = 10.0
    static let segmentLength = 6.0

    public let plan: CastPlan
    public let duration: Double
    /// FFmpeg's name for the container ("matroska,webm") and the audio codec ("eac3").
    public let container: String
    public let audioCodec: String?
    public let subtitles: [Subtitle]
    /// Picture subtitles (PGS, VobSub) the file has, which aren't sent.
    public let hasPictureSubtitles: Bool

    private let path: String
    private let probe: UnsafeMutablePointer<AVFormatContext>
    private let video: Int32
    private let audio: Int32?
    private let selectedSubtitle: Int32?
    /// The file's start time (µs); everything is timed from it.
    private let origin: Int64
    /// Segment start times in the video stream's time base, then the end.
    private let cuts: [Int64]
    /// Copied video: decode time = presentation times in order, minus this.
    private let decodeDelay: Int64
    /// What the copied video's sample entry says: Dolby Vision kept or dropped, hvc1 tag.
    private let videoParameters: UnsafeMutablePointer<AVCodecParameters>
    private let doviProfile: (profile: Int, level: Int, compatibility: Int)?

    private let lock = NSLock()
    private var idleDemuxers: [UnsafeMutablePointer<AVFormatContext>] = []
    private var initSegments: [String: Data] = [:]
    private let subtitleLock = NSLock()
    private var cues: [Int32: [WebVTT.Cue]]?

    /// Opens `url`. `audioStream` and `subtitleStream` are FFmpeg stream
    /// indexes of the tracks to start with (the file's defaults if nil).
    public init(url: URL, audioStream: Int32? = nil, subtitleStream: Int32? = nil) throws {
        path = url.path
        var opened: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&opened, path, nil, nil) == 0, let context = opened else { throw StreamError.cannotOpen }
        probe = context
        guard avformat_find_stream_info(context, nil) >= 0 else {
            avformat_close_input(&opened)
            throw StreamError.cannotOpen
        }
        let streams = (0..<Int32(context.pointee.nb_streams)).map { context.pointee.streams[Int($0)]! }
        func codecName(_ index: Int32) -> String { String(cString: avcodec_get_name(streams[Int(index)].pointee.codecpar.pointee.codec_id)) }
        func isAttachedPicture(_ stream: UnsafeMutablePointer<AVStream>) -> Bool { stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 }

        guard let videoIndex = streams.firstIndex(where: { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO && !isAttachedPicture($0) }).map(Int32.init) else {
            avformat_close_input(&opened)
            throw StreamError.noVideo
        }
        video = videoIndex
        if let audioStream, streams.indices.contains(Int(audioStream)), streams[Int(audioStream)].pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            audio = audioStream
        } else {
            let best = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, video, nil, 0)
            audio = best >= 0 ? Int32(best) : nil
        }

        var subtitles: [Subtitle] = []
        var names: Set<String> = []
        var hasPictureSubtitles = false
        for (index, stream) in streams.enumerated() where stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
            let codec = codecName(Int32(index))
            guard CastPlan.isTextSubtitle(codec: codec) else {
                hasPictureSubtitles = true
                continue
            }
            let tag = Self.metadata(stream.pointee.metadata, "language")
            let language = tag.flatMap { Locale(identifier: $0).language.languageCode?.identifier(.alpha2) }
            let title = Self.metadata(stream.pointee.metadata, "title")
            var name = [tag.flatMap { Locale.current.localizedString(forLanguageCode: $0) }, title].compactMap { $0 }.joined(separator: " · ")
            if name.isEmpty { name = "Subtitles" }
            // Names must differ within a group.
            var unique = name, number = 2
            while names.contains(unique) { unique = "\(name) \(number)"; number += 1 }
            names.insert(unique)
            subtitles.append(Subtitle(index: Int32(index), codec: codec, language: language, name: unique))
        }
        self.subtitles = subtitles
        self.hasPictureSubtitles = hasPictureSubtitles
        selectedSubtitle = subtitles.contains { $0.index == subtitleStream } ? subtitleStream : nil

        let videoStream = streams[Int(video)]
        let parameters = videoStream.pointee.codecpar!
        plan = CastPlan(
            video: CastPlan.video(codec: codecName(video), profile: Int(parameters.pointee.profile)),
            audio: audio.map { CastPlan.audio(codec: codecName($0)) }
        )
        container = String(cString: context.pointee.iformat.pointee.name)
        audioCodec = audio.map(codecName)
        origin = context.pointee.start_time == Self.noTimestamp ? 0 : context.pointee.start_time
        duration = Double(max(context.pointee.duration, 0)) / Double(AV_TIME_BASE)

        // Copied video keeps its Dolby Vision signalling when the TV plays that profile.
        videoParameters = avcodec_parameters_alloc()
        avcodec_parameters_copy(videoParameters, parameters)
        var dovi: (Int, Int, Int)?
        if let side = av_packet_side_data_get(parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF) {
            let record = UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee
            if CastPlan.keepsDolbyVision(profile: Int(record.dv_profile)) {
                dovi = (Int(record.dv_profile), Int(record.dv_level), Int(record.dv_bl_signal_compatibility_id))
            } else {
                av_packet_side_data_remove(videoParameters.pointee.coded_side_data, &videoParameters.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
            }
        }
        doviProfile = plan.video == .copy ? dovi : nil
        if parameters.pointee.codec_id == AV_CODEC_ID_HEVC {
            videoParameters.pointee.codec_tag = Self.tag(doviProfile?.profile == 5 ? "dvh1" : "hvc1")
        } else {
            videoParameters.pointee.codec_tag = 0
        }

        let timeBase = videoStream.pointee.time_base
        let frameDuration = av_rescale_q(1, av_inv_q(Self.frameRate(of: videoStream)), timeBase)
        decodeDelay = Int64(parameters.pointee.video_delay + 1) * frameDuration
        cuts = Self.segmentCuts(context, video: video, copy: plan.video == .copy, origin: origin)
    }

    deinit {
        var context: UnsafeMutablePointer<AVFormatContext>? = probe
        avformat_close_input(&context)
        for demuxer in idleDemuxers {
            var context: UnsafeMutablePointer<AVFormatContext>? = demuxer
            avformat_close_input(&context)
        }
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = videoParameters
        avcodec_parameters_free(&parameters)
    }

    // MARK: Requests

    /// The body and content type for a path under the stream's URL, or nil if there's no such thing.
    public func response(for path: String) throws -> (data: Data, contentType: String)? {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.count {
        case 1:
            switch parts[0] {
            case "master.m3u8": return (Data(masterPlaylist().utf8), "application/vnd.apple.mpegurl")
            case "video.m3u8": return (Data(mediaPlaylist("video").utf8), "application/vnd.apple.mpegurl")
            case "audio.m3u8" where audio != nil: return (Data(mediaPlaylist("audio").utf8), "application/vnd.apple.mpegurl")
            default: return nil
            }
        case 2:
            let (folder, file) = (parts[0], parts[1])
            if folder == "subtitles" {
                let name = file.split(separator: ".")
                guard name.count == 2, let index = Int32(name[0]), let subtitle = subtitles.first(where: { $0.index == index }) else { return nil }
                if name[1] == "m3u8" { return (Data(subtitlePlaylist(subtitle).utf8), "application/vnd.apple.mpegurl") }
                if name[1] == "vtt" { return (Data(webVTT(for: subtitle).utf8), "text/vtt") }
                return nil
            }
            guard folder == "video" || folder == "audio" && audio != nil else { return nil }
            let contentType = folder == "video" ? "video/mp4" : "audio/mp4"
            if file == "init.mp4" { return (try initSegment(folder), contentType) }
            guard file.hasSuffix(".m4s"), let index = Int(file.dropLast(4)), cuts.indices.dropLast().contains(index) else { return nil }
            let output = try fragment(folder, index, initOnly: false)
            return (Data(output[Self.firstFragmentOffset(output)...]), contentType)
        default:
            return nil
        }
    }

    // MARK: Playlists

    public func masterPlaylist() -> String {
        let videoStream = probe.pointee.streams[Int(video)]!
        let parameters = videoStream.pointee.codecpar.pointee
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var codecs = [plan.video == .copy ? Self.codecString(videoParameters) : convertedVideoCodec()]
        var attributes: [String] = []
        if let audio {
            let stream = probe.pointee.streams[Int(audio)]!
            let audioParameters = stream.pointee.codecpar.pointee
            codecs.append(plan.audio == .copy ? Self.audioCodecString(audioParameters) : "alac")
            let atmos = audioParameters.codec_id == AV_CODEC_ID_EAC3 && audioParameters.profile == AV_PROFILE_EAC3_DDP_ATMOS
            let tag = Self.metadata(stream.pointee.metadata, "language")
            let language = tag.flatMap { Locale(identifier: $0).language.languageCode?.identifier(.alpha2) }.map { ",LANGUAGE=\"\($0)\"" } ?? ""
            let name = tag.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Audio"
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(name)\"\(language),DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"\(atmos ? "16/JOC" : String(audioParameters.ch_layout.nb_channels))\",URI=\"audio.m3u8\"")
            attributes.append("AUDIO=\"audio\"")
        }
        for subtitle in subtitles {
            let language = subtitle.language.map { ",LANGUAGE=\"\($0)\"" } ?? ""
            let isDefault = subtitle.index == selectedSubtitle ? "YES" : "NO"
            lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subtitles\",NAME=\"\(subtitle.name)\"\(language),DEFAULT=\(isDefault),AUTOSELECT=YES,FORCED=NO,URI=\"subtitles/\(subtitle.index).m3u8\"")
        }
        if !subtitles.isEmpty { attributes.append("SUBTITLES=\"subtitles\"") }

        let bandwidth = 2 * Int(plan.video == .copy ? max(probe.pointee.bit_rate, 1_000_000) : Int64(Self.convertedBitRate(videoStream)) + 4_000_000)
        var streamInfo = ["BANDWIDTH=\(bandwidth)", "CODECS=\"\(codecs.joined(separator: ","))\""]
        if let dovi = doviProfile, dovi.profile == 8, let brand = [1: "db1p", 4: "db4h"][dovi.compatibility] {
            streamInfo.append("SUPPLEMENTAL-CODECS=\"dvh1.08.\(String(format: "%02d", dovi.level))/\(brand)\"")
        }
        streamInfo.append("RESOLUTION=\(parameters.width)x\(parameters.height)")
        let rate = Self.frameRate(of: videoStream)
        streamInfo.append("FRAME-RATE=\(String(format: "%.3f", av_q2d(rate)))")
        let range = doviProfile?.profile == 5 || parameters.color_trc == AVCOL_TRC_SMPTE2084 ? "PQ" : parameters.color_trc == AVCOL_TRC_ARIB_STD_B67 ? "HLG" : "SDR"
        streamInfo.append("VIDEO-RANGE=\(range)")
        lines.append("#EXT-X-STREAM-INF:" + (streamInfo + attributes).joined(separator: ","))
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The segments of "video" or "audio" (they share times).
    public func mediaPlaylist(_ folder: String) -> String {
        let timeBase = probe.pointee.streams[Int(video)]!.pointee.time_base
        let start = cuts[0]
        // The first segment starts at time zero, even if the first keyframe comes a little later.
        let lengths = cuts.indices.dropLast().map { index in
            av_q2d(timeBase) * Double(cuts[index + 1] - (index == 0 ? min(start, startPts) : cuts[index]))
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int((lengths.max() ?? 1).rounded()))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"\(folder)/init.mp4\""]
        for (index, length) in lengths.enumerated() {
            lines += [String(format: "#EXTINF:%.6f,", length), "\(folder)/\(index).m4s"]
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One WebVTT file for the whole film, next to its playlist in subtitles/.
    private func subtitlePlaylist(_ subtitle: Subtitle) -> String {
        ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))", "#EXT-X-MEDIA-SEQUENCE:0",
         "#EXT-X-PLAYLIST-TYPE:VOD", String(format: "#EXTINF:%.6f,", duration), "\(subtitle.index).vtt", "#EXT-X-ENDLIST"]
            .joined(separator: "\n") + "\n"
    }

    /// The converted video's codec name, from what VideoToolbox makes of this file.
    private func convertedVideoCodec() -> String {
        guard let encoder = try? Self.openVideoEncoder(for: probe.pointee.streams[Int(video)]!, tenBit: isTenBit) else { return "hvc1" }
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = encoder; avcodec_free_context(&context) }
        let parameters = avcodec_parameters_alloc()!
        defer { var parameters: UnsafeMutablePointer<AVCodecParameters>? = parameters; avcodec_parameters_free(&parameters) }
        avcodec_parameters_from_context(parameters, encoder)
        return Self.codecString(parameters)
    }

    private var isTenBit: Bool {
        let format = AVPixelFormat(rawValue: probe.pointee.streams[Int(video)]!.pointee.codecpar.pointee.format)
        return (av_pix_fmt_desc_get(format)?.pointee.comp.0.depth ?? 8) > 8
    }

    /// The file's start in the video stream's time base.
    private var startPts: Int64 {
        av_rescale_q(origin, AVRational(num: 1, den: AV_TIME_BASE), probe.pointee.streams[Int(video)]!.pointee.time_base)
    }

    // MARK: Segments

    private func initSegment(_ folder: String) throws -> Data {
        if let data = lock.withLock({ initSegments[folder] }) { return data }
        // The moov is written with the first fragment: some codecs (E-AC-3)
        // describe themselves only once a packet has gone through.
        let output = try fragment(folder, 0, initOnly: true)
        let data = Data(output.prefix(Self.firstFragmentOffset(output)))
        lock.withLock { initSegments[folder] = data }
        return data
    }

    /// One muxer run over segment `index`: ftyp, moov, then a moof and mdat.
    /// `initOnly` stops after the first few packets (for the init segment).
    private func fragment(_ folder: String, _ index: Int, initOnly: Bool) throws -> Data {
        try withDemuxer { demuxer in
            let stream = folder == "video" ? video : audio!
            for number in 0..<Int(demuxer.pointee.nb_streams) {
                demuxer.pointee.streams[number]!.pointee.discard = number == stream ? AVDISCARD_DEFAULT : AVDISCARD_ALL
            }
            switch (folder, folder == "video" ? plan.video : plan.audio!) {
            case ("video", .copy): return try copyVideo(demuxer, index, initOnly: initOnly)
            case ("video", .convert): return try convertVideo(demuxer, index, initOnly: initOnly)
            case (_, .copy): return try copyAudio(demuxer, index, initOnly: initOnly)
            case (_, .convert): return try convertAudio(demuxer, index, initOnly: initOnly)
            }
        }
    }

    /// Segment bounds in the video stream's time base. The first has no lower
    /// bound and the last no upper one, so nothing before or after is lost.
    private func bounds(_ index: Int) -> (lower: Int64?, upper: Int64?) {
        (index == 0 ? nil : cuts[index], index + 2 < cuts.count ? cuts[index + 1] : nil)
    }

    /// Seeks to the keyframe at or before `time` (video time base), or to the
    /// start of `stream` if nil: seeking there by video would skip packets
    /// before the first keyframe, such as audio priming.
    private func seek(_ demuxer: UnsafeMutablePointer<AVFormatContext>, to time: Int64?, reading stream: Int32) {
        if let time {
            av_seek_frame(demuxer, video, time, AVSEEK_FLAG_BACKWARD)
        } else {
            let start = demuxer.pointee.streams[Int(stream)]!.pointee.start_time
            avformat_seek_file(demuxer, stream, Int64.min, start == Self.noTimestamp ? 0 : start, Int64.max, 0)
        }
    }

    private func copyVideo(_ demuxer: UnsafeMutablePointer<AVFormatContext>, _ index: Int, initOnly: Bool) throws -> Data {
        let timeBase = demuxer.pointee.streams[Int(video)]!.pointee.time_base
        let (lower, upper) = bounds(index)
        seek(demuxer, to: lower, reading: video)
        // The packets from this segment's keyframe up to the next segment's, in decode order.
        var packets: [UnsafeMutablePointer<AVPacket>?] = []
        defer { for index in packets.indices { av_packet_free(&packets[index]) } }
        try readPackets(demuxer, stream: video) { packet in
            let pts = packet.pointee.pts != Self.noTimestamp ? packet.pointee.pts : packet.pointee.dts
            let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            if packets.isEmpty {
                guard isKey, pts >= lower ?? Int64.min else { return true }
            } else if isKey, let upper, pts >= upper {
                return false
            }
            let copy = av_packet_clone(packet)!
            copy.pointee.pts = pts
            packets.append(copy)
            return !(initOnly && packets.count >= 1)
        }
        // Matroska and AVI give no decode times after a seek. They're the
        // presentation times in order, shifted back by the reorder delay.
        let sorted = packets.map { $0!.pointee.pts }.sorted()
        let writer = try FragmentWriter(parameters: videoParameters, tag: videoParameters.pointee.codec_tag, timeBase: Self.videoTimeBase, fragmentIndex: index)
        for (position, packet) in packets.enumerated() {
            let packet = packet!
            packet.pointee.dts = sorted[position] - decodeDelay
            packet.pointee.pts = outputTime(packet.pointee.pts, timeBase, Self.videoTimeBase)
            packet.pointee.dts = outputTime(packet.pointee.dts, timeBase, Self.videoTimeBase)
            packet.pointee.duration = av_rescale_q(packet.pointee.duration, timeBase, Self.videoTimeBase)
            try writer.write(packet)
        }
        return try writer.finish()
    }

    private func convertVideo(_ demuxer: UnsafeMutablePointer<AVFormatContext>, _ index: Int, initOnly: Bool) throws -> Data {
        let stream = demuxer.pointee.streams[Int(video)]!
        let timeBase = stream.pointee.time_base
        let (lower, upper) = bounds(index)
        let decoder = try Self.openDecoder(probe.pointee.streams[Int(video)]!.pointee.codecpar)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&context) }

        let encoder = try Self.openVideoEncoder(for: probe.pointee.streams[Int(video)]!, tenBit: isTenBit)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = encoder; avcodec_free_context(&context) }
        let encoderParameters = avcodec_parameters_alloc()!
        defer { var parameters: UnsafeMutablePointer<AVCodecParameters>? = encoderParameters; avcodec_parameters_free(&parameters) }
        avcodec_parameters_from_context(encoderParameters, encoder)
        let writer = try FragmentWriter(parameters: encoderParameters, tag: Self.tag("hvc1"), timeBase: Self.videoTimeBase, fragmentIndex: index)

        var frame = av_frame_alloc()
        var converted = av_frame_alloc()
        var packet = av_packet_alloc()
        var scaler: UnsafeMutablePointer<SwsContext>?
        defer {
            av_frame_free(&frame)
            av_frame_free(&converted)
            av_packet_free(&packet)
            sws_freeContext(scaler)
        }
        guard let frame, let converted, let packet else { throw StreamError.ffmpeg("alloc", 0) }
        converted.pointee.format = encoder.pointee.pix_fmt.rawValue
        converted.pointee.width = encoder.pointee.width
        converted.pointee.height = encoder.pointee.height
        try check(av_frame_get_buffer(converted, 0), "av_frame_get_buffer")
        let frameDuration = av_rescale_q(1, av_inv_q(encoder.pointee.framerate), Self.videoTimeBase)

        var written = 0
        func drainEncoder() throws {
            while avcodec_receive_packet(encoder, packet) >= 0 {
                if packet.pointee.duration == 0 { packet.pointee.duration = frameDuration }
                try writer.write(packet)
                av_packet_unref(packet)
                written += 1
            }
        }
        /// Encodes the decoder's waiting frames; false once past the segment.
        func drainDecoder() throws -> Bool {
            while avcodec_receive_frame(decoder, frame) >= 0 {
                defer { av_frame_unref(frame) }
                let time = frame.pointee.best_effort_timestamp
                if time == Self.noTimestamp { continue }
                if let lower, time < lower { continue }
                if let upper, time >= upper { return false }
                if scaler == nil {
                    scaler = sws_getContext(frame.pointee.width, frame.pointee.height, AVPixelFormat(rawValue: frame.pointee.format),
                                            converted.pointee.width, converted.pointee.height, encoder.pointee.pix_fmt,
                                            Int32(SWS_BICUBIC.rawValue), nil, nil, nil)
                }
                try check(av_frame_make_writable(converted), "av_frame_make_writable")
                let sourcePlanes = withUnsafeBytes(of: &frame.pointee.data) { Array($0.bindMemory(to: UnsafePointer<UInt8>?.self)) }
                let sourceStrides = withUnsafeBytes(of: &frame.pointee.linesize) { Array($0.bindMemory(to: Int32.self)) }
                let planes = withUnsafeBytes(of: &converted.pointee.data) { Array($0.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)) }
                let strides = withUnsafeBytes(of: &converted.pointee.linesize) { Array($0.bindMemory(to: Int32.self)) }
                try check(sws_scale(scaler, sourcePlanes, sourceStrides, 0, frame.pointee.height, planes, strides), "sws_scale")
                converted.pointee.pts = outputTime(time, timeBase, Self.videoTimeBase)
                try check(avcodec_send_frame(encoder, converted), "avcodec_send_frame")
                try drainEncoder()
                if initOnly && written > 0 { return false }
            }
            return true
        }

        seek(demuxer, to: lower, reading: video)
        var inSegment = true
        try readPackets(demuxer, stream: video) { packet in
            avcodec_send_packet(decoder, packet)
            inSegment = try drainDecoder()
            return inSegment
        }
        if inSegment {
            avcodec_send_packet(decoder, nil)
            _ = try drainDecoder()
        }
        avcodec_send_frame(encoder, nil)
        try drainEncoder()
        return try writer.finish()
    }

    private func copyAudio(_ demuxer: UnsafeMutablePointer<AVFormatContext>, _ index: Int, initOnly: Bool) throws -> Data {
        let stream = demuxer.pointee.streams[Int(audio!)]!
        let parameters = probe.pointee.streams[Int(audio!)]!.pointee.codecpar!
        let timeBase = stream.pointee.time_base
        let sampleRate = parameters.pointee.sample_rate
        let samples = AVRational(num: 1, den: sampleRate)
        let (lower, upper) = microseconds(bounds(index))
        let frameSize = Int64(parameters.pointee.frame_size)
        let streamStart = stream.pointee.start_time != Self.noTimestamp ? stream.pointee.start_time : 0

        let writer = try FragmentWriter(parameters: parameters, tag: 0, timeBase: samples, fragmentIndex: index)
        seek(demuxer, to: bounds(index).lower, reading: audio!)
        var position: Int64?
        var count = 0
        try readPackets(demuxer, stream: audio!) { packet in
            guard packet.pointee.pts != Self.noTimestamp else { return true }
            let time = av_rescale_q(packet.pointee.pts, timeBase, AVRational(num: 1, den: AV_TIME_BASE))
            if let lower, time < lower { return true }
            if let upper, time >= upper { return false }
            // Container timestamps are often rounded to milliseconds; with a
            // fixed frame size, put every frame on the exact sample grid.
            if position == nil || frameSize == 0 {
                var start = av_rescale_q(packet.pointee.pts - streamStart, timeBase, samples)
                if frameSize > 0 { start = Int64((Double(start) / Double(frameSize)).rounded()) * frameSize }
                position = start + av_rescale_q(streamStart, timeBase, samples)
            }
            let length = frameSize > 0 ? frameSize : av_rescale_q(packet.pointee.duration, timeBase, samples)
            packet.pointee.pts = outputTime(position!, samples, samples)
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = length
            position! += length
            try writer.write(packet)
            count += 1
            return !(initOnly && count >= 20)
        }
        return try writer.finish()
    }

    private func convertAudio(_ demuxer: UnsafeMutablePointer<AVFormatContext>, _ index: Int, initOnly: Bool) throws -> Data {
        let stream = demuxer.pointee.streams[Int(audio!)]!
        let timeBase = stream.pointee.time_base
        let decoder = try Self.openDecoder(probe.pointee.streams[Int(audio!)]!.pointee.codecpar)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&context) }
        let encoder = try Self.openALACEncoder(like: decoder)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = encoder; avcodec_free_context(&context) }
        let encoderParameters = avcodec_parameters_alloc()!
        defer { var parameters: UnsafeMutablePointer<AVCodecParameters>? = encoderParameters; avcodec_parameters_free(&parameters) }
        avcodec_parameters_from_context(encoderParameters, encoder)
        let sampleRate = encoder.pointee.sample_rate
        let samples = AVRational(num: 1, den: sampleRate)
        let writer = try FragmentWriter(parameters: encoderParameters, tag: 0, timeBase: samples, fragmentIndex: index)

        let (lowerTime, upperTime) = microseconds(bounds(index))
        let lower = lowerTime.map { av_rescale_q($0, AVRational(num: 1, den: AV_TIME_BASE), samples) }
        let upper = upperTime.map { av_rescale_q($0, AVRational(num: 1, den: AV_TIME_BASE), samples) }
        let streamStart = stream.pointee.start_time != Self.noTimestamp ? stream.pointee.start_time : 0

        var resampler: OpaquePointer?
        var fifo = av_audio_fifo_alloc(encoder.pointee.sample_fmt, encoder.pointee.ch_layout.nb_channels, 8192)
        var frame = av_frame_alloc()
        var output = av_frame_alloc()
        var packet = av_packet_alloc()
        defer {
            swr_free(&resampler)
            av_audio_fifo_free(fifo)
            av_frame_free(&frame)
            av_frame_free(&output)
            av_packet_free(&packet)
        }
        guard let fifo, let frame, let output, let packet else { throw StreamError.ffmpeg("alloc", 0) }
        /// Where the fifo's first sample is, in samples.
        var fifoStart: Int64?
        var written = 0

        func drainEncoder() throws {
            while avcodec_receive_packet(encoder, packet) >= 0 {
                packet.pointee.dts = packet.pointee.pts
                try writer.write(packet)
                av_packet_unref(packet)
                written += 1
            }
        }
        /// Encodes whole frames from the fifo (any rest too when `flush`), not past `upper`.
        func encode(flush: Bool) throws {
            while let start = fifoStart {
                var count = min(av_audio_fifo_size(fifo), encoder.pointee.frame_size)
                if let upper { count = Int32(min(Int64(count), max(upper - start, 0))) }
                guard count > 0, count == encoder.pointee.frame_size || flush else { return }
                av_frame_unref(output)
                output.pointee.nb_samples = count
                output.pointee.format = encoder.pointee.sample_fmt.rawValue
                output.pointee.sample_rate = sampleRate
                av_channel_layout_copy(&output.pointee.ch_layout, &encoder.pointee.ch_layout)
                try check(av_frame_get_buffer(output, 0), "av_frame_get_buffer")
                _ = withUnsafeMutablePointer(to: &output.pointee.data) {
                    av_audio_fifo_read(fifo, UnsafeMutableRawPointer($0).assumingMemoryBound(to: UnsafeMutableRawPointer?.self), count)
                }
                output.pointee.pts = outputTime(start, samples, samples)
                fifoStart = start + Int64(count)
                try check(avcodec_send_frame(encoder, output), "avcodec_send_frame")
                try drainEncoder()
            }
        }
        /// Adds the decoder's frames to the fifo; false once past the segment.
        func drainDecoder() throws -> Bool {
            while avcodec_receive_frame(decoder, frame) >= 0 {
                defer { av_frame_unref(frame) }
                if fifoStart == nil {
                    guard frame.pointee.pts != Self.noTimestamp else { continue }
                    // Snap to the frame grid: container timestamps are often rounded to milliseconds.
                    var start = av_rescale_q(frame.pointee.pts - streamStart, timeBase, samples)
                    let size = Int64(frame.pointee.nb_samples)
                    let snapped = Int64((Double(start) / Double(size)).rounded()) * size
                    if abs(snapped - start) <= Int64(sampleRate) / 1000 { start = snapped }
                    fifoStart = start + av_rescale_q(streamStart, timeBase, samples)
                }
                if resampler == nil {
                    try check(swr_alloc_set_opts2(&resampler, &encoder.pointee.ch_layout, encoder.pointee.sample_fmt, sampleRate,
                                                  &frame.pointee.ch_layout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate, 0, nil), "swr_alloc")
                    try check(swr_init(resampler), "swr_init")
                }
                av_frame_unref(output)
                output.pointee.format = encoder.pointee.sample_fmt.rawValue
                output.pointee.sample_rate = sampleRate
                av_channel_layout_copy(&output.pointee.ch_layout, &encoder.pointee.ch_layout)
                try check(swr_convert_frame(resampler, output, frame), "swr_convert_frame")
                _ = withUnsafeMutablePointer(to: &output.pointee.data) {
                    av_audio_fifo_write(fifo, UnsafeMutableRawPointer($0).assumingMemoryBound(to: UnsafeMutableRawPointer?.self), output.pointee.nb_samples)
                }
                // Drop what comes before the segment.
                if let lower, let start = fifoStart, start < lower {
                    let drop = Int32(min(Int64(av_audio_fifo_size(fifo)), lower - start))
                    av_audio_fifo_drain(fifo, drop)
                    fifoStart! += Int64(drop)
                }
                try encode(flush: false)
                if let upper, let start = fifoStart, start + Int64(av_audio_fifo_size(fifo)) >= upper { return false }
                if initOnly && written > 0 { return false }
            }
            return true
        }

        // Start a second early: some decoders need a run-up to sound right.
        let runUp = av_rescale_q(1, AVRational(num: 1, den: 1), probe.pointee.streams[Int(video)]!.pointee.time_base)
        seek(demuxer, to: bounds(index).lower.map { $0 - runUp }, reading: audio!)
        var inSegment = true
        try readPackets(demuxer, stream: audio!) { packet in
            avcodec_send_packet(decoder, packet)
            inSegment = try drainDecoder()
            return inSegment
        }
        if inSegment {
            avcodec_send_packet(decoder, nil)
            _ = try drainDecoder()
        }
        try encode(flush: true)
        avcodec_send_frame(encoder, nil)
        try drainEncoder()
        return try writer.finish()
    }

    // MARK: Subtitles

    private func webVTT(for subtitle: Subtitle) -> String {
        WebVTT.file(allCues()[subtitle.index] ?? [], timestampOffset: Self.timestampOffset)
    }

    /// Every text subtitle track's cues, read in one pass over the file the first time they're needed.
    private func allCues() -> [Int32: [WebVTT.Cue]] {
        subtitleLock.withLock {
            if let cues { return cues }
            var result: [Int32: [WebVTT.Cue]] = [:]
            let codecs = Dictionary(uniqueKeysWithValues: subtitles.map { ($0.index, $0.codec) })
            try? withDemuxer { demuxer in
                for number in 0..<Int32(demuxer.pointee.nb_streams) {
                    demuxer.pointee.streams[Int(number)]!.pointee.discard = codecs[number] != nil ? AVDISCARD_DEFAULT : AVDISCARD_ALL
                }
                seek(demuxer, to: nil, reading: subtitles[0].index)
                try readPackets(demuxer, stream: nil) { packet in
                    let index = packet.pointee.stream_index
                    guard let codec = codecs[index], packet.pointee.pts != Self.noTimestamp, let data = packet.pointee.data,
                          let text = WebVTT.text(of: Data(bytes: data, count: Int(packet.pointee.size)), codec: codec)
                    else { return true }
                    let timeBase = demuxer.pointee.streams[Int(index)]!.pointee.time_base
                    let start = av_q2d(timeBase) * Double(packet.pointee.pts) - Double(origin) / Double(AV_TIME_BASE)
                    let length = packet.pointee.duration > 0 ? av_q2d(timeBase) * Double(packet.pointee.duration) : 4
                    result[index, default: []].append(WebVTT.Cue(start: start, end: start + length, text: text))
                    return true
                }
            }
            cues = result
            return result
        }
    }

    // MARK: Plumbing

    static let noTimestamp = Int64(bitPattern: 0x8000000000000000)
    static let videoTimeBase = AVRational(num: 1, den: 90000)

    /// A source timestamp as an output one: timed from the file's start, plus `timestampOffset`.
    private func outputTime(_ time: Int64, _ from: AVRational, _ to: AVRational) -> Int64 {
        av_rescale_q(time, from, to) - av_rescale_q(origin, AVRational(num: 1, den: AV_TIME_BASE), to)
            + av_rescale_q(Int64(Self.timestampOffset * 1000), AVRational(num: 1, den: 1000), to)
    }

    private func microseconds(_ bounds: (lower: Int64?, upper: Int64?)) -> (Int64?, Int64?) {
        let timeBase = probe.pointee.streams[Int(video)]!.pointee.time_base
        let convert = { (time: Int64) in av_rescale_q(time, timeBase, AVRational(num: 1, den: AV_TIME_BASE)) }
        return (bounds.lower.map(convert), bounds.upper.map(convert))
    }

    /// Lends a demuxer for this file (opened once, reused across requests).
    private func withDemuxer<T>(_ body: (UnsafeMutablePointer<AVFormatContext>) throws -> T) throws -> T {
        var demuxer = lock.withLock { idleDemuxers.popLast() }
        if demuxer == nil {
            guard avformat_open_input(&demuxer, path, nil, nil) == 0 else { throw StreamError.cannotOpen }
        }
        defer { lock.withLock { idleDemuxers.append(demuxer!) } }
        return try body(demuxer!)
    }

    /// Calls `body` with each packet (of `stream`, or any not discarded) until it returns false or the file ends.
    private func readPackets(_ demuxer: UnsafeMutablePointer<AVFormatContext>, stream: Int32?, _ body: (UnsafeMutablePointer<AVPacket>) throws -> Bool) throws {
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return }
        while av_read_frame(demuxer, packet) >= 0 {
            defer { av_packet_unref(packet) }
            if let stream, packet.pointee.stream_index != stream { continue }
            if try !body(packet) { return }
        }
    }

    /// Segment starts: keyframes at least six seconds apart, from the file's
    /// index, or found by reading the video for copied video, which can only be
    /// cut there. Converted video without an index: every six seconds. Then the end.
    private static func segmentCuts(_ context: UnsafeMutablePointer<AVFormatContext>, video: Int32, copy: Bool, origin: Int64) -> [Int64] {
        let stream = context.pointee.streams[Int(video)]!
        let timeBase = stream.pointee.time_base
        let start = av_rescale_q(origin, AVRational(num: 1, den: AV_TIME_BASE), timeBase)
        let end = start + av_rescale_q(max(context.pointee.duration, 0), AVRational(num: 1, den: AV_TIME_BASE), timeBase)
        let length = av_rescale_q(Int64(segmentLength * 1000), AVRational(num: 1, den: 1000), timeBase)
        // Matroska reads its index on the first seek.
        av_seek_frame(context, video, start, AVSEEK_FLAG_BACKWARD)
        var keyframes = (0..<avformat_index_get_entries_count(stream)).compactMap { index in
            avformat_index_get_entry(stream, index).flatMap { $0.pointee.flags & AVINDEX_KEYFRAME != 0 ? $0.pointee.timestamp : nil }
        }.sorted()
        if keyframes.count < 2 {
            if copy {
                // No index: find the keyframes by reading the video packets.
                for number in 0..<Int(context.pointee.nb_streams) where number != video {
                    context.pointee.streams[number]!.pointee.discard = AVDISCARD_ALL
                }
                av_seek_frame(context, video, start, AVSEEK_FLAG_BACKWARD)
                var packet = av_packet_alloc()
                defer { av_packet_free(&packet) }
                while let packet, av_read_frame(context, packet) >= 0 {
                    if packet.pointee.stream_index == video, packet.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                        keyframes.append(packet.pointee.pts != noTimestamp ? packet.pointee.pts : packet.pointee.dts)
                    }
                    av_packet_unref(packet)
                }
                keyframes.sort()
            } else {
                keyframes = Array(stride(from: start, to: end, by: Int(max(length, 1))))
            }
        }
        var cuts: [Int64] = []
        for keyframe in keyframes where cuts.last.map({ keyframe - $0 >= length }) ?? true {
            cuts.append(keyframe)
        }
        if cuts.isEmpty { cuts.append(start) }
        cuts.append(max(end, cuts.last! + 1))
        return cuts
    }

    private static func frameRate(of stream: UnsafeMutablePointer<AVStream>) -> AVRational {
        for rate in [stream.pointee.avg_frame_rate, stream.pointee.r_frame_rate] where rate.num > 0 && rate.den > 0 {
            return rate
        }
        return AVRational(num: 24, den: 1)
    }

    /// Generous: about 20 Mbit/s for 1080p24, at most 60.
    private static func convertedBitRate(_ stream: UnsafeMutablePointer<AVStream>) -> Int {
        let parameters = stream.pointee.codecpar.pointee
        let pixelsPerSecond = Double(parameters.width * parameters.height) * av_q2d(frameRate(of: stream))
        return Int(min(max(pixelsPerSecond * 0.4, 4_000_000), 60_000_000))
    }

    private static func openDecoder(_ parameters: UnsafePointer<AVCodecParameters>) throws -> UnsafeMutablePointer<AVCodecContext> {
        // FFmpeg's own AV1 decoder only drives hardware decoders; dav1d decodes anywhere.
        let codec = parameters.pointee.codec_id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : avcodec_find_decoder(parameters.pointee.codec_id)
        guard let codec, let context = avcodec_alloc_context3(codec) else { throw StreamError.ffmpeg("no decoder", 0) }
        try check(avcodec_parameters_to_context(context, parameters), "avcodec_parameters_to_context")
        context.pointee.thread_count = 0  // as many as there are cores
        try check(avcodec_open2(context, codec, nil), "avcodec_open2 (decoder)")
        return context
    }

    /// HEVC from VideoToolbox, keeping the source's size, colours and frame rate.
    /// No B-frames, so segments encoded separately join up in decode order.
    private static func openVideoEncoder(for stream: UnsafeMutablePointer<AVStream>, tenBit: Bool) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_encoder_by_name("hevc_videotoolbox"), let context = avcodec_alloc_context3(codec) else {
            throw StreamError.ffmpeg("no hevc_videotoolbox", 0)
        }
        let parameters = stream.pointee.codecpar.pointee
        context.pointee.width = parameters.width
        context.pointee.height = parameters.height
        context.pointee.sample_aspect_ratio = parameters.sample_aspect_ratio
        context.pointee.pix_fmt = tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        context.pointee.profile = tenBit ? AV_PROFILE_HEVC_MAIN_10 : AV_PROFILE_HEVC_MAIN
        context.pointee.time_base = videoTimeBase
        context.pointee.framerate = frameRate(of: stream)
        context.pointee.bit_rate = Int64(convertedBitRate(stream))
        context.pointee.max_b_frames = 0
        context.pointee.gop_size = 1000  // one keyframe per segment, at its start
        context.pointee.color_primaries = parameters.color_primaries
        context.pointee.color_trc = parameters.color_trc
        context.pointee.colorspace = parameters.color_space
        context.pointee.color_range = parameters.color_range
        context.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        do {
            try check(avcodec_open2(context, codec, nil), "avcodec_open2 (hevc_videotoolbox)")
        } catch {
            var context: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&context)
            throw error
        }
        return context
    }

    /// ALAC (lossless) with the decoder's sample rate and channels: 16-bit
    /// for 16-bit sources, 24-bit for everything else. ALAC's own 6.1 and
    /// 8-channel layouts put the extra channels in other places (7.1 "wide"
    /// has front-centre pairs), so beyond 5.1 the channels fold into 5.1.
    private static func openALACEncoder(like decoder: UnsafeMutablePointer<AVCodecContext>) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_ALAC), let context = avcodec_alloc_context3(codec) else {
            throw StreamError.ffmpeg("no alac encoder", 0)
        }
        let source = decoder.pointee.ch_layout
        let kept = ["mono", "stereo", "3.0", "4.0", "5.0", "5.1"].first { name in
            var layout = AVChannelLayout()
            defer { av_channel_layout_uninit(&layout) }
            av_channel_layout_from_string(&layout, name)
            return withUnsafePointer(to: source) { av_channel_layout_compare(&layout, $0) == 0 }
        }
        // Unknown order (some PCM): the usual layout for that many channels.
        let fallback = source.order == AV_CHANNEL_ORDER_UNSPEC && source.nb_channels <= 2 ? (source.nb_channels == 1 ? "mono" : "stereo") : "5.1"
        av_channel_layout_from_string(&context.pointee.ch_layout, kept ?? fallback)
        let format = decoder.pointee.sample_fmt
        let sixteenBit = format == AV_SAMPLE_FMT_S16 || format == AV_SAMPLE_FMT_S16P
        context.pointee.sample_fmt = sixteenBit ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S32P
        context.pointee.bits_per_raw_sample = sixteenBit ? 16 : 24
        context.pointee.sample_rate = decoder.pointee.sample_rate
        context.pointee.time_base = AVRational(num: 1, den: decoder.pointee.sample_rate)
        do {
            try check(avcodec_open2(context, codec, nil), "avcodec_open2 (alac)")
        } catch {
            var context: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&context)
            throw error
        }
        return context
    }

    private static func metadata(_ dictionary: OpaquePointer?, _ key: String) -> String? {
        av_dict_get(dictionary, key, nil, 0).flatMap { $0.pointee.value.map { String(cString: $0) } }.flatMap { $0.isEmpty || $0 == "und" ? nil : $0 }
    }

    static func tag(_ fourCC: String) -> UInt32 {
        fourCC.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Where the first moof box starts (what comes before it is the init segment).
    static func firstFragmentOffset(_ data: Data) -> Int {
        var offset = 0
        while offset + 8 <= data.count {
            let base = data.startIndex + offset
            var size = data[base..<base + 4].reduce(0) { $0 << 8 | Int($1) }
            if String(decoding: data[base + 4..<base + 8], as: UTF8.self) == "moof" { return offset }
            if size == 1, offset + 16 <= data.count { size = data[base + 8..<base + 16].reduce(0) { $0 << 8 | Int($1) } }
            guard size >= 8 else { break }
            offset += size
        }
        return data.count
    }

    // MARK: Codec names for the playlist

    /// "avc1.640028", "hvc1.2.4.L153.B0", "dvh1.05.06": what HLS calls the video codec.
    static func codecString(_ parameters: UnsafePointer<AVCodecParameters>) -> String {
        let extradata = parameters.pointee.extradata.map { Array(UnsafeBufferPointer(start: $0, count: Int(parameters.pointee.extradata_size))) } ?? []
        let tag = parameters.pointee.codec_tag
        switch parameters.pointee.codec_id {
        case AV_CODEC_ID_H264:
            // avcC, or the SPS (NAL type 7) of Annex B headers.
            let bytes = extradata.first == 1 ? Array(extradata.dropFirst().prefix(3)) : nalPayload(extradata) { $0 & 0x1F == 7 }.prefix(4).dropFirst().map { $0 }
            guard bytes.count == 3 else { return "avc1" }
            return "avc1." + bytes.map { String(format: "%02X", $0) }.joined()
        case AV_CODEC_ID_HEVC:
            if tag == self.tag("dvh1"), let side = av_packet_side_data_get(parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF) {
                let record = UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee
                return String(format: "dvh1.%02d.%02d", record.dv_profile, record.dv_level)
            }
            // profile_tier_level: 12 bytes of hvcC, or of the SPS (NAL type 33) after its first byte.
            let ptl = extradata.first == 1 ? Array(extradata.dropFirst().prefix(12)) : Array(nalPayload(extradata) { $0 >> 1 & 0x3F == 33 }.dropFirst(3).prefix(12))
            guard ptl.count == 12 else { return "hvc1" }
            let space = ["", "A", "B", "C"][Int(ptl[0] >> 6)]
            let compatibility = ptl[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let reversed = (0..<32).reduce(UInt32(0)) { $0 | (compatibility >> $1 & 1) << (31 - $1) }
            var constraints = Array(ptl[5...10])
            while constraints.last == 0 { constraints.removeLast() }
            return (["hvc1", "\(space)\(ptl[0] & 0x1F)", String(reversed, radix: 16, uppercase: true), "\(ptl[0] & 0x20 != 0 ? "H" : "L")\(ptl[11])"]
                    + constraints.map { String(format: "%02X", $0) }).joined(separator: ".")
        default:
            return "hvc1"
        }
    }

    static func audioCodecString(_ parameters: AVCodecParameters) -> String {
        switch parameters.codec_id {
        case AV_CODEC_ID_AAC:
            // Audio object types: LC 2, HE-AAC 5, HE-AACv2 29.
            return "mp4a.40." + (parameters.profile == AV_PROFILE_AAC_HE ? "5" : parameters.profile == AV_PROFILE_AAC_HE_V2 ? "29" : "2")
        case AV_CODEC_ID_AC3: return "ac-3"
        case AV_CODEC_ID_EAC3: return "ec-3"
        case AV_CODEC_ID_ALAC: return "alac"
        default: return "alac"
        }
    }

    /// The first Annex B NAL unit whose header byte passes `matches`, header
    /// included, with emulation-prevention bytes removed.
    private static func nalPayload(_ bytes: [UInt8], matches: (UInt8) -> Bool) -> [UInt8] {
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let start = index + 3
                if matches(bytes[start]) {
                    var payload: [UInt8] = []
                    var zeros = 0
                    for byte in bytes[start...] {
                        if zeros >= 2, byte == 3 { zeros = 0; continue }
                        if zeros >= 2, byte <= 1 { break }  // the next start code
                        zeros = byte == 0 ? zeros + 1 : 0
                        payload.append(byte)
                    }
                    return payload
                }
                index = start
            } else {
                index += 1
            }
        }
        return []
    }
}

private func check(_ result: Int32, _ what: String) throws {
    if result < 0 { throw HLSStream.StreamError.ffmpeg(what, result) }
}

/// One run of FFmpeg's MP4 muxer in fragmented mode, into memory: ftyp and
/// moov, then a single moof+mdat holding the packets written. Each segment
/// is a run of its own, timed from the file's start (frag_discont), so any
/// segment can be made without the ones before it.
private final class FragmentWriter {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private let stream: UnsafeMutablePointer<AVStream>
    private let timeBase: AVRational

    /// `tag` is the sample entry's fourCC (hvc1, dvh1), or 0 for the muxer's default.
    init(parameters: UnsafePointer<AVCodecParameters>, tag: UInt32, timeBase: AVRational, fragmentIndex: Int) throws {
        self.timeBase = timeBase
        guard avformat_alloc_output_context2(&context, nil, "mp4", nil) >= 0, let context, let stream = avformat_new_stream(context, nil) else {
            throw HLSStream.StreamError.ffmpeg("avformat_alloc_output_context2", 0)
        }
        self.stream = stream
        avcodec_parameters_copy(stream.pointee.codecpar, parameters)
        stream.pointee.codecpar.pointee.codec_tag = tag
        stream.pointee.time_base = timeBase
        context.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL  // writes Dolby Vision's dvcC/dvvC
        context.pointee.avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED
        try check(avio_open_dyn_buf(&context.pointee.pb), "avio_open_dyn_buf")
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "movflags", "empty_moov+delay_moov+default_base_moof+frag_custom+frag_discont", 0)
        av_dict_set(&options, "use_editlist", "0", 0)
        av_dict_set(&options, "fragment_index", String(fragmentIndex + 1), 0)
        try check(avformat_write_header(context, &options), "avformat_write_header")
    }

    deinit {
        if let pb = context?.pointee.pb {
            var buffer: UnsafeMutablePointer<UInt8>?
            avio_close_dyn_buf(pb, &buffer)
            av_free(buffer)
            context?.pointee.pb = nil
        }
        avformat_free_context(context)
    }

    /// Writes a packet whose timestamps are in `timeBase`.
    func write(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        packet.pointee.stream_index = 0
        av_packet_rescale_ts(packet, timeBase, stream.pointee.time_base)
        try check(av_write_frame(context, packet), "av_write_frame")
    }

    func finish() throws -> Data {
        // With delay_moov the first flush writes only the moov; the second the fragment.
        try check(av_write_frame(context, nil), "av_write_frame (flush)")
        try check(av_write_frame(context, nil), "av_write_frame (flush)")
        var buffer: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(context!.pointee.pb, &buffer)
        context!.pointee.pb = nil
        defer { av_free(buffer) }
        return buffer.map { Data(bytes: $0, count: Int(size)) } ?? Data()
    }
}
