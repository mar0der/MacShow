import MacShowCore
import SwiftUI

struct MoviesView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let movies = library.index.movies
        Group {
            if movies.isEmpty {
                EmptyLibraryView(title: "No Movies", icon: "film")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 24)], spacing: 28) {
                        ForEach(movies) { MovieTile(movie: $0) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Movies")
    }
}

struct MovieTile: View {
    let movie: MediaItem
    @Environment(Player.self) private var player

    var body: some View {
        Button { player.play([movie]) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(key: movie.artworkKey, title: movie.title, aspectRatio: 16 / 9)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text([movie.year.map(String.init), Format.duration(movie.duration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
