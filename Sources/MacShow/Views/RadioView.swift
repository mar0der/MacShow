import MacShowCore
import SwiftUI

/// Radio from around the world (Radio Browser's free directory): your favorites
/// and recent stations, the most played, by country, by genre, or by name.
struct RadioView: View {
    enum Tab: String, CaseIterable {
        case favorites, recent, popular, countries, genres
        var title: LocalizedStringKey {
            switch self {
            case .favorites: "Favorites"
            case .recent: "Recent"
            case .popular: "Popular"
            case .countries: "Countries"
            case .genres: "Genres"
            }
        }
    }

    @Environment(Radio.self) private var radio
    @AppStorage("radioTab") private var tab: Tab = .popular
    @AppStorage("radioCountry") private var country = Locale.current.region?.identifier ?? "BG"
    @AppStorage("radioGenre") private var genre = "pop"
    /// What's typed, and what's searched: the same, a moment after typing stops.
    @State private var search = ""
    @State private var query = ""
    @State private var found: [String: [RadioStation]] = [:]
    @State private var countries: [RadioCountry] = []
    private let directory = RadioDirectory()

    var body: some View {
        let words = query
        // The tabs and search sit in the page, not the window toolbar: toolbar
        // items are rebuilt as the page changes, and the field lost its focus.
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!words.isEmpty)
                Spacer()
                TextField("Search Stations", text: $search, prompt: Text("Search stations"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            content(words)
        }
        .navigationTitle("Radio")
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { query = search.trimmingCharacters(in: .whitespaces) }
        }
    }

    @ViewBuilder
    private func content(_ words: String) -> some View {
        Group {
            if !words.isEmpty {
                stations("search:" + words) { await directory.search(words) }
            } else {
                switch tab {
                case .favorites:
                    StationGrid(stations: radio.favorites, empty: "Right-click a station to add it to your favorites.")
                case .recent:
                    StationGrid(stations: radio.recents, empty: "Stations you play show up here.")
                case .popular:
                    stations("popular") { await directory.popular() }
                case .countries:
                    HStack(spacing: 0) {
                        List(countries, selection: Binding(get: { country }, set: { if let code = $0 { country = code } })) { place in
                            HStack {
                                Text(place.flag)
                                Text(place.name).lineLimit(1)
                                Spacer()
                                Text("\(place.stations)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .tag(place.code)
                        }
                        .frame(width: 250)
                        Divider()
                        stations("country:" + country) { await directory.stations(country: country) }
                    }
                    .task { if countries.isEmpty { countries = await directory.countries() } }
                case .genres:
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(RadioDirectory.genres, id: \.self) { name in
                                    Button(name == "r&b" ? "R&B" : name.capitalized) { genre = name }
                                        .buttonStyle(.bordered)
                                        .tint(name == genre ? .accentColor : nil)
                                }
                            }
                            .padding(.horizontal, 28).padding(.vertical, 12)
                        }
                        stations("genre:" + genre) { await directory.stations(genre: genre) }
                    }
                }
            }
        }
    }

    /// Stations fetched once per `key` (kept while the tab is open).
    private func stations(_ key: String, fetch: @escaping () async -> [RadioStation]) -> some View {
        Group {
            if let list = found[key] {
                StationGrid(stations: list, empty: "No stations found. The radio directory may be unreachable.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            if found[key] == nil { found[key] = await fetch() }
        }
    }
}

/// A grid of station tiles; clicking one plays it (Next and Previous go through the rest).
private struct StationGrid: View {
    let stations: [RadioStation]
    let empty: LocalizedStringKey
    private let grid = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22)]

    var body: some View {
        if stations.isEmpty {
            ContentUnavailableView { Label("No Stations", systemImage: "radio") } description: { Text(empty) }
        } else {
            ScrollView {
                LazyVGrid(columns: grid, spacing: 24) {
                    ForEach(stations) { StationTile(station: $0, stations: stations) }
                }
                .padding(28)
            }
        }
    }
}

private struct StationTile: View {
    let station: RadioStation
    let stations: [RadioStation]
    @Environment(Radio.self) private var radio
    @Environment(Player.self) private var player

    var body: some View {
        let playing = player.radioStation == station
        Button { player.playRadio(station, in: stations) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08))
                    AsyncImage(url: station.logo) { image in image.resizable().scaledToFit().padding(18) } placeholder: {
                        Image(systemName: "radio").font(.system(size: 40)).foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(playing ? Color.accentColor : .clear, lineWidth: 3))
                .overlay(alignment: .topTrailing) {
                    if radio.isFavorite(station) { Image(systemName: "heart.fill").foregroundStyle(.pink).padding(8) }
                }
                .overlay(alignment: .bottomLeading) {
                    if playing {
                        Image(systemName: player.isPaused ? "pause.fill" : "speaker.wave.2.fill")
                            .padding(6).background(.black.opacity(0.6), in: Circle()).padding(8)
                    }
                }
                Text(station.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text([station.flag, station.details].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(playing ? (player.streamTitle ?? station.name) : station.name)
        .contextMenu {
            Button("Play") { player.playRadio(station, in: stations) }
            Button(radio.isFavorite(station) ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites")) {
                radio.toggleFavorite(station)
            }
            if let homepage = station.homepage {
                Button("Open Website") { NSWorkspace.shared.open(homepage) }
            }
        }
    }
}
