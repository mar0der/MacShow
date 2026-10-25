import MacShowCore
import SwiftUI

/// The context menu for anything playable: an album, a selection of songs, a book.
struct MediaMenu: View {
    let items: [MediaItem]
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let playable = items.filter { !$0.isProtected }
        Button("Play") { player.play(playable) }
        Button("Play Next") { player.playNext(playable) }
        Button("Add to Queue") { player.addToQueue(playable) }
        Divider()
        Button(library.isFavorite(items) ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Love")) { library.toggleFavorite(items) }
        Menu("Add to Playlist") {
            Button("New Playlist") { library.createPlaylist(named: Self.newPlaylistName(library), with: playable) }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { contents in
                Button(contents.playlist.name) { library.add(playable, to: contents.playlist) }
            }
        }
        Divider()
        Button("Get Info…") { openWindow(id: "info", value: items.compactMap(\.id)) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(items.prefix(20).map(\.url))
        }
        CategoryMenu(items: items)
        FolderRuleMenu(items: items, classify: false)
    }

    /// "New Playlist", or "New Playlist 2", 3, … if taken.
    static func newPlaylistName(_ library: Library) -> String {
        let names = Set(library.playlists.map(\.playlist.name))
        return (1...).lazy.map { $0 == 1 ? "New Playlist" : "New Playlist \($0)" }.first { !names.contains($0) }!
    }
}

/// Sorting content apart: what the folder of the clicked item holds (normal,
/// personal or adult), never scanning it, or hiding just these files.
struct FolderRuleMenu: View {
    let items: [MediaItem]
    /// Offer Personal and Adult (videos); music only gets Never Scan and Hide.
    var classify = true
    @Environment(Library.self) private var library

    var body: some View {
        if let folder = items.first?.url.deletingLastPathComponent() {
            let current = FolderRules(library.folderRules).kind(for: folder.canonicalPath)
            Menu("Folder “\(folder.lastPathComponent)”") {
                if classify {
                    Section("This folder holds") {
                        option("Movies & TV", nil, current: current, folder: folder)
                        option("Personal Videos", .personal, current: current, folder: folder)
                        option("Adult Content (hidden, Touch ID to show)", .adult, current: current, folder: folder)
                    }
                }
                Button("Never Scan This Folder") { library.setRule(.excluded, for: folder) }
            }
            Button(items.count == 1 ? LocalizedStringKey("Hide from Library") : LocalizedStringKey("Hide \(items.count) Items from Library")) {
                for item in items { library.setRule(.excluded, for: item.url) }
            }
        }
    }

    private func option(_ title: LocalizedStringKey, _ kind: FolderRule.Kind?, current: FolderRule.Kind?, folder: URL) -> some View {
        Toggle(title, isOn: Binding(get: { current == kind }, set: { _ in library.setRule(kind, for: folder) }))
    }
}

/// Move To: the category items are listed under. Videos move between Movies,
/// TV Shows, Sports, Documentaries, Home Videos and Music Videos; audio between
/// Songs and Audiobooks.
struct CategoryMenu: View {
    let items: [MediaItem]
    @Environment(Library.self) private var library

    var body: some View {
        if !items.isEmpty {
            let isVideo = items.allSatisfy(\.isVideo)
            let choices: [(LocalizedStringKey, MediaItem.Kind)] = isVideo
                ? [("Movies", .movie), ("TV Shows", .episode), ("Sports", .sport), ("Documentaries", .documentary),
                   ("Home Videos", .homeVideo), ("Music Videos", .musicVideo)]
                : [("Songs", .music), ("Audiobooks", .audiobook)]
            let current = Set(items.map(\.kind))
            Menu("Move To") {
                ForEach(choices, id: \.1) { title, kind in
                    Toggle(title, isOn: Binding(get: { current == [kind] }, set: { _ in library.setCategory(kind, for: items) }))
                }
                if items.contains(where: { library.edits[$0.path]?.kind != nil }) {
                    Divider()
                    Button("Where MacShow Puts It") { library.setCategory(nil, for: items) }
                }
            }
        }
    }
}
