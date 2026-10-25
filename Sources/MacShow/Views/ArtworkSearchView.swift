import MacShowCore
import SwiftUI

/// Find Artwork Online: covers and posters to pick from (only the search words are sent).
struct ArtworkSearchView: View {
    let kind: ArtworkFetcher.SearchKind
    @State var term: String
    let choose: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [ArtworkSuggestion] = []
    @State private var searching = false
    @State private var downloading: ArtworkSuggestion?
    private let fetcher = ArtworkFetcher(tmdbKey: UserDefaults.standard.string(forKey: ArtworkFetcher.tmdbKeyDefault))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search", text: $term).onSubmit(search)
                Button("Search", action: search).disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                if results.isEmpty {
                    Text(searching ? "Searching…" : "Nothing found. Try other words.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(results) { suggestion in
                            Button { pick(suggestion) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AsyncImage(url: suggestion.thumbnail) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        Color.primary.opacity(0.06)
                                    }
                                    .frame(height: 100)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay { if downloading == suggestion { ProgressView() } }
                                    Text(suggestion.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(suggestion.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(downloading != nil)
                        }
                    }
                    .padding(2)
                }
            }
            HStack {
                Text(kind == .artist ? "From Deezer." : "From TMDB, Deezer, the iTunes Store and Wikipedia.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 420)
        .onAppear(perform: search)
    }

    private func search() {
        let words = term.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        searching = true
        Task {
            results = await fetcher.suggestions(for: words, kind: kind)
            searching = false
        }
    }

    private func pick(_ suggestion: ArtworkSuggestion) {
        downloading = suggestion
        Task {
            if let data = await fetcher.image(suggestion) {
                choose(data)
                dismiss()
            }
            downloading = nil
        }
    }
}
