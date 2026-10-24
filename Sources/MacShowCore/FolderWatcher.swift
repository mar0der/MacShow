import CoreServices
import Foundation

/// Reports folders whose contents changed under the watched paths, batched by
/// `latency` seconds (macOS FSEvents).
public final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "MacShow.FolderWatcher")

    public init(paths: [String], latency: TimeInterval = 2, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(changed)
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
