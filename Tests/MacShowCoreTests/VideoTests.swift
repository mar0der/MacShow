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
