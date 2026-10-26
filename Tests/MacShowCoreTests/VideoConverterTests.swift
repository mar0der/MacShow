import AVFoundation
import Foundation
import Testing
@testable import MacShowCore

struct VideoConverterTests {
    let clip = Bundle.module.url(forResource: "Fixtures/My.Show.S02E05.720p", withExtension: "mkv")!

    func output() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("convert-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("out.mp4")
    }

    @Test func convertsToHEVC() throws {
        let out = try output()
        var last = 0.0
        try VideoConverter.convert([clip], to: out, videoBitrate: 500_000) { last = $0 }
        let meta = try #require(MetadataReader.read(out))
        #expect(meta.videoCodec == "hevc" && meta.audioCodec == "aac")
        #expect(abs(meta.duration - 1.0) < 0.3)
        #expect(last > 0.9)
        // Nothing left over beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path) == ["out.mp4"])
    }

    @Test func joinsParts() throws {
        let out = try output()
        try VideoConverter.convert([clip, clip], to: out, videoBitrate: 500_000) { _ in }
        let meta = try #require(MetadataReader.read(out))
        #expect(abs(meta.duration - 2.0) < 0.4)
    }

    @Test func keepsEveryAudioTrack() async throws {
        let out = try output()
        let input = Bundle.module.url(forResource: "ConvertFixtures/two-audio-tracks", withExtension: "mkv")!
        try VideoConverter.convert([input], to: out, videoBitrate: 500_000) { _ in }
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        var found: [(String?, UInt32)] = []
        for track in tracks {
            let (language, formats) = try await track.load(.languageCode, .formatDescriptions)
            found.append((language, formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0))
        }
        // The dub stays stereo, the original stays 5.1.
        #expect(found.map(\.0) == ["bul", "eng"])
        #expect(found.map(\.1) == [2, 6])
    }

    @Test func refusesFilesWithSubtitlesInside() throws {
        let out = try output()
        let input = Bundle.module.url(forResource: "ConvertFixtures/with-subtitles", withExtension: "mkv")!
        #expect(throws: VideoConverter.Failure.subtitles) {
            try VideoConverter.convert([input], to: out, videoBitrate: 500_000) { _ in }
        }
    }

    @Test func stopsWhenCancelled() throws {
        let out = try output()
        #expect(throws: VideoConverter.Failure.cancelled) {
            try VideoConverter.convert([clip], to: out, videoBitrate: 500_000, isCancelled: { true }) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path).isEmpty)
    }
}
