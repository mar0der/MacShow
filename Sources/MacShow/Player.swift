import AppKit
import Libmpv
import MacShowCore
import Observation

/// One libmpv instance. mpv draws video straight into `layer`; playback state
/// is mirrored into observable properties on the main thread. The play queue
/// is mpv's playlist, which is what makes gapless album playback work.
@MainActor
@Observable
final class Player {
    enum Repeat: String, CaseIterable { case off, all, one }

    let layer = MetalLayer()

    private(set) var queue: [MediaItem] = []
    private(set) var queueIndex: Int?
    private(set) var title = ""
    private(set) var isPaused = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var formatInfo = ""
    private(set) var chapterTitle: String?
    private(set) var isShuffled = false
    /// Remembered across launches.
    var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 100 {
        didSet {
            setDouble("volume", volume)
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var isMuted = false { didSet { setFlag("mute", isMuted) } }
    /// Playback speed (audiobooks); pitch is kept.
    var speed: Double = 1 {
        didSet {
            setDouble("speed", speed)
            nowPlaying?.update()
        }
    }
    /// Control Center / media keys; set by the app once the library exists.
    @ObservationIgnored var nowPlaying: NowPlaying?
    /// Where resume points are read from and saved to; set by the app.
    @ObservationIgnored weak var library: Library?
    @ObservationIgnored private var lastSavedSecond = -1
    /// The item whose file mpv has loaded (positions are saved against it).
    @ObservationIgnored private var loadedItem: MediaItem?
    @ObservationIgnored private var lastExternalOpen = Date.distantPast
    /// Bumped when mpv's track list or track selection changes, so menus refresh.
    private(set) var tracksVersion = 0

    struct Track: Identifiable, Hashable {
        let id: Int
        let title: String
        let isSelected: Bool
    }

    enum SleepTimer: Equatable {
        case off
        case at(Date)
        case endOfChapter
    }

    /// Index of the chapter playing in the current file (nil if it has none).
    private(set) var chapterIndex: Int?
    var sleepTimer: SleepTimer = .off {
        didSet { armSleepTimer() }
    }
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Where "end of chapter" pauses (seconds into the file).
    @ObservationIgnored private var sleepChapterEnd: Double?
    /// Set when you switch files, so "end of chapter" re-targets on the new
    /// file's first position. (Seeks within a file re-target straight away,
    /// from where they're going.)
    @ObservationIgnored private var sleepRetargetOnLoad = false
    @ObservationIgnored private var sleepRetargetFrom: String?
    /// Where each queued file should start (resume points, or a chapter or
    /// bookmark you picked), read by mpv's on_load hook on the event thread.
    @ObservationIgnored nonisolated private let startTimes = StartTimes()

    /// Audiobooks keep their own speed; everything else plays at 1×.
    static let audiobookSpeedKey = "audiobookSpeed"
    var repeatMode: Repeat = .off {
        didSet {
            setString("loop-playlist", repeatMode == .all ? "inf" : "no")
            setString("loop-file", repeatMode == .one ? "inf" : "no")
        }
    }

    var currentItem: MediaItem? { queueIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    /// The loaded file has a real video track (not just cover art).
    private(set) var isVideo = false
    /// The video keeps playing in a corner while you browse the library.
    /// Starting something new brings it back full size.
    var isVideoMinimized = false
    var hasMedia: Bool { duration > 0 || currentItem != nil }

    @ObservationIgnored nonisolated(unsafe) private let mpv: OpaquePointer
    @ObservationIgnored nonisolated private let eventQueue = DispatchQueue(label: "MacShow.mpv")

    init() {
        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        mpv = handle

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("keep-open", "yes"), ("ytdl", "no"),
            ("audio-display", "no"),            // the UI shows cover art itself
            ("gapless-audio", "yes"), ("replaygain", "album"), ("replaygain-fallback", "0"),
            ("input-default-bindings", "no"), ("osc", "no"), ("idle", "yes"),
            // No Lua at all: no user scripts, no config, none of mpv's built-in scripts.
            ("load-scripts", "no"), ("config", "no"), ("load-stats-overlay", "no"), ("load-console", "no"),
            ("load-auto-profiles", "no"), ("load-select", "no"), ("load-commands", "no"),
            ("load-context-menu", "no"), ("load-positioning", "no"),
        ] {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_request_log_messages(mpv, "error")

        let status = mpv_initialize(mpv)
        guard status >= 0 else { fatalError("mpv_initialize: \(String(cString: mpv_error_string(status)))") }
        setDouble("volume", volume)

        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("media-title", MPV_FORMAT_STRING),
            ("chapter-metadata/title", MPV_FORMAT_STRING), ("playlist-pos", MPV_FORMAT_INT64),
            ("track-list/count", MPV_FORMAT_INT64), ("sid", MPV_FORMAT_STRING), ("aid", MPV_FORMAT_STRING),
            ("chapter", MPV_FORMAT_INT64),
        ] {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_hook_add(mpv, 0, "on_load", 50)
        mpv_set_wakeup_callback(mpv, { context in
            let player = Unmanaged<Player>.fromOpaque(context!).takeUnretainedValue()
            player.eventQueue.async { player.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.savePosition()
                self?.library?.flushPendingWrites()  // the app exits right after this
            }
        }
    }

    // MARK: Playback

    /// Replaces the queue with `items` and starts playing `items[index]`, at
    /// `time` if given. Movies, episodes and audiobooks otherwise pick up where
    /// they were left.
    func play(_ items: [MediaItem], startAt index: Int = 0, fromBeginning: Bool = false, at time: Double? = nil) {
        guard items.indices.contains(index) else { return }
        // Files on a drive that isn't connected: play a reachable copy, or leave them out.
        if let library, items.contains(where: { library.playableCopy(of: $0) != $0 }) {
            let reachable = items.indices.compactMap { offset in library.playableCopy(of: items[offset]).map { (offset, $0) } }
            guard let start = reachable.firstIndex(where: { $0.0 == index }) else { return }
            return play(reachable.map(\.1), startAt: start, fromBeginning: fromBeginning, at: time)
        }
        savePosition()
        command("stop")
        isVideoMinimized = false
        queue = items
        queueIndex = index
        isShuffled = false
        sleepTimer = .off
        let isBook = items[index].kind == .audiobook
        let bookSpeed = UserDefaults.standard.double(forKey: Self.audiobookSpeedKey)
        speed = isBook && bookSpeed > 0 ? bookSpeed : 1
        var starts: [String: Double] = [:]
        for item in items {
            starts[item.path] = resumePoint(for: item)
            command("loadfile", item.path, "append")
        }
        starts[items[index].path] = fromBeginning ? nil : (time ?? starts[items[index].path])
        startTimes.replace(with: starts)
        command("playlist-play-index", String(index))
        setFlag("pause", false)
    }

    private func resumePoint(for item: MediaItem) -> Double? {
        guard item.kind != .music, let saved = library?.position(for: item), saved.isResumable else { return nil }
        return saved.position
    }

    /// Records where the loaded movie, episode or audiobook is (music isn't
    /// resumed). Uses the item mpv actually loaded, not `queueIndex`, which can
    /// already point at the next file while the old one's events arrive.
    /// `publish` false skips updating the UI (the periodic saves during playback).
    func savePosition(publish: Bool = true) {
        guard let item = loadedItem, item.kind != .music, duration > 0, position > 0 else { return }
        library?.savePosition(position, duration: duration, for: item, publish: publish)
        startTimes.set(library?.position(for: item)?.isResumable == true ? position : nil, for: item.path)
    }

    /// Sets the playback speed; for audiobooks it's remembered for next time.
    func setSpeed(_ value: Double) {
        speed = value
        if currentItem?.kind == .audiobook {
            UserDefaults.standard.set(value, forKey: Self.audiobookSpeedKey)
        }
    }

    // MARK: Chapters

    /// The current file's chapters: (title, start time).
    func chapters() -> [(title: String, start: Double)] {
        _ = chapterIndex
        let count = Int(string("chapter-list/count") ?? "") ?? 0
        return (0..<count).map { index in
            (string("chapter-list/\(index)/title") ?? "Chapter \(index + 1)",
             Double(string("chapter-list/\(index)/time") ?? "") ?? 0)
        }
    }

    /// Next chapter within the file, or the next file of a folder book.
    func nextChapter() {
        let list = chapters()
        if let chapter = chapterIndex, chapter + 1 < list.count {
            retargetSleep(at: list[chapter + 1].start)
            command("add", "chapter", "1")
        } else {
            next()
        }
    }

    /// Start of this chapter, or the previous one if within its first few seconds.
    func previousChapter() {
        let list = chapters()
        guard let chapter = chapterIndex, !list.isEmpty else { return previous() }
        if position - list[chapter].start > 3 || chapter == 0 && queueIndex.map({ $0 == 0 }) ?? true {
            seek(to: list[chapter].start)
        } else if chapter > 0 {
            retargetSleep(at: list[chapter - 1].start)
            command("add", "chapter", "-1")
        } else {
            fileChanging()
            command("playlist-prev")
        }
    }

    private func armSleepTimer() {
        sleepTask?.cancel()
        sleepChapterEnd = nil
        sleepRetargetOnLoad = false
        switch sleepTimer {
        case .off:
            break
        case .at(let date):
            sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0)))
                guard !Task.isCancelled, let self else { return }
                if !self.isPaused { self.togglePause() }
                self.sleepTimer = .off
            }
        case .endOfChapter:
            sleepChapterEnd = chapterEnd(at: position)
        }
    }

