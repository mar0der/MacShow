import MacShowCore
import SwiftUI

/// Window › Equalizer: ten bands, presets, and an optional setting kept for the playing album.
struct EqualizerView: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        let albumKey = Player.albumKey(player.currentItem)
        let forAlbum = albumKey.map { player.albumEqualizers[$0] != nil } ?? false
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle("On", isOn: $player.equalizerOn).toggleStyle(.switch)
                Spacer()
                Menu(presetName(player.activeEqualizer)) {
                    ForEach(Equalizer.presets, id: \.name) { preset in
                        Button(preset.name) { set(preset.equalizer) }
                    }
                }
                .fixedSize()
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                    VStack(spacing: 6) {
                        Text(String(format: "%+.0f", player.activeEqualizer.gains[band])).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        BandSlider(value: Binding(get: { player.activeEqualizer.gains[band] }, set: { gain in
                            var equalizer = player.activeEqualizer
                            equalizer.gains[band] = gain
                            set(equalizer)
                        }))
                        .accessibilityLabel(Self.label(Equalizer.frequencies[band]) + " Hz")
                        Text(Self.label(Equalizer.frequencies[band])).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!player.equalizerOn)
            Toggle("Use this setting only for “\(player.currentItem?.album ?? "this album")”", isOn: Binding(get: { forAlbum }, set: { on in
                guard let albumKey else { return }
                player.albumEqualizers[albumKey] = on ? player.equalizer : nil
            }))
            .disabled(albumKey == nil)
            Text("Changes the sound, so output is no longer bit-perfect while it's on.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .fixedSize()
    }

    /// Edits the album's own setting when it has one, else the usual one.
    private func set(_ equalizer: Equalizer) {
        if let key = Player.albumKey(player.currentItem), player.albumEqualizers[key] != nil {
            player.albumEqualizers[key] = equalizer
        } else {
            player.equalizer = equalizer
        }
    }

    private func presetName(_ equalizer: Equalizer) -> String {
        Equalizer.presets.first { $0.equalizer == equalizer }?.name ?? "Custom"
    }

    private static func label(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))K" : "\(Int(frequency))"
    }
}

/// A vertical slider for one band, in whole dB (a rotated Slider doesn't draw on macOS).
private struct BandSlider: View {
    @Binding var value: Double
    private let range = Equalizer.range

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let span = range.upperBound - range.lowerBound
            let y = height * (1 - (value - range.lowerBound) / span)
            let zero = height * (1 - (0 - range.lowerBound) / span)
            ZStack(alignment: .top) {
                Capsule().fill(.quaternary).frame(width: 4)
                Capsule().fill(.tint).frame(width: 4, height: abs(y - zero)).offset(y: min(y, zero))
                Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1).offset(y: y - 7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fraction = 1 - min(max(drag.location.y / height, 0), 1)
                value = (range.lowerBound + fraction * span).rounded()
            })
        }
        .frame(width: 34, height: 150)
        .accessibilityRepresentation { Slider(value: $value, in: range, step: 1) }
    }
}
