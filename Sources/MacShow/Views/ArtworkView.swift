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
                    Image(nsImage: image).resizable().scaledToFill()
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

    private var placeholder: some View {
        // A stable hash (String.hashValue changes every launch).
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Rectangle()
            .fill(Color(hue: hue, saturation: 0.45, brightness: 0.32))
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.system(size: 18, weight: .heavy))
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