    /// Where the chapter containing `time` ends: the next chapter's start, or
    /// the end of the file (folder books, where each file is a chapter).
    private func chapterEnd(at time: Double) -> Double {
        let list = chapters()
        guard let current = list.lastIndex(where: { $0.start <= time + 0.05 }), current + 1 < list.count else { return duration }
        return list[current + 1].start
    }

    /// "End of chapter" follows you: after a seek it pauses at the end of the
    /// chapter you jumped into.
    private func retargetSleep(at time: Double) {
        if sleepTimer == .endOfChapter { sleepChapterEnd = chapterEnd(at: time) }
    }

    /// Switching files: re-target once the new file reports its position.
    private func fileChanging() {
        guard sleepTimer == .endOfChapter else { return }
        sleepRetargetOnLoad = true
        sleepRetargetFrom = loadedItem?.path
    }

    /// mpv sets up its video output when a file loads; if the video window
    /// appears afterwards, that output never reaches the screen. Re-selecting
    /// the video track makes mpv build it again on the now-visible layer.
    func reattachVideoOutput() {
        guard let track = string("vid"), track != "no" else { return }
        setString("vid", "no")
        setString("vid", track)
    }

    // MARK: Tracks

    /// Subtitle ("sub") or audio ("audio") tracks of the current file.
    func tracks(_ type: String) -> [Track] {
        _ = tracksVersion
        let count = Int(string("track-list/count") ?? "") ?? 0
        return (0..<count).compactMap { index in
            let base = "track-list/\(index)/"
            guard string(base + "type") == type, let id = Int(string(base + "id") ?? "") else { return nil }
            let language = string(base + "lang").map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            let parts = [string(base + "title"), language, string(base + "codec")?.uppercased(),
                         string(base + "external") == "yes" ? "External" : nil]
            let title = parts.compactMap { $0 }.joined(separator: " · ")
            return Track(id: id, title: title.isEmpty ? "Track \(id)" : title, isSelected: string(base + "selected") == "yes")
        }
    }

