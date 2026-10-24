import AppKit
import SwiftUI

@main
struct MacShowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var player = Player()

    var body: some Scene {
        Window("MacShow", id: "main") {
            ContentView(player: player)
                .onAppear {
                    // `MacShow <file>` opens that file on launch.
                    if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                        player.open(URL(fileURLWithPath: path))
                    }
                }
        }
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
