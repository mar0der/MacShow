import Foundation
import Testing
@testable import MacShowCore

struct ClassifierTests {
    @Test(arguments: [
        ("My.Show.S02E05.720p", "My Show", 2, 5),
        ("The Office - s1e03 - Health Care", "The Office", 1, 3),
        ("Mr. Robot 3x07", "Mr. Robot", 3, 7),
        ("Breaking_Bad_S05E14_Ozymandias", "Breaking Bad", 5, 14),
    ])
    func parsesEpisodeFileNames(name: String, show: String, season: Int, episode: Int) throws {
        let parsed = try #require(Classifier.parseEpisode(fileName: name, folders: []))
        #expect(parsed.show == show)
        #expect(parsed.season == season)
        #expect(parsed.episode == episode)
    }

    @Test func episodeWithoutShowNameUsesFolderSkippingSeasonFolder() throws {
        let parsed = try #require(Classifier.parseEpisode(fileName: "S01E02", folders: ["Season 1", "Severance", "TV"]))
        #expect(parsed.show == "Severance")
    }

    @Test func plainMovieIsNotAnEpisode() {
        #expect(Classifier.parseEpisode(fileName: "Big Buck Bunny (2008)", folders: []) == nil)
    }

    @Test(arguments: [
        ("Some.Movie.2020.1080p.BluRay.x264", "Some Movie", 2020),
        ("Big Buck Bunny (2008)", "Big Buck Bunny", 2008),
        ("Blade Runner 2049 (2017) 2160p", "Blade Runner 2049", 2017),
        ("Home Video", "Home Video", nil),
    ] as [(String, String, Int?)])
    func cleansMovieNames(name: String, title: String, year: Int?) {
        let parsed = Classifier.movieName(name)
        #expect(parsed.title == title)
        #expect(parsed.year == year)
    }

    @Test func numberedVideoIsNamedAfterItsFolder() {
        let item = Classifier.makeItem(
            url: URL(fileURLWithPath: "/Movies/Bg clips/14.mp4"),
            metadata: FileMetadata(duration: 30, hasVideo: true),
            fileSize: 1, modified: 0, artworkKey: nil
        )
        #expect(item.kind == .movie)
        #expect(item.title == "Bg clips 14")
    }

    @Test func fileNameInTitleTagIsCleanedUp() {
        let item = Classifier.makeItem(
            url: URL(fileURLWithPath: "/Movies/Asterix.and.the.Vikings.2006.BDRip.mkv"),
            metadata: FileMetadata(tags: ["title": "Asterix.and.the.Vikings.2006.BDRip.BG.Audio"], duration: 4700, hasVideo: true),
            fileSize: 1, modified: 0, artworkKey: nil
        )
        #expect(item.title == "Asterix and the Vikings")
        #expect(item.year == 2006)
        #expect(!Classifier.looksLikeFileName("Mr. Robot"))
        #expect(!Classifier.looksLikeFileName("Big Buck Bunny"))
    }

    @Test func readsNumbersAndYears() {
        #expect(Classifier.leadingNumber("3/10") == 3)
        #expect(Classifier.leadingNumber("07") == 7)
        #expect(Classifier.leadingNumber("") == nil)
        #expect(Classifier.year("2024-05-01") == 2024)
        #expect(Classifier.year("n/a") == nil)
    }

    @Test func stripsTrackNumberFromArtistTags() {
        #expect(Classifier.stripTrackPrefix("043. Modern Talking") == "Modern Talking")
        #expect(Classifier.stripTrackPrefix("50 Cent") == "50 Cent")
        #expect(Classifier.stripTrackPrefix("311") == "311")
    }

    @Test func stripsTrackNumbersFromFileNames() {
        #expect(Classifier.stripTrackNumber("01 All Souls Rising") == "All Souls Rising")
        #expect(Classifier.stripTrackNumber("03 - Sacred Books") == "Sacred Books")
        #expect(Classifier.stripTrackNumber("1984") == "1984")
    }

    @Test func recognisesAudiobooks() {
        #expect(Classifier.isAudiobook(ext: "m4b", tags: [:], folders: []))
        #expect(Classifier.isAudiobook(ext: "mp3", tags: ["genre": "Audiobook"], folders: []))
        #expect(Classifier.isAudiobook(ext: "mp3", tags: [:], folders: ["Dune", "Audiobooks"]))
        #expect(!Classifier.isAudiobook(ext: "mp3", tags: ["genre": "Rock"], folders: ["Music"]))
    }
}
