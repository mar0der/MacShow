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
    
    /// Caches source detection results per mount point to avoid repeated filesystem
    /// queries. Thread-safe for concurrent reads during library indexing.
    final class SourceCache: @unchecked Sendable {
    private var cache: [String: String?] = [:]
    private let lock = NSLock()
    
    /// Returns the source for a path, caching by actual mount point for performance.
    func source(for path: String) -> String? {
        // Quick check: /Volumes/<name>/ paths (most common network share layout).
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" {
            return String(parts[1])
        }
        
        // Get the actual mount point via statfs (fast, single syscall).
        let mountPoint = Self.getMountPoint(for: path)
        
        // Check cache by actual mount point (not path prefix).
        if let cached = lock.withLock({ cache[mountPoint] }) {
            return cached
        }
        
        // Query the filesystem for source information.
        let detected = Self.detectSource(for: path, mountPoint: mountPoint)
        
        // Cache by the actual mount point only.
        lock.withLock {
            cache[mountPoint] = detected
        }
        
        return detected
    }
    
    /// Gets the mount point for a path using statfs.
    private static func getMountPoint(for path: String) -> String {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else {
            return "/"
        }
        return withUnsafeBytes(of: stat.f_mntonname) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
    }
    
    /// Detects the source for a path given its mount point.
    private static func detectSource(for path: String, mountPoint: String) -> String? {
        // Root filesystem is always "this Mac".
        guard mountPoint != "/" else {
            return nil
        }
        
        // /Volumes/<name>: always return just the volume name for backward compatibility
        // with saved hiddenSources, regardless of filesystem type.
        let mountParts = mountPoint.split(separator: "/", omittingEmptySubsequences: true)
        if mountParts.count >= 2, mountParts[0] == "Volumes" {
            return String(mountParts[1])
        }
        
        // Check filesystem type to distinguish network shares from internal volumes.
        var stat = statfs()
        guard statfs(path, &stat) == 0 else {
            return nil
        }
        
        let fsType = withUnsafeBytes(of: stat.f_fstypename) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        
        let fromName = withUnsafeBytes(of: stat.f_mntfromname) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        
        return detectSourceWithFsType(mountPoint: mountPoint, fsType: fsType, fromName: fromName)
    }
    
    /// Detects the source given mount info. Separated for testability.
    private static func detectSourceWithFsType(mountPoint: String, fsType: String, fromName: String) -> String? {
        // Network filesystems (not under /Volumes/) are sources.
        let networkTypes = ["smbfs", "nfs", "afpfs", "webdav", "cifs", "acfs"]
        if networkTypes.contains(fsType) {
            return sourceNameFromMount(mountPoint: mountPoint, fromName: fromName)
        }
        
        // Internal APFS volumes (like /System/Volumes/Data) are "this Mac".
        return nil
    }
    
    /// Derives a human-readable source name from a volume name and remount URL.
    private static func sourceNameFromVolume(_ volumeName: String, remountURL: URL?) -> String {
        guard let remountURL,
              let host = remountURL.host else {
            return volumeName
        }
        
        // For SMB/AFP/NFS: show "sharename@host" or "sharename on hostname".
        let shortHost = shortHostname(host)
        let shareName = remountURL.lastPathComponent
        
        if !shareName.isEmpty, shareName.lowercased() != volumeName.lowercased() {
            return "\(shareName)@\(shortHost)"
        }
        return "\(volumeName)@\(shortHost)"
    }
    
    /// Shortens hostnames but keeps IP addresses intact.
    /// "dspeter.taild48c09.ts.net" → "dspeter", "192.168.0.202" → "192.168.0.202"
    private static func shortHostname(_ host: String) -> String {
        let components = host.split(separator: ".")
        
        // Check if this looks like an IPv4 address (all components are numeric).
        let isIPv4 = components.count == 4 && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }
        
        if isIPv4 {
            return host // Keep IP addresses intact
        }
        
        // For hostnames, return the first component.
        return components.first.map(String.init) ?? host
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
                    return "\(share)@\(shortHostname(server))"
                }
            }
            
            // NFS: server:/path -> "path@server"
            if let colonIndex = fromName.firstIndex(of: ":") {
                let server = String(fromName[..<colonIndex])
                let sharePath = String(fromName[fromName.index(after: colonIndex)...])
                let shareName = sharePath.split(separator: "/").last.map(String.init) ?? sharePath
                return "\(shareName)@\(shortHostname(server))"
            }
        }
        
        // For other mounts: use the last component of the mount point.
        if let lastComponent = mountPoint.split(separator: "/").last {
            return String(lastComponent)
        }
        
        return mountPoint
    }
    
    // MARK: - Test Helpers
    
    #if DEBUG
    /// Exposed for testing: derives source from mount info with injected filesystem type.
    /// Allows tests to verify network share parsing without depending on real filesystem state.
    static func testDetectSource(mountPoint: String, fsType: String, fromName: String) -> String? {
        // Root filesystem is always "this Mac".
        guard mountPoint != "/" else {
            return nil
        }
        
        // /Volumes/<name>: always return just the volume name.
        let mountParts = mountPoint.split(separator: "/", omittingEmptySubsequences: true)
        if mountParts.count >= 2, mountParts[0] == "Volumes" {
            return String(mountParts[1])
        }
        
        return detectSourceWithFsType(mountPoint: mountPoint, fsType: fsType, fromName: fromName)
    }
    
    /// Exposed for testing: shortens hostnames but keeps IPs intact.
    static func testShortHostname(_ host: String) -> String {
        shortHostname(host)
    }
    #endif
    }
}

extension MediaItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mediaItem"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
