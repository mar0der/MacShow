import AppKit

/// The window a video plays in, its full screen state, and the keys that
/// control playback. Keys are caught app-wide, before any view sees them, so
/// they work whatever has focus, except while typing in a text field:
///
/// - Space: play / pause (anywhere)
/// - With a video on screen: ← → skip 10 seconds, ↑ ↓ volume, F full screen,
///   M mute, Esc leaves full screen, then closes the video.
@MainActor
enum VideoScreen {
    /// The window showing the video, set by the video player while it's on screen.
    static weak var window: NSWindow?
    /// Full screen was entered for the video, so closing the video leaves it.
    private static var enteredFullScreen = false
    private static var monitor: Any?

    static var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    static func toggleFullScreen() {
        guard let window else { return }
        enteredFullScreen = !isFullScreen
        window.toggleFullScreen(nil)
    }

    /// The video closed: leave the full screen it was playing in.
    static func videoClosed() {
        if enteredFullScreen, isFullScreen { window?.toggleFullScreen(nil) }
        enteredFullScreen = false
        window = nil
    }

    static func installKeys(for player: Player) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, player: player) } ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, player: Player) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if let text = event.window?.firstResponder as? NSTextView, text.isEditable { return false }

        if event.keyCode == 49, player.hasMedia {  // Space
            player.togglePause()
            return true
        }
        guard player.isVideo, let window, event.window === window else { return false }
        switch event.keyCode {
        case 123: player.skip(-10)                              // ←
        case 124: player.skip(10)                               // →
        case 126: player.volume = min(100, player.volume + 5)   // ↑
        case 125: player.volume = max(0, player.volume - 5)     // ↓
        case 53:                                                // Esc
            if isFullScreen { toggleFullScreen() } else { player.stop() }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen()
            case "m": player.isMuted.toggle()
            default: return false
            }
        }
        NotificationCenter.default.post(name: activity, object: nil)
        return true
    }

    /// Posted when a key controlled the video, so its controls show what changed.
    static let activity = Notification.Name("MacShow.VideoScreen.activity")
}
