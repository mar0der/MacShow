import AppIntents
import MacShowCore

/// The running app's library and player, for Shortcuts and Siri.
@MainActor
enum AppServices {
    static var library: Library?
    static var player: Player?

    /// macshow://play?q=words, macshow://pause, …/resume, …/playpause, …/next,
    /// …/previous: for Shortcuts' Open URL action, scripts and other apps.
    static func handle(_ url: URL) {
        guard let player else { return }
        switch url.host {
        case "play":
            if let words = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
                _ = play(words)
            } else {
                player.setPaused(false)
            }
        case "pause": player.setPaused(true)
        case "resume": player.setPaused(false)
        case "playpause": player.togglePause()
        case "next": player.next()
        case "previous": player.previous()
        default: break
        }
    }

    /// What "play <words>" means: a playlist, album, artist, show or song, in
    /// that order, by name. Returns what's playing, or nil if nothing matched.
    static func play(_ words: String) -> String? {
        guard let library, let player else { return nil }
        let query = words.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        let index = library.index
        func named(_ name: String) -> Bool { name.lowercased() == query }
        func containing(_ name: String) -> Bool { name.lowercased().contains(query) }
        if let list = library.playlists.first(where: { named($0.playlist.name) }) ?? library.playlists.first(where: { containing($0.playlist.name) }), !list.items.isEmpty {
            player.play(list.items)
            return list.playlist.name
        }
        if let album = index.albums.first(where: { named($0.title) }) ?? index.albums.first(where: { containing($0.title) }) {
            player.play(album.tracks)
            return "\(album.title) by \(album.artist)"
        }
        if let artist = index.artists.first(where: { named($0.name) && !$0.songs.isEmpty }) {
            player.play(artist.songs.shuffled())
            return artist.name
        }
        if let show = index.shows.first(where: { named($0.title) }) ?? index.shows.first(where: { containing($0.title) }) {
            let next = show.episodes.first { library.positions[$0.id ?? -1]?.isResumable == true }
                ?? show.episodes.first { library.positions[$0.id ?? -1]?.isFinished != true } ?? show.episodes[0]
            player.play(show.episodes, startAt: show.episodes.firstIndex(of: next) ?? 0, showVideo: true)
            AppDelegate.openMainWindow?()
            return show.title
        }
        if let song = index.songs.first(where: { named($0.title) }) ?? index.songs.first(where: { containing($0.title) }) {
            player.play([song])
            return [song.title, song.artist].compactMap { $0 }.joined(separator: " by ")
        }
        return nil
    }
}

struct PlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Play in MacShow"
    static let description = IntentDescription("Plays a playlist, album, artist, show or song from your MacShow library.")

    @Parameter(title: "What", requestValueDialog: "What would you like to play?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let playing = AppServices.play(query) else {
            return .result(dialog: "Nothing called \(query) in your MacShow library.")
        }
        return .result(dialog: "Playing \(playing).")
    }
}

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause MacShow"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.player?.togglePause()
        return .result()
    }
}

struct NextIntent: AppIntent {
    static let title: LocalizedStringResource = "Next in MacShow"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.player?.next()
        return .result()
    }
}

struct PreviousIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous in MacShow"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.player?.previous()
        return .result()
    }
}

/// Siri phrases (and the actions Shortcuts shows without setup).
struct MacShowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayItemIntent(), phrases: ["Play \(\.$item) in \(.applicationName)", "Put on \(\.$item) in \(.applicationName)"],
                    shortTitle: "Play Item", systemImageName: "play.circle")
        AppShortcut(intent: PlayIntent(), phrases: ["Play something in \(.applicationName)", "Play music in \(.applicationName)"],
                    shortTitle: "Play", systemImageName: "play.fill")
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Play or Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextIntent(), phrases: ["Next song in \(.applicationName)", "Skip in \(.applicationName)"],
                    shortTitle: "Next", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousIntent(), phrases: ["Previous song in \(.applicationName)"],
                    shortTitle: "Previous", systemImageName: "backward.fill")
    }
}

