import MacShowCore
import SwiftUI

/// The floating now-playing bar at the bottom of the library window.
struct PlayerBar: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                ArtworkView(key: player.currentItem?.artworkKey, title: player.currentItem?.album ?? player.title, cornerRadius: 6)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentItem?.title ?? player.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 230, alignment: .leading)

            TransportControls()

            HStack(spacing: 10) {
                Text(Format.time(player.position)).monospacedDigit()
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                    .controlSize(.small)
                Text(Format.time(player.duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let badge = AlbumTile.badge(player.formatInfo) {
                FormatBadge(text: badge)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...100).controlSize(.small).frame(width: 90)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 18)
    }

    private var subtitle: String {
        guard let item = player.currentItem else { return player.formatInfo }
        if let chapter = player.chapterTitle, item.kind == .audiobook { return chapter }
        return [item.artist, item.album].compactMap { $0 }.joined(separator: " — ")
    }
}

/// Shuffle, previous, play/pause, next, repeat.
struct TransportControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 4) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help("Shuffle")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .help("Previous")
            Button { player.togglePause() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .help(player.isPaused ? "Play" : "Pause")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .help("Next")
            Button {
                let modes = Player.Repeat.allCases
                player.repeatMode = modes[(modes.firstIndex(of: player.repeatMode)! + 1) % modes.count]
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help("Repeat")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}
