import Foundation
import Testing
@testable import MacShowCore

struct VideoTests {
    @Test func grabsAStillFromAnMKV() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("My.Show.S02E05.720p.mkv")
        let image = try #require(VideoThumbnailer.thumbnail(of: url))
        #expect(image.width == 64)
        #expect(image.height == 64)
    }

    @Test func audioFileHasNoStill() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("book.m4b")
        #expect(VideoThumbnailer.thumbnail(of: url) == nil)
    }

    @Test func positionThresholds() {
        let early = PlaybackPosition(mediaItemId: 1, position: 5, duration: 3600, updatedAt: Date())
        let middle = PlaybackPosition(mediaItemId: 1, position: 1800, duration: 3600, updatedAt: Date())
        let credits = PlaybackPosition(mediaItemId: 1, position: 3580, duration: 3600, updatedAt: Date())
        #expect(!early.isResumable && !early.isFinished)
        #expect(middle.isResumable)
        #expect(credits.isFinished && !credits.isResumable)

        let shortFile = PlaybackPosition(mediaItemId: 1, position: 21, duration: 30, updatedAt: Date())
        #expect(shortFile.isResumable && !shortFile.isFinished)
    }

    @MainActor
    @Test func continueWatchingOffersPartlyWatchedAndNextEpisode() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([
            makeItem("/tv/s1e1.mkv", kind: .episode, show: "Severance", season: 1, episode: 1),
            makeItem("/tv/s1e2.mkv", kind: .episode, show: "Severance", season: 1, episode: 2),
            makeItem("/movies/film.mkv", kind: .movie),
        ])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")
        let library = Library(database: database, artwork: ArtworkStore(directory: folder))
        for _ in 0..<50 where library.index.itemsByID.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        let items = Dictionary(uniqueKeysWithValues: library.index.itemsByID.values.map { ($0.path, $0) })
        library.savePosition(3590, duration: 3600, for: try #require(items["/tv/s1e1.mkv"]))
        library.savePosition(1200, duration: 6000, for: try #require(items["/movies/film.mkv"]))

        #expect(library.continueWatching.map(\.path) == ["/movies/film.mkv", "/tv/s1e2.mkv"])
    }

    @MainActor
    @Test func continueWatchingShowsOneEpisodePerShow() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([
            makeItem("/tv/s3e1.mkv", kind: .episode, show: "Yellowstone", season: 3, episode: 1),
            makeItem("/tv/s4e1.mkv", kind: .episode, show: "Yellowstone", season: 4, episode: 1),
        ])
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        for _ in 0..<50 where library.index.itemsByID.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let items = Dictionary(uniqueKeysWithValues: library.index.itemsByID.values.map { ($0.path, $0) })

        library.savePosition(1200, duration: 3000, for: try #require(items["/tv/s3e1.mkv"]))
        try await Task.sleep(for: .milliseconds(10))
        library.savePosition(600, duration: 3000, for: try #require(items["/tv/s4e1.mkv"]))
        #expect(library.continueWatching.map(\.path) == ["/tv/s4e1.mkv"])
    }

    @MainActor
    @Test func removedItemsLeaveContinueWatchingUntilPlayedAgain() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([makeItem("/movies/a-\(UUID()).mkv", kind: .movie)])
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        for _ in 0..<50 where library.index.itemsByID.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let film = try #require(library.index.itemsByID.values.first)

        library.savePosition(1200, duration: 6000, for: film)
        library.removeFromContinueWatching(film)
        #expect(library.continueWatching.isEmpty)
        try await Task.sleep(for: .milliseconds(10))
        library.savePosition(1300, duration: 6000, for: film)
        #expect(library.continueWatching.map(\.path) == [film.path])
    }

    @MainActor
    @Test func findsAPersonsTitlesInTheLibrary() async throws {
        let database = try LibraryDatabase.inMemory()
        let tag = UUID().uuidString
        try database.upsert([
            makeItem("/m/iron-\(tag).mkv", kind: .movie, title: "Iron Man", year: 2008),
            makeItem("/m/iron-remake-\(tag).mkv", kind: .movie, title: "Iron Man", year: 2030),
            makeItem("/m/chaplin-\(tag).mkv", kind: .movie, title: "Chaplin"),
            makeItem("/tv/ally-\(tag).mkv", kind: .episode, show: "Ally McBeal", season: 1, episode: 1),
        ].map { var item = $0; item.duration = 6000; return item })
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        for _ in 0..<50 where library.index.shows.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let credits = [
            PersonProfile.Credit(title: "Iron Man", isShow: false, year: 2008),
            PersonProfile.Credit(title: "Chaplin", isShow: false, year: 1992),
            PersonProfile.Credit(title: "Ally McBeal", isShow: true, year: 1997),
            PersonProfile.Credit(title: "Oppenheimer", isShow: false, year: 2023),
        ]
        let found = library.titles(in: PersonProfile(name: "R", credits: credits))
        // The 2030 "Iron Man" is another film; Chaplin without a year still counts.
        #expect(Set(found.movies.map(\.path)) == ["/m/iron-\(tag).mkv", "/m/chaplin-\(tag).mkv"])
        #expect(found.shows.map(\.title) == ["Ally McBeal"])
    }

    @MainActor
    @Test func removedBooksLeaveJumpBackInUntilPlayedAgain() async throws {
        let database = try LibraryDatabase.inMemory()
        try database.upsert([makeItem("/books/b-\(UUID()).m4b", kind: .audiobook, album: "A Book")])
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        for _ in 0..<50 where library.index.books.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let book = try #require(library.index.books.first)

        library.savePosition(20, duration: 60, for: book.parts[0])
        library.removeFromContinueWatching(book)
        #expect(library.booksInProgress.isEmpty)
        try await Task.sleep(for: .milliseconds(10))
        library.savePosition(25, duration: 60, for: book.parts[0])
        #expect(library.booksInProgress.map(\.id) == [book.id])
    }
}

