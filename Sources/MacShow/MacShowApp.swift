import AppKit
import LocalAuthentication
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
        VideoScreen.installKeys(for: player)
        // At launch, not when a window appears: the app can be opened for a file
        // from Finder without its main window.
        library.start()
    }

    var body: some Scene {
        Window("MacShow", id: "main") {
            RootView()
                .modifier(MainWindowReopener())
                // "Open With MacShow" / files dropped on the Dock icon. SwiftUI delivers
                // these here (not to the app delegate), one URL at a time.
                .onOpenURL { url in player.openExternal(url) }
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
                .onAppear {
                    // `MacShow <file>` plays that file on launch. Only a media file: the
                    // value of an option (`-sidebarSelection movies`) can name a folder too.
                    let arguments = Array(CommandLine.arguments.dropFirst())
                    let path = arguments.indices.first { index in
                        let argument = arguments[index]
                        return !argument.hasPrefix("-") && (index == 0 || !arguments[index - 1].hasPrefix("-"))
                            && Classifier.isMediaFile(URL(fileURLWithPath: argument)) && FileManager.default.fileExists(atPath: argument)
                    }.map { arguments[$0] }
                    if let path { player.open(URL(fileURLWithPath: path)) }
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
                Button("Import Playlists…") { importPlaylists(into: library) }
            }
            CommandMenu("Controls") {
                // Space itself is handled by VideoScreen, so it works whatever has focus.
                Button(player.isPaused ? "Play (Space)" : "Pause (Space)") { player.togglePause() }
                    .disabled(!player.hasMedia)
                Button("Next") { player.next() }.keyboardShortcut(.rightArrow)
                Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow)
                Divider()
                Button("Skip Forward 10 Seconds") { player.skip(10) }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Skip Back 10 Seconds") { player.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Divider()
                Button("Volume Up") { player.volume = min(100, player.volume + 5) }.keyboardShortcut(.upArrow)
                Button("Volume Down") { player.volume = max(0, player.volume - 5) }.keyboardShortcut(.downArrow)
                Button(player.isMuted ? "Unmute" : "Mute") { player.isMuted.toggle() }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Full Screen Video") { VideoScreen.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                    .disabled(!player.isVideo)
                Button("Close Video") { player.stop() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!player.isVideo)
            }
            CommandGroup(after: .sidebar) {
                Button(library.showingAdult ? "Hide Adult Content" : "Show Adult Content…") {
                    if library.showingAdult { library.showingAdult = false } else { unlockAdult(library) }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!library.folderRules.contains { $0.kind == .adult } && !library.showingAdult)
                Divider()
            }
            CommandGroup(before: .windowList) {
                OpenWindowButton(title: "Mini Player", id: "mini").keyboardShortcut("m", modifiers: [.command, .shift])
                OpenWindowButton(title: "Equalizer", id: "equalizer").keyboardShortcut("e", modifiers: [.command, .option])
                OpenWindowButton(title: "Library", id: "main").keyboardShortcut("1")
                Divider()
            }
        }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .opensMainWindowForVideo()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .noRestoration()

        Window("Equalizer", id: "equalizer") {
            EqualizerView()
                .environment(player)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        WindowGroup("Get Info", id: "info", for: [Int64].self) { $ids in
            InfoView(ids: ids ?? [])
                .environment(library)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .noRestoration()

        Settings {
            SettingsView()
                .environment(library)
                .environment(player)
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
    /// Videos play in the main window; bring it up when one starts from the mini player.
    func opensMainWindowForVideo() -> some View { modifier(MainWindowOpener()) }
}

private struct MainWindowOpener: ViewModifier {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: player.isVideo) { _, isVideo in
            if isVideo { openWindow(id: "main") }
        }
    }
}

/// Keeps SwiftUI's `openWindow` so a Dock click can bring the main window back after it was closed.
private struct MainWindowReopener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Shows Adult content after Touch ID or the Mac's password. It locks again at every launch.
@MainActor
func unlockAdult(_ library: Library) {
    LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show adult content") { success, _ in
        if success { DispatchQueue.main.async { library.showingAdult = true } }
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
    @MainActor static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Like Music and TV: closing the window keeps the app (and any music) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no window open brings the library back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { Self.openMainWindow?() } }
        return true
    }
}
