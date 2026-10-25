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

    @Test func cachesDetails() throws {
        let database = try LibraryDatabase.inMemory()
        #expect(try database.cachedDetails("movie:x:0") == nil)
        try database.cacheDetails(MediaDetails(title: "X", year: 2000), key: "movie:x:0")
        #expect(try database.cachedDetails("movie:x:0")?.year == 2000)
    }
}