    /// Selects a track, or turns subtitles off with nil.
    func select(_ track: Track?, type: String) {
        setString(type == "sub" ? "sid" : "aid", track.map { String($0.id) } ?? "no")
    }

    func addSubtitleFile(_ url: URL) { command("sub-add", url.path, "select") }

    /// Plays a file that isn't in the library (File › Open, or a launch argument).
    func open(_ url: URL) {
        savePosition()
        command("stop")
        isVideoMinimized = false
        queue = []
        queueIndex = nil
        command("loadfile", url.path)
    }

    /// A file opened from Finder. Finder hands over several files one by one,
    /// so files arriving within a second of each other queue up after the first.
    func openExternal(_ url: URL) {
        if Date().timeIntervalSince(lastExternalOpen) < 1 {
            command("loadfile", url.path, "append")
        } else {
            open(url)
        }
        lastExternalOpen = Date()
    }

    func togglePause() { command("cycle", "pause") }
    /// One frame forward or back (pauses).
    func stepFrame(forward: Bool) { command(forward ? "frame-step" : "frame-back-step") }
    /// The next subtitle track, then off.
    func cycleSubtitles() { command("cycle", "sub") }
    func seek(to seconds: Double) {
        retargetSleep(at: seconds)
        command("seek", String(seconds), "absolute")
    }

