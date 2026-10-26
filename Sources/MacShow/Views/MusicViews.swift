import MacShowCore
import SwiftUI

private let albumGrid = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)]

struct AlbumsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let albums = library.index.albums
        Group {
            if albums.isEmpty {
                EmptyLibraryView(title: "No Albums", icon: "square.stack")
            } else {
                ScrollView {
                    LazyVGrid(columns: albumGrid, spacing: 28) {
                        ForEach(albums) { AlbumTile(album: $0) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Albums")
    }
}

struct AlbumTile: View {
    let album: Album

    var body: some View {
        NavigationLink(value: AlbumRef(id: album.id)) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(key: album.artworkKey, title: album.title)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .overlay(alignment: .topTrailing) {
                        if let badge = album.tracks.first.map(\.formatInfo).flatMap(Self.badge) {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { MediaMenu(items: album.tracks) }
    }

    /// "FLAC · 96 kHz" → "FLAC 96 kHz"; plain 44.1/48 kHz show just the codec.
    static func badge(_ formatInfo: String) -> String? {
        let parts = formatInfo.components(separatedBy: " · ")
        guard let codec = parts.first, !codec.isEmpty else { return nil }
        if let rate = parts.last, rate != codec, let kHz = Double(rate.replacingOccurrences(of: " kHz", with: "")), kHz > 48 {
            return "\(codec) \(rate)"
        }
        return codec
    }
}

/// Big artwork, title, details and Play / Shuffle buttons above a list.
struct CollectionHeader: View {
    let artworkKey: String?
    let title: String
    let subtitle: String
    let details: String
    var circular = false
    let items: [MediaItem]

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ArtworkView(key: artworkKey, title: title, cornerRadius: circular ? 110 : 10)
                .frame(width: 220)
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.largeTitle.weight(.bold)).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                Text(details).font(.callout).foregroundStyle(.secondary)
                PlayShuffleButtons(items: items).padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }
}

struct AlbumDetailView: View {
    let album: Album
    @Environment(Player.self) private var player

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CollectionHeader(
                    artworkKey: album.artworkKey, title: album.title, subtitle: album.artist,
                    details: [album.year.map(String.init), "\(album.tracks.count) songs", Format.duration(album.duration)]
                        .compactMap { $0 }.joined(separator: " · "),
                    items: album.tracks
                )
                TrackList(tracks: album.tracks, showsArtist: album.artist == "Various Artists")
            }
            .padding(28)
        }
        .navigationTitle(album.title)
    }
}

/// Songs in order; double-click plays from that song, right-click for more.
struct TrackList: View {
    let tracks: [MediaItem]
    var showsArtist = false
    var numbered = true
    var extraMenu: ((Int) -> AnyView)?
    @Environment(Player.self) private var player

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                TrackRow(
                    track: track, number: numbered ? track.trackNumber : offset + 1, showsArtist: showsArtist,
                    isCurrent: player.currentItem?.id == track.id
                ) {
                    // Count by row, so the second copy of a song plays from the second copy.
                    let playable = tracks.filter { !$0.isProtected }
                    let start = tracks[..<offset].filter { !$0.isProtected }.count
                    if !track.isProtected { player.play(playable, startAt: start) }
                }
                .contextMenu {
                    MediaMenu(items: [track])
                    extraMenu?(offset)
                }
            }
        }
    }
}

