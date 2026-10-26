import MacShowCore
import SwiftUI

/// Old videos worth converting to HEVC, movies in parts to join, and the conversion queue.
struct ModernizeSettings: View {
    @Environment(Library.self) private var library
    @Environment(Modernizer.self) private var modernizer
    @State private var candidates: [Modernize.Candidate] = []
    @State private var keptSize: Int64 = 0
    @State private var confirmingRemoval = false

    var body: some View {
        @Bindable var modernizer = modernizer
        let waiting = candidates.filter { !modernizer.isQueued($0) && modernizer.isOffered($0) }
        Form {
            if let current = modernizer.current {
                Section("Converting") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.title).lineLimit(1)
                        ProgressView(value: modernizer.progress)
                        HStack {
                            if modernizer.isSaving {
                                Text("Saving next to the original…")
                            } else if let reason = modernizer.waitingReason {
                                Text(reason)
                            } else if let remaining = modernizer.remaining {
                                Text("\(Int(modernizer.progress * 100))% · about \(Self.time(remaining)) left")
                            }
                            Spacer()
                            Button(modernizer.isPausedByUser ? "Resume" : "Pause") { modernizer.isPausedByUser.toggle() }
                            Button("Cancel") { modernizer.cancelCurrent() }
                        }
                        .font(.caption).foregroundStyle(.secondary).controlSize(.small)
                    }
                    ForEach(modernizer.queue) { candidate in
                        HStack {
                            Text(candidate.title).lineLimit(1)
                            Spacer()
                            Text("Next, about \(Self.time(modernizer.estimate(candidate)))").font(.caption).foregroundStyle(.secondary)
                            Button { modernizer.remove(candidate) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Don't convert")
                        }
                    }
                }
            }

            Section {
                if waiting.isEmpty {
                    Label("Nothing to convert. Your videos are in modern formats.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(waiting) { candidate in
                    row(candidate)
                }
                if waiting.count > 1 {
                    Button("Convert All") { Task { await modernizer.convert(waiting) } }
                }
            } header: {
                let saving = waiting.reduce(0) { $0 + $1.size - $1.estimatedSize }
                Text("Worth Converting (\(waiting.count))") + Text(saving > 0 ? String(localized: " · saves about \(Self.bytes(saving))") : "")
            } footer: {
                Text("Old formats (DivX, XviD, Windows Media, MPEG-2, DV…) become HEVC, which keeps about the same picture in half the space or less and plays on every Apple device. Movies split into parts (CD1, CD2) become one file. Converting happens on this Mac with its hardware encoder; files on a network share are read over the network and the new file is written back, so the connection sets the pace, and it waits while you watch something from the same server. Converting on the server itself would need a MacShow helper running there, which doesn't exist yet.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !modernizer.keptOriginals.isEmpty {
                Section {
                    HStack {
                        let count = modernizer.keptOriginals.count
                        Text(count == 1 ? "1 file, \(Self.bytes(keptSize))" : "\(count) files, \(Self.bytes(keptSize))")
                        Spacer()
                        Button("Remove Originals…") { confirmingRemoval = true }
                    }
                } header: {
                    Text("Originals Kept")
                } footer: {
                    Text("The converted videos replaced these in the library: your resume points, favorites, play counts, playlists and edits moved over. Check a few of the new files, then remove the originals to free the space.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: library.index.itemsByID.count) { candidates = library.modernizeCandidates }
        .task(id: modernizer.keptOriginals) {
            let paths = modernizer.keptOriginals
            keptSize = await Task.detached { Modernizer.size(of: paths) }.value
        }
        .confirmationDialog("Remove \(modernizer.keptOriginals.count) original files?", isPresented: $confirmingRemoval) {
            Button("Remove Originals", role: .destructive) { _ = modernizer.removeOriginals() }
        } message: {
            Text("They go to the Trash. On a network share that has no Trash, they're deleted for good.")
        }
    }

    private func row(_ candidate: Modernize.Candidate) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).lineLimit(1)
                Text(Self.summary(candidate) + String(localized: " · about \(Self.time(modernizer.estimate(candidate)))"))
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = modernizer.failures[candidate.id] {
                    Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Convert") { Task { await modernizer.convert([candidate]) } }
                .controlSize(.small)
        }
    }

    /// "DivX 3 · 700 MB → about 350 MB", "Joins 2 parts · …".
    static func summary(_ candidate: Modernize.Candidate) -> String {
        let sizes = "\(bytes(candidate.size)) → \(bytes(candidate.estimatedSize))"
        return candidate.joinsParts
            ? String(localized: "Joins \(candidate.items.count) parts · \(candidate.codec) · \(sizes)")
            : "\(candidate.codec) · \(sizes)"
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func time(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 60)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// On a movie's page: an old format or a movie in parts, and a button to convert it.
struct ModernizeOffer: View {
    let movie: MediaItem
    @Environment(Library.self) private var library
    @Environment(Modernizer.self) private var modernizer

    var body: some View {
        let folder = movie.url.deletingLastPathComponent().path
        let neighbours = (library.index.movies + library.index.documentaries + library.index.sports + library.index.homeVideos).filter { $0.url.deletingLastPathComponent().path == folder }
        if let candidate = Modernize.candidates(in: neighbours).first(where: { $0.items.contains { $0.path == movie.path } }), modernizer.isOffered(candidate) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Label(candidate.joinsParts ? "In \(candidate.items.count) parts" : "Old format", systemImage: "wand.and.stars")
                    Text(ModernizeSettings.summary(candidate)).foregroundStyle(.secondary)
                    if modernizer.current?.id == candidate.id {
                        ProgressView(value: modernizer.progress).frame(width: 80)
                    } else if modernizer.isQueued(candidate) {
                        Text("Queued").foregroundStyle(.secondary)
                    } else {
                        Button(candidate.joinsParts ? "Join and Convert" : "Convert") { Task { await modernizer.convert([candidate]) } }
                            .controlSize(.small)
                    }
                }
                if let failure = modernizer.failures[candidate.id] {
                    Text(failure).foregroundStyle(.red).frame(maxWidth: 720, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
    }
}
