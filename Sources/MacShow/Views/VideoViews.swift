import MacShowCore
import SwiftUI

private let videoGrid = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 24)]

/// Movies, Home Videos and the like: a grid of stills. `section` names the
/// section for its choice of sources.
struct VideoGridView: View {
    let title: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let icon: String
    let section: String
    let videos: [MediaItem]

    var body: some View {
        Group {
            if videos.isEmpty {
                EmptyLibraryView(title: emptyTitle, icon: icon)
            } else {
                SourceFiltered(section: section, items: videos) { shown in
                    ScrollView {
                        LazyVGrid(columns: videoGrid, spacing: 28) {
                            ForEach(shown) { MovieTile(movie: $0) }
                        }
                        .padding(28)
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

/// Shows `items` from the drives and network shares chosen for `section` in its
/// toolbar's Sources menu, so a slow share can be left out of one section and
/// kept in another. The menu appears when there's more than one source.
struct SourceFiltered<Content: View>: View {
    let section: String
    let items: [MediaItem]
    @ViewBuilder let content: ([MediaItem]) -> Content
    @Environment(Library.self) private var library
    /// Hidden sources, one per line; "/" is this Mac.
    @AppStorage private var hidden: String

    init(section: String, items: [MediaItem], @ViewBuilder content: @escaping ([MediaItem]) -> Content) {
        self.section = section
        self.items = items
        self.content = content
        _hidden = AppStorage(wrappedValue: "", "hiddenSources." + section)
    }

    var body: some View {
        let hiddenSources = Set(hidden.split(separator: "\n").map(String.init))
        let sources = Set(items.map { $0.source ?? "/" }).sorted()
        content(items.filter { !hiddenSources.contains($0.source ?? "/") })
            .toolbar {
                if sources.count > 1 {
                    Menu {
                        ForEach(sources, id: \.self) { source in
                            Toggle(name(of: source), isOn: Binding(
                                get: { !hiddenSources.contains(source) },
                                set: { shown in
                                    hidden = (shown ? hiddenSources.subtracting([source]) : hiddenSources.union([source])).sorted().joined(separator: "\n")
                                }))
                        }
                    } label: {
                        Label("Sources", systemImage: "externaldrive.connected.to.line.below")
                    }
                    .help("Choose which drives and network shares this section shows")
                }
            }
    }

    /// "This Mac", "SSD", or "Media on dspeter" for a network share.
    private func name(of source: String) -> String {
        guard source != "/" else { return String(localized: "This Mac") }
        let host = library.folders.lazy
            .first { $0.path.hasPrefix("/Volumes/\(source)/") && $0.remountURL != nil }
            .flatMap { $0.remountURL.flatMap(URL.init(string:))?.host?.split(separator: ".").first }
        return host.map { String(localized: "\(source) on \(String($0))") } ?? source
    }
}

/// Sports, one tab per kind of sport ("Formula 1", "Football"…; the rest under Other).
struct SportsView: View {
    @Environment(Library.self) private var library
    @AppStorage("sportsTab") private var tab: String?

    var body: some View {
        let sports = library.index.sports
        Group {
            if sports.isEmpty {
                EmptyLibraryView(title: "No Sports", icon: "sportscourt")
            } else {
                SourceFiltered(section: "sports", items: sports) { shown in
                    let groups = Dictionary(grouping: shown) { LibraryIndex.sportCategory(of: $0) ?? "" }
                    // Named sports in order, then Other ("").
                    let names = groups.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                        + (groups[""] == nil ? [] : [""])
                    let selected = tab.flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? ""
                    ScrollView {
                        LazyVGrid(columns: videoGrid, spacing: 28) {
                            ForEach(groups[selected] ?? []) { MovieTile(movie: $0) }
                        }
                        .padding(28)
                    }
                    .toolbar {
                        if names.count > 1 {
                            Picker("Sport", selection: Binding(get: { selected }, set: { tab = $0 })) {
                                ForEach(names, id: \.self) { Text($0.isEmpty ? String(localized: "Other") : $0).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sports")
    }
}

/// Adult videos, as full videos or as clips (under 5 minutes).
struct AdultView: View {
    @Environment(Library.self) private var library
    @AppStorage("adultShowsClips") private var clips = false

    var body: some View {
        VideoGridView(title: "Adult", emptyTitle: clips ? "No Clips" : "No Full Videos", icon: "eye.slash", section: "adult",
                      videos: library.index.adult.filter { LibraryIndex.isClip($0) == clips })
            .toolbar {
                Picker("Length", selection: $clips) {
                    Text("Full Videos").tag(false)
                    Text("Clips").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Clips are shorter than 5 minutes")
            }
    }
}

/// A video's still (generated on first display), with a progress bar when partly watched.
struct VideoStill: View {
    let item: MediaItem
    var cornerRadius: CGFloat = 8
    /// An official still (TMDB) to show instead of a frame from the file.
    var still: URL?
    @Environment(Library.self) private var library
    @State private var stillKey: String?

    var body: some View {
        // Episodes show their own still; a poster chosen for them is the show's.
        let frame = ArtworkView(key: (item.kind == .episode ? nil : item.artworkKey) ?? stillKey, title: item.title, cornerRadius: cornerRadius, aspectRatio: 16 / 9)
        Group {
            if let still {
                AsyncImage(url: still) { image in
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { image.resizable().scaledToFill() }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                } placeholder: { frame }
            } else {
                frame
            }
        }
            .opacity(library.isAvailable(item) ? 1 : 0.4)
            .overlay {
                if !library.isAvailable(item) {
                    Label("Drive not connected", systemImage: "externaldrive.badge.xmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                }
            }
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

    /// Movies and documentaries open their page; other videos just play.
    var body: some View {
        Group {
            if movie.kind == .movie || movie.kind == .documentary, let id = movie.id {
                NavigationLink(value: MovieRef(id: id)) { label }
            } else {
                Button { player.play([movie], showVideo: true) } label: { label }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { VideoMenu(item: movie, queue: [movie]) }
    }

    private var label: some View {
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

    private var subtitle: String {
        if let saved = movie.id.flatMap({ library.positions[$0] }), saved.isResumable {
            return String(localized: "\(Format.duration(saved.remaining)) left")
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let start = queue.firstIndex(of: item) ?? 0
        Button("Play") { player.play(queue, startAt: start, showVideo: true) }
        if let saved = item.id.flatMap({ library.positions[$0] }), saved.isResumable {
            Button("Play from Beginning") { player.play(queue, startAt: start, fromBeginning: true, showVideo: true) }
        }
        if item.kind == .musicVideo {
            Button("Play as Song") { player.play(queue, startAt: start) }
        }
        Divider()
        if item.id.flatMap({ library.positions[$0] })?.isFinished == true {
            Button("Mark as Unwatched") { library.clearPosition(for: item) }
        } else {
            Button("Mark as Watched") { library.savePosition(item.duration, duration: item.duration, for: item) }
        }
        Divider()
        Button(library.isFavorite([item]) ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Love")) { library.toggleFavorite([item]) }
        Button("Get Info…") { openWindow(id: "info", value: [item.id].compactMap { $0 }) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        CategoryMenu(items: [item])
        FolderRuleMenu(items: [item])
    }
}

// MARK: TV shows

struct ShowsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shows = library.index.shows
        Group {
            if shows.isEmpty {
                EmptyLibraryView(title: "No TV Shows", icon: "tv")
            } else {
                SourceFiltered(section: "shows", items: shows.flatMap(\.episodes)) { shown in
                let shownPaths = Set(shown.map(\.path))
                ScrollView {
                    LazyVGrid(columns: videoGrid, spacing: 28) {
                        ForEach(shows.filter { $0.episodes.contains { shownPaths.contains($0.path) } }) { show in
                            NavigationLink(value: ShowRef(id: show.id)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ShowArtwork(show: show)
                                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(show.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        Text(seasonSummary(show)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Play") { player.play(show.episodes) }
                                Button("Get Info…") { openWindow(id: "info", value: show.episodes.compactMap(\.id)) }
                                Divider()
                                FolderRuleMenu(items: show.episodes)
                            }
                        }
                    }
                    .padding(28)
                }
                }
            }
        }
        .navigationTitle("TV Shows")
    }

    private func seasonSummary(_ show: Show) -> String {
        let seasons = show.seasons.count
        return seasons == 1 ? String(localized: "1 season · \(show.episodes.count) episodes") : String(localized: "\(seasons) seasons · \(show.episodes.count) episodes")
    }
}

/// A show's poster when one was chosen (Get Info), else its first episode's still.
struct ShowArtwork: View {
    let show: Show

    var body: some View {
        if let key = show.artworkKey {
            ArtworkView(key: key, title: show.title, aspectRatio: 16 / 9)
        } else {
            VideoStill(item: show.episodes[0])
        }
    }
}

/// A show's page, laid out like the streaming apps: a wide picture with Resume,
/// what it's about, the season's episodes with stills and summaries, and the
/// cast. Details come from TMDB when there's a key (Settings › Library).
struct ShowDetailView: View {
    let show: Show
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var season: Int?
    @State private var details: MediaDetails?
    @State private var seasonDetails: MediaDetails?

    var body: some View {
        let selectedSeason = season ?? nextUp?.season ?? show.seasons.first ?? 1
        let episodes = show.episodes.filter { $0.season == selectedSeason }
        let info = Dictionary((seasonDetails?.episodes ?? []).map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                VStack(alignment: .leading, spacing: 20) {
                    if let overview = details?.overview {
                        Text(overview).frame(maxWidth: 720, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if let makers = details?.makers, !makers.isEmpty {
                        Text("Created by " + makers.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Episodes").font(.title3.weight(.semibold))
                        Spacer()
                        if show.seasons.count > 1 {
                            Picker("Season", selection: Binding(get: { selectedSeason }, set: { season = $0 })) {
                                ForEach(show.seasons, id: \.self) { Text("Season \($0)").tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } else {
                            Text("Season \(selectedSeason)").foregroundStyle(.secondary)
                        }
                    }
                    LazyVStack(spacing: 4) {
                        ForEach(episodes) { episode in
                            EpisodeRow(episode: episode, info: episode.episode.flatMap { info[$0] }) { play(episode) }
                                .contextMenu { VideoMenu(item: episode, queue: show.episodes) }
                        }
                    }
                    if let cast = details?.cast, !cast.isEmpty { CastRow(cast: cast).padding(.top, 8) }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 28)
        }
        .navigationTitle(show.title)
        .task(id: show.id) { details = await library.details(for: show.episodes[0]) }
        .task(id: "\(show.id):\(selectedSeason)") {
            seasonDetails = nil
            seasonDetails = await library.details(of: show, season: selectedSeason)
        }
    }

    private var hero: some View {
        let still = VideoStill(item: show.episodes[0], cornerRadius: 0).aspectRatio(16 / 9, contentMode: .fill)
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let backdrop = details?.backdrop {
                    AsyncImage(url: backdrop) { image in image.resizable().scaledToFill() } placeholder: { still }
                } else {
                    still
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 8) {
                Text(details?.title ?? show.title).font(.system(size: 40, weight: .bold))
                Text(metadata).foregroundStyle(.secondary)
                if let next = nextUp {
                    HStack(spacing: 10) {
                        Button { play(next) } label: {
                            Label(resumeLabel(next), systemImage: "play.fill").frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        if let saved = next.id.flatMap({ library.positions[$0] }), saved.isResumable {
                            Text("\(Format.duration(saved.remaining)) left").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(28)
        }
    }

    /// "2018 · 2 of 5 seasons · 20 episodes · ★ 8.3 · Western, Drama"
    private var metadata: String {
        let seasons = details?.seasons.map { String(localized: "\(show.seasons.count) of \($0) seasons") } ?? String(localized: "\(show.seasons.count) seasons")
        return [details?.year.map(String.init), seasons, String(localized: "\(show.episodes.count) episodes"),
                details?.rating.map { String(format: "★ %.1f", $0) }, details?.genres.prefix(3).joined(separator: ", ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func play(_ episode: MediaItem) {
        player.play(show.episodes, startAt: show.episodes.firstIndex(of: episode) ?? 0)
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
        return resuming ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
    }
}

/// An episode in a show's list: still, number and title, length or time left, and summary.
struct EpisodeRow: View {
    let episode: MediaItem
    /// TMDB's title, summary and still for it, when known.
    var info: MediaDetails.Episode?
    let play: () -> Void
    @Environment(Library.self) private var library
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 16) {
                VideoStill(item: episode, cornerRadius: 6, still: info?.still)
                    .frame(width: 220)
                    .overlay {
                        if hovering {
                            Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white).shadow(radius: 6)
                        }
                    }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(heading).font(.headline).lineLimit(1)
                        Spacer()
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if let overview = info?.overview {
                        Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(.top, 4)
            }
            .padding(10)
            .background(.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// "3. Title": the file's title, or TMDB's when the file only says "Episode 3".
    private var heading: String {
        let number = episode.episode ?? 0
        let name = episode.title == "Episode \(number)" ? info?.title : episode.title
        return name.map { "\(number). \($0)" } ?? String(localized: "Episode \(number)")
    }

    private var detail: String {
        if let saved = episode.id.flatMap({ library.positions[$0] }), saved.isResumable {
            return String(localized: "\(Format.duration(saved.remaining)) left")
        }
        return info?.runtimeMinutes.map { Format.duration(Double($0 * 60)) } ?? Format.duration(episode.duration)
    }
}