/// One song; double-click plays it.
struct TrackRow: View {
    let track: MediaItem
    var number: Int?
    var showsArtist = false
    let isCurrent: Bool
    let play: () -> Void
    @Environment(Library.self) private var library
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                } else {
                    Text(number.map(String.init) ?? "").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if showsArtist, let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if track.isProtected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .help("Copy-protected: plays only in the app it came from")
            } else if !library.isAvailable(track) {
                Image(systemName: "externaldrive.badge.xmark").foregroundStyle(.secondary)
                    .help("On a drive that isn't connected")
            }
            // Loved songs show their heart; others offer one on hover.
            let loved = library.isFavorite([track])
            Button { library.toggleFavorite([track]) } label: {
                Label(loved ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Love"), systemImage: loved ? "heart.fill" : "heart").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(loved ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
            .opacity(loved || hovering ? 1 : 0)
            .help(loved ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Love"))
            Text(Format.time(track.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: showsArtist ? 46 : 40)
        .onHover { hovering = $0 }
        .background(isCurrent ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        .opacity(track.isProtected || !library.isAvailable(track) ? 0.5 : 1)
    }
}

// MARK: Artists

struct ArtistsView: View {
    @Environment(Library.self) private var library
    /// Off: only artists you have albums or songs by. On: also everyone featured on them.
    @AppStorage("showFeaturedArtists") private var showFeatured = false
    @State private var changingPicture: Artist?

    var body: some View {
        let artists = library.index.artists.filter { showFeatured || !$0.isFeaturedOnly }
        Group {
            if artists.isEmpty {
                EmptyLibraryView(title: "No Artists", icon: "music.mic")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 24)], spacing: 24) {
                        ForEach(artists) { artist in
                            NavigationLink(value: ArtistRef(id: artist.id)) {
                                VStack(spacing: 8) {
                                    ArtistAvatar(artist: artist)
                                    VStack(spacing: 2) {
                                        Text(artist.name).font(.callout.weight(.semibold)).lineLimit(1)
                                        if artist.isFeaturedOnly {
                                            Text(artist.appearances.count == 1 ? LocalizedStringKey("Featured on 1 song") : "Featured on \(artist.appearances.count) songs")
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                MediaMenu(items: artist.isFeaturedOnly ? artist.appearances : artist.songs)
                                Divider()
                                Button("Change Picture…") { changingPicture = artist }
                                if library.artistImages[artist.id] != nil {
                                    Button("Use Album Cover") { library.setPicture(nil, for: artist) }
                                }
                            }
                        }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Artists")
        .sheet(item: $changingPicture) { artist in
            ArtworkSearchView(kind: .artist, term: artist.name) { data in
                if let key = library.artwork.store(data) { library.setPicture(key, for: artist) }
            }
        }
        .toolbar {
            if let progress = library.findingArtistPictures {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(width: 80)
                    .help("Finding pictures: \(progress.done) of \(progress.total)")
            } else {
                Button { library.findArtistPictures(for: artists) } label: { Label("Find Pictures", systemImage: "person.crop.circle.badge.plus") }
                    .help("Find a photo for every artist without one (you can change any later)")
                    .disabled(!artists.contains { library.picture(of: $0) == nil })
            }
            Toggle(isOn: $showFeatured) { Label("Featured Artists", systemImage: "person.2") }
                .toggleStyle(.button)
                .help(showFeatured ? LocalizedStringKey("Hide artists who are only featured on songs") : LocalizedStringKey("Also show artists featured on songs"))
        }
    }
}

/// An artist's round picture. Someone who is only ever featured gets their
/// initials, with the artist they appear with in a small circle at the corner.
struct ArtistAvatar: View {
    let artist: Artist
    @Environment(Library.self) private var library

    var body: some View {
        ArtworkView(key: library.picture(of: artist), title: artist.name, cornerRadius: 100)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            .overlay(alignment: .bottomTrailing) {
                if let lead = artist.appearsWith, let leadArtist = library.index.artists.first(where: { $0.id == lead.lowercased() }) {
                    GeometryReader { geometry in
                        ArtworkView(key: library.picture(of: leadArtist), title: leadArtist.name, cornerRadius: 100)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 3))
                            .frame(width: geometry.size.width * 0.36, height: geometry.size.width * 0.36)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    .help("Appears with \(leadArtist.name)")
                }
            }
    }
}

struct ArtistDetailView: View {
    let artist: Artist
    @Environment(Library.self) private var library
    @State private var bio: MediaDetails?
    @State private var bioExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CollectionHeader(
                    artworkKey: library.picture(of: artist), title: artist.name,
                    subtitle: artist.appearsWith.map { "Featured with \($0)" } ?? "",
                    details: [artist.albums.isEmpty ? nil : "\(artist.albums.count) albums",
                              artist.songs.isEmpty ? nil : "\(artist.songs.count) songs",
                              artist.appearances.isEmpty ? nil : artist.appearances.count == 1 ? String(localized: "Featured on 1 song") : String(localized: "Featured on \(artist.appearances.count) songs")]
                        .compactMap { $0 }.joined(separator: " · "),
                    circular: true, items: artist.songs.isEmpty ? artist.appearances : artist.songs
                )
                if let text = bio?.overview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text).lineLimit(bioExpanded ? nil : 3).frame(maxWidth: 720, alignment: .leading)
                        HStack {
                            Button(bioExpanded ? LocalizedStringKey("Less") : LocalizedStringKey("More")) { bioExpanded.toggle() }.buttonStyle(.link)
                            Text("From Wikipedia").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !artist.albums.isEmpty {
                    Text("Albums").font(.title3.weight(.semibold))
                    LazyVGrid(columns: albumGrid, spacing: 28) {
                        ForEach(artist.albums) { AlbumTile(album: $0) }
                    }
                }
                if !artist.songs.isEmpty {
                    Text("Songs").font(.title3.weight(.semibold))
                    TrackList(tracks: artist.songs, showsArtist: artist.songs.contains { $0.artist != artist.name }, numbered: false)
                }
                if !artist.appearances.isEmpty {
                    Text("Featured On").font(.title3.weight(.semibold))
                    TrackList(tracks: artist.appearances, showsArtist: true, numbered: false)
                }
            }
            .padding(28)
        }
        .navigationTitle(artist.name)
        .task(id: artist.id) { bio = await library.bio(of: artist) }
    }
}

// MARK: Songs

extension MediaItem {
    var artistName: String { artist ?? "" }
    var albumName: String { album ?? "" }
}

struct SongsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var sortOrder = [Self.titleOrder]
    @State private var selection = Set<MediaItem.ID>()
    @State private var sorted: [MediaItem]?

    private static let titleOrder = KeyPathComparator(\MediaItem.title, comparator: .localizedStandard)
    /// mpv's playlist is loaded item by item, so a click in a huge list queues a window around it.
    private static let queueLimit = 500

    /// The index already sorts songs by title; other orders are sorted in the background.
    private struct SortKey: Equatable {
        let generation: Int
        let order: [KeyPathComparator<MediaItem>]
    }

    var body: some View {
        let songs = sortOrder == [Self.titleOrder] ? library.index.songs : (sorted ?? library.index.songs)
        Group {
            if songs.isEmpty {
                EmptyLibraryView(title: "No Songs", icon: "music.note")
            } else {
                Table(songs, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Title", value: \.title) { song in
                        HStack(spacing: 6) {
                            if player.currentItem?.id == song.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                            Text(song.title)
                            if song.isProtected { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn("Artist", value: \.artistName, comparator: .localizedStandard)
                    TableColumn("Album", value: \.albumName, comparator: .localizedStandard)
                    TableColumn("Time", value: \.duration) { Text(Format.time($0.duration)).monospacedDigit() }
                        .width(min: 50, ideal: 60, max: 80)
                }
                .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
                    MediaMenu(items: songs.filter { ids.contains($0.id) })
                } primaryAction: { ids in
                    let playable = songs.filter { !$0.isProtected }
                    guard let start = playable.firstIndex(where: { ids.contains($0.id) }) else { return }
                    let window = playable[start..<min(start + Self.queueLimit, playable.count)]
                    player.play(Array(window))
                }
            }
        }
        .navigationTitle("Songs")
        .task(id: SortKey(generation: library.generation, order: sortOrder)) {
            guard sortOrder != [Self.titleOrder] else { return }
            let songs = library.index.songs, order = sortOrder
            let result = await Task.detached(priority: .userInitiated) { songs.sorted(using: order) }.value
            if !Task.isCancelled { sorted = result }
        }
    }
}

// MARK: Playlists

struct PlaylistView: View {
    let contents: PlaylistContents
    @Environment(Library.self) private var library
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    ArtworkView(key: contents.items.lazy.compactMap(\.artworkKey).first, title: contents.playlist.name, cornerRadius: 10)
                        .frame(width: 220)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Playlist Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.weight(.bold))
                            .onSubmit { library.rename(contents.playlist, to: name) }
                        Text("\(contents.items.count) songs · \(Format.duration(contents.items.reduce(0) { $0 + $1.duration }))")
                            .font(.callout).foregroundStyle(.secondary)
                        PlayShuffleButtons(items: contents.items).padding(.top, 8)
                    }
                }
                if contents.items.isEmpty {
                    Text("Right-click songs or albums and choose Add to Playlist.")
                        .foregroundStyle(.secondary)
                } else {
                    TrackList(tracks: contents.items, showsArtist: true, numbered: false) { offset in
                        AnyView(Button("Remove from Playlist") { library.removeEntries(positions: [contents.positions[offset]], from: contents.playlist) })
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(contents.playlist.name)
        .onAppear { name = contents.playlist.name }
        .onChange(of: contents.playlist.name) { _, newName in name = newName }
    }
}

