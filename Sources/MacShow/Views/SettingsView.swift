import MacShowCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings().tabItem { Label("Library", systemImage: "folder") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "hifispeaker") }
            ContentSettings().tabItem { Label("Content", systemImage: "eye.slash") }
            AgentSettings().tabItem { Label("Agents", systemImage: "sparkles") }
            DuplicatesSettings().tabItem { Label("Duplicates", systemImage: "square.on.square") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 580)
    }
}

/// Watched folders, where purchases come from, and artwork downloads.
struct LibrarySettings: View {
    @Environment(Library.self) private var library
    @State private var selection: WatchedFolder.ID?
    @State private var addingNetworkFolder = false
    @AppStorage(Library.fetchArtworkKey) private var fetchArtwork = true
    @AppStorage(ArtworkFetcher.tmdbKeyDefault) private var tmdbKey = ""
    @AppStorage(Library.fetchLyricsKey) private var fetchLyrics = true
    @AppStorage(Library.fetchInfoKey) private var fetchInfo = true

    var body: some View {
        Form {
            Section {
                List(library.folders, selection: $selection) { folder in
                    HStack {
                        Label(folder.path.replacingOccurrences(of: Library.realHomeDirectory.path, with: "~"),
                              systemImage: folder.isOnNetworkShare ? "server.rack" : "folder")
                        Spacer()
                        if library.offlineFolders.contains(folder.path) {
                            Text("Offline").font(.caption).foregroundStyle(.secondary)
                            if let share = folder.remountURL.flatMap(URL.init(string:)) {
                                Button("Connect") { NSWorkspace.shared.open(share) }
                                    .controlSize(.small)
                                    .help("Connect to \(share.host ?? "the server") again")
                            }
                        }
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Menu {
                        Button("Add Folder…") { addFolder() }
                        Button("Add Network Folder…") { addingNetworkFolder = true }
                    } label: { Image(systemName: "plus") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add Folder")
                    Button {
                        if let folder = library.folders.first(where: { $0.id == selection }) { library.removeFolder(folder) }
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Remove Folder")
                    Spacer()
                    if library.isScanning { ProgressView().controlSize(.small) }
                    Button("Rescan") { library.rescanAll() }.disabled(library.isScanning)
                }
            } header: {
                Text("Watched Folders")
            } footer: {
                Text("New files in these folders are added automatically. Folders on an external drive come back when it's plugged in; folders on a network share reconnect by themselves and are rescanned every 15 minutes.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Purchases from Apple") {
                Text("Music you bought on the iTunes Store is DRM-free. Turn on Automatic Downloads in the Music app (or download albums from Account › Purchased) and they appear here on their own.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Music") {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Music.app"), configuration: .init())
                }
            }

            Section {
                Toggle("Download missing album artwork", isOn: $fetchArtwork)
            } footer: {
                Text("Looks up covers for albums that have none on the iTunes Store. Only album and artist names are sent.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Look up artist bios and book details", isOn: $fetchInfo)
            } footer: {
                Text("Artist pages show the start of their Wikipedia article; audiobooks get a description and, if they have none, a cover from Open Library. Only names are sent.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Look up lyrics online", isOn: $fetchLyrics)
            } footer: {
                Text("For songs without an .lrc file or lyrics in their tags, from LRCLIB (lrclib.net). Only the artist, title, album and length are sent.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                SecureField("TMDB API key", text: $tmdbKey, prompt: Text("Optional"))
            } footer: {
                Text("Posters and wide artwork for movies and shows in Get Info › Find Artwork Online, from themoviedb.org. A free key comes with a TMDB account (Settings › API). Without one, Wikipedia is used.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingNetworkFolder) { NetworkFolderSheet() }
        #if DEBUG
        .onAppear { if UserDefaults.standard.bool(forKey: "debugNetworkSheet") { addingNetworkFolder = true } }
        #endif
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(library.addFolder)
    }
}

/// Bit-perfect output.
struct PlaybackSettings: View {
    @Environment(Player.self) private var player
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some View {
        @Bindable var player = player
        Form {
            Section {
                Toggle("Show controls in the menu bar", isOn: $showInMenuBar)
            }
            Section {
                Picker("Volume leveling (ReplayGain)", selection: $player.replayGain) {
                    Text("Album").tag("album")
                    Text("Track").tag("track")
                    Text("Off").tag("no")
                }
            } footer: {
                Text("Uses the ReplayGain tags in your files. Album keeps the quiet and loud songs of an album as the artist meant; Track makes every song as loud as the next.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Bit-perfect output", isOn: $player.exclusiveAudio)
                if let file = player.fileSampleRate {
                    LabeledContent("Now playing") {
                        let device = player.deviceSampleRate
                        Text("file \(Self.kHz(file)), device \(device.map(Self.kHz) ?? "–")" + (device == file ? " ✓" : " (resampled by macOS)"))
                            .foregroundStyle(device == file ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                }
            } footer: {
                Text("macOS normally resamples everything to the rate set in Audio MIDI Setup. With this on, MacShow takes the audio device for itself and switches it to each file's own sample rate, so lossless and hi-res files reach your DAC untouched (keep the volume at 100% and the equalizer off for that). Other apps can't play sound while MacShow is playing.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    static func kHz(_ rate: Int) -> String {
        String(format: "%g kHz", Double(rate) / 1000)
    }
}

/// Folders marked Personal or Adult, and what's never scanned.
struct ContentSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        Form {
            Section {
                if library.folderRules.isEmpty {
                    Text("Nothing yet. Right-click a video and choose its folder to sort it.").foregroundStyle(.secondary)
                }
                ForEach(library.folderRules) { rule in
                    HStack {
                        Label(rule.path.replacingOccurrences(of: Library.realHomeDirectory.path, with: "~"), systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: Binding(get: { rule.kind }, set: { library.setRule($0, for: URL(fileURLWithPath: rule.path)) })) {
                            ForEach(FolderRule.Kind.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { library.setRule(nil, for: URL(fileURLWithPath: rule.path)) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Back to normal")
                    }
                }
                Menu("Add Folder") {
                    ForEach(FolderRule.Kind.allCases, id: \.self) { kind in
                        Button(Self.title(kind) + "…") { addFolder(kind) }
                    }
                }
                .fixedSize()
            } header: {
                Text("Sorted Folders")
            } footer: {
                Text("Personal: videos show under Home Videos. Adult: kept out of Home, search and every list; shown in their own section after Touch ID (View › Show Adult Content, ⇧⌘A), and hidden again at every launch. Never Scan: not in the library at all.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let locked = library.index.itemsByID.values.filter(\.isProtected).sorted { $0.path < $1.path }
            Section {
                if locked.isEmpty {
                    Label("None. Everything in your library plays.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(locked) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(1)
                            Text(item.path.replacingOccurrences(of: Library.realHomeDirectory.path, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                    }
                }
                if !locked.isEmpty {
                    Button("Hide These from the Library") { locked.forEach { library.setRule(.excluded, for: $0.url) } }
                }
            } header: {
                Text("Copy-Protected Files (\(locked.count))")
            } footer: {
                Text("These are locked to Apple's apps with DRM: old iTunes Store movies and TV shows, Audible books, songs saved from an Apple Music subscription. No other player can open them. What you bought is a licence that the store can withdraw, so where you can, download a DRM-free copy (iTunes music purchases since 2009 are DRM-free) and keep it in a watched folder.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    static func title(_ kind: FolderRule.Kind) -> String {
        switch kind {
        case .excluded: "Never Scan"
        case .personal: "Personal"
        case .adult: "Adult"
        }
    }

    private func addFolder(_ kind: FolderRule.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Mark as \(Self.title(kind))"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { library.setRule(kind, for: url) }
    }
}

/// Songs found in more than one place, and which copy MacShow plays.
struct DuplicatesSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        let groups = library.index.duplicates
        if groups.isEmpty {
            ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle", description: Text("Every song appears once."))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(groups.count) songs are in your library more than once. MacShow plays the best copy (lossless first, then the highest sample rate) and hides the rest.")
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top])
                List {
                    ForEach(groups, id: \.first?.path) { copies in
                        Section("\(copies[0].title) — \(copies[0].artist ?? "Unknown Artist")") {
                            ForEach(Array(copies.enumerated()), id: \.element.path) { offset, copy in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(copy.url.deletingLastPathComponent().path.replacingOccurrences(of: Library.realHomeDirectory.path, with: "~"))
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(copy.formatInfo).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if offset == 0 { Text("Plays").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([copy.url]) } label: {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Show in Finder")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
