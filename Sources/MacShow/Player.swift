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
    var volume: Double = 100 { didSet { setDouble("volume", volume) } }
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
    /// Bumped when mpv's track list or track selection changes, so menus refresh.
    private(set) var tracksVersion = 0

    struct Track: Identifiable, Hashable {
        let id: Int
        let title: String
        let isSelected: Bool
    }
    var repeatMode: Repeat = .off {
        didSet {
            setString("loop-playlist", repeatMode == .all ? "inf" : "no")
            setString("loop-file", repeatMode == .one ? "inf" : "no")
        }
    }

    var currentItem: MediaItem? { queueIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    /// The loaded file has a real video track (not just cover art).
    private(set) var isVideo = false
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
        ] {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_request_log_messages(mpv, "error")

        let status = mpv_initialize(mpv)
        guard status >= 0 else { fatalError("mpv_initialize: \(String(cString: mpv_error_string(status)))") }

        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("media-title", MPV_FORMAT_STRING),
            ("chapter-metadata/title", MPV_FORMAT_STRING), ("playlist-pos", MPV_FORMAT_INT64),
            ("track-list/count", MPV_FORMAT_INT64), ("sid", MPV_FORMAT_STRING), ("aid", MPV_FORMAT_STRING),
        ] {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_set_wakeup_callback(mpv, { context in
            let player = Unmanaged<Player>.fromOpaque(context!).takeUnretainedValue()
            player.eventQueue.async { player.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    // MARK: Playback

    /// Replaces the queue with `items` and starts playing `items[index]`.
    /// Movies, episodes and audiobooks pick up where they were left.
    func play(_ items: [MediaItem], startAt index: Int = 0, fromBeginning: Bool = false) {
        guard items.indices.contains(index) else { return }
        savePosition()
        command("stop")
        queue = items
        queueIndex = index
        isShuffled = false
        for (offset, item) in items.enumerated() {
            if let start = fromBeginning && offset == index ? nil : resumePoint(for: item) {
                command("loadfile", item.path, "append", "-1", "start=\(Int(start))")
            } else {
                command("loadfile", item.path, "append")
            }
        }
        command("playlist-play-index", String(index))
        setFlag("pause", false)
    }

    private func resumePoint(for item: MediaItem) -> Double? {
        guard item.kind != .music, let id = item.id, let saved = library?.positions[id], saved.isResumable else { return nil }
        return saved.position
    }

    /// Records where the current movie, episode or audiobook is (music isn't resumed).
    func savePosition() {
        guard let item = currentItem, item.kind != .music, duration > 0 else { return }
        library?.savePosition(position, duration: duration, for: item)
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
        command("stop")
        queue = []
        queueIndex = nil
        command("loadfile", url.path)
    }

    func togglePause() { command("cycle", "pause") }
    func seek(to seconds: Double) { command("seek", String(seconds), "absolute") }
    func skip(_ seconds: Double) { command("seek", String(seconds), "relative") }
    func next() { command("playlist-next") }

    /// Restarts the current track, or goes to the previous one near its start.
    func previous() {
        if position > 3 { seek(to: 0) } else { command("playlist-prev") }
    }

    func playQueueItem(at index: Int) { command("playlist-play-index", String(index)) }

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

    func string(_ name: String) -> String? {
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
            case MPV_EVENT_FILE_LOADED:
                let (info, hasVideo) = formatDescription()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.formatInfo = info
                        self.isVideo = hasVideo
                    }
                }
            case MPV_EVENT_PLAYBACK_RESTART:  // after a seek or a new file starts
                DispatchQueue.main.async { MainActor.assumeIsolated { self.nowPlaying?.update() } }
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
            position = value as? Double ?? 0
            // Every 5 seconds of playback.
            let second = Int(position) / 5
            if second != lastSavedSecond {
                lastSavedSecond = second
                savePosition()
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
            parts.append("\((rate / 1000).formatted()) kHz")
        }
        return (parts.joined(separator: " · "), video != nil)
    }
}
