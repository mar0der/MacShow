import CryptoKit
import Foundation

/// A live TV channel from an M3U playlist.
public struct LiveChannel: Codable, Hashable, Sendable, Identifiable {
    /// Which source it's from and its name: kept across playlist refreshes, for favorites.
    public var id: String { source + "/" + name }
    public var source: String
    public var name: String
    public var url: URL
    public var logo: URL?
    public var group: String?
    /// Its id in program guides (`tvg-id`).
    public var guideID: String?

    public init(source: String, name: String, url: URL, logo: URL? = nil, group: String? = nil, guideID: String? = nil) {
        self.source = source
        self.name = name
        self.url = url
        self.logo = logo
        self.group = group
        self.guideID = guideID
    }
}

/// M3U playlists, as IPTV providers, Tvheadend and channel lists publish them.
public enum M3U {
    public struct Playlist: Sendable {
        /// Program guides the playlist names (`url-tvg` in its header).
        public var guides: [URL] = []
        public var channels: [LiveChannel] = []
    }

    public static func parse(_ text: String, source: String) -> Playlist {
        var playlist = Playlist()
        var pending: (attributes: [String: String], name: String)?
        var names = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTM3U") {
                let header = attributes(in: line)
                playlist.guides = (header["url-tvg"] ?? header["x-tvg-url"] ?? "").split(separator: ",")
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            } else if line.hasPrefix("#EXTINF:") {
                // The name follows the first comma outside the quoted attributes.
                var inQuotes = false
                let comma = line.firstIndex { character in
                    if character == "\"" { inQuotes.toggle() }
                    return character == "," && !inQuotes
                }
                let name = comma.map { String(line[line.index(after: $0)...]) } ?? ""
                pending = (attributes(in: line), cleanName(name))
            } else if !line.isEmpty, !line.hasPrefix("#"), let entry = pending {
                pending = nil
                guard let url = URL(string: line), url.scheme != nil, !entry.name.isEmpty, names.insert(entry.name).inserted else { continue }
                let attributes = entry.attributes
                playlist.channels.append(LiveChannel(
                    source: source, name: entry.name, url: url,
                    logo: attributes["tvg-logo"].flatMap { $0.isEmpty ? nil : URL(string: $0) },
                    group: attributes["group-title"]?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) },
                    guideID: attributes["tvg-id"].flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        return playlist
    }

    private static let attribute = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)

    private static func attributes(in line: String) -> [String: String] {
        var found: [String: String] = [:]
        for match in attribute.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            found[String(line[Range(match.range(at: 1), in: line)!]).lowercased()] = String(line[Range(match.range(at: 2), in: line)!])
        }
        return found
    }

    /// "Travel TV (576p) [Not 24/7]" → "Travel TV"
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: #"(\s*(\(\d{3,4}[pi]\)|\[[^\]]*\]))+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A programme in a TV guide.
public struct Programme: Codable, Hashable, Sendable {
    public var start: Date
    public var stop: Date
    public var title: String
    public var description: String?
}

/// What's on, from XMLTV guides, by guide channel id.
public struct TVGuide: Sendable {
    /// Lowercased guide id → programmes, in time order.
    var programmes: [String: [Programme]] = [:]
    /// Normalized display name → guide id, for channels a playlist gives no id.
    var idsByName: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { programmes.isEmpty }

    public func programmes(for channel: LiveChannel) -> [Programme] {
        if let id = channel.guideID?.lowercased(), let found = programmes[id] { return found }
        return idsByName[Self.normalized(channel.name)].flatMap { programmes[$0] } ?? []
    }

    public func nowAndNext(for channel: LiveChannel, at date: Date = Date()) -> (now: Programme?, next: Programme?) {
        let list = programmes(for: channel)
        let now = list.lastIndex { $0.start <= date && date < $0.stop }
        let next = list.first { $0.start >= (now.map { list[$0].stop } ?? date) }
        return (now.map { list[$0] }, next)
    }

    public mutating func merge(_ other: TVGuide) {
        programmes.merge(other.programmes) { mine, _ in mine }
        idsByName.merge(other.idsByName) { mine, _ in mine }
    }

