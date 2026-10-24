import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale

/// Grabs a still from a video with FFmpeg, so tiles get a picture for any
/// container or codec (MKV, AVI, HEVC…), not only what AVFoundation reads.
public enum VideoThumbnailer {
    /// A frame about 10% in (at most five minutes in), at most `width` pixels wide.
    public static func thumbnail(of url: URL, width: Int = 640) -> CGImage? {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&formatContext, url.path, nil, nil) == 0, let format = formatContext else { return nil }
        defer { avformat_close_input(&formatContext) }
        guard avformat_find_stream_info(format, nil) >= 0 else { return nil }

        var decoder: UnsafePointer<AVCodec>?
        let streamIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        guard streamIndex >= 0, let decoder, let stream = format.pointee.streams[Int(streamIndex)] else { return nil }

        var codecContext = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codecContext) }
        guard let codec = codecContext,
              avcodec_parameters_to_context(codec, stream.pointee.codecpar) >= 0,
              avcodec_open2(codec, decoder, nil) >= 0
        else { return nil }

        let duration = format.pointee.duration > 0 ? Double(format.pointee.duration) / 1_000_000 : 0
        let target = min(duration * 0.1, 300)
        if target > 1 {
            av_seek_frame(format, -1, Int64(target * 1_000_000), AVSEEK_FLAG_BACKWARD)
            avcodec_flush_buffers(codec)
        }

        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        guard let packet, let frame else { return nil }

        var videoPackets = 0
        while videoPackets < 600, av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            videoPackets += 1
            if avcodec_send_packet(codec, packet) >= 0, avcodec_receive_frame(codec, frame) >= 0 {
                return image(from: frame, maxWidth: width)
            }
        }
        // Short files: drain what the decoder still holds.
        avcodec_send_packet(codec, nil)
        return avcodec_receive_frame(codec, frame) >= 0 ? image(from: frame, maxWidth: width) : nil
    }

    /// Converts a decoded frame to an RGB image at its display aspect ratio.
    private static func image(from frame: UnsafeMutablePointer<AVFrame>, maxWidth: Int) -> CGImage? {
        let sourceWidth = frame.pointee.width, sourceHeight = frame.pointee.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let aspect = frame.pointee.sample_aspect_ratio
        let displayWidth = aspect.num > 0 && aspect.den > 0
            ? Double(sourceWidth) * Double(aspect.num) / Double(aspect.den) : Double(sourceWidth)
        let width = Int32(min(Double(maxWidth), displayWidth))
        let height = max(Int32(Double(width) * Double(sourceHeight) / displayWidth), 2)

        guard let scaler = sws_getContext(
            sourceWidth, sourceHeight, AVPixelFormat(rawValue: frame.pointee.format),
            width, height, AV_PIX_FMT_RGBA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        ) else { return nil }
        defer { sws_freeContext(scaler) }

        let bytesPerRow = Int(width) * 4
        var pixels = Data(count: bytesPerRow * Int(height))
        var planes = frame.pointee.data
        var strides = frame.pointee.linesize
        let sourcePlanes = withUnsafeBytes(of: &planes) { Array($0.bindMemory(to: UnsafePointer<UInt8>?.self)) }
        let sourceStrides = withUnsafeBytes(of: &strides) { Array($0.bindMemory(to: Int32.self)) }
        let scaledRows = pixels.withUnsafeMutableBytes { buffer -> Int32 in
            let destination: [UnsafeMutablePointer<UInt8>?] = [buffer.bindMemory(to: UInt8.self).baseAddress, nil, nil, nil]
            let destinationStrides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            return sws_scale(scaler, sourcePlanes, sourceStrides, 0, sourceHeight, destination, destinationStrides)
        }
        guard scaledRows > 0, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
