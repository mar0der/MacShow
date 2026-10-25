import MacShowCore
import SwiftUI

/// Cover art from the artwork store, or a typographic tile in a colour derived
/// from the title when there is none (as in the design's album grid).
struct ArtworkView: View {
    let key: String?
    let title: String
    var cornerRadius: CGFloat = 8
    var aspectRatio: CGFloat = 1

    @Environment(Library.self) private var library
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    if abs(image.size.width / max(image.size.height, 1) - aspectRatio) > 0.4 {
                        // A tall poster in a wide tile: whole, over a blurred copy of itself.
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background { Image(nsImage: image).resizable().scaledToFill().blur(radius: 24).opacity(0.6) }
                    } else {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: key) {
                image = nil
                guard let key else { return }
                image = await ArtworkCache.shared.image(at: library.artwork.url(for: key))
            }
    }

    /// Artist photos are drawn as circles (a corner radius of 50 or more).
    private var isCircle: Bool { cornerRadius >= 50 }

    /// "Lamb of God" → "LG", "Eminem" → "E".
    private var initials: String {
        let words = title.split(separator: " ").filter { $0.first?.isLetter ?? false && $0.first!.isUppercase }
        return String((words.isEmpty ? [Substring(title)] : words).prefix(2).compactMap(\.first))
    }

    private var placeholder: some View {
        // A stable hash (String.hashValue changes every launch).
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Rectangle()
            .fill(Color(hue: hue, saturation: 0.45, brightness: 0.32))
            .overlay(alignment: isCircle ? .center : .bottomLeading) {
                Text(isCircle ? initials : title)
                    .font(.system(size: isCircle ? 34 : 18, weight: .heavy))
                    .foregroundStyle(Color(hue: hue, saturation: 0.25, brightness: 0.92))
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .padding(12)
            }
    }
}

/// Decoded artwork kept in memory, loaded off the main thread.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(at url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
