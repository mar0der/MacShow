import MacShowCore
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, albums, movies, books

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .albums: "Albums"
        case .movies: "Movies"
        case .books: "All Books"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .albums: "square.stack"
        case .movies: "film"
        case .books: "book"
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow
    // Remembered across launches; `-sidebarSelection albums` on the command line overrides it.
    @AppStorage("sidebarSelection") private var selection: SidebarItem = .home

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { if let item = $0 { selection = item } })) {
                row(.home)
                Section("Music") { row(.albums) }
                Section("Video") { row(.movies) }
                Section("Audiobooks") { row(.books) }
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
        } detail: {
            NavigationStack {
                detail
                    .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            }
            .safeAreaInset(edge: .bottom) {
                if player.hasMedia, !player.isVideo {
                    PlayerBar().padding(.horizontal, 20).padding(.bottom, 14)
                }
            }
        }
        .onChange(of: player.isVideo) { _, isVideo in
            if isVideo { openWindow(id: "video") }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.icon).tag(item)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home: HomeView()
        case .albums: AlbumsView()
        case .movies: MoviesView()
        case .books: BooksView()
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