    func skip(_ seconds: Double) {
        retargetSleep(at: position + seconds)
        command("seek", String(seconds), "relative")
    }

    func next() {
        fileChanging()
        command("playlist-next")
    }

    /// Restarts the current track, or goes to the previous one near its start.
    func previous() {
        if position > 3 {
            seek(to: 0)
        } else {
            fileChanging()
            command("playlist-prev")
        }
    }

    func playQueueItem(at index: Int) {
        fileChanging()
        command("playlist-play-index", String(index))
    }

    /// Inserts `items` right after the current one (or plays them if nothing is queued).
    func playNext(_ items: [MediaItem]) {
        guard let index = queueIndex, !queue.isEmpty else { return play(items) }
        for item in items.reversed() { command("loadfile", item.path, "insert-next") }
        queue.insert(contentsOf: items, at: index + 1)
    }

    /// Appends `items` to the end of the queue (or plays them if nothing is queued).
    func addToQueue(_ items: [MediaItem]) {
        guard !queue.isEmpty else { return play(items) }
        for item in items { command("loadfile", item.path, "append") }
        queue.append(contentsOf: items)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != queueIndex else { return }
        command("playlist-remove", String(index))
        queue.remove(at: index)
        if let current = queueIndex, index < current { queueIndex = current - 1 }
    }

    func stop() {
        savePosition()
        command("stop")
        queue = []
        queueIndex = nil
        duration = 0
        position = 0
        title = ""
        isVideo = false
    }

    func toggleShuffle() {
        command(isShuffled ? "playlist-unshuffle" : "playlist-shuffle")
        isShuffled.toggle()
        syncQueueOrder()
    }

    /// After mpv reorders its playlist, mirror the new order in `queue`.
    private func syncQueueOrder() {
        let byPath = Dictionary(queue.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let count = Int(string("playlist-count") ?? "") ?? 0
        let ordered = (0..<count).compactMap { string("playlist/\($0)/filename").flatMap { byPath[$0] } }
        if ordered.count == queue.count { queue = ordered }
        queueIndex = Int(string("playlist-pos") ?? "")
    }

    // MARK: mpv plumbing

    private func command(_ args: String...) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(mpv, &cargs)
    }

