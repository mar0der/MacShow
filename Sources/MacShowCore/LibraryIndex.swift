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
    /// Songs this artist leads, including duets ("Eminem & Jelly Roll") and
    /// ones on compilations.
    public var songs: [MediaItem]
    /// Songs led by someone else that this artist is featured on.
    public var appearances: [MediaItem] = []
    /// For an artist who is only ever featured: who they appear with most.
    public var appearsWith: String?
    public var isFeaturedOnly: Bool { albums.isEmpty && songs.isEmpty }
    public var artworkKey: String? { albums.lazy.compactMap(\.artworkKey).first ?? songs.lazy.compactMap(\.artworkKey).first }
}

/// Where a show's recap or intro ends (seconds from the start) and how long
/// its credits run (seconds before the end).
public struct ShowMarkers: Codable, Hashable, Sendable {
    public var recapEnd: Double?
    public var creditsLength: Double?
    public init() {}
}

public struct Show: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artworkKey: String?
    /// In season, episode order.
    public var episodes: [MediaItem]
    public var seasons: [Int] { Array(Set(episodes.compactMap(\.season))).sorted() }

    /// The id of the show an episode belongs to.
    public static func id(for episode: MediaItem) -> String { (episode.show ?? "Unknown Show").lowercased() }
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
    /// Videos in folders marked Personal, plus other videos shorter than 20
    /// minutes that aren't TV episodes: clips, recordings, phone videos.
    public var homeVideos: [MediaItem] = []
    /// Videos in a "Music Videos" folder, named like "(Official Video)", or moved
    /// there. They're also in `songs`, where they play without the picture.
    public var musicVideos: [MediaItem] = []
    /// Videos in a Sport or Sports folder (or moved there), grouped on screen by
    /// `sportCategory(of:)`.
    public var sports: [MediaItem] = []
    /// Videos in a Documentaries folder, or moved there.
    public var documentaries: [MediaItem] = []
    /// Items in folders marked Adult, when they're shown at all. They appear
    /// nowhere else: not in Home, search, `itemsByID` or any other list.
    public var adult: [MediaItem] = []
    public var shows: [Show] = []
    public var books: [Book] = []
    public var recentlyAdded: [MediaItem] = []
    public var itemsByID: [Int64: MediaItem] = [:]
    /// "title artist album" lowercased, parallel to `songs`, so search doesn't
    /// re-lowercase the library on every keystroke.
    public var songSearchKeys: [String] = []

    public init() {}

    /// Songs found more than once (the same track in several folders), best copy
    /// first. Only the best copy appears in albums, artists and songs.
    public var duplicates: [[MediaItem]] = []
    /// Kept song id → all its copies, best first (to fall back to a reachable copy).
    public var copies: [Int64: [MediaItem]] = [:]
    /// Episode id → the episode after it in its show.
    public var nextEpisode: [Int64: MediaItem] = [:]

    public var isEmpty: Bool {
        songs.isEmpty && movies.isEmpty && homeVideos.isEmpty && musicVideos.isEmpty && shows.isEmpty && books.isEmpty
            && sports.isEmpty && documentaries.isEmpty
    }

    /// Groups `items`, applying `rules`. Adult items are left out entirely
    /// unless `showingAdult`, and then only listed in `adult`.
    /// Groups `items`, applying `rules`. Adult items are left out entirely
    /// unless `showingAdult`, and then only listed in `adult`. Items in
    /// `chosenKinds` (moved to a category by you) keep their kind as it is.
    public init(items allItems: [MediaItem], rules: FolderRules = FolderRules(), showingAdult: Bool = false,
                chosenKinds: Set<String> = []) {
        var items: [MediaItem] = []
        for var item in allItems {
            let rule = rules.kind(for: item.path)
            if !chosenKinds.contains(item.path) {
                item.kind = Self.category(of: item, inPersonalFolder: rule == .personal)
            }
            switch rule {
            case .excluded: continue
            case .adult: if showingAdult { adult.append(item) }
            case .personal, nil: items.append(item)
            }
        }
        adult.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let byKind = Dictionary(grouping: items, by: \.kind)
        let (music, duplicateGroups) = Self.removingDuplicates(byKind[.music] ?? [])
        duplicates = duplicateGroups
        for group in duplicateGroups {
            if let id = group[0].id { copies[id] = group }
        }

        musicVideos = (byKind[.musicVideo] ?? []).map(Self.musicVideoDetails)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        songs = (music + musicVideos).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        songSearchKeys = songs.map { [$0.title, $0.artist, $0.album].compactMap { $0 }.joined(separator: " ").lowercased() }
        // A folder whose tracks disagree on album artist (a compilation where only
        // some tracks are tagged) stays one album, grouped by folder.
        // Worked out once per song: thousands of songs share a few hundred folders.
        let folderKeys = Dictionary(music.map { ($0.path, Self.folderAlbumKey($0)) }, uniquingKeysWith: { first, _ in first })
        let mixedFolders = Set(Dictionary(grouping: music, by: { folderKeys[$0.path]! })
            .filter { Set($0.value.map(\.albumArtist)).count > 1 }.keys)
        albums = Dictionary(grouping: music) { mixedFolders.contains(folderKeys[$0.path]!) ? folderKeys[$0.path]! : Self.albumKey($0) }
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
        // Each song goes to its main artist; the others credited on it are featured.
        let soloArtists = Set(music.flatMap { [$0.artist, $0.albumArtist] }.compactMap { $0?.lowercased() })
        // Many songs share a tag: split each distinct one once.
        var creditCache: [String: [String]] = [:]
        func credits(_ tag: String) -> [String] {
            if let known = creditCache[tag] { return known }
            let names = Self.credits(tag, soloArtists: soloArtists)
            creditCache[tag] = names
            return names
        }
        var spellings: [String: [String]] = [:]
        var songsByArtist: [String: [MediaItem]] = [:], appearancesByArtist: [String: [MediaItem]] = [:]
        var leadsOfAppearances: [String: [String]] = [:]
        for song in music {
            guard let tag = song.artist else { continue }
            var names = credits(tag)
            if let albumArtist = song.albumArtist, albumArtist.lowercased() != "various artists",
               let lead = credits(albumArtist).first {
                names = [lead] + names.filter { $0.lowercased() != lead.lowercased() }
            }
            for guest in Self.featuredInTitle(song.title) where !names.contains(where: { $0.lowercased() == guest.lowercased() }) {
                names.append(guest)
            }
            for name in names { spellings[name.lowercased(), default: []].append(name) }
            songsByArtist[names[0].lowercased(), default: []].append(song)
            for name in names.dropFirst() {
                appearancesByArtist[name.lowercased(), default: []].append(song)
                leadsOfAppearances[name.lowercased(), default: []].append(names[0])
            }
        }
        let albumsByArtist = Dictionary(grouping: albums) { album in
            (credits(album.artist).first ?? album.artist).lowercased()
        }
        artists = Set(albumsByArtist.keys).union(songsByArtist.keys).union(appearancesByArtist.keys)
            .subtracting(["various artists"])
            .map { key in
                let albums = (albumsByArtist[key] ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                var artist = Artist(id: key, name: Self.mostCommon(spellings[key] ?? []) ?? albums[0].artist, albums: albums,
                                    songs: (songsByArtist[key] ?? []).sorted(by: Self.trackOrder))
                artist.appearances = (appearancesByArtist[key] ?? []).sorted(by: Self.trackOrder)
                if artist.isFeaturedOnly { artist.appearsWith = Self.mostCommon(leadsOfAppearances[key] ?? []) }
                return artist
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        movies = (byKind[.movie] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        homeVideos = (byKind[.homeVideo] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        sports = (byKind[.sport] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        documentaries = (byKind[.documentary] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        shows = Dictionary(grouping: byKind[.episode] ?? [], by: Show.id(for:))
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

        for show in shows {
            for (episode, next) in zip(show.episodes, show.episodes.dropFirst()) {
                if let id = episode.id { nextEpisode[id] = next }
            }
        }
        recentlyAdded = Array(items.sorted { $0.addedAt > $1.addedAt }.prefix(20))
        itemsByID = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.id.map { ($0, item) } })
    }

    static let homeVideoMaxDuration: Double = 20 * 60

    /// Where a video goes when you haven't chosen: music videos by folder or
    /// name, Personal folders to Home Videos, Sports and Documentaries folders to
    /// theirs, other short clips to Home Videos, the rest stays.
    static func category(of item: MediaItem, inPersonalFolder: Bool) -> MediaItem.Kind {
        guard item.kind == .movie || item.kind == .episode else { return item.kind }
        let path = item.path.lowercased()
        if path.contains("/music videos/") || path.contains("/musicvideos/")
            || item.title.range(of: #"\b(official\s+(music\s+)?video|music\s+video)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .musicVideo
        }
        if inPersonalFolder { return .homeVideo }
        let folders = item.url.deletingLastPathComponent().pathComponents.map { $0.lowercased() }
        if folders.contains(where: sportsFolders.contains) { return .sport }
        if folders.contains(where: ["documentaries", "documentary"].contains) { return .documentary }
        if item.kind == .movie, item.duration < homeVideoMaxDuration { return .homeVideo }
        return item.kind
    }

    private static let sportsFolders: Set<String> = ["sport", "sports"]

    /// The kind of sport: the item's genre (from its tags, Get Info or an agent),
    /// else the folder right under the Sports folder ("Sports/Formula 1/…"),
    /// unless that folder is one event: dated ("…_27_02_14") or a match ("A vs B").
    public static func sportCategory(of item: MediaItem) -> String? {
        if let genre = item.genre { return genre }
        let folders = item.url.deletingLastPathComponent().pathComponents
        guard let sports = folders.lastIndex(where: { sportsFolders.contains($0.lowercased()) }), sports + 1 < folders.count else { return nil }
        let folder = folders[sports + 1]
        let isEvent = folder.range(of: #"\d{1,2}[._-]\d{1,2}[._-]\d{2,4}|\bvs\.?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        return isEvent ? nil : folder
    }

    /// Adult videos shorter than this are clips; longer ones are full videos.
    public static func isClip(_ item: MediaItem) -> Bool { item.duration < 5 * 60 }

    /// "Artist - Song (Official Music Video)" without tags → artist "Artist", title "Song".
    static func musicVideoDetails(_ item: MediaItem) -> MediaItem {
        var item = item
        var title = item.title.replacingOccurrences(of: #"\s*[(\[][^)\]]*\b(video|official|lyrics?|audio|visuali[sz]er|4k|hd)\b[^)\]]*[)\]]"#,
                                                    with: "", options: [.regularExpression, .caseInsensitive])
        if item.artist == nil, let dash = title.range(of: " - ") {
            item.artist = String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            title = String(title[dash.upperBound...])
        }
        item.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? item.title : title.trimmingCharacters(in: .whitespaces)
        return item
    }

    /// Groups copies of the same song and keeps the best one of each. Only
    /// songs tagged with an artist and an album are compared (untagged rips named
    /// "Track 01" are not the same song), and copies must agree on disc, track
    /// number and title and be within two seconds of each other in length.
    static func removingDuplicates(_ songs: [MediaItem]) -> (kept: [MediaItem], duplicates: [[MediaItem]]) {
        var kept = songs.filter { $0.artist == nil || $0.album == nil }
        var duplicates: [[MediaItem]] = []
        let tagged = songs.filter { $0.artist != nil && $0.album != nil }
        let groups = Dictionary(grouping: tagged) { song in
            [song.title, song.artist!, song.album!, String(song.discNumber ?? 1), song.trackNumber.map(String.init) ?? ""]
                .joined(separator: "\u{1F}").lowercased()
        }
        for group in groups.values {
            // Split into runs of similar length: 179.98 s and 180.03 s are one song, 3:00 and 4:10 aren't.
            var clusters: [[MediaItem]] = []
            for song in group.sorted(by: { $0.duration < $1.duration }) {
                if let last = clusters.last?.last, song.duration - last.duration <= 2 {
                    clusters[clusters.count - 1].append(song)
                } else {
                    clusters.append([song])
                }
            }
            for cluster in clusters {
                let ranked = cluster.sorted(by: isBetterCopy)
                kept.append(ranked[0])
                if ranked.count > 1 { duplicates.append(ranked) }
            }
        }
        duplicates.sort { $0[0].title.localizedStandardCompare($1[0].title) == .orderedAscending }
        return (kept, duplicates)
    }

    /// Lossless beats lossy, then a higher sample rate, then the larger file.
    static func isBetterCopy(_ a: MediaItem, _ b: MediaItem) -> Bool {
        func quality(_ item: MediaItem) -> (Int, Double, Int64) {
            let parts = item.formatInfo.components(separatedBy: " · ")
            let lossless = ["FLAC", "ALAC", "PCM", "APE", "WAVPACK", "TTA", "DSD", "MLP", "TRUEHD"].contains { parts.first?.hasPrefix($0) ?? false }
            let rate = parts.last.flatMap { Double($0.replacingOccurrences(of: " kHz", with: "")) } ?? 0
            return (lossless ? 1 : 0, rate, item.fileSize)
        }
        let left = quality(a), right = quality(b)
        if left != right { return left > right }
        return a.path < b.path
    }

    /// Tracks with an album artist group by (album artist, album). Without one,
    /// an album is the album name within a folder, so a various-artists
    /// compilation stays together and untagged rips group by folder.
    static func albumKey(_ item: MediaItem) -> String {
        if let albumArtist = item.albumArtist {
            return "artist\u{1F}\(albumArtist.lowercased())\u{1F}\((item.album ?? folderName(item)).lowercased())"
        }
        return folderAlbumKey(item)
    }

    static func folderAlbumKey(_ item: MediaItem) -> String {
        // String work, not URL: this runs for every song on every library change.
        let folder = item.path[..<(item.path.lastIndex(of: "/") ?? item.path.endIndex)]
        let name = item.album ?? String(folder[(folder.lastIndex(of: "/").map(folder.index(after:)) ?? folder.startIndex)...])
        return "folder\u{1F}\(folder.lowercased())\u{1F}\(name.lowercased())"
    }

    /// The album artist tag, else the one artist on every track, else "Various Artists".
    static func albumArtist(of tracks: [MediaItem]) -> String {
        if let tagged = mostCommon(tracks.compactMap(\.albumArtist)) { return tagged }
        let artists = Set(tracks.compactMap { $0.artist?.lowercased() })
        if artists.count > 1 { return "Various Artists" }
        return mostCommon(tracks.compactMap(\.artist)) ?? "Unknown Artist"
    }

    /// The names credited in an artist tag, main artist first:
    /// "Eminem feat. Big Sean" and "Eminem, Big Sean & Babytron" give each name.
    /// A name joined with "&" or "," only splits when its first part is an artist
    /// on its own in the library, so "Emerson, Lake & Palmer" stays one band;
    /// "feat." and "ft." always split.
    static func credits(_ tag: String, soloArtists: Set<String>) -> [String] {
        // Most tags name one artist: nothing to split.
        let lowered = tag.lowercased()
        guard tag.contains("&") || tag.contains(",") || lowered.contains("feat") || lowered.contains("ft.") else {
            return [tag.trimmingCharacters(in: .whitespaces)]
        }
        func parts(_ text: String) -> [String] {
            text.components(separatedBy: ", ").flatMap { $0.components(separatedBy: " & ") }
                .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()[]"))) }
                .filter { !$0.isEmpty }
        }
        var lead = tag, featured: [String] = []
        if let feat = tag.range(of: #"\s*[(\[]?\b(feat\.?|ft\.|featuring)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            lead = String(tag[..<feat.lowerBound])
            featured = parts(String(tag[feat.upperBound...]))
        }
        var leads = parts(lead)
        if leads.count > 1, !soloArtists.contains(leads[0].lowercased()) {
            leads = [lead.trimmingCharacters(in: .whitespaces)]
        }
        var seen = Set<String>()
        let names = (leads + featured).filter { seen.insert($0.lowercased()).inserted }
        return names.isEmpty ? [tag] : names
    }

    /// Guests named in a title: "Lucky You (feat. Joyner Lucas)" → ["Joyner Lucas"].
    static func featuredInTitle(_ title: String) -> [String] {
        guard let match = title.range(of: #"[(\[](feat\.?|ft\.|featuring)\s+[^)\]]+[)\]]"#, options: [.regularExpression, .caseInsensitive]) else { return [] }
        return Array(credits("x " + title[match], soloArtists: []).dropFirst())
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

extension Book {
    /// Books grouped by author, authors A–Z (books without one last), each
    /// author's books by title.
    public static func byAuthor(_ books: [Book]) -> [(author: String?, books: [Book])] {
        Dictionary(grouping: books) { $0.author?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            .map { ($0.key, $0.value.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
            .sorted { first, second in
                switch (first.0, second.0) {
                case let (a?, b?): a.localizedStandardCompare(b) == .orderedAscending
                case (nil, _): false
                case (_, nil): true
                }
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
