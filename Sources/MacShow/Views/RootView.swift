import MacShowCore
import SwiftUI

enum SidebarItem: Hashable, RawRepresentable {
    case home, albums, artists, songs, movies, shows, liveTV, sports, documentaries, homeVideos, musicVideos, books, adult
    case playlist(Int64)
    case smart(SmartList)

    static let fixed: [SidebarItem] = [.home, .albums, .artists, .songs, .movies, .shows, .liveTV, .sports, .documentaries, .homeVideos, .musicVideos, .books, .adult]

    init?(rawValue: String) {
        if rawValue.hasPrefix("playlist:"), let id = Int64(rawValue.dropFirst("playlist:".count)) {
            self = .playlist(id)
        } else if rawValue.hasPrefix("smart:"), let list = SmartList(rawValue: String(rawValue.dropFirst("smart:".count))) {
            self = .smart(list)
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
        case .shows: "shows"
        case .liveTV: "liveTV"
        case .sports: "sports"
        case .documentaries: "documentaries"
        case .homeVideos: "homeVideos"
        case .musicVideos: "musicVideos"
        case .books: "books"
        case .adult: "adult"
        case .playlist(let id): "playlist:\(id)"
        case .smart(let list): "smart:" + list.rawValue
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .liveTV: "Live TV"
        case .sports: "Sports"
        case .documentaries: "Documentaries"
        case .homeVideos: "Home Videos"
        case .musicVideos: "Music Videos"
        case .books: "All Books"
        case .adult: "Adult"
        case .playlist: "Playlist"
        case .smart(let list): LocalizedStringKey(list.title)
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .movies: "film"
        case .shows: "tv"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .sports: "sportscourt"
        case .documentaries: "globe.europe.africa"
        case .homeVideos: "video"
        case .musicVideos: "music.note.tv"
        case .books: "book"
        case .adult: "eye.slash"
        case .playlist: "music.note.list"
        case .smart(let list): list.icon
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
    @AppStorage("showsLyrics") private var showsLyrics = false
    @State private var path = NavigationPath()

    var body: some View {
        // Videos play in this window, TV-app style. Back (or Esc) returns here,
        // with the video carrying on in a corner.
        Group {
            if player.isVideo || player.isOpeningVideo, !player.isVideoMinimized {
                VideoPlayerView()
            } else {
                browser.overlay(alignment: .bottomTrailing) {
                    // In Picture in Picture the video is in its own floating window instead.
                    if player.isVideo, !PictureInPicture.shared.isActive { FloatingVideo().padding(24) }
                }
            }
        }
        // Closing the window stops a video (music keeps playing).
        .onDisappear { if player.isVideo { player.stop() } }
        // Siri learns the names of albums, playlists and shows from these.
        .onChange(of: library.generation) { MacShowShortcuts.updateAppShortcutParameters() }
        .onChange(of: player.isVideoMinimized) { _, minimized in
            if minimized { showCurrentShow() }
        }
    }

    /// Back from an episode lands on its show's page, to pick another one
    /// (the episode carries on in the corner).
    private func showCurrentShow() {
        guard let item = player.currentItem, item.kind == .episode,
              let show = library.index.shows.first(where: { $0.episodes.contains { $0.id == item.id } })
        else { return }
        selection = .shows
        search = ""
        // After the selection change has reset the path.
        DispatchQueue.main.async {
            path = NavigationPath()
            path.append(ShowRef(id: show.id))
        }
    }

    private var browser: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .withPlayerBar()
                    .libraryDestinations()
            }
            .onChange(of: selection) { _, _ in path = NavigationPath() }
            .onChange(of: library.showingAdult) { _, showing in
                if !showing, selection == .adult { selection = .home }
            }
            #if DEBUG
            .modifier(DebugHooks(path: $path))
            #endif
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search everything")
        .inspector(isPresented: Binding(get: { showsLyrics && player.currentItem?.isMusic == true }, set: { showsLyrics = $0 })) {
            LyricsView().inspectorColumnWidth(min: 260, ideal: 320, max: 480)
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
            Section("Video") {
                row(.movies)
                row(.shows)
                row(.liveTV)
                row(.sports)
                row(.documentaries)
                row(.homeVideos)
                row(.musicVideos)
                if library.showingAdult {
                    row(.adult)
                        .contextMenu { Button("Hide Adult Content") { library.showingAdult = false } }
                }
            }
            Section("Audiobooks") { row(.books) }
            Section {
                ForEach(SmartList.allCases, id: \.self) { row(.smart($0)) }
                ForEach(library.playlists) { contents in
                    if let id = contents.playlist.id {
                        Label(contents.playlist.name, systemImage: "music.note.list")
                            .tag(SidebarItem.playlist(id))
                            .contextMenu {
                                Button("Play") { player.play(contents.items) }
                                Button("Export as M3U…") { exportPlaylist(contents) }
                                Divider()
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
            if library.isScanning { ScanStatusView() }
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
            case .movies: VideoGridView(title: "Movies", emptyTitle: "No Movies", icon: "film", section: "movies", videos: library.index.movies)
            case .shows: ShowsView()
            case .liveTV: LiveTVView()
            case .sports: SportsView()
            case .documentaries:
                VideoGridView(title: "Documentaries", emptyTitle: "No Documentaries", icon: "globe.europe.africa", section: "documentaries",
                              videos: library.index.documentaries)
            case .homeVideos: VideoGridView(title: "Home Videos", emptyTitle: "No Home Videos", icon: "video", section: "homeVideos", videos: library.index.homeVideos)
            case .musicVideos: VideoGridView(title: "Music Videos", emptyTitle: "No Music Videos", icon: "music.note.tv", section: "musicVideos", videos: library.index.musicVideos)
            case .books: BooksView()
            case .adult:
                if library.showingAdult {
                    AdultView()
                } else {
                    HomeView()
                }
            case .smart(let list): SmartPlaylistView(list: list)
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
/// What the library scan is doing: which folder, how far, the file just read,
/// and how many folders wait their turn.
private struct ScanStatusView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            if let progress = library.scanProgress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)).controlSize(.small)
                Text("\(progress.done) of \(progress.total) new or changed files")
                if let file = progress.file { Text(file).lineLimit(1).truncationMode(.middle) }
            } else if library.scanningFolder != nil {
                Text(library.scanProgress == nil ? LocalizedStringKey("Looking for files…") : LocalizedStringKey("Up to date"))
            }
            if library.foldersWaiting > 0 { Text("\(library.foldersWaiting) more folders waiting") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .help(library.scanningAdultFolder && !library.showingAdult ? "" : library.scanningFolder ?? "")
    }

    /// "Scanning Music on Media", "Scanning ~/Movies"
    private var title: String {
        guard let path = library.scanningFolder else { return String(localized: "Updating library…") }
        if library.scanningAdultFolder, !library.showingAdult { return String(localized: "Scanning a hidden folder") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let parts = folder.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return String(localized: "Scanning \(folder.lastPathComponent) on \(parts[2])") }
        return String(localized: "Scanning \((path as NSString).abbreviatingWithTildeInPath)")
    }
}

struct EmptyLibraryView: View {
    let title: LocalizedStringKey
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
