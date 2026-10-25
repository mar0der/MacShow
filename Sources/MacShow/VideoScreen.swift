import AppKit

/// The window a video plays in, its full screen state, and the keys that
/// control playback. Keys are caught app-wide, before any view sees them, so
/// they work whatever has focus, except while typing in a text field:
///
/// - Space: play / pause (anywhere)
/// - With a video on screen: ← → skip 10 seconds (⇧ for 30), ↑ ↓ volume,
///   , . step a frame, F full screen, M mute, S next subtitles, Esc leaves
///   full screen, then shrinks the video into a corner of the library.
///   Scrolling over the video changes the volume.
@MainActor
enum VideoScreen {
    /// The window showing the video, set by the video player while it's on screen.
    static weak var window: NSWindow?
    /// Full screen was entered for the video, so closing the video leaves it.
    private static var enteredFullScreen = false
    private static var monitors: [Any] = []

    static var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    static func toggleFullScreen() {
        guard let window else { return }
        enteredFullScreen = !isFullScreen
        window.toggleFullScreen(nil)
    }

    /// The full-size video went away: leave the full screen it was playing in.
    static func leaveFullScreen() {
        if enteredFullScreen, isFullScreen { window?.toggleFullScreen(nil) }
        enteredFullScreen = false
    }

    static func installKeys(for player: Player) {
        guard monitors.isEmpty else { return }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handle(event, player: player) } ? nil : event
            },
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { scroll(event, player: player) } ? nil : event
            },
        ].compactMap { $0 }
    }

    private static func handle(_ event: NSEvent, player: Player) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        if let text = event.window?.firstResponder as? NSTextView, text.isEditable { return false }

        if event.keyCode == 49, modifiers.isEmpty, player.hasMedia {  // Space
            player.togglePause()
            return true
        }
        guard player.isVideo, !player.isVideoMinimized, let window, event.window === window else { return false }
        let jump: Double = modifiers == .shift ? 30 : 10
        switch event.keyCode {
        case 123: player.skip(-jump)                            // ←
        case 124: player.skip(jump)                             // →
        case 126: player.volume = min(100, player.volume + 5)   // ↑
        case 125: player.volume = max(0, player.volume - 5)     // ↓
        case 53:                                                // Esc
            if isFullScreen { toggleFullScreen() } else { player.isVideoMinimized = true }
        default:
            guard modifiers.isEmpty else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen()
            case "m": player.isMuted.toggle()
            case "s": player.cycleSubtitles()
            case ",": player.stepFrame(forward: false)
            case ".": player.stepFrame(forward: true)
            default: return false
            }
        }
        NotificationCenter.default.post(name: activity, object: nil)
        return true
    }

    /// Up raises the volume: the direction the wheel or fingers move, whatever
    /// the natural-scrolling setting. A trackpad sends many small steps, a mouse
    /// wheel one per notch (5%).
    private static func scroll(_ event: NSEvent, player: Player) -> Bool {
        guard player.isVideo, !player.isVideoMinimized, let window, event.window === window,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        else { return false }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // At most 5% per step, so a fast flick can't jump to full volume.
        let change = min(5, max(-5, event.hasPreciseScrollingDeltas ? delta * 0.25 : delta * 5))
        player.volume = min(100, max(0, player.volume + change))
        NotificationCenter.default.post(name: activity, object: nil)
        return true
    }

    /// Posted when a key controlled the video, so its controls show what changed.
    static let activity = Notification.Name("MacShow.VideoScreen.activity")
}
