import MacShowCore
import SwiftUI

/// The compact Now Playing window (Window › Mini Player).
struct MiniPlayerView: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var player = player
        VStack(spacing: 14) {
            ArtworkView(key: player.currentItem?.artworkKey, title: player.currentItem?.album ?? player.title, cornerRadius: 12)
                .frame(width: 300, height: 300)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                .padding(.top, 34)

            VStack(spacing: 3) {
                Text(player.currentItem?.title ?? (player.title.isEmpty ? "Not Playing" : player.title))
                    .font(.title3.weight(.bold)).lineLimit(1)
                Text([player.currentItem?.artist, player.currentItem?.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                    .controlSize(.small)
                HStack {
                    Text(Format.time(player.position))
                    Spacer()
                    Text("-" + Format.time(player.duration - player.position))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            TransportControls()

            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...100).controlSize(.small)
                if let badge = AlbumTile.badge(player.formatInfo) { FormatBadge(text: badge) }
                Button { openWindow(id: "main") } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help("Open Library")
            }
        }
        .disabled(!player.hasMedia)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 348)
        .background(.background)
    }
}

/// "Up Next": the play queue, with the current item highlighted.
struct QueueView: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next").font(.headline).padding(14)
            Divider()
            if player.queue.isEmpty {
                Text("Nothing queued.").foregroundStyle(.secondary).padding(14)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, item in
                            HStack(spacing: 10) {
                                ArtworkView(key: item.artworkKey, title: item.album ?? item.title, cornerRadius: 4)
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).fontWeight(offset == player.queueIndex ? .semibold : .regular).lineLimit(1)
                                    Text(item.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if offset == player.queueIndex {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                                }
                            }
                            .opacity(offset < (player.queueIndex ?? 0) ? 0.5 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { player.playQueueItem(at: offset) }
                            .contextMenu {
                                Button("Play") { player.playQueueItem(at: offset) }
                                Button("Remove from Queue") { player.removeFromQueue(at: offset) }
                                    .disabled(offset == player.queueIndex)
                            }
                            .id(offset)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear { proxy.scrollTo(player.queueIndex, anchor: .top) }
                }
            }
        }
        .frame(width: 340, height: 420)
    }
}