/// Recently Played, Most Played, Recently Added, Never Played.
struct SmartPlaylistView: View {
    let list: SmartList
    @Environment(Library.self) private var library

    var body: some View {
        let songs = library.songs(in: list)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    Image(systemName: list.icon)
                        .font(.system(size: 72, weight: .light))
                        .frame(width: 220, height: 220)
                        .background(.tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(list.title)).font(.largeTitle.weight(.bold))
                        Text(songs.count == 1 ? LocalizedStringKey("1 song · fills itself as you listen") : "\(songs.count) songs · fills itself as you listen").font(.callout).foregroundStyle(.secondary)
                        PlayShuffleButtons(items: songs).padding(.top, 8)
                    }
                }
                if songs.isEmpty {
                    Text(list == .recentlyPlayed || list == .mostPlayed ? LocalizedStringKey("Songs appear here once you've listened to most of them.") : LocalizedStringKey("Nothing here."))
                        .foregroundStyle(.secondary)
                } else {
                    TrackList(tracks: songs, showsArtist: true, numbered: false)
                }
            }
            .padding(28)
        }
        .navigationTitle(LocalizedStringKey(list.title))
    }
}

struct PlayShuffleButtons: View {
    let items: [MediaItem]
    @Environment(Player.self) private var player

    var body: some View {
        let playable = items.filter { !$0.isProtected }
        HStack(spacing: 10) {
            PlayPauseButton(items: playable) { player.play(playable) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                .buttonStyle(.borderedProminent)
            Button { player.play(playable.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(playable.isEmpty)
    }
}
