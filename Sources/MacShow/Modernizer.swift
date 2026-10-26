import AppKit
import MacShowCore
import os

/// Converts old videos to HEVC in the background (Settings › Modernize), one at a
/// time, on this Mac. A file on a network share waits while you watch something
/// from that share or the library scans it, so playback never has to share the
/// connection. The result goes next to the original; the original leaves the
/// library but stays on disk until you remove it.
@MainActor @Observable
final class Modernizer {
    private(set) var queue: [Modernize.Candidate] = []
    private(set) var current: Modernize.Candidate?
    private(set) var progress = 0.0
    /// Why the current conversion is waiting, if it is.
    private(set) var waitingReason: String?
    var isPausedByUser = false
    /// Converted; copying the new file next to the original and adding it to the library.
    private(set) var isSaving = false
    /// Seconds of conversion so far (waiting doesn't count), for the time left.
    private(set) var activeSeconds = 0.0
    private(set) var failures: [String: String] = [:]
    /// Originals of finished conversions, still on disk.
    private(set) var keptOriginals: [String] = UserDefaults.standard.stringArray(forKey: "modernizeKeptOriginals") ?? []
    /// Converted once without saving space: not offered again.
    private(set) var skipped = Set(UserDefaults.standard.stringArray(forKey: "modernizeSkipped") ?? []) {
        didSet { UserDefaults.standard.set(Array(skipped), forKey: "modernizeSkipped") }
    }
    /// Folders MacShow may write in (checked with a test file).
    private(set) var writable: [String: Bool] = [:]

    private let library: Library
    private let player: Player
    private let flags = Flags()
    private var networkVolume: String?

    init(library: Library, player: Player) {
        self.library = library
        self.player = player
        // Pick up what was queued before quitting, once the library has loaded.
        Task {
            let ids = UserDefaults.standard.stringArray(forKey: "modernizeQueue") ?? []
            guard !ids.isEmpty else { return }
            for _ in 0..<120 where library.index.itemsByID.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            let candidates = library.modernizeCandidates
            add(ids.compactMap { id in candidates.first { $0.id == id } })
        }
    }

    // MARK: Estimates

    /// Seconds of video converted a second (measured on files on this Mac).
    private var encodeSpeed: Double { UserDefaults.standard.object(forKey: "modernizeEncodeSpeed") as? Double ?? 30 }
    /// Bytes a second read and written for files on a network share.
    private var networkRate: Double { UserDefaults.standard.object(forKey: "modernizeNetworkRate") as? Double ?? 2_000_000 }

    func isOnNetwork(_ candidate: Modernize.Candidate) -> Bool {
        library.watchedFolder(containing: candidate.items[0].path)?.isOnNetworkShare ?? false
    }

    /// About how long a conversion takes, in seconds: the encoder's speed, or for a
    /// file on a network share, reading it and writing the new one back if slower.
    func estimate(_ candidate: Modernize.Candidate) -> Double {
        let encoding = candidate.duration / encodeSpeed
        guard isOnNetwork(candidate) else { return encoding }
        return max(encoding, Double(candidate.size + candidate.estimatedSize) / networkRate)
    }

    /// Time left for the current conversion.
    var remaining: Double? {
        guard let current else { return nil }
        if progress > 0.02 { return activeSeconds / progress * (1 - progress) }
        return estimate(current)
    }

    // MARK: Write access

    func destinationFolder(_ candidate: Modernize.Candidate) -> String {
        candidate.items[0].url.deletingLastPathComponent().path
    }

    /// Queues `candidates` where MacShow may write next to them, first asking for
    /// write access to their watched folders where it can't yet.
    func convert(_ candidates: [Modernize.Candidate]) async {
        await probe(candidates)
        let blocked = candidates.filter { writable[destinationFolder($0)] != true }
        let folders = Set(blocked.compactMap { library.watchedFolder(containing: $0.items[0].path) })
        for folder in folders.sorted(by: { $0.path < $1.path }) where askForWriteAccess(to: folder) {
            writable = writable.filter { !$0.key.hasPrefix(folder.path + "/") }
        }
        await probe(blocked)
        for candidate in candidates where writable[destinationFolder(candidate)] != true {
            failures[candidate.id] = isOnNetwork(candidate)
                ? String(localized: "The server lets MacShow only read here. Let the account it connects with write in this shared folder (on a Synology: Control Panel › Shared Folder › Edit › Permissions), then try again.")
                : String(localized: "MacShow can't write in this folder.")
        }
        add(candidates.filter { writable[destinationFolder($0)] == true })
    }

