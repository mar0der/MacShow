import Foundation

/// A 10-band graphic equalizer, as gains in dB per band.
public struct Equalizer: Codable, Hashable, Sendable {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let range: ClosedRange<Double> = -12...12

    public var gains: [Double]

    public init(gains: [Double] = Array(repeating: 0, count: Equalizer.frequencies.count)) {
        self.gains = gains
    }

    public static let presets: [(name: String, equalizer: Equalizer)] = [
        ("Flat", Equalizer()),
        ("Bass Booster", Equalizer(gains: [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0])),
        ("Bass Reducer", Equalizer(gains: [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0])),
        ("Treble Booster", Equalizer(gains: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6])),
        ("Vocal Booster", Equalizer(gains: [-2, -3, -3, 1, 4, 4, 3, 1, 0, -2])),
        ("Loudness", Equalizer(gains: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1])),
        ("Rock", Equalizer(gains: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5])),
        ("Electronic", Equalizer(gains: [4.5, 4, 1.5, 0, -2, 2, 1, 1.5, 4, 5])),
        ("Spoken Word", Equalizer(gains: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 4.5, 4, 2.5, 0])),
    ]

    public var isFlat: Bool { gains.allSatisfy { $0 == 0 } }

    /// mpv's audio filter for these gains: one peaking band per frequency, after
    /// turning the signal down by the largest boost so boosted bands don't clip.
    /// Nil when flat (no filter at all).
    public var mpvFilter: String? {
        guard !isFlat else { return nil }
        var filters: [String] = []
        if let boost = gains.max(), boost > 0 { filters.append("volume=-\(Self.format(boost))dB") }
        for (frequency, gain) in zip(Self.frequencies, gains) where gain != 0 {
            filters.append("equalizer=f=\(Self.format(frequency)):t=o:w=1:g=\(Self.format(gain))")
        }
        return "lavfi=[\(filters.joined(separator: ","))]"
    }

    private static func format(_ value: Double) -> String { String(format: "%g", value) }
}
