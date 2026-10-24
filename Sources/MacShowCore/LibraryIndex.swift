import Foundation

public struct Album: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var artworkKey: String?
    /// In disc, track, title order.
    public var tracks: [MediaItem]
    public var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
}

public struct Artist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Albums credited to this artist, newest first.
    public var albums: [Album]
    /// Every song by this artist, including ones on compilations.
    public var songs: [MediaItem]
    public var artworkKey: String? { albums.lazy.compactMap(\.artworkKey).first ?? songs.lazy.compactMap(\.artworkKey).first }
}

public struct Show: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artworkKey: String?
    /// In season, episode order.
    public var episodes: [MediaItem]
    public var seasons: [Int] { Array(Set(episodes.compactMap(\.season))).sorted() }
}

/// An audiobook: one file with chapters, or a folder of files played in order.
public struct Book: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var author: String?
    public var artworkKey: String?
    public var parts: [MediaItem]
    public var duration: Double { parts.reduce(0) { $0 + $1.duration } }
}

/// The library grouped the ways the screens show it. Rebuilt whenever items change.
public struct LibraryIndex: Sendable {
    public var albums: [Album] = []
    public var artists: [Artist] = []
    public var songs: [MediaItem] = []
    public var movies: [MediaItem] = []
    /// Videos shorter than 20 minutes that aren't TV episodes: clips, recordings, phone videos.
    public var homeVideos: [MediaItem] = []
    public var shows: [Show] = []
    public var books: [Book] = []
    public var recentlyAdded: [MediaItem] = []

    public init() {}

    public var isEmpty: Bool {
        songs.isEmpty && movies.isEmpty && homeVideos.isEmpty && shows.isEmpty && books.isEmpty
    }

    public init(items: [MediaItem]) {
        let byKind = Dictionary(grouping: items, by: \.kind)
        let music = byKind[.music] ?? []

        songs = music.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        albums = Dictionary(grouping: music, by: Self.albumKey)
            .map { key, tracks in
                let sorted = tracks.sorted(by: Self.trackOrder)
                return Album(
                    id: key, title: Self.mostCommon(sorted.compactMap(\.album)) ?? Self.folderName(sorted[0]),
                    artist: Self.albumArtist(of: sorted),
                    year: sorted.compactMap(\.year).max(), artworkKey: sorted.lazy.compactMap(\.artworkKey).first,
                    tracks: sorted
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let albumsByArtist = Dictionary(grouping: albums) { $0.artist.lowercased() }
        let songsByArtist = Dictionary(grouping: music.filter { $0.artist != nil }) { $0.artist!.lowercased() }
        artists = Set(albumsByArtist.keys).union(songsByArtist.keys)
            .subtracting(["various artists"])
            .map { key in
                let songs = (songsByArtist[key] ?? []).sorted(by: Self.trackOrder)
                let albums = (albumsByArtist[key] ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                let name = Self.mostCommon(songs.compactMap(\.artist)) ?? albums[0].artist
                return Artist(id: key, name: name, albums: albums, songs: songs)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let videos = (byKind[.movie] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        movies = videos.filter { $0.duration >= Self.homeVideoMaxDuration }
        homeVideos = videos.filter { $0.duration < Self.homeVideoMaxDuration }
        shows = Dictionary(grouping: byKind[.episode] ?? []) { ($0.show ?? "Unknown Show").lowercased() }
            .map { key, episodes in
                let sorted = episodes.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
                return Show(id: key, title: sorted[0].show ?? "Unknown Show",
                            artworkKey: sorted.lazy.compactMap(\.artworkKey).first, episodes: sorted)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        books = Dictionary(grouping: byKind[.audiobook] ?? [], by: Self.bookKey)
            .map { key, parts in
                let sorted = parts.sorted(by: Self.trackOrder)
                let first = sorted[0]
                let isSingleFile = sorted.count == 1
                let title = first.album ?? (isSingleFile ? first.title : first.url.deletingLastPathComponent().lastPathComponent)
                return Book(id: key, title: title, author: first.albumArtist ?? first.artist,
                            artworkKey: sorted.lazy.compactMap(\.artworkKey).first, parts: sorted)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        recentlyAdded = Array(items.sorted { $0.addedAt > $1.addedAt }.prefix(20))
    }

    static let homeVideoMaxDuration: Double = 20 * 60

    /// Tracks with an album artist group by (album artist, album). Without one,
    /// an album is the album name within a folder, so a various-artists
    /// compilation stays together and untagged rips group by folder.
    static func albumKey(_ item: MediaItem) -> String {
        let album = (item.album ?? folderName(item)).lowercased()
        if let albumArtist = item.albumArtist {
            return "artist\u{1F}\(albumArtist.lowercased())\u{1F}\(album)"
        }
        return "folder\u{1F}\(item.url.deletingLastPathComponent().path.lowercased())\u{1F}\(album)"
    }

    /// The album artist tag, else the one artist on every track, else "Various Artists".
    static func albumArtist(of tracks: [MediaItem]) -> String {
        if let tagged = mostCommon(tracks.compactMap(\.albumArtist)) { return tagged }
        let artists = Set(tracks.compactMap { $0.artist?.lowercased() })
        if artists.count > 1 { return "Various Artists" }
        return mostCommon(tracks.compactMap(\.artist)) ?? "Unknown Artist"
    }

    static func folderName(_ item: MediaItem) -> String {
        item.url.deletingLastPathComponent().lastPathComponent
    }

    /// A file with chapters (or an .m4b) is a book on its own; other audiobook
    /// files belong to the book of their folder.
    static func bookKey(_ item: MediaItem) -> String {
        if item.chapterCount > 0 || item.url.pathExtension.lowercased() == "m4b" { return item.path }
        return item.url.deletingLastPathComponent().path
    }

    /// The spelling most tracks use ("Live" over a stray "live"); ties go to the first seen.
    static func mostCommon(_ values: [String]) -> String? {
        let counts = values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return values.max { counts[$0]! < counts[$1]! }
    }

    static func trackOrder(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let left = (a.discNumber ?? 1, a.trackNumber ?? Int.max)
        let right = (b.discNumber ?? 1, b.trackNumber ?? Int.max)
        if left != right { return left < right }
        return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
    }
}
