import MacShowCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings().tabItem { Label("Library", systemImage: "folder") }
            DuplicatesSettings().tabItem { Label("Duplicates", systemImage: "square.on.square") }
        }
        .frame(width: 600, height: 520)
    }
}

/// Watched folders, where purchases come from, and artwork downloads.
struct LibrarySettings: View {
    @Environment(Library.self) private var library
    @State private var selection: WatchedFolder.ID?
    @AppStorage(Library.fetchArtworkKey) private var fetchArtwork = true

    var body: some View {
        Form {
            Section {
                List(library.folders, selection: $selection) { folder in
                    HStack {
                        Label(folder.path.replacingOccurrences(of: Library.realHomeDirectory.path, with: "~"), systemImage: "folder")
                        Spacer()
                        if library.offlineFolders.contains(folder.path) {
                            Text("Offline").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Button { addFolder() } label: { Image(systemName: "plus") }.help("Add Folder")
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
                Text("New files in these folders are added automatically. Folders on an external drive come back when it's plugged in.")
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
            }
        }
        .formStyle(.grouped)
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
