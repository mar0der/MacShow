import MacShowCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            FoldersSettings().tabItem { Label("Library", systemImage: "folder") }
        }
        .frame(width: 560, height: 380)
    }
}

/// The watched folders: add (via an Open panel, so the sandbox grants access), remove, rescan.
struct FoldersSettings: View {
    @Environment(Library.self) private var library
    @State private var selection: WatchedFolder.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacShow keeps these folders in your library and adds new files as they appear.")
                .foregroundStyle(.secondary)
            List(library.folders, selection: $selection) { folder in
                Label(folder.path.replacingOccurrences(of: Library.realHomeDirectory.path, with: "~"), systemImage: "folder")
            }
            .listStyle(.bordered)
            HStack {
                Button { addFolder() } label: { Image(systemName: "plus") }.help("Add Folder")
                Button {
                    if let folder = library.folders.first(where: { $0.id == selection }) { library.removeFolder(folder) }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove Folder")
                Spacer()
                if library.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button("Rescan") { library.rescanAll() }
                    .disabled(library.isScanning)
            }
        }
        .padding(20)
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
