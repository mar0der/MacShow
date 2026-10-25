import MacShowCore
import SwiftUI

/// Everything matching the sidebar search, grouped by kind.
struct SearchResultsView: View {
    let query: String
    @Environment(Library.self) private var library

    var body: some View {
        let index = library.index
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let matches = { (text: String) in terms.allSatisfy(text.contains) }
        let artists = index.artists.filter { matches($0.name.lowercased()) }
        let albums = index.albums.filter { matches("\($0.title) \($0.artist)".lowercased()) }
        let songs = zip(index.songs, index.songSearchKeys).lazy.filter { matches($0.1) }.prefix(50).map(\.0)
        let movies = (index.movies + index.sports + index.documentaries + index.homeVideos).filter { matches($0.title.lowercased()) }
        let shows = index.shows.filter { matches($0.title.lowercased()) }
        let books = index.books.filter { matches("\($0.title) \($0.author ?? "")".lowercased()) }

        Group {
            if artists.isEmpty, albums.isEmpty, songs.isEmpty, movies.isEmpty, shows.isEmpty, books.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !artists.isEmpty {
                            Shelf(title: "Artists") {
                                ForEach(artists.prefix(20)) { artist in
                                    NavigationLink(value: ArtistRef(id: artist.id)) {
                                        VStack {
                                            ArtworkView(key: library.picture(of: artist), title: artist.name, cornerRadius: 70).frame(width: 120)
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
                                TrackList(tracks: Array(songs), showsArtist: true, numbered: false)
                            }
                            .padding(.horizontal, 28)
                        }
                        if !shows.isEmpty {
                            Shelf(title: "TV Shows") {
                                ForEach(shows.prefix(20)) { show in
                                    NavigationLink(value: ShowRef(id: show.id)) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            VideoStill(item: show.episodes[0])
                                            Text(show.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        }
                                        .frame(width: 240)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !movies.isEmpty {
                            Shelf(title: "Videos") { ForEach(movies.prefix(20)) { MovieTile(movie: $0).frame(width: 240) } }
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
