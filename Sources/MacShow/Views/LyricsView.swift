import MacShowCore
import SwiftUI

/// The playing song's lyrics, beside the library: the line being sung is
/// highlighted and kept in view; click a line to jump there.
struct LyricsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var lyrics: Lyrics?
    @State private var loading = false

    var body: some View {
        let item = player.currentItem
        Group {
            if let item, item.isMusic {
                if let lyrics, !lyrics.lines.isEmpty {
                    lines(lyrics)
                } else {
                    ContentUnavailableView(loading ? "Looking for Lyrics…" : lyrics?.isInstrumental == true ? "Instrumental" : "No Lyrics",
                                           systemImage: "quote.bubble",
                                           description: Text(loading ? "" : "Add an .lrc file named like the song next to it, or turn on looking them up online in Settings › Library."))
                }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "quote.bubble")
            }
        }
        .frame(minWidth: 260)
        .task(id: item?.path) {
            lyrics = nil
            guard let item, item.isMusic else { return }
            loading = true
            lyrics = await library.lyrics(for: item)
            loading = false
        }
    }

    private func lines(_ lyrics: Lyrics) -> some View {
        let current = lyrics.lineIndex(at: player.position)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: lyrics.isSynced ? 14 : 4) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(lyrics.isSynced ? .title3.weight(.semibold) : .body)
                            .foregroundStyle(!lyrics.isSynced || index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { if let time = line.time { player.seek(to: time) } }
                            .id(index)
                    }
                    Text(lyrics.source == "LRCLIB" ? "Lyrics from LRCLIB" : "").font(.caption2).foregroundStyle(.tertiary).padding(.top, 20)
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.2), value: current)
            }
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}
