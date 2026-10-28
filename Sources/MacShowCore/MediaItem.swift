import Foundation
import GRDB

/// One playable file in the library.
public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case music, movie, episode, audiobook
        /// Set by the library (short videos, Personal, Sports and Documentaries folders)
        /// or by you, never by the scanner.
        case homeVideo, musicVideo, sport, documentary
    }

    public var id: Int64?
    public var path: String
    public var kind: Kind
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var show: String?
    public var season: Int?
    public var episode: Int?
    public var chapterCount: Int
    public var isProtected: Bool
    public var formatInfo: String
    public var artworkKey: String?
    public var fileSize: Int64
    public var modified: Double
    public var addedAt: Date

    /// Saying it's a file keeps Foundation from asking the disk, which on a network
    /// share is a round trip each time (and the index sorts by `url` parts).
    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }

    /// Songs and music videos: no resume points, and they sit in Songs.
    public var isMusic: Bool { kind == .music || kind == .musicVideo }

    /// Movies, episodes, home videos and music videos.
    public var isVideo: Bool { [.movie, .episode, .homeVideo, .musicVideo, .sport, .documentary].contains(kind) }

    /// The drive or network share the file is on ("Media", "media@192.168.0.202"),
    /// or nil for this Mac's own disk (the root filesystem).
    public var source: String? {
        MediaItem.sourceCache.source(for: path)
    }
    
    /// Derives the source for a path by checking its mount point. Cached per path
    /// prefix to avoid repeated filesystem queries in hot paths.
    nonisolated(unsafe) private static let sourceCache = SourceCache()

    /// The name albums are grouped and listed under.
    public var albumArtistOrArtist: String { albumArtist ?? artist ?? "Unknown Artist" }
}

extension MediaItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mediaItem"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Caches source detection results per mount point to avoid repeated filesystem
/// queries. Thread-safe for concurrent reads during library indexing.
private final class SourceCache: @unchecked Sendable {
    private struct CacheEntry {
        let mountPoint: String
        let source: String?
    }
    
    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    
    /// Returns the source for a path, caching by mount point for performance.
    func source(for path: String) -> String? {
        // Quick check: /Volumes/<name>/ paths (most common network share layout).
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" {
            return String(parts[1])
        }
        
        // Check cache first, keyed by a path prefix likely to share a mount point.
        let prefix = parts.count >= 2 ? "/\(parts[0])/\(parts[1])" : path
        if let cached = lock.withLock({ cache[prefix] }) {
            return cached.source
        }
        
        // Query the filesystem for mount point and whether it's a network volume.
        let detected = Self.detectSource(for: path)
        
        // Cache under both the detected mount point and our prefix guess.
        lock.withLock {
            let entry = CacheEntry(mountPoint: detected.mountPoint, source: detected.source)
            cache[detected.mountPoint] = entry
            if detected.mountPoint != prefix {
                cache[prefix] = entry
            }
        }
        
        return detected.source
    }
    
    /// Detects the source and mount point for a path by querying the filesystem.
    private static func detectSource(for path: String) -> (mountPoint: String, source: String?) {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        
        // Try getting volume information from URL resource values.
        if let values = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeNameKey]),
           let volumeName = values.volumeName,
           values.volumeURLForRemounting != nil {
            // This is a network share: use volume name plus any useful network info.
            let source = sourceNameFromVolume(volumeName, remountURL: values.volumeURLForRemounting)
            return (mountPoint: mountPointFromPath(path), source: source)
        }
        
        // Fall back to statfs to detect any non-root mount point.
        var stat = statfs()
        guard statfs(path, &stat) == 0 else {
            return (mountPoint: "/", source: nil)
        }
        
        let mountPoint = withUnsafeBytes(of: stat.f_mntonname) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        
        // Root filesystem is "this Mac"; everything else is its own source.
        guard mountPoint != "/" else {
            return (mountPoint: "/", source: nil)
        }
        
        // Non-root mount: derive a source name from the mount point.
        let volumeName = withUnsafeBytes(of: stat.f_mntfromname) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        
        let source = sourceNameFromMount(mountPoint: mountPoint, fromName: volumeName)
        return (mountPoint: mountPoint, source: source)
    }
    
    /// Derives a human-readable source name from a volume name and remount URL.
    private static func sourceNameFromVolume(_ volumeName: String, remountURL: URL?) -> String {
        guard let remountURL,
              let host = remountURL.host else {
            return volumeName
        }
        
        // For SMB/AFP/NFS: show "sharename@host" or "sharename on hostname".
        let shortHost = host.split(separator: ".").first.map(String.init) ?? host
        let shareName = remountURL.lastPathComponent
        
        if !shareName.isEmpty, shareName.lowercased() != volumeName.lowercased() {
            return "\(shareName)@\(shortHost)"
        }
        return "\(volumeName)@\(shortHost)"
    }
    
    /// Derives a source name from a mount point and the device/network path.
    private static func sourceNameFromMount(mountPoint: String, fromName: String) -> String {
        // For /Volumes/<name>: return the name.
        let mountParts = mountPoint.split(separator: "/", omittingEmptySubsequences: true)
        if mountParts.count >= 2, mountParts[0] == "Volumes" {
            return String(mountParts[1])
        }
        
        // For network mounts (//server/share, server:/path): extract meaningful info.
        if fromName.hasPrefix("//") || fromName.contains(":/") {
            // SMB: //server/share -> "share@server"
            if fromName.hasPrefix("//") {
                let components = fromName.dropFirst(2).split(separator: "/", maxSplits: 2)
                if components.count >= 2 {
                    let server = String(components[0])
                    let share = String(components[1])
                    let shortServer = server.split(separator: ".").first.map(String.init) ?? server
                    return "\(share)@\(shortServer)"
                }
            }
            
            // NFS: server:/path -> "path@server"
            if let colonIndex = fromName.firstIndex(of: ":") {
                let server = String(fromName[..<colonIndex])
                let sharePath = String(fromName[fromName.index(after: colonIndex)...])
                let shareName = sharePath.split(separator: "/").last.map(String.init) ?? sharePath
                let shortServer = server.split(separator: ".").first.map(String.init) ?? server
                return "\(shareName)@\(shortServer)"
            }
        }
        
        // For other mounts: use the last component of the mount point.
        if let lastComponent = mountPoint.split(separator: "/").last {
            return String(lastComponent)
        }
        
        return mountPoint
    }
    
    /// Extracts the likely mount point from a path for cache keying.
    private static func mountPointFromPath(_ path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: true)
        if parts.count >= 2 {
            if parts[0] == "Volumes" {
                return "/\(parts[0])/\(parts[1])"
            }
            // For /Users/<user>/something, it's likely /
            if parts[0] == "Users" {
                return "/"
            }
        }
        return "/"
    }
}
