import MacShowCore
import SwiftUI

enum SidebarItem: Hashable, RawRepresentable {
    case home, albums, artists, songs, movies, books
    case playlist(Int64)

    static let fixed: [SidebarItem] = [.home, .albums, .artists, .songs, .movies, .books]

    init?(rawValue: String) {
        if rawValue.hasPrefix("playlist:"), let id = Int64(rawValue.dropFirst("playlist:".count)) {
            self = .playlist(id)
        } else if let item = Self.fixed.first(where: { $0.rawValue == rawValue }) {
            self = item
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .albums: "albums"
        case .artists: "artists"
        case .songs: "songs"
        case .movies: "movies"
        case .books: "books"
        case .playlist(let id): "playlist:\(id)"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .movies: "Movies"
        case .books: "All Books"
        case .playlist: "Playlist"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .movies: "film"
        case .books: "book"
        case .playlist: "music.note.list"
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow
    // Remembered across launches; `-sidebarSelection albums` on the command line overrides it.
    @AppStorage("sidebarSelection") private var selection: SidebarItem = .home
    @State private var search = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .withPlayerBar()
                    .navigationDestination(for: Album.self) { AlbumDetailView(album: $0).withPlayerBar() }
                    .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).withPlayerBar() }
            }
            .onChange(of: selection) { _, _ in path = NavigationPath() }
            #if DEBUG
            .modifier(DebugHooks(path: $path))
            #endif
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search everything")
        .onChange(of: player.isVideo) { _, isVideo in
            if isVideo { openWindow(id: "video") }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: { if let item = $0 { selection = item } })) {
            row(.home)
            Section("Music") {
                row(.albums)
                row(.artists)
                row(.songs)
            }
            Section("Video") { row(.movies) }
            Section("Audiobooks") { row(.books) }
            Section {
                ForEach(library.playlists) { contents in
                    if let id = contents.playlist.id {
                        Label(contents.playlist.name, systemImage: "music.note.list")
                            .tag(SidebarItem.playlist(id))
                            .contextMenu {
                                Button("Play") { player.play(contents.items) }
                                Button("Delete Playlist", role: .destructive) { library.delete(contents.playlist) }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        if let id = library.createPlaylist(named: MediaMenu.newPlaylistName(library))?.id {
                            selection = .playlist(id)
                        }
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Playlist")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) {
            if library.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating library…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.icon).tag(item)
    }

    @ViewBuilder
    private var detail: some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(query: search)
        } else {
            switch selection {
            case .home: HomeView()
            case .albums: AlbumsView()
            case .artists: ArtistsView()
            case .songs: SongsView()
            case .movies: MoviesView()
            case .books: BooksView()
            case .playlist(let id):
                if let contents = library.playlists.first(where: { $0.playlist.id == id }) {
                    PlaylistView(contents: contents)
                } else {
                    HomeView()
                }
            }
        }
    }
}

/// Shown when a section has nothing in it yet.
struct EmptyLibraryView: View {
    let title: String
    let icon: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text("Add files to your Music, Movies or Downloads folder, or add another folder in Settings.")
        } actions: {
            SettingsLink { Text("Open Settings") }
        }
    }
}
