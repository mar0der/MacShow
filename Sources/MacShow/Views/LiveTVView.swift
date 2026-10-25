import MacShowCore
import SwiftUI
import UniformTypeIdentifiers

/// Live TV: the free channels and your playlists, one tab per group (Favorites
/// first), each card saying what's on now and next.
struct LiveTVView: View {
    @Environment(LiveTV.self) private var live
    @Environment(Player.self) private var player
    @AppStorage("liveTVTab") private var tab: String?
    @State private var adding = false

    private static let favoritesTab = "\u{1}favorites"
    private let grid = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)]

    var body: some View {
        let channels = live.channels
        let groups = Array(Set(channels.map { $0.group ?? "" })).sorted { $1.isEmpty || !$0.isEmpty && $0.localizedStandardCompare($1) == .orderedAscending }
        let tabs = (live.favoriteChannels.isEmpty ? [] : [Self.favoritesTab]) + groups
        let selected = tab.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? ""
        let shown = selected == Self.favoritesTab ? live.favoriteChannels : channels.filter { ($0.group ?? "") == selected }
        Group {
            if channels.isEmpty {
                VStack(spacing: 14) {
                    EmptyLibraryView(title: live.isLoading ? "Loading Channels…" : "No Channels", icon: "antenna.radiowaves.left.and.right")
                    Button("Add Playlist…") { adding = true }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: grid, spacing: 20) {
                        ForEach(shown) { channel in
                            ChannelCard(channel: channel) { player.playLive(channel, in: shown) }
                        }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Live TV")
        .toolbar {
            if tabs.count > 1 {
                Picker("Group", selection: Binding(get: { selected }, set: { tab = $0 })) {
                    ForEach(tabs, id: \.self) { name in
                        switch name {
                        case Self.favoritesTab: Text("Favorites").tag(name)
                        case "": Text("Other").tag(name)
                        default: Text(name).tag(name)
                        }
                    }
                }
                .pickerStyle(.segmented)
            }
            Button { adding = true } label: { Label("Add Playlist…", systemImage: "plus") }
                .help("Add an M3U playlist from your TV provider, Tvheadend or a channel list")
        }
        .sheet(isPresented: $adding) { AddPlaylistSheet() }
    }
}

/// A channel: its logo, name, and what's on now (with how far along) and next.
private struct ChannelCard: View {
    let channel: LiveChannel
    let play: () -> Void
    @Environment(LiveTV.self) private var live
    @Environment(Player.self) private var player

    var body: some View {
        let (now, next) = live.nowAndNext(for: channel)
        Button(action: play) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                    AsyncImage(url: channel.logo) { image in image.resizable().scaledToFit() } placeholder: {
                        Text(channel.name).font(.title3.weight(.bold)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if live.favorites.contains(channel.id) {
                        Image(systemName: "heart.fill").foregroundStyle(.pink).padding(8)
                    }
                    if player.liveChannel == channel {
                        Label("Playing", systemImage: "speaker.wave.2.fill").labelStyle(.iconOnly).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if let now {
                        Text(now.title).font(.caption).lineLimit(1)
                        ProgressView(value: Date().timeIntervalSince(now.start), total: now.stop.timeIntervalSince(now.start))
                            .controlSize(.mini)
                    }
                    if let next {
                        Text("Next: \(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(now?.description ?? channel.name)
        .contextMenu {
            Button("Play", action: play)
            Button(live.favorites.contains(channel.id) ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites")) {
                live.toggleFavorite(channel)
            }
        }
    }
}

/// Add Playlist: a name, the playlist's address (or a file), and optionally a guide.
struct AddPlaylistSheet: View {
    @Environment(LiveTV.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var playlist = ""
    @State private var guide = ""
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Playlist").font(.headline)
            Text("An M3U playlist from your TV provider, Tvheadend or a channel list. Add only channels you're allowed to watch.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("My channels"))
                HStack {
                    TextField("Playlist", text: $playlist, prompt: Text("https://…/playlist.m3u"))
                    Button("Choose File…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.m3uPlaylist] + [UTType(filenameExtension: "m3u8")].compactMap { $0 }
                        if panel.runModal() == .OK, let url = panel.url {
                            playlist = url.absoluteString
                            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                        }
                    }
                }
                TextField("Program guide", text: $guide, prompt: Text("Optional: https://…/guide.xml.gz"))
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(adding || URL(string: playlist.trimmingCharacters(in: .whitespaces))?.scheme == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() {
        guard let url = URL(string: playlist.trimmingCharacters(in: .whitespaces)) else { return }
        let guideURL = URL(string: guide.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
        adding = true
        problem = nil
        Task {
            do {
                try await live.addSource(name: name.isEmpty ? (url.host ?? url.lastPathComponent) : name, playlist: url, guide: guideURL)
                dismiss()
            } catch LiveTV.AddError.noChannels {
                problem = String(localized: "That playlist has no channels.")
            } catch {
                problem = String(localized: "Couldn't read that playlist. Check the address.")
            }
            adding = false
        }
    }
}

/// Settings › Live TV: the free channels on or off, and your playlists.
struct LiveTVSettings: View {
    @Environment(LiveTV.self) private var live
    @State private var adding = false

    var body: some View {
        @Bindable var live = live
        Form {
            Section {
                Toggle("Free channels", isOn: $live.showsFreeChannels)
                Text("Bulgarian regional channels and international news, streamed for free by the broadcasters themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your Playlists") {
                if live.sources.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(live.sources) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.name)
                            Text(source.playlist.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { live.removeSource(source) }
                    }
                }
                Button("Add Playlist…") { adding = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
        .sheet(isPresented: $adding) { AddPlaylistSheet() }
    }
}
