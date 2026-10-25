import MacShowCore
import SwiftUI

/// Subtitle and audio-track choices, plus adding a subtitle file.
struct TracksMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        let subtitles = player.tracks("sub")
        let audio = player.tracks("audio")
        Menu {
            Section("Subtitles") {
                Toggle("Off", isOn: Binding(get: { !subtitles.contains(where: \.isSelected) }, set: { _ in player.select(nil, type: "sub") }))
                ForEach(subtitles) { track in
                    Toggle(track.title, isOn: Binding(get: { track.isSelected }, set: { _ in player.select(track, type: "sub") }))
                }
                Button("Add Subtitle File…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = []
                    panel.allowsOtherFileTypes = true
                    panel.message = "Choose a subtitle file (SRT, ASS, VTT…)"
                    if panel.runModal() == .OK, let url = panel.url { player.addSubtitleFile(url) }
                }
            }
            if audio.count > 1 {
                Section("Audio") {
                    ForEach(audio) { track in
                        Toggle(track.title, isOn: Binding(get: { track.isSelected }, set: { _ in player.select(track, type: "audio") }))
                    }
                }
            }
        } label: {
            Image(systemName: subtitles.contains(where: \.isSelected) ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles and Audio")
    }
}

/// A playing video, filling the main window: the picture, with controls that
/// fade in when the mouse moves. Click to pause, double-click for full screen.
struct VideoPlayerView: View {
    @Environment(Player.self) private var player
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isFullScreen = false

    var body: some View {
        @Bindable var player = player
        ZStack {
            VideoView(layer: player.layer) { window in
                VideoScreen.window = window
                player.reattachVideoOutput()
            }

            // Catches clicks on the picture (the Metal view itself doesn't).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { VideoScreen.toggleFullScreen() }
                .onTapGesture { player.togglePause(); showControls() }

            VStack {
                HStack(spacing: 12) {
                    Button { player.stop() } label: {
                        Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back to Library (Esc)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.currentItem?.title ?? player.title).font(.headline)
                        if let item = player.currentItem, item.kind == .episode, let show = item.show {
                            Text("\(show) · S\(item.season ?? 0) E\(item.episode ?? 0)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ForEach(player.formatInfo.components(separatedBy: " · ").filter { !$0.isEmpty }, id: \.self) {
                        Text($0).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .padding(.leading, isFullScreen ? 0 : 64)  // clear of the window buttons
                .glassPanel(cornerRadius: 0)

                Spacer()

                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Text(Format.time(player.position)).monospacedDigit()
                        Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                        Text("-" + Format.time(player.duration - player.position)).monospacedDigit()
                    }
                    .font(.caption)
                    HStack {
                        HStack(spacing: 6) {
                            Button { player.isMuted.toggle() } label: {
                                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.caption)
                            }
                            .help(player.isMuted ? "Unmute (M)" : "Mute (M)")
                            Slider(value: $player.volume, in: 0...100).controlSize(.small).frame(width: 110)
                        }
                        .frame(width: 200, alignment: .leading)
                        Spacer()
                        HStack(spacing: 18) {
                            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                                .help("Previous (⌘←)")
                                .disabled(player.queue.count < 2)
                            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }.help("Back 10 seconds (←)")
                            Button { player.togglePause() } label: {
                                Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title)
                            }
                            .help(player.isPaused ? "Play (Space)" : "Pause (Space)")
                            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }.help("Forward 10 seconds (→)")
                            Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                                .help("Next (⌘→)")
                                .disabled((player.queueIndex ?? 0) + 1 >= player.queue.count)
                        }
                        .imageScale(.large)
                        Spacer()
                        HStack(spacing: 14) {
                            TracksMenu()
                            Button { VideoScreen.toggleFullScreen() } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("Full Screen (F or double-click)")
                        }
                        .frame(width: 200, alignment: .trailing)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(maxWidth: 860)
                .glassPanel(cornerRadius: 20)
                .padding(24)
            }
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .background(.black)
        .ignoresSafeArea()
        .hidingWindowTitle()
        .onContinuousHover { _ in showControls() }
        .onReceive(NotificationCenter.default.publisher(for: VideoScreen.activity)) { _ in showControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = VideoScreen.isFullScreen }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = VideoScreen.isFullScreen }
        .onAppear {
            isFullScreen = VideoScreen.isFullScreen
            showControls()
        }
        .onDisappear {
            hideTask?.cancel()
            VideoScreen.videoClosed()
            // The window was closed while the video played.
            if player.isVideo { player.stop() }
        }
    }

    /// Shows the controls and hides them (and the pointer) again after three idle seconds while playing.
    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !player.isPaused {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

private extension View {
    /// Lets the picture run under the title bar, with no title over it.
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title).toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
