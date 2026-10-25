import AVFoundation
import AVKit
import MacShowCore
import Observation
import SwiftUI

/// Plays the current video on an AirPlay device such as an Apple TV. mpv
/// only draws on this Mac's screen, so the file is served as HLS from
/// `CastServer` (repackaged by `HLSStream`) and handed to an AVPlayer, whose
/// URL the Apple TV fetches itself. mpv waits, paused, and picks up at the
/// same spot when AirPlay stops.
@MainActor
@Observable
final class AirPlay: Cast {
    /// The video is playing on an AirPlay device.
    private(set) var isActive = false
    let deviceName = "AirPlay"
    /// "Direct", or what's being converted, for the file on the TV.
    private(set) var summary = ""
    /// The file has picture subtitles (PGS, VobSub), which the TV doesn't get.
    private(set) var hasPictureSubtitles = false

    @ObservationIgnored let avPlayer = AVPlayer()
    @ObservationIgnored weak var player: Player?
    @ObservationIgnored private let server = CastServer()
    @ObservationIgnored private var stream: HLSStream?
    @ObservationIgnored private var url: URL?
    /// The file, audio and subtitle streams the AVPlayer's item was made for.
    @ObservationIgnored private var loaded: (path: String, audio: Int32?, subtitle: Int32?)?
    /// Swapping items while on the TV; the route may blink off meanwhile.
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        avPlayer.allowsExternalPlayback = true
        observation = avPlayer.observe(\.isExternalPlaybackActive) { [weak self] _, _ in
            DispatchQueue.main.async { self?.routeChanged() }
        }
        avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isActive, !self.isSwitching, time.isNumeric else { return }
                self.player?.castProgress(position: time.seconds, isPaused: self.avPlayer.rate == 0)
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isActive, (note.object as? AVPlayerItem) === self.avPlayer.currentItem else { return }
                self.player?.castDidReachEnd()
            }
        }
    }

    /// Readies the playing video for AirPlay. Called when the AirPlay menu opens.
    func prepare() {
        guard let player, player.isVideo, let path = player.loadedPath else { return }
        load(path, audio: player.streamIndex("audio"), subtitle: player.streamIndex("sub"), startAt: nil)
    }

    /// mpv moved on to another video (next episode) while on the TV.
    func follow(_ path: String, startAt start: Double) {
        guard let player else { return }
        load(path, audio: player.streamIndex("audio"), subtitle: player.streamIndex("sub"), startAt: start)
    }

    /// The audio or subtitle track was changed in the Tracks menu.
    func tracksChanged() {
        guard isActive, let player, let loaded else { return }
        let audio = player.streamIndex("audio"), subtitle = player.streamIndex("sub")
        if audio != loaded.audio {
            // The audio rendition is fixed per item: make a new one, from here.
            load(loaded.path, audio: audio, subtitle: subtitle, startAt: avPlayer.currentTime().seconds)
        } else if subtitle != loaded.subtitle, let item = avPlayer.currentItem {
            self.loaded?.subtitle = subtitle
            Task { await selectSubtitle(subtitle, in: item) }
        }
    }

    func togglePause() {
        if avPlayer.rate == 0 { avPlayer.play() } else { avPlayer.pause() }
        player?.castProgress(position: avPlayer.currentTime().seconds, isPaused: avPlayer.rate == 0)
    }

    func seek(to seconds: Double) {
        avPlayer.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.castProgress(position: max(seconds, 0), isPaused: avPlayer.rate == 0)
    }

    /// Stops playing on the TV; with `resume`, mpv carries on from there on the Mac.
    func stop(resume: Bool) {
        let position = avPlayer.currentTime().seconds
        let wasPlaying = avPlayer.rate != 0
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        if let url { server.unpublish(url) }
        url = nil
        stream = nil
        loaded = nil
        guard isActive else { return }
        isActive = false
        if resume, position.isFinite { player?.castDidEnd(at: position, playing: wasPlaying) }
    }

    private func load(_ path: String, audio: Int32?, subtitle: Int32?, startAt start: Double?) {
        if let loaded, loaded.path == path, loaded.audio == audio, loaded.subtitle == subtitle, start == nil { return }
        loaded = (path, audio, subtitle)
        isSwitching = isActive
        Task {
            do {
                let stream = try await Task.detached { try HLSStream(url: URL(fileURLWithPath: path), audioStream: audio, subtitleStream: subtitle) }.value
                let url = try await server.publish(stream)
                guard loaded?.path == path, loaded?.audio == audio else { return server.unpublish(url) }
                if let old = self.url { server.unpublish(old) }
                self.stream = stream
                self.url = url
                summary = stream.plan.summary
                hasPictureSubtitles = stream.hasPictureSubtitles
                let item = AVPlayerItem(url: url)
                avPlayer.replaceCurrentItem(with: item)
                await selectSubtitle(subtitle, in: item)
                if let start {
                    await avPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
                    avPlayer.play()
                }
            } catch {
                FileHandle.standardError.write(Data("AirPlay: can't serve \(path): \(error)\n".utf8))
                loaded = nil
            }
            isSwitching = false
            routeChanged()  // the route may have been picked before the item was ready
        }
    }

    /// Shows the subtitle rendition marked default (the one mpv shows), or none.
    private func selectSubtitle(_ subtitle: Int32?, in item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), let stream else { return }
        // Renditions are listed in the order of the stream's subtitles.
        let option = stream.subtitles.firstIndex { $0.index == subtitle }.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
        item.select(option, in: group)
    }

    private func routeChanged() {
        guard !isSwitching else { return }
        let external = avPlayer.isExternalPlaybackActive && avPlayer.currentItem != nil
        if external, !isActive, let player {
            player.activeCast?.stop(resume: false)  // off the DLNA TV
            isActive = true
            let wasPaused = player.isPaused
            player.castDidStart()
            seek(to: player.position)
            if !wasPaused { avPlayer.play() }
        } else if !external, isActive {
            stop(resume: true)
        }
    }
}

/// The AirPlay button: AVKit's route picker, steering MacShow's AVPlayer.
struct AirPlayButton: NSViewRepresentable {
    let airPlay: AirPlay

    func makeCoordinator() -> Coordinator { Coordinator(airPlay: airPlay) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = airPlay.avPlayer
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.labelColor, for: .normal)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let airPlay: AirPlay
        init(airPlay: AirPlay) { self.airPlay = airPlay }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MainActor.assumeIsolated { airPlay.prepare() }
        }
    }
}
