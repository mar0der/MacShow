import MacShowCore
import SwiftUI

struct AlbumsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let albums = library.index.albums
        Group {
            if albums.isEmpty {
                EmptyLibraryView(title: "No Albums", icon: "square.stack")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)], spacing: 28) {
                        ForEach(albums) { AlbumTile(album: $0) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle("Albums")
    }
}

struct AlbumTile: View {
    let album: Album
    @Environment(Player.self) private var player

    var body: some View {
        NavigationLink(value: album) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(key: album.artworkKey, title: album.title)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .overlay(alignment: .topTrailing) {
                        if let badge = album.tracks.first.map(\.formatInfo).flatMap(Self.badge) {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { player.play(album.tracks) }
        }
    }

    /// "FLAC · 96 kHz" → "FLAC 96 kHz"; plain 44.1/48 kHz show just the codec.
    static func badge(_ formatInfo: String) -> String? {
        let parts = formatInfo.components(separatedBy: " · ")
        guard let codec = parts.first, !codec.isEmpty else { return nil }
        if let rate = parts.last, rate != codec, let kHz = Double(rate.replacingOccurrences(of: " kHz", with: "")), kHz > 48 {
            return "\(codec) \(rate)"
        }
        return codec
    }
}

struct AlbumDetailView: View {
    let album: Album
    @Environment(Player.self) private var player

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    ArtworkView(key: album.artworkKey, title: album.title, cornerRadius: 10)
                        .frame(width: 220)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.largeTitle.weight(.bold)).lineLimit(2)
                        Text(album.artist).font(.title3).foregroundStyle(.secondary)
                        Text([album.year.map(String.init), "\(album.tracks.count) songs", Format.duration(album.duration)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button { player.play(album.tracks) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 8)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { offset, track in
                        TrackRow(track: track, number: track.trackNumber, isCurrent: player.currentItem?.id == track.id) {
                            player.play(album.tracks, startAt: offset)
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(album.title)
    }
}

/// One song in a list; double-click or Return plays it.
struct TrackRow: View {
    let track: MediaItem
    var number: Int?
    var showsArtist = false
    let isCurrent: Bool
    let play: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                } else {
                    Text(number.map(String.init) ?? "").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if showsArtist, let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if track.isProtected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Copy-protected: plays only in the app it was bought from")
            }
            Text(Format.time(track.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(isCurrent ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        .opacity(track.isProtected ? 0.5 : 1)
    }
}
