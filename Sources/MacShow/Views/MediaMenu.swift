import MacShowCore
import SwiftUI

/// The context menu for anything playable: an album, a selection of songs, a book.
struct MediaMenu: View {
    let items: [MediaItem]
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let playable = items.filter { !$0.isProtected }
        Button("Play") { player.play(playable) }
        Button("Play Next") { player.playNext(playable) }
        Button("Add to Queue") { player.addToQueue(playable) }
        Divider()
        Menu("Add to Playlist") {
            Button("New Playlist") { library.createPlaylist(named: Self.newPlaylistName(library), with: playable) }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { contents in
                Button(contents.playlist.name) { library.add(playable, to: contents.playlist) }
            }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(items.prefix(20).map(\.url))
        }
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
            Button(items.count == 1 ? "Hide from Library" : "Hide \(items.count) Items from Library") {
                for item in items { library.setRule(.excluded, for: item.url) }
            }
        }
    }

    private func option(_ title: String, _ kind: FolderRule.Kind?, current: FolderRule.Kind?, folder: URL) -> some View {
        Toggle(title, isOn: Binding(get: { current == kind }, set: { _ in library.setRule(kind, for: folder) }))
    }
}
