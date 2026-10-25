import MacShowCore
import SwiftUI

/// The menu bar panel: what's playing and the controls, without the window.
struct MenuBarPlayer: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var player = player
        VStack(spacing: 12) {
            if player.hasMedia {
                HStack(spacing: 12) {
                    ArtworkView(key: player.currentItem?.artworkKey, title: player.currentItem?.album ?? player.title, cornerRadius: 8)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentItem?.title ?? player.title).font(.headline).lineLimit(2)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                        .controlSize(.small)
                    HStack {
                        Text(Format.time(player.position))
                        Spacer()
                        Text("-" + Format.time(player.duration - player.position))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                TransportControls()
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $player.volume, in: 0...100).controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing Playing").font(.headline).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            Divider()
            HStack {
                Button("Open MacShow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var subtitle: String {
        guard let item = player.currentItem else { return "" }
        if item.kind == .episode, let show = item.show { return "\(show) · S\(item.season ?? 0) E\(item.episode ?? 0)" }
        return [item.artist, item.album].compactMap { $0 }.joined(separator: " — ")
    }
}
