import Foundation
import Testing
@testable import MacShowCore

struct RadioTests {
    let stationsJSON = """
    [{"stationuuid":"a","name":"  Energy NRJ Bulgaria ","url":"http://play.global.audio/nrj128","url_resolved":"http://play.global.audio/nrj128",
      "favicon":"http://media.example.com/nrj.png","tags":"pop, Dance,,retro","country":"Bulgaria","countrycode":"BG","codec":"MP3","bitrate":128,
      "homepage":"https://radioenergy.bg/"},
     {"stationuuid":"b","name":"Energy NRJ Bulgaria","url":"http://other/nrj","url_resolved":"","favicon":"","tags":"","countrycode":"BG","bitrate":0},
     {"stationuuid":"c","name":"Jazz FM","url":"","url_resolved":"https://jazz.example/stream","favicon":"","tags":"jazz","countrycode":"GB","codec":"AAC","bitrate":64},
     {"stationuuid":"d","name":"No Address","url":"","url_resolved":"","tags":""}]
    """

    @Test func readsStations() throws {
        let stations = RadioDirectory.stations(from: Data(stationsJSON.utf8))
        // The same name twice is one station (the first, most played); no address, no station.
        #expect(stations.map(\.name) == ["Energy NRJ Bulgaria", "Jazz FM"])
        let nrj = stations[0]
        #expect(nrj.id == "a" && nrj.url.absoluteString == "http://play.global.audio/nrj128")
        #expect(nrj.tags == ["pop", "dance", "retro"] && nrj.countryCode == "BG" && nrj.bitrate == 128 && nrj.codec == "MP3")
        // Logos load over https (the app allows no plain http).
        #expect(nrj.logo?.absoluteString == "https://media.example.com/nrj.png")
        #expect(stations[1].url.absoluteString == "https://jazz.example/stream" && stations[1].logo == nil)
        #expect(nrj.details == "Pop · MP3 128 kbps")
    }

    @Test func readsCountries() throws {
        let countries = RadioDirectory.countries(from: Data(#"[{"name":"Bulgaria","iso_3166_1":"BG","stationcount":410},{"name":"","iso_3166_1":"XX","stationcount":3},{"name":"Germany","iso_3166_1":"DE","stationcount":5000}]"#.utf8))
        #expect(countries.map(\.code) == ["DE", "BG"])
        #expect(countries[1].flag == "🇧🇬")
    }

    @MainActor
    @Test func remembersFavoritesAndRecents() throws {
        let defaults = try #require(UserDefaults(suiteName: "radio-\(UUID())"))
        let stations = RadioDirectory.stations(from: Data(stationsJSON.utf8))
        let radio = Radio(defaults: defaults)
        radio.toggleFavorite(stations[1])
        radio.played(stations[0])
        radio.played(stations[1])
        radio.played(stations[0])
        let again = Radio(defaults: defaults)
        #expect(again.favorites.map(\.name) == ["Jazz FM"] && again.isFavorite(stations[1]))
        // Most recent first, each once.
        #expect(again.recents.map(\.name) == ["Energy NRJ Bulgaria", "Jazz FM"])
        again.toggleFavorite(stations[1])
        #expect(Radio(defaults: defaults).favorites.isEmpty)
    }
}
