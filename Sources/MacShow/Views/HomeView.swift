import MacShowCore
import SwiftUI

struct HomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let index = library.index
        if index.isEmpty {
            EmptyLibraryView(title: library.isScanning ? LocalizedStringKey("Reading Your Library…") : LocalizedStringKey("Nothing Here Yet"), icon: "play.square.stack")
                .navigationTitle("Home")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    let resume = library.continueWatching
                    let books = library.booksInProgress
                    if !resume.isEmpty || !books.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Jump back in").font(.title3.weight(.semibold)).padding(.horizontal, 28)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)], spacing: 16) {
                                ForEach(books.prefix(3)) { BookJumpCard(book: $0) }
                                ForEach(resume.prefix(6)) { JumpBackInCard(item: $0) }
                            }
                            .padding(.horizontal, 28)
                        }
                    }
                    if !index.albums.isEmpty {
                        Shelf(title: "Albums") {
                            ForEach(index.albums.prefix(12)) { AlbumTile(album: $0).frame(width: 170) }
                        }
                    }
                    if !index.shows.isEmpty {
                        Shelf(title: "TV Shows") {
                            ForEach(index.shows.prefix(12)) { show in
                                NavigationLink(value: ShowRef(id: show.id)) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ShowArtwork(show: show)
                                        Text(show.title).font(.callout.weight(.semibold)).lineLimit(1)
                                    }
                                    .frame(width: 240)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
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

/// A "Jump back in" card: still, kind, title, time left and progress.
struct JumpBackInCard: View {
    let item: MediaItem
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let saved = item.id.flatMap { library.positions[$0] }
        Button { play() } label: {
            HStack(spacing: 14) {
                VideoStill(item: item, cornerRadius: 6).frame(width: 128)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(item.kind == .episode ? (item.show ?? item.title) : item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(detail(saved)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let saved, saved.isResumable { ProgressBar(progress: saved.progress).padding(.top, 2) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RemoveFromJumpBackIn { library.removeFromContinueWatching(item) })
        .contextMenu {
            Button("Play") { play() }
            Button("Remove from Jump Back In") { library.removeFromContinueWatching(item) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private var kind: LocalizedStringKey {
        switch item.kind {
        case .episode: "Episode"
        case .audiobook: "Audiobook"
        case .homeVideo: "Home Video"
        default: "Movie"
        }
    }

    private func detail(_ saved: PlaybackPosition?) -> String {
        let episode = item.kind == .episode ? "S\(item.season ?? 1) E\(item.episode ?? 0) · " : ""
        if let saved, saved.isResumable { return episode + String(localized: "\(Format.duration(saved.remaining)) left") }
        return episode + (item.kind == .episode ? String(localized: "Up next") : Format.duration(item.duration))
    }

    /// Episodes play on through the rest of their show.
    private func play() {
        if item.kind == .episode, let show = library.index.shows.first(where: { $0.episodes.contains(item) }) {
            player.play(show.episodes, startAt: show.episodes.firstIndex(of: item) ?? 0)
        } else {
            player.play([item])
        }
    }
}

/// "Jump back in" for an audiobook: opens the book's page.
struct BookJumpCard: View {
    let book: Book
    @Environment(Library.self) private var library

    var body: some View {
        let progress = library.progress(of: book)
        NavigationLink(value: BookRef(id: book.id)) {
            HStack(spacing: 14) {
                ArtworkView(key: book.artworkKey, title: book.title, cornerRadius: 6).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audiobook").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(Format.duration(progress.remaining)) left").font(.caption).foregroundStyle(.secondary)
                    ProgressBar(progress: progress.fraction).padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RemoveFromJumpBackIn { library.removeFromContinueWatching(book) })
        .contextMenu { Button("Remove from Jump Back In") { library.removeFromContinueWatching(book) } }
    }
}

/// The × in a "Jump back in" card's corner (on hover), for something you won't finish.
private struct RemoveFromJumpBackIn: ViewModifier {
    let remove: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Jump Back In")
                    .padding(6)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// A titled, horizontally scrolling row.
struct Shelf<Content: View>: View {
    let title: LocalizedStringKey
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
