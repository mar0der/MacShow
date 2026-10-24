import AppKit
import MacShowCore
import MediaPlayer

/// Publishes what's playing to Control Center / the menu bar Now Playing widget
/// and routes the keyboard's media keys back to the player.
@MainActor
final class NowPlaying {
    private weak var player: Player?
    private let artwork: ArtworkStore
    private var artworkKey: String?
    private var artworkImage: MPMediaItemArtwork?

    init(player: Player, artwork: ArtworkStore) {
        self.player = player
        self.artwork = artwork
        let commands = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player, MPRemoteCommandEvent) -> Void) {
            command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let player = self?.player, player.hasMedia else { return .noActionableNowPlayingItem }
                    action(player, event)
                    return .success
                }
            }
        }
        handle(commands.togglePlayPauseCommand) { player, _ in player.togglePause() }
        handle(commands.playCommand) { player, _ in if player.isPaused { player.togglePause() } }
        handle(commands.pauseCommand) { player, _ in if !player.isPaused { player.togglePause() } }
        // In an audiobook, next/previous move by chapter.
        handle(commands.nextTrackCommand) { player, _ in
            player.currentItem?.kind == .audiobook ? player.nextChapter() : player.next()
        }
        handle(commands.previousTrackCommand) { player, _ in
            player.currentItem?.kind == .audiobook ? player.previousChapter() : player.previous()
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [30]
        handle(commands.skipBackwardCommand) { player, _ in player.skip(-15) }
        handle(commands.skipForwardCommand) { player, _ in player.skip(30) }
        handle(commands.changePlaybackPositionCommand) { player, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(to: event.positionTime) }
        }
    }

    /// Call when the item, play state, duration or position (after a seek) changes.
    func update() {
        guard let player, player.hasMedia else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        let item = player.currentItem
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item?.title ?? player.title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0.0 : player.speed,
            MPNowPlayingInfoPropertyMediaType: (player.isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue,
        ]
        if let artist = item?.artist ?? item?.show { info[MPMediaItemPropertyArtist] = artist }
        if let album = item?.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork = artwork(for: item?.artworkKey) { info[MPMediaItemPropertyArtwork] = artwork }
        // 15 s / 30 s skip buttons only make sense for audiobooks.
        let isBook = item?.kind == .audiobook
        MPRemoteCommandCenter.shared().skipBackwardCommand.isEnabled = isBook
        MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled = isBook
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.isPaused ? .paused : .playing
    }

    private func artwork(for key: String?) -> MPMediaItemArtwork? {
        if key != artworkKey {
            artworkKey = key
            artworkImage = key.flatMap { NSImage(contentsOf: artwork.url(for: $0)) }.map { image in
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        return artworkImage
    }
}
