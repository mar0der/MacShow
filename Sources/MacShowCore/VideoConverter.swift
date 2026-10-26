import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale

/// Converts videos to MP4: HEVC video from the Mac's hardware encoder, every audio
/// track as AAC (5.1 stays 5.1), with its language. Several inputs (a movie's
/// parts) become one file, in order.
public enum VideoConverter {
    public enum Failure: Error, Equatable {
        case unreadable(String)
        case noVideo
        case encoder(String)
        case cancelled
        /// Subtitles inside the file, which this conversion would lose.
        case subtitles
    }

    /// Writes `<output>.part` and renames it when done (nothing is left behind on
    /// failure). `shouldPause` is asked between packets: while it says yes, the
    /// conversion waits. `progress` gets 0…1.
    public static func convert(_ inputs: [URL], to output: URL, videoBitrate: Int,
                               shouldPause: @escaping () -> Bool = { false }, isCancelled: @escaping () -> Bool = { false },
                               progress: (Double) -> Void) throws {
        let temp = output.appendingPathExtension("part")
        let job = try Job(inputs: inputs, output: temp, videoBitrate: videoBitrate)
        do {
            try job.run(shouldPause: shouldPause, isCancelled: isCancelled, progress: progress)
            job.close()
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: temp, to: output)
        } catch {
            job.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static let eof = -Int32(bitPattern: 0x45 | 0x4F << 8 | 0x46 << 16 | 0x20 << 24)  // AVERROR_EOF
    private static let again = -EAGAIN  // AVERROR(EAGAIN)
    private static let sampleRate: Int32 = 48_000

    private final class Job {
        let inputs: [URL]
        let total: Double
        var out: UnsafeMutablePointer<AVFormatContext>?
        var video: UnsafeMutablePointer<AVCodecContext>?
        var videoStream: UnsafeMutablePointer<AVStream>?
        var audio: [AudioTrack] = []
        var packet = av_packet_alloc()
        var lastVideoPts: Int64 = -1
        var headerWritten = false
        var closed = false

        init(inputs: [URL], output: URL, videoBitrate: Int) throws {
            self.inputs = inputs
            // Lengths first, for progress; the first input sets the picture size and rate.
            var total = 0.0
            var first: (width: Int32, height: Int32, aspect: AVRational, rate: AVRational)?
            var audioTracks: [(channels: Int32, tags: OpaquePointer?)] = []
            defer { for var track in audioTracks { av_dict_free(&track.tags) } }
            for url in inputs {
                let input = try Input(url)
                defer { input.close() }
                guard !input.hasSubtitles else { throw Failure.subtitles }
                total += input.duration
                if first == nil, let decoder = input.videoDecoder, let stream = input.videoStream {
                    first = (decoder.pointee.width, decoder.pointee.height, decoder.pointee.sample_aspect_ratio,
                             av_guess_frame_rate(input.format, stream, nil))
                    for track in input.audio {
                        var tags: OpaquePointer?
                        av_dict_copy(&tags, track.stream.pointee.metadata, 0)
                        audioTracks.append((track.decoder.pointee.ch_layout.nb_channels, tags))
                    }
                }
            }
            guard let first else { throw Failure.noVideo }
            self.total = max(total, 0.001)

            guard avformat_alloc_output_context2(&out, nil, "mp4", output.path) >= 0, let out else { throw Failure.encoder("mp4") }
            let globalHeader = out.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0

            guard let hevc = avcodec_find_encoder_by_name("hevc_videotoolbox"), let video = avcodec_alloc_context3(hevc) else {
                throw Failure.encoder("hevc_videotoolbox")
            }
            self.video = video
            let rate = first.rate.num > 0 && first.rate.den > 0 ? first.rate : AVRational(num: 25, den: 1)
            video.pointee.width = first.width & ~1
            video.pointee.height = first.height & ~1
            video.pointee.sample_aspect_ratio = first.aspect
            video.pointee.pix_fmt = AV_PIX_FMT_YUV420P
            video.pointee.framerate = rate
            video.pointee.time_base = AVRational(num: 1, den: 90_000)
            video.pointee.bit_rate = Int64(videoBitrate)
            if globalHeader { video.pointee.flags |= Int32(AV_CODEC_FLAG_GLOBAL_HEADER) }
            guard avcodec_open2(video, hevc, nil) >= 0, let stream = avformat_new_stream(out, nil) else { throw Failure.encoder("hevc_videotoolbox") }
            avcodec_parameters_from_context(stream.pointee.codecpar, video)
            // "hvc1", the tag Apple's players want for HEVC in MP4.
            stream.pointee.codecpar.pointee.codec_tag = UInt32(0x68) | UInt32(0x76) << 8 | UInt32(0x63) << 16 | UInt32(0x31) << 24
            stream.pointee.time_base = video.pointee.time_base
            videoStream = stream

            for (number, track) in audioTracks.enumerated() {
                audio.append(try AudioTrack(in: out, channels: track.channels, tags: track.tags, isDefault: number == 0, globalHeader: globalHeader))
            }

            guard avio_open(&out.pointee.pb, output.path, AVIO_FLAG_WRITE) >= 0 else { throw Failure.encoder("write") }
            var options: OpaquePointer?
            av_dict_set(&options, "movflags", "+faststart", 0)  // plays while it downloads
            defer { av_dict_free(&options) }
            guard avformat_write_header(out, &options) >= 0 else { throw Failure.encoder("header") }
            headerWritten = true
        }

        func run(shouldPause: () -> Bool, isCancelled: () -> Bool, progress: (Double) -> Void) throws {
            var offset = 0.0
            for url in inputs {
                let input = try Input(url)
                defer { input.close() }
                // Each part starts where the last one ended, picture and sound alike;
                // its audio tracks go to the first part's, in order.
                let tracks = zip(input.audio, audio).compactMap { source, track in
                    track.resampler(for: source.decoder).map { (source, track, $0) }
                }
                defer { for (_, _, resampler) in tracks { var context: OpaquePointer? = resampler; swr_free(&context) } }
                for (_, track, _) in tracks { track.samples = max(track.samples, Int64(offset * Double(sampleRate))) }
                var packets = 0
                while true {
                    if isCancelled() { throw Failure.cancelled }
                    packets += 1
                    if packets % 50 == 0 {
                        while shouldPause() {
                            if isCancelled() { throw Failure.cancelled }
                            Thread.sleep(forTimeInterval: 0.5)
                        }
                    }
                    guard let packet, av_read_frame(input.format, packet) >= 0 else { break }
                    defer { av_packet_unref(packet) }
                    if packet.pointee.stream_index == input.videoIndex, let decoder = input.videoDecoder {
                        try decode(packet, with: decoder) { frame in
                            let seconds = try self.writeVideo(frame, from: input, offset: offset)
                            progress(min((offset + seconds) / self.total, 1))
                        }
                    } else if let (source, track, resampler) = tracks.first(where: { $0.0.stream.pointee.index == packet.pointee.stream_index }) {
                        try decode(packet, with: source.decoder) { try self.write($0, to: track, resampler: resampler) }
                    }
                }
                // What the decoders still hold.
                if let decoder = input.videoDecoder {
                    try decode(nil, with: decoder) { _ = try self.writeVideo($0, from: input, offset: offset) }
                }
                for (source, track, resampler) in tracks {
                    try decode(nil, with: source.decoder) { try self.write($0, to: track, resampler: resampler) }
                }
                offset += input.duration
            }
            try finish()
            progress(1)
        }

        private func decode(_ packet: UnsafeMutablePointer<AVPacket>?, with decoder: UnsafeMutablePointer<AVCodecContext>,
                            _ handle: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
            guard avcodec_send_packet(decoder, packet) >= 0 || packet == nil else { return }  // a damaged packet: skip it
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            guard let frame else { return }
            while avcodec_receive_frame(decoder, frame) >= 0 {
                try handle(frame)
                av_frame_unref(frame)
            }
        }

        /// Encodes a picture; returns how far into its input it is (seconds).
        private func writeVideo(_ frame: UnsafeMutablePointer<AVFrame>, from input: Input, offset: Double) throws -> Double {
            guard let video, let stream = input.videoStream else { return 0 }
            let base = stream.pointee.time_base
            let start = stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time
            let timestamp = frame.pointee.best_effort_timestamp
            let seconds = timestamp == Int64.min ? Double(lastVideoPts + 3000) / 90_000 - offset
                : Double(timestamp - start) * Double(base.num) / Double(base.den)
            var pts = Int64((offset + max(seconds, 0)) * 90_000)
            if pts <= lastVideoPts { pts = lastVideoPts + 1 }  // strictly increasing for the encoder
            lastVideoPts = pts

            var converted: UnsafeMutablePointer<AVFrame>?
            defer { av_frame_free(&converted) }
            var send = frame
            if frame.pointee.format != AV_PIX_FMT_YUV420P.rawValue || frame.pointee.width != video.pointee.width
                || frame.pointee.height != video.pointee.height {
                converted = av_frame_alloc()
                guard let converted, let scaler = input.scaler(for: frame, to: video) else { return seconds }
                converted.pointee.format = AV_PIX_FMT_YUV420P.rawValue
                converted.pointee.width = video.pointee.width
                converted.pointee.height = video.pointee.height
                guard sws_scale_frame(scaler, converted, frame) >= 0 else { return seconds }
                send = converted
            }
            send.pointee.pts = pts
            send.pointee.pict_type = AV_PICTURE_TYPE_NONE
            guard avcodec_send_frame(video, send) >= 0 else { throw Failure.encoder("hevc_videotoolbox") }
            try drain(video, into: videoStream)
            return seconds
        }

        private func write(_ frame: UnsafeMutablePointer<AVFrame>, to track: AudioTrack, resampler: OpaquePointer) throws {
            var converted = av_frame_alloc()
            defer { av_frame_free(&converted) }
            guard let converted else { return }
            converted.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            converted.pointee.sample_rate = sampleRate
            av_channel_layout_copy(&converted.pointee.ch_layout, &track.encoder.pointee.ch_layout)
            converted.pointee.nb_samples = swr_get_out_samples(resampler, frame.pointee.nb_samples)
            guard converted.pointee.nb_samples > 0, av_frame_get_buffer(converted, 0) >= 0 else { return }
            let made = swr_convert(resampler,
                                   UnsafeRawPointer(converted.pointee.extended_data).assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self),
                                   converted.pointee.nb_samples,
                                   UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                                   frame.pointee.nb_samples)
            guard made > 0 else { return }
            av_audio_fifo_write(track.fifo, UnsafeRawPointer(converted.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self), made)
            try encode(track, final: false)
        }

        /// Sends whole AAC frames from a track's queue (and the rest, at the end).
        private func encode(_ track: AudioTrack, final: Bool) throws {
            let encoder = track.encoder, fifo = track.fifo
            let size = encoder.pointee.frame_size > 0 ? encoder.pointee.frame_size : 1024
            while av_audio_fifo_size(fifo) >= size || (final && av_audio_fifo_size(fifo) > 0) {
                let count = min(size, av_audio_fifo_size(fifo))
                var frame = av_frame_alloc()
                defer { av_frame_free(&frame) }
                guard let frame else { return }
                frame.pointee.nb_samples = count
                frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
                frame.pointee.sample_rate = sampleRate
                av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
                guard av_frame_get_buffer(frame, 0) >= 0 else { return }
                av_audio_fifo_read(fifo, UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self), count)
                frame.pointee.pts = track.samples
                track.samples += Int64(count)
                guard avcodec_send_frame(encoder, frame) >= 0 else { throw Failure.encoder("aac") }
                try drain(encoder, into: track.stream)
            }
        }