    /// "FRANCE 24 HD" and "France 24" both → "france24".
    static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"\b(hd|fhd|uhd|sd|4k)\b"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// XMLTV, the format free and provider TV guides come in (often gzipped).
public enum XMLTV {
    /// The programmes overlapping `window`, for every channel in `data` (XML, or gzipped XML).
    public static func parse(_ data: Data, window: ClosedRange<Date>) -> TVGuide {
        let reader = Reader(window: window)
        let parser = XMLParser(data: gunzip(data) ?? data)
        parser.delegate = reader
        parser.parse()
        var guide = TVGuide()
        guide.programmes = reader.programmes.mapValues { $0.sorted { $0.start < $1.start } }
        guide.idsByName = reader.idsByName
        return guide
    }

    /// The contents of gzip `data`, or nil if it isn't gzip.
    public static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 4 != 0 { offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8 }  // extra field
        if flags & 8 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }  // file name
        if flags & 16 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }  // comment
        if flags & 2 != 0 { offset += 2 }  // header checksum
        guard offset < bytes.count - 8 else { return nil }
        // What follows is raw DEFLATE, which is what Foundation's "zlib" means.
        return try? (Data(bytes[offset..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let window: ClosedRange<Date>
        var programmes: [String: [Programme]] = [:]
        var idsByName: [String: String] = [:]
        private var channelID: String?
        private var programme: (channel: String, start: Date, stop: Date)?
        private var title: String?
        private var summary: String?
        private var text = ""
        private let dateFormat: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMddHHmmss Z"
            return formatter
        }()

        init(window: ClosedRange<Date>) { self.window = window }

        private func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            // Without a time zone it's UTC.
            return dateFormat.date(from: text.count == 14 ? text + " +0000" : text)
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            switch element {
            case "channel": channelID = attributes["id"]?.lowercased()
            case "programme":
                if let channel = attributes["channel"]?.lowercased(), let start = date(attributes["start"]), let stop = date(attributes["stop"]),
                   stop > window.lowerBound, start < window.upperBound {
                    programme = (channel, start, stop)
                }
                title = nil
                summary = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "display-name":
                if let channelID, !value.isEmpty { idsByName[TVGuide.normalized(value)] = idsByName[TVGuide.normalized(value)] ?? channelID }
            case "channel": channelID = nil
            case "title": if title == nil, !value.isEmpty { title = value }
            case "desc": if summary == nil, !value.isEmpty { summary = value }
            case "programme":
                if let programme, let title {
                    programmes[programme.channel, default: []].append(Programme(start: programme.start, stop: programme.stop, title: title, description: summary))
                }
                programme = nil
            default: break
            }
            text = ""
        }
    }
}

