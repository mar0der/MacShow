#if DEBUG
import MacShowCore
import SwiftUI

/// Debug-build launch arguments for checking screens without clicking:
///   -debugOpenAlbum "Kamikaze"   pushes that album's page
///   -debugPlayAlbum "Kamikaze"   starts playing it
///   -debugOpenWindow mini        opens a window by id
///   -debugShow "Name" -debugOpenShow YES / -debugPlayShow YES
struct DebugHooks: ViewModifier {
    @Binding var path: NavigationPath
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var done = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: run)
            .onChange(of: library.index.albums.count) { _, _ in run() }
    }

    private func run() {
        guard !done, !library.index.albums.isEmpty else { return }
        done = true
        let defaults = UserDefaults.standard
        func album(_ key: String) -> Album? {
            defaults.string(forKey: key).flatMap { title in library.index.albums.first { $0.title == title } }
        }
        if let album = album("debugOpenAlbum") { path.append(AlbumRef(id: album.id)) }
        let show = defaults.string(forKey: "debugShow").flatMap { title in library.index.shows.first { $0.title == title } }
        if let show, defaults.bool(forKey: "debugOpenShow") { path.append(ShowRef(id: show.id)) }
        if let show, defaults.bool(forKey: "debugPlayShow") { player.play(show.episodes) }
        let book = defaults.string(forKey: "debugBook").flatMap { title in library.index.books.first { $0.title == title } }
        if let book, defaults.bool(forKey: "debugOpenBook") { path.append(BookRef(id: book.id)) }
        if let book, defaults.object(forKey: "debugPlayBookPart") != nil {
            player.play(book.parts, startAt: defaults.integer(forKey: "debugPlayBookPart"), at: defaults.double(forKey: "debugPlayBookAt"))
            if defaults.bool(forKey: "debugSleepEndOfChapter") {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    player.sleepTimer = .endOfChapter
                    if defaults.bool(forKey: "debugNextChapter") {
                        try? await Task.sleep(for: .seconds(1))
                        player.nextChapter()
                    }
                }
            }
        }
        if let album = album("debugPlayAlbum") { player.play(album.tracks) }
        if let id = defaults.string(forKey: "debugOpenWindow") { openWindow(id: id) }
        if defaults.bool(forKey: "debugOpenSettings") { openSettings() }
        if defaults.bool(forKey: "debugLogPlayer") {
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    FileHandle.standardError.write(Data("player: hasMedia=\(player.hasMedia) isVideo=\(player.isVideo) paused=\(player.isPaused) pos=\(Int(player.position))/\(Int(player.duration)) index=\(player.queueIndex ?? -1) format=\(player.formatInfo) vo=\(player.string("vo-configured") ?? "-") out=\(player.string("video-out-params/dw") ?? "-")x\(player.string("video-out-params/dh") ?? "-") layer=\(player.layer.drawableSize) inWindow=\(player.layer.superlayer != nil)\n".utf8))
                }
            }
        }
    }
}
#endif
