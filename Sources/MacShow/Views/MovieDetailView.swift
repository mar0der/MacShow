import MacShowCore
import SwiftUI

/// A movie's page: a wide picture, what it's about, who's in it, and Play.
/// Details come from TMDB when there's a key (Settings › Library), else the
/// page shows what the file says.
struct MovieDetailView: View {
    let movie: MediaItem
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var details: MediaDetails?

    var body: some View {
        let saved = movie.id.flatMap { library.positions[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero(saved: saved)
                VStack(alignment: .leading, spacing: 24) {
                    if let overview = details?.overview {
                        Text(overview).font(.body).frame(maxWidth: 720, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if let makers = details?.makers, !makers.isEmpty {
                        Text("Directed by " + makers.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    if let cast = details?.cast, !cast.isEmpty { CastRow(cast: cast) }
                    Text([movie.formatInfo, movie.url.lastPathComponent].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 28)
        }
        .navigationTitle(movie.title)
        .contextMenu { VideoMenu(item: movie, queue: [movie]) }
        .task(id: movie.id) { details = await library.details(for: movie) }
    }

    private func hero(saved: PlaybackPosition?) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backdrop = details?.backdrop {
                    AsyncImage(url: backdrop) { image in image.resizable().scaledToFill() } placeholder: { VideoStill(item: movie, cornerRadius: 0) }
                } else {
                    VideoStill(item: movie, cornerRadius: 0)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 8) {
                Text(details?.title ?? movie.title).font(.system(size: 40, weight: .bold))
                Text(metadata).foregroundStyle(.secondary)
                if let tagline = details?.tagline { Text(tagline).italic().foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    Button { player.play([movie], showVideo: true) } label: {
                        Label(saved?.isResumable == true ? LocalizedStringKey("Resume") : LocalizedStringKey("Play"), systemImage: "play.fill").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let saved, saved.isResumable {
                        Button("Play from Beginning") { player.play([movie], fromBeginning: true, showVideo: true) }
                            .controlSize(.large)
                        Text("\(Format.duration(saved.remaining)) left").foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .padding(28)
        }
    }

    /// "2008 · 2h 6m · ★ 7.7 · Action, Science Fiction"
    private var metadata: String {
        let runtime = details?.runtimeMinutes.map { Format.duration(Double($0 * 60)) } ?? Format.duration(movie.duration)
        return [(details?.year ?? movie.year).map(String.init), runtime, details?.rating.map { String(format: "★ %.1f", $0) },
                details?.genres.prefix(3).joined(separator: ", ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The people in a movie or show: photo, name and role.
struct CastRow: View {
    let cast: [MediaDetails.Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast").font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(cast, id: \.self) { person in
                        VStack(spacing: 6) {
                            AsyncImage(url: person.photo) { image in image.resizable().scaledToFill() } placeholder: {
                                ArtworkView(key: nil, title: person.name, cornerRadius: 100)
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(Circle())
                            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let role = person.role { Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(width: 100)
                    }
                }
            }
        }
    }
}
