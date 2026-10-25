import MacShowCore
import SwiftUI

/// Get Info: change the title, artist, album, show details or artwork of one
/// item or several at once. Changes are stored in MacShow, never in the files.
struct InfoView: View {
    let ids: [Int64]
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [Field: String] = [:]
    @State private var changed: Set<Field> = []
    @State private var artworkKey: String?
    @State private var loaded = false
    @State private var searchingArtwork = false

    enum Field: String, CaseIterable {
        case title = "Title", artist = "Artist", album = "Album", albumArtist = "Album Artist", genre = "Genre", year = "Year"
        case show = "Show", season = "Season", episode = "Episode"
    }

    private var items: [MediaItem] { ids.compactMap { library.index.itemsByID[$0] } }

    var body: some View {
        let items = items
        let isVideo = items.contains(where: \.isVideo)
        Form {
            HStack(alignment: .top, spacing: 16) {
                ArtworkView(key: artworkKey ?? items.first?.artworkKey, title: items.first?.album ?? items.first?.title ?? "", cornerRadius: 8)
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) items")
                        .font(.headline).lineLimit(2)
                    HStack {
                        Button("Find Artwork Online…") { searchingArtwork = true }
                        Button("Choose File…", action: chooseArtwork)
                    }
                    Text("Saved in MacShow only; your files aren't changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(fieldsShown(isVideo: isVideo, single: items.count == 1), id: \.self) { field in
                    TextField(field.rawValue, text: binding(field), prompt: Text(placeholder(field, items)))
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Use File's Details") {
                    library.save(items.map { ItemEdit(path: $0.path) })
                    dismiss()
                }
                .disabled(!items.contains { library.edits[$0.path] != nil })
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(items); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changed.isEmpty && artworkKey == nil)
            }
            .padding()
        }
        .frame(width: 460)
        .sheet(isPresented: $searchingArtwork) {
            ArtworkSearchView(kind: Self.searchKind(items), term: Self.searchTerm(items)) { data in
                artworkKey = library.artwork.store(data)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            for field in Field.allCases { fields[field] = common(field, items) ?? "" }
        }
    }

    private func fieldsShown(isVideo: Bool, single: Bool) -> [Field] {
        let base: [Field] = isVideo ? [.title, .show, .season, .episode, .genre, .year] : [.title, .artist, .album, .albumArtist, .genre, .year]
        return single ? base : base.filter { $0 != .title && $0 != .episode }
    }

    private func binding(_ field: Field) -> Binding<String> {
        Binding(get: { fields[field] ?? "" }, set: {
            fields[field] = $0
            changed.insert(field)
        })
    }

    private func placeholder(_ field: Field, _ items: [MediaItem]) -> String {
        items.count > 1 && common(field, items) == nil ? "Mixed" : ""
    }

    /// The value all the items share, nil if they differ.
    private func common(_ field: Field, _ items: [MediaItem]) -> String? {
        let values = Set(items.map { value(field, of: $0) })
        return values.count == 1 ? values.first! : nil
    }

    private func value(_ field: Field, of item: MediaItem) -> String {
        switch field {
        case .title: item.title
        case .artist: item.artist ?? ""
        case .album: item.album ?? ""
        case .albumArtist: item.albumArtist ?? ""
        case .genre: item.genre ?? ""
        case .year: item.year.map(String.init) ?? ""
        case .show: item.show ?? ""
        case .season: item.season.map(String.init) ?? ""
        case .episode: item.episode.map(String.init) ?? ""
        }
    }

    private func save(_ items: [MediaItem]) {
        library.save(items.map { item in
            var edit = library.edits[item.path] ?? ItemEdit(path: item.path)
            for field in changed {
                let text = fields[field, default: ""].trimmingCharacters(in: .whitespaces)
                // Empty goes back to what the file says.
                let string = text.isEmpty ? nil : text
                switch field {
                case .title: edit.title = string
                case .artist: edit.artist = string
                case .album: edit.album = string
                case .albumArtist: edit.albumArtist = string
                case .genre: edit.genre = string
                case .year: edit.year = string.flatMap(Int.init)
                case .show: edit.show = string
                case .season: edit.season = string.flatMap(Int.init)
                case .episode: edit.episode = string.flatMap(Int.init)
                }
            }
            if let artworkKey { edit.artworkKey = artworkKey }
            return edit
        })
    }

    static func searchKind(_ items: [MediaItem]) -> ArtworkFetcher.SearchKind {
        switch items.first?.kind {
        case .episode: .tvShow
        case .movie, .homeVideo, .documentary, .sport: .movie
        case .musicVideo: .musicVideo
        default: .album
        }
    }

    /// What to search for: the show, the movie's name and year, or artist and album.
    static func searchTerm(_ items: [MediaItem]) -> String {
        guard let item = items.first else { return "" }
        switch item.kind {
        case .episode: return item.show ?? item.title
        case .movie, .homeVideo, .documentary, .sport: return [item.title, item.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        case .musicVideo: return [item.artist, item.title].compactMap { $0 }.joined(separator: " ")
        // Untagged albums are named after their folder, as in the library.
        default: return [item.albumArtist ?? item.artist, item.album ?? item.url.deletingLastPathComponent().lastPathComponent]
            .compactMap { $0 }.joined(separator: " ")
        }
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to use as the artwork."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        artworkKey = library.artwork.store(data)
    }
}
