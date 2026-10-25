import Foundation
import MacShowCore
import Observation
import SwiftUI

/// Plays the current video on a smart TV over DLNA. TVs that play the file's
/// container and codecs get the file itself; others get the same HLS
/// repackaging as AirPlay. The TV's position is polled every second, so the
/// controls follow it and resume points keep saving; mpv waits, paused.
@MainActor
@Observable
final class DLNACast: Cast {
    private(set) var renderers: [DLNA.Renderer] = []
    private(set) var isSearching = false
    /// The TV being played on.
    private(set) var renderer: DLNA.Renderer?
    private(set) var summary = ""
    private(set) var hasPictureSubtitles = false
    var isActive: Bool { renderer != nil }
    var deviceName: String { renderer?.name ?? "" }

    @ObservationIgnored weak var player: Player?
    @ObservationIgnored private let server = CastServer()
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var isPaused = false
    /// The last position the TV reported, and whether it got to playing.
    @ObservationIgnored private var lastPosition: Double = 0
    @ObservationIgnored private var hasPlayed = false

    func search() async {
        guard !isSearching else { return }
        isSearching = true
        renderers = await DLNA.discover()
        isSearching = false
    }

    /// Sends the playing video to `renderer`, from where it is now.
    func cast(to renderer: DLNA.Renderer) {
        guard let player, player.isVideo, let path = player.loadedPath else { return }
        player.activeCast?.stop(resume: false)
        self.renderer = renderer
        player.castDidStart()
        load(path, startAt: player.position)
    }

    func follow(_ path: String, startAt start: Double) { load(path, startAt: start) }

    /// Tracks are the TV's own business when it plays the file; HLS keeps the starting ones.
    func tracksChanged() {}

    func togglePause() {
        guard let renderer else { return }
        isPaused.toggle()
        player?.castProgress(position: lastPosition, isPaused: isPaused)
        let action = isPaused ? "Pause" : "Play"
        Task { try? await DLNA.send(action, action == "Play" ? [("Speed", "1")] : [], to: renderer) }
    }

    func seek(to seconds: Double) {
        guard let renderer else { return }
        lastPosition = max(seconds, 0)
        player?.castProgress(position: lastPosition, isPaused: isPaused)
        Task { try? await DLNA.seek(to: lastPosition, on: renderer) }
    }

    func stop(resume: Bool) {
        poll?.cancel()
        poll = nil
        if let renderer { Task { try? await DLNA.send("Stop", to: renderer) } }
        if let url { server.unpublish(url) }
        url = nil
        guard renderer != nil else { return }
        renderer = nil
        if resume { player?.castDidEnd(at: lastPosition, playing: !isPaused) }
    }

    private func load(_ path: String, startAt start: Double) {
        guard let renderer, let player else { return }
        poll?.cancel()
        if let url { server.unpublish(url) }
        let title = player.currentItem?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let (audio, subtitle) = (player.streamIndex("audio"), player.streamIndex("sub"))
        lastPosition = start
        hasPlayed = false
        isPaused = false
        poll = Task {
            do {
                let file = URL(fileURLWithPath: path)
                let stream = try await Task.detached { try HLSStream(url: file, audioStream: audio, subtitleStream: subtitle) }.value
                let mimeType: String
                if let original = DLNA.originalMimeType(container: stream.container, video: stream.plan.video, audioCodec: stream.audioCodec) {
                    url = try await server.publish(file: file, mimeType: original)
                    mimeType = original
                    summary = "Direct"
                    hasPictureSubtitles = false  // they're in the file; the TV may show them
                } else {
                    url = try await server.publish(stream)
                    mimeType = "application/vnd.apple.mpegurl"
                    summary = stream.plan.summary
                    hasPictureSubtitles = stream.hasPictureSubtitles
                }
                try await DLNA.play(url!, title: title, mimeType: mimeType, duration: stream.duration, on: renderer)
                try await follow(renderer, seekingTo: start)
            } catch is CancellationError {
            } catch {
                FileHandle.standardError.write(Data("DLNA: can't play on \(renderer.name): \(error)\n".utf8))
                stop(resume: true)
            }
        }
    }

    /// Polls the TV until casting stops: seeks to `start` once it plays,
    /// reports its position, and notices when it stops by itself.
    private func follow(_ renderer: DLNA.Renderer, seekingTo start: Double) async throws {
        var duration: Double = 0
        var waited = 0
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(1))
            waited += 1
            // Never started: the TV can't play it.
            if !hasPlayed, waited > 30 { throw URLError(.timedOut) }
            guard let status = try? await DLNA.status(of: renderer), !Task.isCancelled else { continue }
            switch status.state {
            case "PLAYING", "PAUSED_PLAYBACK":
                // Many TVs only take a seek once they're playing.
                if !hasPlayed, start > 1 { try? await DLNA.seek(to: start, on: renderer) }
                hasPlayed = true
                lastPosition = status.position
                if status.duration > 0 { duration = status.duration }
                isPaused = status.state == "PAUSED_PLAYBACK"
                player?.castProgress(position: lastPosition, isPaused: isPaused)
            case "STOPPED", "NO_MEDIA_PRESENT" where hasPlayed:
                // Played to the end, or stopped with the TV's remote.
                if duration > 0, duration - lastPosition < 15 {
                    let hasNext = player.map { ($0.queueIndex ?? .max - 1) + 1 < $0.queue.count } ?? false
                    hasPlayed = false
                    player?.castDidReachEnd()  // the next episode follows here
                    if !hasNext { return stop(resume: false) }
                } else {
                    return stop(resume: true)
                }
            default:
                break
            }
        }
    }
}

/// TVs found on the network, next to the AirPlay button.
struct DLNAMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        let dlna = player.dlna
        Menu {
            Section(dlna.isSearching ? "Looking for TVs…" : "TVs (DLNA)") {
                ForEach(dlna.renderers) { renderer in
                    Toggle(renderer.name, isOn: Binding(get: { dlna.renderer == renderer }, set: { on in
                        if on { dlna.cast(to: renderer) } else { dlna.stop(resume: true) }
                    }))
                }
                if dlna.renderers.isEmpty, !dlna.isSearching {
                    Text("No TVs found")
                }
            }
            Button("Look Again") { Task { await dlna.search() } }
        } label: {
            Image(systemName: dlna.isActive ? "tv.fill" : "tv")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Play on a TV")
        .task { if dlna.renderers.isEmpty { await dlna.search() } }
    }
}
