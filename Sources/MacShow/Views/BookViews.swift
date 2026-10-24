import MacShowCore
import SwiftUI

struct BooksView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let books = library.index.books
        Group {
            if books.isEmpty {
                EmptyLibraryView(title: "No Audiobooks", icon: "book")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)], spacing: 28) {
                        ForEach(books) { BookTile(book: $0) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Audiobooks")
    }
}

struct BookTile: View {
    let book: Book
    @Environment(Player.self) private var player

    var body: some View {
        Button { player.play(book.parts) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(key: book.artworkKey, title: book.title)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text([book.author, Format.duration(book.duration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
