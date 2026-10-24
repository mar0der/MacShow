import Foundation

extension URL {
    /// The path with symlinks resolved the way the file system reports it
    /// ("/private/var/…", not "/var/…"), so folder listings, FSEvents and the
    /// database all spell a file the same way. Unchanged if the file doesn't exist.
    public var canonicalPath: String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
