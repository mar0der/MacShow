import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cover-art thumbnails on disk, named by a hash of the original image so an
/// album's tracks share one file.
public struct ArtworkStore: Sendable {
    public let directory: URL
    static let maxPixelSize = 800

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for key: String) -> URL {
        directory.appendingPathComponent(key + ".jpg")
    }

    /// Saves a thumbnail of `imageData` if it isn't stored yet; returns its key,
    /// or nil if the data isn't a readable image.
    public func store(_ imageData: Data) -> String? {
        let key = SHA256.hash(data: imageData).prefix(12).map { String(format: "%02x", $0) }.joined()
        let destination = url(for: key)
        if FileManager.default.fileExists(atPath: destination.path) { return key }
        let temporary = directory.appendingPathComponent(".\(key)-\(UUID().uuidString).jpg")

        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
              ] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(output, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        // Written aside and renamed into place, so a reader never sees half a file.
        guard CGImageDestinationFinalize(output), rename(temporary.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        return key
    }

    /// A cover image file next to the media ("cover.jpg", "folder.png", …).
    static func folderImage(in directory: URL) -> Data? {
        let names = ["cover", "folder", "front", "album", "poster"]
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let match = files.first { file in
            let url = URL(fileURLWithPath: file)
            return ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased())
                && names.contains(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        return match.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
    }
}