        private func drain(_ encoder: UnsafeMutablePointer<AVCodecContext>, into stream: UnsafeMutablePointer<AVStream>?) throws {
            guard let out, let stream, let packet = av_packet_alloc() else { return }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            while true {
                let result = avcodec_receive_packet(encoder, packet)
                if result == again || result == eof { return }
                guard result >= 0 else { throw Failure.encoder("encode") }
                av_packet_rescale_ts(packet, encoder.pointee.time_base, stream.pointee.time_base)
                packet.pointee.stream_index = stream.pointee.index
                guard av_interleaved_write_frame(out, packet) >= 0 else { throw Failure.encoder("write") }
            }
        }

        private func finish() throws {
            for track in audio { try encode(track, final: true) }
            if let video { avcodec_send_frame(video, nil); try drain(video, into: videoStream) }
            for track in audio { avcodec_send_frame(track.encoder, nil); try drain(track.encoder, into: track.stream) }
            guard let out, av_write_trailer(out) >= 0 else { throw Failure.encoder("trailer") }
            headerWritten = false
        }

        func close() {
            guard !closed else { return }
            closed = true
            if headerWritten, let out { av_write_trailer(out) }
            if let out { avio_closep(&out.pointee.pb) }
            avformat_free_context(out)
            avcodec_free_context(&video)
            audio.forEach { $0.close() }
            av_packet_free(&packet)
        }
    }

    /// One AAC track of the output: mono, stereo or 5.1, like its source.
    private final class AudioTrack {
        var encoder: UnsafeMutablePointer<AVCodecContext>
        let stream: UnsafeMutablePointer<AVStream>
        let fifo: OpaquePointer
        /// Where the next frame starts, in samples.
        var samples: Int64 = 0

        init(in out: UnsafeMutablePointer<AVFormatContext>, channels: Int32, tags: OpaquePointer?, isDefault: Bool, globalHeader: Bool) throws {
            guard let aac = avcodec_find_encoder(AV_CODEC_ID_AAC), let encoder = avcodec_alloc_context3(aac) else { throw Failure.encoder("aac") }
            self.encoder = encoder
            let layout = channels > 2 ? 6 : max(channels, 1)
            encoder.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
            encoder.pointee.sample_rate = sampleRate
            av_channel_layout_default(&encoder.pointee.ch_layout, layout)
            encoder.pointee.bit_rate = 64_000 * Int64(max(layout, 2))
            encoder.pointee.time_base = AVRational(num: 1, den: sampleRate)
            if globalHeader { encoder.pointee.flags |= Int32(AV_CODEC_FLAG_GLOBAL_HEADER) }
            guard avcodec_open2(encoder, aac, nil) >= 0, let stream = avformat_new_stream(out, nil),
                  let fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, layout, 1) else {
                var owned: UnsafeMutablePointer<AVCodecContext>? = encoder
                avcodec_free_context(&owned)
                throw Failure.encoder("aac")
            }
            avcodec_parameters_from_context(stream.pointee.codecpar, encoder)
            stream.pointee.time_base = encoder.pointee.time_base
            av_dict_copy(&stream.pointee.metadata, tags, 0)  // language, name
            stream.pointee.disposition = isDefault ? AV_DISPOSITION_DEFAULT : 0
            self.stream = stream
            self.fifo = fifo
        }

        /// Converts `decoder`'s sound to this track's: 48 kHz floats, its channels.
        func resampler(for decoder: UnsafeMutablePointer<AVCodecContext>) -> OpaquePointer? {
            var context: OpaquePointer?
            guard swr_alloc_set_opts2(&context, &encoder.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, VideoConverter.sampleRate,
                                      &decoder.pointee.ch_layout, decoder.pointee.sample_fmt, decoder.pointee.sample_rate, 0, nil) >= 0,
                  swr_init(context) >= 0 else {
                swr_free(&context)
                return nil
            }
            return context
        }

        func close() {
            var owned: UnsafeMutablePointer<AVCodecContext>? = encoder
            avcodec_free_context(&owned)
            av_audio_fifo_free(fifo)
        }
    }

    /// One input file, opened, with decoders for its main picture and every audio track.
    private final class Input {
        var format: UnsafeMutablePointer<AVFormatContext>?
        var videoDecoder: UnsafeMutablePointer<AVCodecContext>?
        var audio: [(stream: UnsafeMutablePointer<AVStream>, decoder: UnsafeMutablePointer<AVCodecContext>)] = []
        var hasSubtitles = false
        var videoIndex: Int32 = -1
        var videoStream: UnsafeMutablePointer<AVStream>? { videoIndex >= 0 ? format?.pointee.streams[Int(videoIndex)] : nil }
        var duration: Double { format.map { $0.pointee.duration > 0 ? Double($0.pointee.duration) / 1_000_000 : 0 } ?? 0 }
        private var sws: UnsafeMutablePointer<SwsContext>?

        init(_ url: URL) throws {
            guard avformat_open_input(&format, url.path, nil, nil) == 0, let format, avformat_find_stream_info(format, nil) >= 0 else {
                throw Failure.unreadable(url.lastPathComponent)
            }
            var codec: UnsafePointer<AVCodec>?
            videoIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
            videoDecoder = videoIndex >= 0 ? Self.open(format.pointee.streams[Int(videoIndex)]!) : nil
            for index in 0..<Int(format.pointee.nb_streams) {
                guard let stream = format.pointee.streams[index] else { continue }
                switch stream.pointee.codecpar.pointee.codec_type {
                case AVMEDIA_TYPE_AUDIO: if let decoder = Self.open(stream) { audio.append((stream, decoder)) }
                case AVMEDIA_TYPE_SUBTITLE: hasSubtitles = true
                default: break
                }
            }
        }

        private static func open(_ stream: UnsafeMutablePointer<AVStream>) -> UnsafeMutablePointer<AVCodecContext>? {
            guard let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id), var context = avcodec_alloc_context3(codec) else { return nil }
            context.pointee.thread_count = 0  // as many threads as make sense
            guard avcodec_parameters_to_context(context, stream.pointee.codecpar) >= 0, avcodec_open2(context, codec, nil) >= 0 else {
                var owned: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&owned)
                return nil
            }
            context.pointee.pkt_timebase = stream.pointee.time_base
            _ = withUnsafeMutablePointer(to: &context) { $0 }
            return context
        }

        func scaler(for frame: UnsafeMutablePointer<AVFrame>, to encoder: UnsafeMutablePointer<AVCodecContext>) -> UnsafeMutablePointer<SwsContext>? {
            if sws == nil {
                sws = sws_getContext(frame.pointee.width, frame.pointee.height, AVPixelFormat(rawValue: frame.pointee.format),
                                     encoder.pointee.width, encoder.pointee.height, AV_PIX_FMT_YUV420P, Int32(SWS_BICUBIC.rawValue), nil, nil, nil)
            }
            return sws
        }

        func close() {
            if let sws { sws_freeContext(sws) }
            avcodec_free_context(&videoDecoder)
            for (_, decoder) in audio { var owned: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&owned) }
            avformat_close_input(&format)
        }
    }
}