/// Live TV: the free channels MacShow comes with and the playlists you add, with
/// what's on from their program guides. Playlists and guides are kept on disk
/// and fetched again twice a day.
@MainActor
@Observable
public final class LiveTV {
    public struct Source: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var playlist: URL
        /// A guide you gave; else the ones the playlist names.
        public var guide: URL?
    }

    public enum AddError: Error {
        case unreadable, noChannels
    }

    public private(set) var sources: [Source] = []
    public private(set) var guide = TVGuide()
    public private(set) var favorites: Set<String> = []
    public var showsFreeChannels: Bool {
        didSet { defaults.set(showsFreeChannels, forKey: Self.showsFreeKey) }
    }
    public private(set) var isLoading = false
    /// Playlists read, by source id ("free" for the built-in one).
    private var playlists: [String: M3U.Playlist] = [:]

    public var channels: [LiveChannel] {
        (showsFreeChannels ? playlists[Self.freeID]?.channels ?? [] : []) + sources.flatMap { playlists[$0.id]?.channels ?? [] }
    }
    public var favoriteChannels: [LiveChannel] { channels.filter { favorites.contains($0.id) } }

    public nonisolated static let freeID = "free"
    private static let sourcesKey = "liveTVSources", favoritesKey = "liveTVFavorites", showsFreeKey = "liveTVShowsFreeChannels"
    private static let refreshAge: TimeInterval = 12 * 60 * 60

    @ObservationIgnored private let builtInPlaylist: URL?
    @ObservationIgnored private let cacheFolder: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetchesGuides: Bool
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    public init(builtInPlaylist: URL?, cacheFolder: URL, defaults: UserDefaults = .standard, fetchesGuides: Bool = true) {
        self.builtInPlaylist = builtInPlaylist
        self.cacheFolder = cacheFolder
        self.defaults = defaults
        self.fetchesGuides = fetchesGuides
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        sources = (defaults.data(forKey: Self.sourcesKey)).flatMap { try? JSONDecoder().decode([Source].self, from: $0) } ?? []
        favorites = Set(defaults.stringArray(forKey: Self.favoritesKey) ?? [])
        showsFreeChannels = defaults.object(forKey: Self.showsFreeKey) as? Bool ?? true
    }

    /// Reads the playlists (from the cache, refetching old ones), then the guides.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        if let builtInPlaylist, let text = try? String(contentsOf: builtInPlaylist, encoding: .utf8) {
            playlists[Self.freeID] = M3U.parse(text, source: Self.freeID)
        }
        for source in sources {
            let cached = cacheFile(for: source)
            if let text = Self.read(cached), !isStale(cached) {
                playlists[source.id] = M3U.parse(text, source: source.id)
            } else if let text = await fetch(source.playlist) {
                try? text.write(to: cached, atomically: true, encoding: .utf8)
                playlists[source.id] = M3U.parse(text, source: source.id)
            } else if let text = Self.read(cached) {
                playlists[source.id] = M3U.parse(text, source: source.id)  // offline: the last copy
            }
        }
        await loadGuides()
    }

    /// Adds a playlist (a web address or a file), if it has channels.
    public func addSource(name: String, playlist: URL, guide: URL? = nil) async throws {
        guard let text = await fetch(playlist) else { throw AddError.unreadable }
        let source = Source(id: UUID().uuidString, name: name, playlist: playlist, guide: guide)
        let read = M3U.parse(text, source: source.id)
        guard !read.channels.isEmpty else { throw AddError.noChannels }
        try? text.write(to: cacheFile(for: source), atomically: true, encoding: .utf8)
        playlists[source.id] = read
        sources.append(source)
        saveSources()
        await loadGuides()
    }

    public func removeSource(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        playlists[source.id] = nil
        try? FileManager.default.removeItem(at: cacheFile(for: source))
        saveSources()
    }

    public func toggleFavorite(_ channel: LiveChannel) {
        if favorites.contains(channel.id) { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        defaults.set(Array(favorites).sorted(), forKey: Self.favoritesKey)
    }

    public func nowAndNext(for channel: LiveChannel) -> (now: Programme?, next: Programme?) {
        guide.nowAndNext(for: channel)
    }

    private func loadGuides() async {
        guard fetchesGuides else { return }
        var urls: [URL] = playlists[Self.freeID]?.guides ?? []
        for source in sources {
            urls += source.guide.map { [$0] } ?? playlists[source.id]?.guides ?? []
        }
        var merged = TVGuide()
        let window = Date().addingTimeInterval(-3 * 3600)...Date().addingTimeInterval(36 * 3600)
        for url in Array(Set(urls)) {
            let cached = cacheFolder.appendingPathComponent("guide-" + Self.hash(url.absoluteString))
            var data = isStale(cached) ? nil : try? Data(contentsOf: cached)
            if data == nil, let (fetched, reply) = try? await session.data(from: url), (reply as? HTTPURLResponse)?.statusCode ?? 200 == 200 {
                try? fetched.write(to: cached)
                data = fetched
            }
            guard let data = data ?? (try? Data(contentsOf: cached)) else { continue }
            // Guides run to tens of megabytes: read them off the main thread.
            merged.merge(await Task.detached(priority: .utility) { XMLTV.parse(data, window: window) }.value)
        }
        guide = merged
    }

    private func fetch(_ url: URL) async -> String? {
        if url.isFileURL { return Self.read(url) }
        guard let (data, reply) = try? await session.data(from: url), (reply as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func isStale(_ file: URL) -> Bool {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { Date().timeIntervalSince($0) > Self.refreshAge } ?? true
    }

    private func cacheFile(for source: Source) -> URL { cacheFolder.appendingPathComponent(source.id + ".m3u") }

    private func saveSources() {
        defaults.set(try? JSONEncoder().encode(sources), forKey: Self.sourcesKey)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
