import MacShowCore
import SwiftUI

extension View {
    /// Adds the floating player bar under a library page while audio is playing.
    /// (Applied per page: on a NavigationStack itself the inset isn't drawn.)
    func withPlayerBar() -> some View { modifier(PlayerBarInset()) }
}

private struct PlayerBarInset: ViewModifier {
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if player.hasMedia, !player.isVideo {
                PlayerBar().padding(.horizontal, 20).padding(.bottom, 14)
            }
        }
    }
}

/// The floating now-playing bar at the bottom of the library window.
struct PlayerBar: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow
    @State private var showsQueue = false
    @AppStorage("showsLyrics") private var showsLyrics = false

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Button { openWindow(id: "mini") } label: {
                    ArtworkView(key: player.currentItem?.artworkKey, title: player.currentItem?.album ?? player.title, cornerRadius: 6)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .help("Open Mini Player")
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

            if player.currentItem?.isMusic == true {
                Button { showsLyrics.toggle() } label: {
                    Label("Lyrics", systemImage: showsLyrics ? "quote.bubble.fill" : "quote.bubble").labelStyle(.iconOnly)
                }
                    .buttonStyle(.borderless)
                    .imageScale(.large)
                    .help(showsLyrics ? "Hide Lyrics" : "Lyrics")
            }
            Button { showsQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.borderless)
                .imageScale(.large)
                .help("Up Next")
                .popover(isPresented: $showsQueue, arrowEdge: .top) { QueueView() }
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

/// Previous chapter, back 15 s, play/pause, forward 30 s, next chapter.
struct BookTransportControls: View {
    var large = false
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: large ? 18 : 4) {
            Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous Chapter")
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .help("Back 15 Seconds")
            Button { player.togglePause() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(large ? .title : .title3)
                    .foregroundStyle(large ? Color.white : Color.primary)
                    .frame(width: large ? 60 : 36, height: large ? 60 : 36)
                    .background(large ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.1)), in: Circle())
            }
            .help(player.isPaused ? "Play" : "Pause")
            Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
                .help("Forward 30 Seconds")
            Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                .help("Next Chapter")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .font(large ? .title2 : .body)
    }
}

/// Shuffle, previous, play/pause, next, repeat.
struct TransportControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        if player.currentItem?.kind == .audiobook {
            BookTransportControls()
        } else {
            musicControls
        }
    }

    private var musicControls: some View {
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
