import SwiftUI

extension View {
    /// Liquid Glass on macOS 26+, a material on older systems.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.08)))
        }
    }
}

enum Format {
    /// 75 → "1:15", 3725 → "1:02:05".
    static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds.isFinite ? seconds : 0, 0))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 37_000 → "10 h 16 min", 900 → "15 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(minutes, 1)) min"
    }
}

/// Small uppercase format badge, e.g. "FLAC 96 kHz".
struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.5)))
    }
}