    /// Tries a test file in each folder not checked yet.
    private func probe(_ candidates: [Modernize.Candidate]) async {
        let folders = Set(candidates.map(destinationFolder)).filter { writable[$0] != true }
        let results = await Task.detached {
            folders.map { ($0, Library.canWrite(in: URL(fileURLWithPath: $0, isDirectory: true))) }
        }.value
        for (folder, ok) in results { writable[folder] = ok }
    }

    private func askForWriteAccess(to folder: WatchedFolder) -> Bool {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: folder.path, isDirectory: true)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Allow Writing")
        panel.message = String(localized: "MacShow writes converted videos next to the originals. Choose “\(URL(fileURLWithPath: folder.path).lastPathComponent)” to let it write there.")
        guard panel.runModal() == .OK, let url = panel.url, url.canonicalPath == URL(fileURLWithPath: folder.path).canonicalPath else { return false }
        library.allowWriting(to: folder, url: url)
        return true
    }

    // MARK: Queue

    func add(_ candidates: [Modernize.Candidate]) {
        let busy = Set(queue.map(\.id) + [current?.id].compactMap { $0 })
        queue += candidates.filter { !busy.contains($0.id) }
        candidates.forEach { failures[$0.id] = nil }
        saveQueue()
        startNext()
    }

    func remove(_ candidate: Modernize.Candidate) {
        queue.removeAll { $0.id == candidate.id }
        saveQueue()
    }

    func cancelCurrent() {
        flags.set(cancelled: true)
    }

    /// Still worth showing: not tried in vain before (unless it just was, to say so).
    func isOffered(_ candidate: Modernize.Candidate) -> Bool {
        !skipped.contains(candidate.id) || failures[candidate.id] != nil
    }

    func isQueued(_ candidate: Modernize.Candidate) -> Bool {
        current?.id == candidate.id || queue.contains { $0.id == candidate.id }
    }

    private func saveQueue() {
        UserDefaults.standard.set(([current] + queue).compactMap { $0?.id }, forKey: "modernizeQueue")
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let candidate = queue.removeFirst()
        current = candidate
        progress = 0
        activeSeconds = 0
        flags.set(cancelled: false)
        let first = candidate.items[0].path
        networkVolume = isOnNetwork(candidate) ? first.split(separator: "/").prefix(2).map { "/" + $0 }.joined() : nil
        saveQueue()
        Task { await run(candidate) }
    }

    /// Waits while you watch from the same share, the library scans it, or you paused.
    private func updateWaiting() {
        if isPausedByUser {
            waitingReason = String(localized: "Paused")
        } else if let volume = networkVolume, !player.isPaused, player.currentItem?.path.hasPrefix(volume + "/") == true {
            waitingReason = String(localized: "Waiting while you watch from the same server")
        } else if let volume = networkVolume, library.isScanning, library.scanningFolder?.hasPrefix(volume) == true {
            waitingReason = String(localized: "Waiting for the library scan")
        } else {
            waitingReason = nil
        }
        flags.set(paused: waitingReason != nil)
    }

    private func run(_ candidate: Modernize.Candidate) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Converting a video")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let temp = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modernize", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        // Written here first: finishing an MP4 rewrites it, which over a network would be twice the traffic.
        let local = temp.appendingPathComponent(UUID().uuidString + ".mp4")
        let output = Self.output(for: candidate)
        let flags = flags
        let monitor = Task {
            while !Task.isCancelled {
                updateWaiting()
                if waitingReason == nil { activeSeconds += 1 }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let result = await Task.detached(priority: .utility) {
            Result {
                var last = 0.0
                try VideoConverter.convert(candidate.items.map(\.url), to: local, videoBitrate: candidate.videoBitrate,
                                           shouldPause: { flags.paused }, isCancelled: { flags.cancelled }) { value in
                    guard value - last > 0.002 else { return }
                    last = value
                    Task { @MainActor in self.progress = value }
                }
                // The estimate can't know about extra audio tracks: a file that hardly shrinks stays as it was.
                let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if !candidate.joinsParts, size * 10 > candidate.size * 9 { throw Modernizer.NoSaving() }
                // Copying back waits like the conversion does.
                while flags.paused, !flags.cancelled { Thread.sleep(forTimeInterval: 1) }
                Task { @MainActor in self.isSaving = true }
                try FileManager.default.moveItem(at: local, to: output)
            }
        }.value
        monitor.cancel()
        waitingReason = nil
        switch result {
        case .success:
            let converted = await library.adoptConversion(of: candidate.items, output: output)
            if converted == nil { failures[candidate.id] = String(localized: "Converted, but the new file didn't appear in the library.") }
            keptOriginals += candidate.items.map(\.path)
            UserDefaults.standard.set(keptOriginals, forKey: "modernizeKeptOriginals")
            if activeSeconds > 30 {
                if networkVolume != nil {
                    let bytes = Double(candidate.size) + Double((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    UserDefaults.standard.set(bytes / activeSeconds, forKey: "modernizeNetworkRate")
                } else {
                    UserDefaults.standard.set(candidate.duration / activeSeconds, forKey: "modernizeEncodeSpeed")
                }
            }
        case .failure(let error):
            try? FileManager.default.removeItem(at: local)
            if error as? VideoConverter.Failure != .cancelled { failures[candidate.id] = Self.describe(error) }
            if error is NoSaving { skipped.insert(candidate.id) }
        }
        current = nil
        isSaving = false
        networkVolume = nil
        saveQueue()
        startNext()
    }

    /// Next to the original: "<movie>.mp4" for joined parts, the same name with .mp4
    /// otherwise, and " (HEVC)" added if that's taken.
    static func output(for candidate: Modernize.Candidate) -> URL {
        let first = candidate.items[0].url
        let folder = first.deletingLastPathComponent()
        let name = candidate.joinsParts
            ? candidate.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            : first.deletingPathExtension().lastPathComponent
        let plain = folder.appendingPathComponent(name + ".mp4")
        return FileManager.default.fileExists(atPath: plain.path) ? folder.appendingPathComponent(name + " (HEVC).mp4") : plain
    }

    private struct NoSaving: Error {}

    private static func describe(_ error: Error) -> String {
        if error is NoSaving { return String(localized: "Converted, it would hardly be smaller, so it stays as it is.") }
        return switch error as? VideoConverter.Failure {
        case .unreadable(let file): String(localized: "Couldn't read \(file).")
        case .noVideo: String(localized: "There's no picture in it to convert.")
        case .subtitles: String(localized: "It has subtitles inside, which an MP4 can't keep, so it stays as it is.")
        case .encoder(let reason): String(localized: "The encoder stopped: \(reason)")
        default: error.localizedDescription
        }
    }

    // MARK: Originals

    /// Moves the originals of finished conversions to the Trash (or deletes them where
    /// the disk has no Trash, like most network shares). Returns how many couldn't go.
    func removeOriginals() -> Int {
        let failed = library.removeOriginals(keptOriginals)
        keptOriginals = failed
        UserDefaults.standard.set(keptOriginals, forKey: "modernizeKeptOriginals")
        return failed.count
    }

    nonisolated static func size(of paths: [String]) -> Int64 {
        paths.reduce(0) { total, path in
            total + Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Pause and cancel, read by the converter on its own thread.
    private final class Flags: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (paused: false, cancelled: false))
        var paused: Bool { state.withLock { $0.paused } }
        var cancelled: Bool { state.withLock { $0.cancelled } }
        func set(paused: Bool) { state.withLock { $0.paused = paused } }
        func set(cancelled: Bool) { state.withLock { $0.cancelled = cancelled } }
    }
}
