import AppKit
import MacShowCore
import SwiftUI

@main
struct MacShowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library: Library
    @State private var player: Player

    init() {
        let library: Library
        do {
            library = try Library()
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
        let player = Player()
        player.nowPlaying = NowPlaying(player: player, artwork: library.artwork)
        player.library = library
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        // At launch, not when a window appears: the app can be opened for a file
        // from Finder without its main window.
        library.start()
    }

    var body: some Scene {
        Window("MacShow", id: "main") {
            RootView()
                .opensVideoWindow()  // inside the .environment calls, so it can read the player
                // "Open With MacShow" / files dropped on the Dock icon. SwiftUI delivers
                // these here (not to the app delegate), one URL at a time.
                .onOpenURL { url in player.openExternal(url) }
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
                .onAppear {
                    // `MacShow <file>` plays that file on launch.
                    if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }) {
                        player.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url {
                        player.open(url)
                    }
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Controls") {
                Button(player.isPaused ? "Play" : "Pause") { player.togglePause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!player.hasMedia)
                Button("Next") { player.next() }.keyboardShortcut(.rightArrow)
                Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow)
                Divider()
                Button("Skip Forward 10 Seconds") { player.skip(10) }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Skip Back 10 Seconds") { player.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                OpenWindowButton(title: "Mini Player", id: "mini").keyboardShortcut("m", modifiers: [.command, .shift])
                OpenWindowButton(title: "Library", id: "main").keyboardShortcut("1")
                Divider()
            }
        }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .opensVideoWindow()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .noRestoration()

        Window("Video", id: "video") {
            VideoPlayerView()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .noRestoration()

        Settings {
            SettingsView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
    }
}

extension Scene {
    /// Windows that only make sense while something plays shouldn't come back at launch.
    func noRestoration() -> some Scene {
        if #available(macOS 15, *) {
            return restorationBehavior(.disabled)
        } else {
            return self
        }
    }
}

extension View {
    /// Opens the video window when a video starts, from whichever MacShow window is open.
    func opensVideoWindow() -> some View { modifier(VideoWindowOpener()) }
}

private struct VideoWindowOpener: ViewModifier {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            // A file opened from Finder can start before any window exists.
            .onAppear { if player.isVideo { openWindow(id: "video") } }
            .onChange(of: player.isVideo) { _, isVideo in
                if isVideo { openWindow(id: "video") }
            }
    }
}

/// Menu items can't read `openWindow` from the environment directly.
private struct OpenWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: id) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
