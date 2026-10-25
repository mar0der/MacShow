import AppKit
import MacShowCore
import UniformTypeIdentifiers

/// File › Import Playlists…: the Music app's exported library or an M3U.
@MainActor
func importPlaylists(into library: Library) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.xml, .m3uPlaylist] + [UTType(filenameExtension: "m3u8")].compactMap { $0 }
    panel.message = String(localized: "Choose the library you exported from Music (File › Library › Export Library…), or an M3U playlist.")
    panel.prompt = String(localized: "Import")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let alert = NSAlert()
    do {
        let result = try library.importPlaylists(from: url)
        alert.messageText = result.playlists == 0 ? String(localized: "No playlists imported") : String(localized: "Imported playlists: \(result.playlists)")
        alert.informativeText = String(localized: "Songs added: \(result.songs).")
        if result.missing > 0 {
            alert.informativeText += " " + String(localized: "\(result.missing) weren't found in your MacShow library: songs streamed from Apple Music, or files in folders MacShow doesn't watch.")
        }
    } catch {
        alert.messageText = String(localized: "Couldn't read that file")
        alert.informativeText = String(localized: "Choose the Library.xml exported from Music (File › Library › Export Library…), or an .m3u / .m3u8 file.")
    }
    alert.runModal()
}

/// Saves a playlist as an M3U8 any player can open.
@MainActor
func exportPlaylist(_ contents: PlaylistContents) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .m3uPlaylist]
    panel.nameFieldStringValue = contents.playlist.name + ".m3u8"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try PlaylistFile.m3u(contents.items).write(to: url, atomically: true, encoding: .utf8)
    } catch {
        NSAlert(error: error).runModal()
    }
}
