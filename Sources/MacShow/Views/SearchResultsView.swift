import MacShowCore
import SwiftUI

/// Everything matching the sidebar search, grouped by kind.
struct SearchResultsView: View {
    let query: String
    @Environment(Library.self) private var library

    /// True if every word of the query appears in one of `fields`.
    private func matches(_ fields: String?...) -> Bool {
        let text = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
        return query.lowercased().split(separator: " ").allSatisfy { text.contains($0) }
    }

    var body: some View {
        let index = library.index
        let artists = index.artists.filter { matches($0.name) }
        let albums = index.albums.filter { matches($0.title, $0.artist) }
        let songs = index.songs.filter { matches($0.title, $0.artist, $0.album) }
        let movies = index.movies.filter { matches($0.title) }
        let books = index.books.filter { matches($0.title, $0.author) }

        Group {
            if artists.isEmpty, albums.isEmpty, songs.isEmpty, movies.isEmpty, books.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !artists.isEmpty {
                            Shelf(title: "Artists") {
                                ForEach(artists.prefix(20)) { artist in
                                    NavigationLink(value: artist) {
                                        VStack {
                                            ArtworkView(key: artist.artworkKey, title: artist.name, cornerRadius: 70).frame(width: 120)
                                            Text(artist.name).font(.callout.weight(.semibold)).lineLimit(1)
                                        }
                                        .frame(width: 130)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !albums.isEmpty {
                            Shelf(title: "Albums") { ForEach(albums.prefix(20)) { AlbumTile(album: $0).frame(width: 160) } }
                        }
                        if !songs.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Songs").font(.title3.weight(.semibold))
                                TrackList(tracks: Array(songs.prefix(50)), showsArtist: true, numbered: false)
                            }
                            .padding(.horizontal, 28)
                        }
                        if !movies.isEmpty {
                            Shelf(title: "Movies") { ForEach(movies.prefix(20)) { MovieTile(movie: $0).frame(width: 240) } }
                        }
                        if !books.isEmpty {
                            Shelf(title: "Audiobooks") { ForEach(books.prefix(20)) { BookTile(book: $0).frame(width: 160) } }
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle("Search")
    }
}
