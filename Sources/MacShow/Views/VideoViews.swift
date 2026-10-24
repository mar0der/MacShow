import MacShowCore
import SwiftUI

private let videoGrid = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 24)]

/// Movies or Home Videos: a grid of stills.
struct VideoGridView: View {
    let title: String
    let icon: String
    let videos: [MediaItem]

    var body: some View {
        Group {
            if videos.isEmpty {
                EmptyLibraryView(title: "No \(title)", icon: icon)
            } else {
                ScrollView {
                    LazyVGrid(columns: videoGrid, spacing: 28) {
                        ForEach(videos) { MovieTile(movie: $0) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle(title)
    }
}

/// A video's still (generated on first display), with a progress bar when partly watched.
struct VideoStill: View {
    let item: MediaItem
    var cornerRadius: CGFloat = 8
    @Environment(Library.self) private var library
    @State private var stillKey: String?

    var body: some View {
        ArtworkView(key: item.artworkKey ?? stillKey, title: item.title, cornerRadius: cornerRadius, aspectRatio: 16 / 9)
            .overlay(alignment: .bottom) {
                if let saved = item.id.flatMap({ library.positions[$0] }), saved.isResumable || saved.isFinished {
                    if saved.isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(8)
                    } else {
                        ProgressBar(progress: saved.progress).padding(8)
                    }
                }
            }
            .task(id: item.id) { stillKey = await library.still(for: item) }
    }
}

struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.tint).frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 4)
    }
}

struct MovieTile: View {
    let movie: MediaItem
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        Button { player.play([movie]) } label: {
            VStack(alignment: .leading, spacing: 8) {
                VideoStill(item: movie)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { VideoMenu(item: movie, queue: [movie]) }
    }

    private var subtitle: String {
        if let saved = movie.id.flatMap({ library.positions[$0] }), saved.isResumable {
            return "\(Format.duration(saved.remaining)) left"
        }
        return [movie.year.map(String.init), Format.duration(movie.duration)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Context menu for a movie or episode.
struct VideoMenu: View {
    let item: MediaItem
    /// What to play: the item alone, or the rest of a season.
    let queue: [MediaItem]
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let start = queue.firstIndex(of: item) ?? 0
        Button("Play") { player.play(queue, startAt: start) }
        if let saved = item.id.flatMap({ library.positions[$0] }), saved.isResumable {
            Button("Play from Beginning") { player.play(queue, startAt: start, fromBeginning: true) }
        }
        Divider()
        if item.id.flatMap({ library.positions[$0] })?.isFinished == true {
            Button("Mark as Unwatched") { library.clearPosition(for: item) }
        } else {
            Button("Mark as Watched") { library.savePosition(item.duration, duration: item.duration, for: item) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    }
}

// MARK: TV shows

struct ShowsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let shows = library.index.shows
        Group {
            if shows.isEmpty {
                EmptyLibraryView(title: "No TV Shows", icon: "tv")
            } else {
                ScrollView {
                    LazyVGrid(columns: videoGrid, spacing: 28) {
                        ForEach(shows) { show in
                            NavigationLink(value: ShowRef(id: show.id)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    VideoStill(item: show.episodes[0])
                                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(show.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        Text(seasonSummary(show)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("TV Shows")
    }

    private func seasonSummary(_ show: Show) -> String {
        let seasons = show.seasons.count
        return "\(seasons) season\(seasons == 1 ? "" : "s") · \(show.episodes.count) episodes"
    }
}

struct ShowDetailView: View {
    let show: Show
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var season: Int?

    var body: some View {
        let selectedSeason = season ?? nextUp?.season ?? show.seasons.first
        let episodes = show.episodes.filter { $0.season == selectedSeason }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    VideoStill(item: nextUp ?? show.episodes[0], cornerRadius: 10)
                        .frame(width: 360)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(show.title).font(.largeTitle.weight(.bold))
                        Text("\(show.seasons.count) seasons · \(show.episodes.count) episodes").foregroundStyle(.secondary)
                        if let next = nextUp {
                            Button {
                                player.play(show.episodes, startAt: show.episodes.firstIndex(of: next) ?? 0)
                            } label: {
                                Label(resumeLabel(next), systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.top, 8)
                        }
                    }
                }
                if show.seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { selectedSeason ?? 1 }, set: { season = $0 })) {
                        ForEach(show.seasons, id: \.self) { Text("Season \($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                LazyVStack(spacing: 14) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode) {
                            player.play(show.episodes, startAt: show.episodes.firstIndex(of: episode) ?? 0)
                        }
                        .contextMenu { VideoMenu(item: episode, queue: show.episodes) }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(show.title)
    }

    /// The episode to continue with: one in progress, else the first unwatched.
    private var nextUp: MediaItem? {
        let saved = { (item: MediaItem) in item.id.flatMap { library.positions[$0] } }
        return show.episodes.first { saved($0)?.isResumable == true }
            ?? show.episodes.first { saved($0)?.isFinished != true }
    }

    private func resumeLabel(_ episode: MediaItem) -> String {
        let label = "S\(episode.season ?? 1) E\(episode.episode ?? 0)"
        let resuming = episode.id.flatMap { library.positions[$0] }?.isResumable == true
        return resuming ? "Resume \(label)" : "Play \(label)"
    }
}

struct EpisodeRow: View {
    let episode: MediaItem
    let play: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        Button(action: play) {
            HStack(spacing: 16) {
                VideoStill(item: episode, cornerRadius: 6).frame(width: 192)
                VStack(alignment: .leading, spacing: 4) {
                    let number = "Episode \(episode.episode ?? 0)"
                    if episode.title != number {
                        Text(number).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(episode.title).font(.headline).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        if let saved = episode.id.flatMap({ library.positions[$0] }), saved.isResumable {
            return "\(Format.duration(saved.remaining)) left"
        }
        return Format.duration(episode.duration)
    }
}
