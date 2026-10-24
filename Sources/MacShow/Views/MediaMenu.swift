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
    }

    /// "New Playlist", or "New Playlist 2", 3, … if taken.
    static func newPlaylistName(_ library: Library) -> String {
        let names = Set(library.playlists.map(\.playlist.name))
        return (1...).lazy.map { $0 == 1 ? "New Playlist" : "New Playlist \($0)" }.first { !names.contains($0) }!
    }
}
