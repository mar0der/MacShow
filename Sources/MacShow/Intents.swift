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
