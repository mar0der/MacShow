import MacShowCore
import SwiftUI

/// An actor's or director's page, from TMDB: photo, birth, biography, what of
/// theirs is in your library, and what they're best known for.
struct PersonView: View {
    let ref: PersonRef
    @Environment(Library.self) private var library
    @State private var profile: PersonProfile?
    @State private var bioExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 28) {
                    AsyncImage(url: profile?.photo) { image in image.resizable().scaledToFill() } placeholder: {
                        ArtworkView(key: nil, title: ref.name, cornerRadius: 12)
                    }
                    .frame(width: 220, height: 330)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile?.name ?? ref.name).font(.system(size: 34, weight: .bold))
                        if let line = lifeLine { Text(line).foregroundStyle(.secondary) }
                        if let biography = profile?.biography {
                            Text(biography).lineLimit(bioExpanded ? nil : 8)
                                .frame(maxWidth: 720, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                            Button(bioExpanded ? LocalizedStringKey("Less") : LocalizedStringKey("More")) { bioExpanded.toggle() }.buttonStyle(.link)
                        }
                        if profile != nil { Text("From TMDB").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
                .padding(.horizontal, 28)

                if let profile {
                    let owned = library.titles(in: profile)
                    if !owned.movies.isEmpty || !owned.shows.isEmpty {
                        Shelf(title: "In Your Library") {
                            ForEach(owned.movies) { MovieTile(movie: $0).frame(width: 240) }
                            ForEach(owned.shows) { show in
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
                    if !profile.credits.isEmpty {
                        Shelf(title: "Known For") {
                            ForEach(profile.credits.prefix(20), id: \.self) { CreditTile(credit: $0) }
                        }
                    }
                }
            }
            .padding(.vertical, 28)
        }
        .navigationTitle(profile?.name ?? ref.name)
        .task(id: ref.id) { profile = await library.profile(ofPerson: ref.id) }
    }

    /// "Acting · Born April 4, 1965 in New York City"
    private var lifeLine: String? {
        guard let profile else { return nil }
        func date(_ text: String?) -> String? {
            text.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) }?.formatted(date: .long, time: .omitted)
        }
        var born = date(profile.birthday).map { String(localized: "Born \($0)") }
        if let born1 = born, let place = profile.placeOfBirth { born = String(localized: "\(born1) in \(place)") }
        let died = date(profile.deathday).map { String(localized: "Died \($0)") }
        let parts = [profile.knownFor, born, died].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A poster from someone's filmography, with year and role.
private struct CreditTile: View {
    let credit: PersonProfile.Credit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: credit.poster) { image in image.resizable().scaledToFill() } placeholder: {
                ArtworkView(key: nil, title: credit.title, cornerRadius: 8)
            }
            .frame(width: 140, height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(credit.title).font(.callout.weight(.semibold)).lineLimit(1)
            Text([credit.year.map(String.init), credit.role].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 140)
    }
}