struct SubtitleFinderTests {
    @Test func findsSubtitlesBesideAndInSubsFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Subs-\(UUID())")
        let subs = folder.appendingPathComponent("Subs/My.Show.S02E05")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        for file in ["My.Show.S02E05.mkv", "My.Show.S02E05.en.srt", "My.Show.S02E05.srt", "Other.Movie.srt", "notes.txt", "readme.nfo"] {
            try Data().write(to: folder.appendingPathComponent(file))
        }
        try Data().write(to: subs.appendingPathComponent("2_English.srt"))

        let found = SubtitleFinder.candidates(for: folder.appendingPathComponent("My.Show.S02E05.mkv")).map(\.lastPathComponent)
        #expect(Array(found.prefix(2)) == ["My.Show.S02E05.srt", "My.Show.S02E05.en.srt"])
        #expect(Set(found) == ["My.Show.S02E05.srt", "My.Show.S02E05.en.srt", "Other.Movie.srt", "2_English.srt"])
    }
}

struct ShowMarkerTests {
    @MainActor
    @Test func marksAndNextShow() async throws {
        let database = try LibraryDatabase.inMemory()
        let tag = UUID().uuidString
        try database.upsert([
            makeItem("/tv/a1.mkv", kind: .episode, show: "A \(tag)", season: 1, episode: 1),
            makeItem("/tv/b1.mkv", kind: .episode, show: "B \(tag)", season: 1, episode: 1),
            makeItem("/tv/b2.mkv", kind: .episode, show: "B \(tag)", season: 1, episode: 2),
        ].map { var item = $0; item.duration = 3000; return item })
        let library = Library(database: database, artwork: ArtworkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID())")))
        for _ in 0..<50 where library.index.shows.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let byPath = Dictionary(uniqueKeysWithValues: library.index.itemsByID.values.map { ($0.path, $0) })
        let a1 = try #require(byPath["/tv/a1.mkv"]), b1 = try #require(byPath["/tv/b1.mkv"])

        library.setRecapEnd(95, for: a1)
        library.setCreditsStart(2940, duration: 3000, for: a1)
        #expect(library.markers(for: a1)?.recapEnd == 95)
        #expect(library.markers(for: a1)?.creditsLength == 60)
        #expect(library.markers(for: b1) == nil)

        // After show A: the first unwatched episode of B.
        #expect(library.nextShow(after: Show.id(for: a1))?.path == "/tv/b1.mkv")
        // B partly watched: pick it up where it was.
        library.savePosition(3000, duration: 3000, for: b1)
        #expect(library.nextShow(after: Show.id(for: a1))?.path == "/tv/b2.mkv")

        library.setRecapEnd(nil, for: a1)
        library.setCreditsStart(nil, duration: 3000, for: a1)
        #expect(library.markers(for: a1) == nil)
    }
}

struct MediaDetailsTests {
    @Test func readsMovieAndShowDetails() throws {
        let movie = #"{"title":"Iron Man","release_date":"2008-04-30","runtime":126,"vote_average":7.7,"tagline":"Heroes aren't born.","overview":"Tony Stark...","genres":[{"name":"Action"}],"credits":{"cast":[{"name":"Robert Downey Jr.","character":"Tony Stark","profile_path":"/r.jpg"}],"crew":[{"name":"Jon Favreau","job":"Director"},{"name":"X","job":"Writer"}]},"backdrop_path":"/b.jpg"}"#
        let iron = try #require(ArtworkFetcher.mediaDetails(from: Data(movie.utf8)))
        #expect(iron.year == 2008 && iron.runtimeMinutes == 126 && iron.makers == ["Jon Favreau"])
        #expect(iron.cast.first?.role == "Tony Stark" && iron.cast.first?.photo?.absoluteString == "https://image.tmdb.org/t/p/w185/r.jpg")
        #expect(iron.backdrop?.absoluteString == "https://image.tmdb.org/t/p/w1280/b.jpg")

        let show = #"{"name":"Yellowstone","first_air_date":"2018-06-20","number_of_seasons":5,"episode_run_time":[],"vote_average":0,"created_by":[{"name":"Taylor Sheridan"}],"overview":""}"#
        let yellowstone = try #require(ArtworkFetcher.mediaDetails(from: Data(show.utf8)))
        #expect(yellowstone.seasons == 5 && yellowstone.makers == ["Taylor Sheridan"])
        #expect(yellowstone.rating == nil && yellowstone.overview == nil && yellowstone.runtimeMinutes == nil)
    }

