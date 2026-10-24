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

/// The video window: the picture fills it, controls fade in when the mouse moves.
struct VideoPlayerView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        @Bindable var player = player
        ZStack {
            VideoView(layer: player.layer) { player.reattachVideoOutput() }.ignoresSafeArea()

            VStack {
                HStack(spacing: 12) {
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
                .padding(.leading, 64)  // clear of the window buttons
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
                            Image(systemName: "speaker.wave.2.fill").font(.caption)
                            Slider(value: $player.volume, in: 0...100).controlSize(.small).frame(width: 110)
                        }
                        .frame(width: 200, alignment: .leading)
                        Spacer()
                        HStack(spacing: 18) {
                            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }.help("Back 10 seconds")
                            Button { player.togglePause() } label: {
                                Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title)
                            }
                            .help(player.isPaused ? "Play" : "Pause")
                            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }.help("Forward 10 seconds")
                        }
                        .imageScale(.large)
                        Spacer()
                        HStack(spacing: 14) {
                            TracksMenu()
                            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("Full Screen")
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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { player.skip(-10); showControls(); return .handled }
        .onKeyPress(.rightArrow) { player.skip(10); showControls(); return .handled }
        .onKeyPress("f") { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .onContinuousHover { _ in showControls() }
        .onAppear {
            // Never sit empty (e.g. if macOS restores the window at launch).
            if player.isVideo { showControls() } else { dismissWindow(id: "video") }
        }
        .onChange(of: player.isVideo) { _, isVideo in
            if !isVideo { dismissWindow(id: "video") }
        }
        .onDisappear {
            if player.isVideo { player.stop() }
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    /// Shows the controls and hides them again after three idle seconds while playing.
    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !player.isPaused { controlsVisible = false }
        }
    }
}
