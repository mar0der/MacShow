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
    }

    var body: some Scene {
        Window("MacShow", id: "main") {
            RootView()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
                .onAppear {
                    library.start()
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