/// Something in the library Siri and Shortcuts can name: an album, artist,
/// playlist, show or song ("Play Kamikaze in MacShow").
struct LibraryItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Library Item"
    static let defaultQuery = LibraryItemQuery()

    /// "album:<id>", "artist:<id>", "playlist:<id>", "show:<id>" or "song:<id>".
    let id: String
    let name: String
    let kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }
}

struct LibraryItemQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        identifiers.compactMap(AppServices.entity(id:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        AppServices.entities(matching: string)
    }

    /// What Siri learns names from: playlists, albums and shows.
    @MainActor
    func suggestedEntities() async throws -> [LibraryItemEntity] {
        AppServices.suggestedEntities()
    }
}

struct PlayItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Item in MacShow"
    static let description = IntentDescription("Plays an album, artist, playlist, show or song from your MacShow library.")

    @Parameter(title: "Item")
    var item: LibraryItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppServices.play(entity: item)
        return .result(dialog: "Playing \(item.name).")
    }
}

extension AppServices {
    static func entity(id: String) -> LibraryItemEntity? {
        guard let library else { return nil }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let index = library.index
        switch parts[0] {
        case "album": return index.albums.first { $0.id == parts[1] }.map { LibraryItemEntity(id: id, name: $0.title, kind: $0.artist) }
        case "artist": return index.artists.first { $0.id == parts[1] }.map { LibraryItemEntity(id: id, name: $0.name, kind: String(localized: "Artist")) }
        case "show": return index.shows.first { $0.id == parts[1] }.map { LibraryItemEntity(id: id, name: $0.title, kind: String(localized: "TV Show")) }
        case "playlist":
            return library.playlists.first { $0.playlist.id.map(String.init) == parts[1] }
                .map { LibraryItemEntity(id: id, name: $0.playlist.name, kind: String(localized: "Playlist")) }
        case "song":
            return Int64(parts[1]).flatMap { index.itemsByID[$0] }.map { LibraryItemEntity(id: id, name: $0.title, kind: $0.artist ?? String(localized: "Song")) }
        default: return nil
        }
    }

    static func entities(matching string: String) -> [LibraryItemEntity] {
        guard let library else { return [] }
        let query = string.lowercased()
        let index = library.index
        func has(_ name: String) -> Bool { name.lowercased().contains(query) }
        let ids = library.playlists.filter { has($0.playlist.name) }.compactMap { $0.playlist.id.map { "playlist:\($0)" } }
            + index.albums.filter { has($0.title) }.map { "album:" + $0.id }
            + index.artists.filter { has($0.name) && !$0.isFeaturedOnly }.map { "artist:" + $0.id }
            + index.shows.filter { has($0.title) }.map { "show:" + $0.id }
            + index.songs.filter { has($0.title) }.prefix(20).compactMap { $0.id.map { "song:\($0)" } }
        return ids.prefix(40).compactMap(entity(id:))
    }

    static func suggestedEntities() -> [LibraryItemEntity] {
        guard let library else { return [] }
        let ids = library.playlists.compactMap { $0.playlist.id.map { "playlist:\($0)" } }
            + library.index.albums.prefix(200).map { "album:" + $0.id }
            + library.index.shows.map { "show:" + $0.id }
            + library.index.artists.filter { !$0.isFeaturedOnly }.prefix(100).map { "artist:" + $0.id }
        return ids.compactMap(entity(id:))
    }

    static func play(entity: LibraryItemEntity) {
        guard let library, let player else { return }
        let index = library.index
        let parts = entity.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "album": if let album = index.albums.first(where: { $0.id == parts[1] }) { player.play(album.tracks) }
        case "artist": if let artist = index.artists.first(where: { $0.id == parts[1] }) { player.play(artist.songs.shuffled()) }
        case "playlist":
            if let list = library.playlists.first(where: { $0.playlist.id.map(String.init) == parts[1] }), !list.items.isEmpty { player.play(list.items) }
        case "show": _ = play(entity.name)
        case "song": if let song = Int64(parts[1]).flatMap({ index.itemsByID[$0] }) { player.play([song]) }
        default: break
        }
    }
}
