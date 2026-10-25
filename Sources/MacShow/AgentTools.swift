import AppKit
import MacShowCore

/// What agents can do in MacShow, as MCP tools.
@MainActor
enum AgentTools {
    static let instructions = """
    MacShow is the user's media player for their own music, movies, TV shows, music videos and audiobooks. \
    Use search to find things (each result has an id), then play, queue or organize them by id. \
    now_playing tells what's on. Library changes (playlists, categories, details) may be switched off by the user (read-only).
    """

    static func make(library: Library, player: Player) -> [MCPTool] {
        func items(_ arguments: JSONValue) throws -> [MediaItem] {
            let ids = (arguments["ids"]?.array ?? []).compactMap(\.int).map(Int64.init)
            let found = ids.compactMap { library.index.itemsByID[$0] }
            guard !found.isEmpty else { throw MCPToolError("No items with those ids. Use search to find ids.") }
            return found
        }
        let ids: JSONValue = ["type": "array", "items": ["type": "integer"], "description": "Item ids from search"]

        return [
            MCPTool("search", "Find songs, albums, artists, movies, TV shows and episodes, music videos, home videos and audiobooks by words in their title, artist, album or show.",
                    input: ["type": "object", "required": ["query"], "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Results per kind (default 20)"],
                    ]]) { arguments in
                let words = (arguments["query"]?.string ?? "").lowercased().split(separator: " ").map(String.init)
                let limit = arguments["limit"]?.int ?? 20
                func matches(_ text: String) -> Bool { let text = text.lowercased(); return words.allSatisfy(text.contains) }
                func found(_ list: [MediaItem]) -> JSONValue {
                    .array(list.filter { matches([$0.title, $0.artist, $0.album, $0.show].compactMap { $0 }.joined(separator: " ")) }.prefix(limit).map(describe))
                }
                let index = library.index
                return [
                    "songs": found(index.songs),
                    "albums": .array(index.albums.filter { matches("\($0.title) \($0.artist)") }.prefix(limit).map { album in
                        ["title": .string(album.title), "artist": .string(album.artist), "year": album.year.map { .number(Double($0)) } ?? .null,
                         "track_ids": .array(album.tracks.compactMap(\.id).map { .number(Double($0)) })]
                    }),
                    "artists": .array(index.artists.filter { matches($0.name) }.prefix(limit).map { artist in
                        ["name": .string(artist.name), "albums": .number(Double(artist.albums.count)), "songs": .number(Double(artist.songs.count)),
                         "song_ids": .array(artist.songs.prefix(200).compactMap(\.id).map { .number(Double($0)) })]
                    }),
                    "movies": found(index.movies),
                    "shows": .array(index.shows.filter { matches($0.title) }.prefix(limit).map { show in
                        ["title": .string(show.title), "seasons": .array(show.seasons.map { .number(Double($0)) }),
                         "episode_ids": .array(show.episodes.compactMap(\.id).map { .number(Double($0)) })]
                    }),
                    "music_videos": found(index.musicVideos),
                    "sports": found(index.sports),
                    "documentaries": found(index.documentaries),
                    "home_videos": found(index.homeVideos),
                    "audiobooks": .array(index.books.filter { matches("\($0.title) \($0.author ?? "")") }.prefix(limit).map { book in
                        ["title": .string(book.title), "author": book.author.map { .string($0) } ?? .null,
                         "part_ids": .array(book.parts.compactMap(\.id).map { .number(Double($0)) })]
                    }),
                ]
            },
            MCPTool("library_summary", "How much is in the library, its playlists, and what the library scan is doing.") { _ in
                let index = library.index
                return [
                    "songs": .number(Double(index.songs.count)), "albums": .number(Double(index.albums.count)),
                    "artists": .number(Double(index.artists.filter { !$0.isFeaturedOnly }.count)),
                    "movies": .number(Double(index.movies.count)), "shows": .number(Double(index.shows.count)),
                    "music_videos": .number(Double(index.musicVideos.count)), "home_videos": .number(Double(index.homeVideos.count)),
                    "sports": .number(Double(index.sports.count)), "documentaries": .number(Double(index.documentaries.count)),
                    "scanning": library.scanningFolder.map { folder in
                        .object(["folder": .string(folder), "done": library.scanProgress.map { .number(Double($0.done)) } ?? .null,
                                 "total": library.scanProgress.map { .number(Double($0.total)) } ?? .null,
                                 "folders_waiting": .number(Double(library.foldersWaiting))])
                    } ?? .null,
                    "audiobooks": .number(Double(index.books.count)),
                    "playlists": .array(library.playlists.map { ["id": .number(Double($0.playlist.id ?? 0)), "name": .string($0.playlist.name), "items": .number(Double($0.items.count))] }),
                ]
            },
            MCPTool("now_playing", "What's playing: the item, position, paused or not, volume, and the queue.") { _ in
                guard let item = player.currentItem else {
                    return player.hasMedia ? ["title": .string(player.title), "position": .number(player.position.rounded())] : ["playing": false]
                }
                return [
                    "item": describe(item), "position": .number(player.position.rounded()), "duration": .number(player.duration.rounded()),
                    "paused": .bool(player.isPaused), "volume": .number(player.volume.rounded()), "muted": .bool(player.isMuted),
                    "queue_index": .number(Double(player.queueIndex ?? 0)),
                    "queue": .array(player.queue.prefix(100).map(describe)),
                ]
            },
            MCPTool("play", "Play items in this order (a whole album, a season, a playlist's ids…). Movies and episodes resume where they were left.",
                    input: ["type": "object", "required": ["ids"], "properties": [
                        "ids": ids, "start_at": ["type": "integer", "description": "Index in ids to start from (default 0)"],
                        "shuffle": ["type": "boolean"],
                    ]]) { arguments in
                let queue = try items(arguments)
                player.play(queue, startAt: min(max(arguments["start_at"]?.int ?? 0, 0), queue.count - 1), showVideo: true)
                if arguments["shuffle"]?.bool == true { player.toggleShuffle() }
                if queue.contains(where: \.isVideo) { AppDelegate.openMainWindow?() }
                return ["playing": describe(player.currentItem ?? queue[0]), "queued": .number(Double(queue.count))]
            },
            MCPTool("pause", "Pause.") { _ in player.setPaused(true); return ["paused": true] },
            MCPTool("resume", "Carry on playing.") { _ in player.setPaused(false); return ["paused": false] },
            MCPTool("next", "Next in the queue.") { _ in player.next(); return "ok" },
            MCPTool("previous", "Previous in the queue (or back to the start of this one).") { _ in player.previous(); return "ok" },
            MCPTool("seek", "Jump to a time, or by an amount.",
                    input: ["type": "object", "required": ["seconds"], "properties": [
                        "seconds": ["type": "number"], "relative": ["type": "boolean", "description": "Move by seconds instead of to it"],
                    ]]) { arguments in
                let seconds = arguments["seconds"]?.number ?? 0
                if arguments["relative"]?.bool == true { player.skip(seconds) } else { player.seek(to: seconds) }
                return ["position": .number((arguments["relative"]?.bool == true ? player.position + seconds : seconds).rounded())]
            },
            MCPTool("set_volume", "Volume from 0 to 100.",
                    input: ["type": "object", "required": ["volume"], "properties": ["volume": ["type": "number"]]]) { arguments in
                player.volume = min(100, max(0, arguments["volume"]?.number ?? player.volume))
                return ["volume": .number(player.volume.rounded())]
            },
            MCPTool("queue_add", "Add items to Up Next: after the current one, or at the end.",
                    input: ["type": "object", "required": ["ids"], "properties": ["ids": ids, "next": ["type": "boolean", "description": "Play right after the current item"]]]) { arguments in
                let added = try items(arguments)
                if arguments["next"]?.bool == true { player.playNext(added) } else { player.addToQueue(added) }
                return ["queue_length": .number(Double(player.queue.count))]
            },
            MCPTool("playlist_create", "Make a playlist, optionally with items.",
                    input: ["type": "object", "required": ["name"], "properties": ["name": ["type": "string"], "ids": ids]],
                    changesLibrary: true) { arguments in
                guard let name = arguments["name"]?.string, !name.isEmpty else { throw MCPToolError("A playlist needs a name.") }
                let list = (try? items(arguments)) ?? []
                guard let playlist = library.createPlaylist(named: name, with: list) else { throw MCPToolError("Couldn't make the playlist.") }
                return ["id": .number(Double(playlist.id ?? 0)), "name": .string(name), "items": .number(Double(list.count))]
            },
            MCPTool("playlist_add", "Add items to the end of a playlist (by its id from library_summary).",
                    input: ["type": "object", "required": ["playlist_id", "ids"], "properties": ["playlist_id": ["type": "integer"], "ids": ids]],
                    changesLibrary: true) { arguments in
                guard let contents = library.playlists.first(where: { $0.playlist.id == Int64(arguments["playlist_id"]?.int ?? -1) }) else {
                    throw MCPToolError("No playlist with that id. library_summary lists them.")
                }
                library.add(try items(arguments), to: contents.playlist)
                return "ok"
            },
            MCPTool("playlist_delete", "Delete a playlist (by its id from library_summary). The songs stay in the library.",
                    input: ["type": "object", "required": ["playlist_id"], "properties": ["playlist_id": ["type": "integer"]]],
                    changesLibrary: true) { arguments in
                guard let contents = library.playlists.first(where: { $0.playlist.id == Int64(arguments["playlist_id"]?.int ?? -1) }) else {
                    throw MCPToolError("No playlist with that id. library_summary lists them.")
                }
                library.delete(contents.playlist)
                return "ok"
            },
            MCPTool("set_category", "Move items to a category: movie, episode, sport, documentary, home_video, music_video, song or audiobook; automatic puts them back where MacShow would. MacShow sorts by folder (Sports, Documentaries, Music Videos) and length; use this for what those rules miss, judging by title and folder. For a sport, edit_info's genre sets the kind of sport (\"Football\", \"Formula 1\").",
                    input: ["type": "object", "required": ["ids", "category"], "properties": [
                        "ids": ids, "category": ["type": "string", "enum": ["movie", "episode", "sport", "documentary", "home_video", "music_video", "song", "audiobook", "automatic"]],
                    ]], changesLibrary: true) { arguments in
                let kinds: [String: MediaItem.Kind] = ["movie": .movie, "episode": .episode, "sport": .sport, "documentary": .documentary,
                                                        "home_video": .homeVideo, "music_video": .musicVideo, "song": .music, "audiobook": .audiobook]
                let category = arguments["category"]?.string ?? ""
                guard category == "automatic" || kinds[category] != nil else { throw MCPToolError("Unknown category \(category).") }
                library.setCategory(kinds[category], for: try items(arguments))
                return "ok"
            },
            MCPTool("edit_info", "Change details shown in MacShow (never written to the files). Empty text goes back to the file's own value.",
                    input: ["type": "object", "required": ["ids"], "properties": [
                        "ids": ids, "title": ["type": "string"], "artist": ["type": "string"], "album": ["type": "string"],
                        "album_artist": ["type": "string"], "genre": ["type": "string"], "year": ["type": "integer"],
                        "show": ["type": "string"], "season": ["type": "integer"], "episode": ["type": "integer"],
                    ]], changesLibrary: true) { arguments in
                func text(_ key: String) -> String?? { arguments[key]?.string.map { $0.isEmpty ? nil : $0 } }
                func number(_ key: String) -> Int?? { arguments[key].map { $0.int } }
                library.save(try items(arguments).map { item in
                    var edit = library.edits[item.path] ?? ItemEdit(path: item.path)
                    if let value = text("title") { edit.title = value }
                    if let value = text("artist") { edit.artist = value }
                    if let value = text("album") { edit.album = value }
                    if let value = text("album_artist") { edit.albumArtist = value }
                    if let value = text("genre") { edit.genre = value }
                    if let value = text("show") { edit.show = value }
                    if let value = number("year") { edit.year = value }
                    if let value = number("season") { edit.season = value }
                    if let value = number("episode") { edit.episode = value }
                    return edit
                })
                return "ok"
            },
            MCPTool("lyrics", "A song's lyrics (timed lines when available), from an .lrc file, its tags or LRCLIB.",
                    input: ["type": "object", "required": ["id"], "properties": ["id": ["type": "integer"]]]) { arguments in
                guard let item = arguments["id"]?.int.flatMap({ library.index.itemsByID[Int64($0)] }) else { throw MCPToolError("No item with that id.") }
                guard let lyrics = await library.lyrics(for: item) else { return ["found": false] }
                return ["source": .string(lyrics.source), "instrumental": .bool(lyrics.isInstrumental),
                        "lines": .array(lyrics.lines.map { ["time": $0.time.map { .number($0) } ?? .null, "text": .string($0.text)] })]
            },
            MCPTool("details", "What TMDB knows about a movie or a show's episode: plot, year, runtime, rating, genres, cast.",
                    input: ["type": "object", "required": ["id"], "properties": ["id": ["type": "integer"]]]) { arguments in
                guard let item = arguments["id"]?.int.flatMap({ library.index.itemsByID[Int64($0)] }), item.kind == .movie || item.kind == .episode else {
                    throw MCPToolError("Give the id of a movie or episode.")
                }
                guard let details = await library.details(for: item) else { return ["found": false] }
                return [
                    "title": .string(details.title), "year": details.year.map { .number(Double($0)) } ?? .null,
                    "overview": details.overview.map { .string($0) } ?? .null, "rating": details.rating.map { .number($0) } ?? .null,
                    "genres": .array(details.genres.map { .string($0) }), "made_by": .array(details.makers.map { .string($0) }),
                    "cast": .array(details.cast.map { ["name": .string($0.name), "role": $0.role.map { .string($0) } ?? .null] }),
                ]
            },
            MCPTool("smart_list", "Songs in a smart playlist: recently_played, most_played, recently_added or never_played.",
                    input: ["type": "object", "required": ["list"], "properties": [
                        "list": ["type": "string", "enum": ["recently_played", "most_played", "recently_added", "never_played"]],
                        "limit": ["type": "integer"],
                    ]]) { arguments in
                let lists: [String: SmartList] = ["recently_played": .recentlyPlayed, "most_played": .mostPlayed,
                                                   "recently_added": .recentlyAdded, "never_played": .neverPlayed]
                guard let list = lists[arguments["list"]?.string ?? ""] else { throw MCPToolError("Unknown list.") }
                return .array(library.songs(in: list).prefix(arguments["limit"]?.int ?? 50).map { song in
                    var described = describe(song)
                    if case .object(var fields) = described, let stat = song.id.flatMap({ library.playStats[$0] }) {
                        fields["plays"] = .number(Double(stat.playCount))
                        described = .object(fields)
                    }
                    return described
                })
            },
            MCPTool("rescan", "Look for new, changed and removed files in all watched folders.") { _ in
                library.rescanAll()
                return "started"
            },
        ]
    }

    nonisolated static func describe(_ item: MediaItem) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .number(Double(item.id ?? 0)), "kind": .string(item.kind.rawValue), "title": .string(item.title),
            "duration": .number(item.duration.rounded()),
        ]
        if let artist = item.artist { fields["artist"] = .string(artist) }
        if let album = item.album { fields["album"] = .string(album) }
        if let show = item.show { fields["show"] = .string(show) }
        if let season = item.season { fields["season"] = .number(Double(season)) }
        if let episode = item.episode { fields["episode"] = .number(Double(episode)) }
        if let year = item.year { fields["year"] = .number(Double(year)) }
        if let genre = item.genre { fields["genre"] = .string(genre) }
        // The folder it's in says a lot about what it is ("Movies/Sports/Formula 1").
        if item.isVideo { fields["folder"] = .string(item.url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")) }
        return .object(fields)
    }
}
