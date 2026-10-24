import SwiftUI

struct ContentView: View {
    let player: Player

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoView(layer: player.layer)

            if !player.hasPicture {
                VStack(spacing: 10) {
                    Image(systemName: player.duration > 0 ? "waveform" : "play.rectangle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(player.duration > 0 ? player.title : "Open a file with ⌘O")
                        .font(.title2.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if player.duration > 0 {
                ControlBar(player: player)
                    .padding(16)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .frame(minWidth: 720, minHeight: 440)
    }
}

private struct ControlBar: View {
    @Bindable var player: Player

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button { player.togglePause() } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 22)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
            }
            .buttonStyle(.borderless)
            .font(.title2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(player.title).fontWeight(.semibold).lineLimit(1)
                    if let chapter = player.chapterTitle {
                        Text(chapter).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(player.formatInfo).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(Self.time(player.position))
                    Slider(
                        value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                        in: 0...max(player.duration, 1)
                    )
                    Text("-" + Self.time(player.duration - player.position))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...100).frame(width: 90)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