    private func setDouble(_ name: String, _ value: Double) {
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setString(_ name: String, _ value: String) {
        mpv_set_property_string(mpv, name, value)
    }

    func string(_ name: String) -> String? { Self.string(mpv, name) }

    nonisolated private static func string(_ mpv: OpaquePointer, _ name: String) -> String? {
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    // MARK: Events (drained on `eventQueue`, applied on the main thread)

    nonisolated private func drainEvents() {
        while let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                let property = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                let name = String(cString: property.name)
                let value = Self.value(of: property)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(name, value) } }
            case MPV_EVENT_HOOK:
                // on_load: set this file's start point before mpv opens it.
                let hook = event.data.assumingMemoryBound(to: mpv_event_hook.self).pointee
                if String(cString: hook.name) == "on_load", let path = Self.string(mpv, "path"), let start = startTimes.time(for: path) {
                    mpv_set_property_string(mpv, "file-local-options/start", String(start))
                }
                mpv_hook_continue(mpv, hook.id)
            case MPV_EVENT_FILE_LOADED:
                let (info, hasVideo) = formatDescription()
                let index = Int(Self.string(mpv, "playlist-pos") ?? "")
                let path = Self.string(mpv, "path")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.formatInfo = info
                        self.isVideo = hasVideo
                        // Match by path: the queue may have changed since mpv reported the index.
                        if let index, self.queue.indices.contains(index), self.queue[index].path == path {
                            self.loadedItem = self.queue[index]
                        } else {
                            self.loadedItem = self.queue.first { $0.path == path }
                        }
                        self.position = 0
                        self.lastSavedSecond = -1
                    }
                }
            case MPV_EVENT_END_FILE:
                let reason = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Played to the end: mark it finished (periodic saves stop a few seconds short).
                        if reason == MPV_END_FILE_REASON_EOF, let item = self.loadedItem, item.kind != .music {
                            let length = self.duration > 0 ? self.duration : item.duration
                            self.library?.savePosition(length, duration: length, for: item, publish: true)
                            self.startTimes.set(nil, for: item.path)
                        }
                        // "End of chapter" at the end of a file: the next one starts paused.
                        if reason == MPV_END_FILE_REASON_EOF, self.sleepTimer == .endOfChapter,
                           (self.sleepChapterEnd ?? 0) >= self.duration - 1 {
                            self.setFlag("pause", true)
                            self.sleepTimer = .off
                        }
                        self.loadedItem = nil
                        self.position = 0
                        self.lastSavedSecond = -1
                    }
                }
            case MPV_EVENT_PLAYBACK_RESTART:  // after a seek or a new file starts
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.nowPlaying?.update()
                    }
                }
            case MPV_EVENT_LOG_MESSAGE:
                let message = event.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                FileHandle.standardError.write(Data("[mpv \(String(cString: message.prefix))] \(String(cString: message.text))".utf8))
            default:
                break
            }
        }
    }

    nonisolated private static func value(of property: mpv_event_property) -> Any? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_DOUBLE: return data.load(as: Double.self)
        case MPV_FORMAT_FLAG: return data.load(as: Int32.self) != 0
        case MPV_FORMAT_INT64: return Int(data.load(as: Int64.self))
        case MPV_FORMAT_STRING: return String(cString: data.load(as: UnsafePointer<CChar>.self))
        default: return nil
        }
    }

    private func apply(_ name: String, _ value: Any?) {
        switch name {
        case "time-pos":
            // Unavailable while a file unloads; keep the last real position.
            guard let seconds = value as? Double else { return }
            position = seconds
            // Every 5 seconds of playback.
            let bucket = Int(position) / 5
            if bucket != lastSavedSecond {
                lastSavedSecond = bucket
                savePosition(publish: false)
            }
            if sleepRetargetOnLoad, let loaded = loadedItem, loaded.path != sleepRetargetFrom {
                sleepRetargetOnLoad = false
                sleepChapterEnd = chapterEnd(at: position)
            }
            if sleepTimer == .endOfChapter, !sleepRetargetOnLoad, let end = sleepChapterEnd, end < duration - 1, position >= end - 0.3 {
                if !isPaused { togglePause() }
                sleepTimer = .off
            }
            return
        case "duration": duration = value as? Double ?? 0
        case "pause":
            isPaused = value as? Bool ?? true
            if isPaused { savePosition() }
        case "track-list/count", "sid", "aid": tracksVersion += 1
        case "media-title": title = value as? String ?? ""
        case "chapter-metadata/title": chapterTitle = value as? String
        case "playlist-pos":
            if let index = value as? Int, index >= 0, !queue.isEmpty { queueIndex = index }
        case "chapter":
            chapterIndex = (value as? Int).flatMap { $0 >= 0 ? $0 : nil }
        default: break
        }
        nowPlaying?.update()
    }

    /// e.g. "HEVC · AC3 · 48 kHz" or "FLAC · 96 kHz", and whether there's a real
    /// video track (album art doesn't count).
    nonisolated private func formatDescription() -> (String, Bool) {
        func get(_ name: String) -> String? {
            guard let cString = mpv_get_property_string(mpv, name) else { return nil }
            defer { mpv_free(cString) }
            return String(cString: cString)
        }
        var parts: [String] = []
        let video = get("current-tracks/video/albumart") == "no" ? get("current-tracks/video/codec") : nil
        if let video {
            parts.append(video.uppercased())
        }
        if let audio = get("current-tracks/audio/codec") {
            parts.append(audio.uppercased())
        }
        if let rate = get("current-tracks/audio/demux-samplerate").flatMap(Double.init) {
            parts.append(String(format: "%g kHz", rate / 1000))
        }
        return (parts.joined(separator: " · "), video != nil)
    }
}

/// Start times by file path, shared between the main thread and mpv's event thread.
final class StartTimes: @unchecked Sendable {
    private var times: [String: Double] = [:]
    private let lock = NSLock()

    func replace(with times: [String: Double]) { lock.withLock { self.times = times } }
    func set(_ time: Double?, for path: String) { lock.withLock { times[path] = time } }
    func time(for path: String) -> Double? { lock.withLock { times[path] } }
}
