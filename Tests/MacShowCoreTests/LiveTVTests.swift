import Foundation
import Testing
@testable import MacShowCore

struct LiveTVTests {
    let playlist = """
    #EXTM3U url-tvg="https://example.com/a.xml.gz,https://example.com/b.xml"
    # a comment
    #EXTINF:-1 tvg-id="Travel.TV.bg" tvg-logo="https://example.com/t.png" group-title="Bulgaria",Travel TV (576p) [Not 24/7]
    #EXTVLCOPT:http-user-agent=Mozilla
    https://example.com/travel.m3u8
    #EXTINF:-1 tvg-name="News, Weather" group-title="News;General",News, Weather
    http://example.com/news.m3u8

    #EXTINF:-1,No Address
    """

    @Test func readsPlaylists() throws {
        let read = M3U.parse(playlist, source: "mine")
        #expect(read.guides.map(\.absoluteString) == ["https://example.com/a.xml.gz", "https://example.com/b.xml"])
        #expect(read.channels.count == 2)
        let travel = read.channels[0]
        #expect(travel.name == "Travel TV" && travel.guideID == "Travel.TV.bg" && travel.group == "Bulgaria")
        #expect(travel.logo?.absoluteString == "https://example.com/t.png" && travel.url.absoluteString == "https://example.com/travel.m3u8")
        // A comma inside an attribute isn't the start of the name; groups take their first part.
        #expect(read.channels[1].name == "News, Weather" && read.channels[1].group == "News" && read.channels[1].guideID == nil)
        #expect(travel.id != read.channels[1].id)
    }

    let guideXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="Travel.TV.bg"><display-name lang="bg">Travel TV</display-name></channel>
      <channel id="FRANCE.24.HD.uk"><display-name>FRANCE 24 HD</display-name></channel>
      <programme start="20261026100000 +0200" stop="20261026110000 +0200" channel="Travel.TV.bg">
        <title lang="bg">Islands &amp; Beaches</title><desc>Sun.</desc>
      </programme>
      <programme start="20261026110000 +0200" stop="20261026120000 +0200" channel="Travel.TV.bg"><title>Mountains</title></programme>
      <programme start="20261020110000 +0200" stop="20261020120000 +0200" channel="Travel.TV.bg"><title>Long ago</title></programme>
      <programme start="20261026090000 +0000" stop="20261026100000 +0000" channel="FRANCE.24.HD.uk"><title>The World This Morning</title></programme>
    </tv>
    """

    func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    @Test func readsGuidesAndKnowsWhatsOn() throws {
        let window = date("2026-10-26T00:00:00Z")...date("2026-10-27T00:00:00Z")
        let guide = XMLTV.parse(Data(guideXML.utf8), window: window)
        let travel = LiveChannel(source: "mine", name: "Travel TV", url: URL(string: "https://x/t.m3u8")!, guideID: "travel.tv.bg")
        // Outside the window: dropped.
        #expect(guide.programmes(for: travel).map(\.title) == ["Islands & Beaches", "Mountains"])
        let (now, next) = guide.nowAndNext(for: travel, at: date("2026-10-26T08:30:00Z"))
        #expect(now?.title == "Islands & Beaches" && now?.description == "Sun." && next?.title == "Mountains")
        // No guide id: matched by name, ignoring "HD" and case.
        let france = LiveChannel(source: "mine", name: "France 24", url: URL(string: "https://x/f.m3u8")!)
        #expect(guide.programmes(for: france).map(\.title) == ["The World This Morning"])
    }

    @Test func readsCompressedGuides() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gz-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("guide.xml")
        try Data(guideXML.utf8).write(to: file)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [file.path]
        try gzip.run()
        gzip.waitUntilExit()
        let compressed = try Data(contentsOf: folder.appendingPathComponent("guide.xml.gz"))
        #expect(XMLTV.gunzip(compressed) == Data(guideXML.utf8))
        #expect(XMLTV.gunzip(Data(guideXML.utf8)) == nil)
    }

    @MainActor
    @Test func keepsSourcesAndFavorites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let builtIn = folder.appendingPathComponent("Free.m3u")
        try "#EXTM3U\n#EXTINF:-1 group-title=\"News\",DW\nhttps://x/dw.m3u8\n".write(to: builtIn, atomically: true, encoding: .utf8)
        let mine = folder.appendingPathComponent("mine.m3u")
        try playlist.write(to: mine, atomically: true, encoding: .utf8)
        let defaults = try #require(UserDefaults(suiteName: "live-\(UUID())"))

        let live = LiveTV(builtInPlaylist: builtIn, cacheFolder: folder.appendingPathComponent("cache"), defaults: defaults, fetchesGuides: false)
        await live.load()
        #expect(live.channels.map(\.name) == ["DW"])
        try await live.addSource(name: "Mine", playlist: mine)
        #expect(live.channels.map(\.name) == ["DW", "Travel TV", "News, Weather"])
        live.toggleFavorite(live.channels[1])

        // A new launch: same sources and favorites, read from the cache.
        let again = LiveTV(builtInPlaylist: builtIn, cacheFolder: folder.appendingPathComponent("cache"), defaults: defaults, fetchesGuides: false)
        await again.load()
        #expect(again.sources.map(\.name) == ["Mine"])
        #expect(again.channels.count == 3 && again.favoriteChannels.map(\.name) == ["Travel TV"])
        again.showsFreeChannels = false
        #expect(again.channels.map(\.name) == ["Travel TV", "News, Weather"])
        again.removeSource(again.sources[0])
        #expect(again.channels.isEmpty)

        await #expect(throws: LiveTV.AddError.self) { try await again.addSource(name: "Empty", playlist: builtIn.appendingPathExtension("missing")) }
    }
}
