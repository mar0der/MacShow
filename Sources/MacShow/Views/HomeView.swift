import MacShowCore
import SwiftUI

struct HomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let index = library.index
        if index.isEmpty {
            EmptyLibraryView(title: library.isScanning ? "Reading Your Library…" : "Nothing Here Yet", icon: "play.square.stack")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if !index.albums.isEmpty {
                        Shelf(title: "Albums") {
                            ForEach(index.albums.prefix(12)) { AlbumTile(album: $0).frame(width: 170) }
                        }
                    }
                    if !index.movies.isEmpty {
                        Shelf(title: "Movies") {
                            ForEach(index.movies.prefix(12)) { MovieTile(movie: $0).frame(width: 240) }
                        }
                    }
                    if !index.books.isEmpty {
                        Shelf(title: "Audiobooks") {
                            ForEach(index.books.prefix(12)) { BookTile(book: $0).frame(width: 170) }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Home")
        }
    }
}

/// A titled, horizontally scrolling row.
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) { content }
                    .padding(.horizontal, 28)
            }
        }
    }
}
