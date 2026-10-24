import MacShowCore
import SwiftUI

// Pages are pushed by id and look up the current value, so an album opened
// during a scan fills in as tracks arrive and drops tracks that were deleted.
struct AlbumRef: Hashable { let id: String }
struct ArtistRef: Hashable { let id: String }
struct ShowRef: Hashable { let id: String }
struct BookRef: Hashable { let id: String }

extension View {
    func libraryDestinations() -> some View {
        navigationDestination(for: AlbumRef.self) { ref in
            Resolved(ref.id, in: \.albums) { AlbumDetailView(album: $0) }.withPlayerBar()
        }
        .navigationDestination(for: ArtistRef.self) { ref in
            Resolved(ref.id, in: \.artists) { ArtistDetailView(artist: $0) }.withPlayerBar()
        }
        .navigationDestination(for: ShowRef.self) { ref in
            Resolved(ref.id, in: \.shows) { ShowDetailView(show: $0) }.withPlayerBar()
        }
        .navigationDestination(for: BookRef.self) { ref in
            Resolved(ref.id, in: \.books) { BookDetailView(book: $0) }.withPlayerBar()
        }
    }
}

/// Finds `id` in the current library index, or says it's gone.
private struct Resolved<Value: Identifiable<String>, Content: View>: View {
    let id: String
    let path: KeyPath<LibraryIndex, [Value]>
    let content: (Value) -> Content
    @Environment(Library.self) private var library

    init(_ id: String, in path: KeyPath<LibraryIndex, [Value]>, @ViewBuilder content: @escaping (Value) -> Content) {
        self.id = id
        self.path = path
        self.content = content
    }

    var body: some View {
        if let value = library.index[keyPath: path].first(where: { $0.id == id }) {
            content(value)
        } else {
            ContentUnavailableView("No Longer in Your Library", systemImage: "questionmark.folder")
        }
    }
}
