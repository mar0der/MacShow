import AppKit
import MacShowCore
import SwiftUI

/// Picture in Picture: the playing video in a small window that floats above
/// other apps, on every desktop, while MacShow's own window shows the library.
@MainActor
@Observable
final class PictureInPicture {
    static let shared = PictureInPicture()
    private(set) var isActive = false
    @ObservationIgnored private var panel: NSPanel?

    func toggle(_ player: Player, library: Library) {
        isActive ? close(returnTo: player) : open(player, library: library)
    }

    func open(_ player: Player, library: Library) {
        guard player.isVideo, !isActive else { return }
        VideoScreen.leaveFullScreen()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.contentView = NSHostingView(rootView: PictureInPictureView().environment(player).environment(library))
        // Bottom right of the screen, clear of the Dock.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.minY + 24))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(player) }
        }
        self.panel = panel
        isActive = true
        // The library shows in the main window meanwhile; the video goes to the panel.
        player.isVideoMinimized = true
        panel.orderFrontRegardless()
    }

    /// Back into MacShow's window, full size.
    func close(returnTo player: Player) {
        panel?.close()
        player.isVideoMinimized = false
        AppDelegate.openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The panel's close button stops the video.
    private func closed(_ player: Player) {
        guard isActive else { return }
        isActive = false
        panel = nil
        if player.isVideoMinimized, player.isVideo { player.stop() }
    }

    /// Playback ended or switched to audio: no picture to show.
    func videoEnded() {
        guard isActive else { return }
        isActive = false
        let panel = panel
        self.panel = nil
        panel?.close()
    }
}

/// What the floating window shows: the picture, and controls on hover.
private struct PictureInPictureView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var hovering = false

    var body: some View {
        ZStack {
            VideoView(layer: player.layer) { _ in player.reattachVideoOutput() }
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { PictureInPicture.shared.close(returnTo: player) }
            if hovering {
                ZStack {
                    Color.black.opacity(0.3).allowsHitTesting(false)
                    HStack(spacing: 28) {
                        Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                        Button { player.togglePause() } label: { Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.largeTitle) }
                        Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                    }
                    .font(.title2)
                    VStack {
                        HStack {
                            Spacer()
                            Button { PictureInPicture.shared.close(returnTo: player) } label: {
                                Label("Back to MacShow", systemImage: "pip.exit").labelStyle(.iconOnly).font(.title3)
                            }
                            .help("Back to MacShow (or double-click)")
                        }
                        Spacer()
                        ProgressBar(progress: player.duration > 0 ? player.position / player.duration : 0)
                    }
                    .padding(12)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .onChange(of: player.isVideo) { _, isVideo in if !isVideo { PictureInPicture.shared.videoEnded() } }
        // Something new started full size in MacShow's window.
        .onChange(of: player.isVideoMinimized) { _, minimized in if !minimized { PictureInPicture.shared.videoEnded() } }
    }
}
