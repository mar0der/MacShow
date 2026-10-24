import AppKit
import MacShowCore
import SwiftUI

@main
struct MacShowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library: Library
    @State private var player = Player()

    init() {
        do {
            _library = State(initialValue: try Library())
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
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
        }

        Window("Video", id: "video") {
            VideoPlayerView()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        Settings {
            SettingsView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
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
