import AppKit
import Libmpv
import Observation

/// One libmpv instance. mpv draws video straight into `layer`; playback state
/// is mirrored into observable properties on the main thread.
@Observable
final class Player {
    let layer = MetalLayer()

    private(set) var title = ""
    private(set) var isPaused = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var hasPicture = false  // a video track or embedded album art
    private(set) var formatInfo = ""
    private(set) var chapterTitle: String?
    var volume: Double = 100 { didSet { setDouble("volume", volume) } }

    @ObservationIgnored private let mpv: OpaquePointer
    @ObservationIgnored private let queue = DispatchQueue(label: "MacShow.mpv")

    init() {
        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        mpv = handle

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("keep-open", "yes"), ("ytdl", "no"),
        ] {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_request_log_messages(mpv, "warn")

        let status = mpv_initialize(mpv)
        guard status >= 0 else { fatalError("mpv_initialize: \(String(cString: mpv_error_string(status)))") }

        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("media-title", MPV_FORMAT_STRING),
            ("vid", MPV_FORMAT_STRING), ("chapter-metadata/title", MPV_FORMAT_STRING),
        ] {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_set_wakeup_callback(mpv, { context in
            Unmanaged<Player>.fromOpaque(context!).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func open(_ url: URL) { command("loadfile", url.path) }
    func togglePause() { command("cycle", "pause") }
    func seek(to seconds: Double) { command("seek", String(seconds), "absolute") }
    func skip(_ seconds: Double) { command("seek", String(seconds), "relative") }

    private func command(_ args: String...) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(mpv, &cargs)
    }

    private func setDouble(_ name: String, _ value: Double) {
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func string(_ name: String) -> String? {
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    // MARK: Events (called from mpv's wakeup callback; drained on `queue`)

    private func drainEvents() {
        queue.async { [self] in
            while let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
                handle(event)
            }
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            let property = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            let value = Self.value(of: property)
            DispatchQueue.main.async { self.apply(name, value) }
        case MPV_EVENT_FILE_LOADED:
            let info = formatDescription()
            DispatchQueue.main.async { self.formatInfo = info }
        case MPV_EVENT_LOG_MESSAGE:
            let message = event.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            FileHandle.standardError.write(Data("[mpv \(String(cString: message.prefix))] \(String(cString: message.text))".utf8))
        default:
            break
        }
    }

    private static func value(of property: mpv_event_property) -> Any? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_DOUBLE: return data.load(as: Double.self)
        case MPV_FORMAT_FLAG: return data.load(as: Int32.self) != 0
        case MPV_FORMAT_STRING: return String(cString: data.load(as: UnsafePointer<CChar>.self))
        default: return nil
        }
    }

    private func apply(_ name: String, _ value: Any?) {
        switch name {
        case "time-pos": position = value as? Double ?? 0
        case "duration": duration = value as? Double ?? 0
        case "pause": isPaused = value as? Bool ?? true
        case "media-title": title = value as? String ?? ""
        case "vid": hasPicture = (value as? String).map { $0 != "no" } ?? false
        case "chapter-metadata/title": chapterTitle = value as? String
        default: break
        }
    }

    /// e.g. "HEVC · AC3 · 48 kHz" or "FLAC · 96 kHz" (album art is not counted as video).
    private func formatDescription() -> String {
        var parts: [String] = []
        if string("current-tracks/video/albumart") == "no", let video = string("current-tracks/video/codec") {
            parts.append(video.uppercased())
        }
        if let audio = string("current-tracks/audio/codec") {
            parts.append(audio.uppercased())
        }
        if let rate = string("current-tracks/audio/demux-samplerate").flatMap(Double.init) {
            parts.append("\((rate / 1000).formatted()) kHz")
        }
        return parts.joined(separator: " · ")
    }
}