    @Test func readsPersonProfiles() throws {
        let movie = #"{"title":"Iron Man","credits":{"cast":[{"id":3223,"name":"Robert Downey Jr.","character":"Tony Stark"}]}}"#
        #expect(try #require(ArtworkFetcher.mediaDetails(from: Data(movie.utf8))).cast.first?.id == 3223)

        let person = #"{"name":"Robert Downey Jr.","biography":"An actor.","birthday":"1965-04-04","place_of_birth":"New York City","known_for_department":"Acting","profile_path":"/p.jpg","combined_credits":{"cast":[{"media_type":"movie","title":"Iron Man","character":"Tony Stark","release_date":"2008-04-30","poster_path":"/i.jpg","vote_count":25000},{"media_type":"tv","name":"Ally McBeal","character":"Larry Paul","first_air_date":"1997-09-08","vote_count":900},{"media_type":"movie","title":"Iron Man","character":"Tony Stark (uncredited)","release_date":"2008-04-30","vote_count":25000},{"media_type":"movie","title":"Chaplin","release_date":"","vote_count":1200}]}}"#
        let profile = try #require(ArtworkFetcher.personProfile(from: Data(person.utf8)))
        #expect(profile.name == "Robert Downey Jr." && profile.biography == "An actor." && profile.knownFor == "Acting")
        #expect(profile.birthday == "1965-04-04" && profile.placeOfBirth == "New York City")
        #expect(profile.photo?.absoluteString == "https://image.tmdb.org/t/p/w500/p.jpg")
        // Most-voted first, each title once.
        #expect(profile.credits.map(\.title) == ["Iron Man", "Chaplin", "Ally McBeal"])
        #expect(profile.credits[0].isShow == false && profile.credits[0].year == 2008 && profile.credits[0].role == "Tony Stark")
        #expect(profile.credits[0].poster?.absoluteString == "https://image.tmdb.org/t/p/w342/i.jpg")
        #expect(profile.credits[1].year == nil && profile.credits[2].isShow == true)
    }

    @Test func readsSeasonEpisodes() throws {
        let season = #"{"name":"Season 3","episodes":[{"episode_number":1,"name":"You're the Indian Now","overview":"John learns...","still_path":"/s1.jpg","runtime":48,"air_date":"2020-06-21"},{"episode_number":2,"name":"","overview":"","still_path":null}]}"#
        let details = try #require(ArtworkFetcher.seasonDetails(from: Data(season.utf8)))
        let episodes = try #require(details.episodes)
        #expect(episodes.map(\.number) == [1, 2])
        #expect(episodes[0].title == "You're the Indian Now" && episodes[0].runtimeMinutes == 48)
        #expect(episodes[0].still?.absoluteString == "https://image.tmdb.org/t/p/w500/s1.jpg")
        #expect(episodes[1].title == nil && episodes[1].overview == nil && episodes[1].still == nil)
    }

    @Test func cachesDetails() throws {
        let database = try LibraryDatabase.inMemory()
        #expect(try database.cachedDetails("movie:x:0") == nil)
        try database.cacheDetails(MediaDetails(title: "X", year: 2000), key: "movie:x:0")
        #expect(try database.cachedDetails("movie:x:0")?.year == 2000)
    }
}

struct ArtistAndBookInfoTests {
    @Test func picksTheBandArticle() {
        let json = #"{"query":{"pages":{"2":{"index":2,"title":"Lamb of God (album)","description":"2020 studio album by Lamb of God","extract":"An album."},"1":{"index":1,"title":"Lamb of God (band)","description":"American heavy metal band","extract":"Lamb of God is an American heavy metal band."},"3":{"index":3,"title":"Lamb of God","description":"Christian title for Jesus","extract":"A title."}}}}"#
        let bio = ArtworkFetcher.artistBio(from: Data(json.utf8), name: "Lamb of God")
        #expect(bio?.overview == "Lamb of God is an American heavy metal band.")
        #expect(ArtworkFetcher.artistBio(from: Data(json.utf8), name: "Lamb") == nil)
    }

    @Test func readsBookDescriptions() {
        #expect(ArtworkFetcher.bookDescription(from: Data(#"{"description":"A desert planet."}"#.utf8)) == "A desert planet.")
        #expect(ArtworkFetcher.bookDescription(from: Data(#"{"description":{"type":"/type/text","value":"Spice.\n----------\nSee also: x"}}"#.utf8)) == "Spice.")
        #expect(ArtworkFetcher.bookDescription(from: Data(#"{"title":"x"}"#.utf8)) == nil)
    }
}
