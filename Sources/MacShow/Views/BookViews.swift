import MacShowCore
import SwiftUI

struct BooksView: View {
    enum Order: String, CaseIterable {
        case title = "Title", author = "Author", recent = "Recently Played"
    }

    @Environment(Library.self) private var library
    @AppStorage("bookOrder") private var order: Order = .title
    private let grid = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)]

    var body: some View {
        let books = library.index.books
        Group {
            if books.isEmpty {
                EmptyLibraryView(title: "No Audiobooks", icon: "book")
            } else {
                ScrollView {
                    if order == .author {
                        LazyVStack(alignment: .leading, spacing: 32) {
                            ForEach(Book.byAuthor(books), id: \.author) { group in
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(group.author ?? "Unknown Author").font(.title3.weight(.semibold))
                                    LazyVGrid(columns: grid, spacing: 28) {
                                        ForEach(group.books) { BookTile(book: $0) }
                                    }
                                }
                            }
                        }
                        .padding(28)
                    } else {
                        LazyVGrid(columns: grid, spacing: 28) {
                            ForEach(order == .recent ? recentFirst(books) : books) { BookTile(book: $0) }
                        }
                        .padding(28)
                    }
                }
            }
        }
        .navigationTitle("Audiobooks")
        .toolbar {
            if !books.isEmpty {
                Picker("Sort By", selection: $order) {
                    ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Sort audiobooks")
            }
        }
    }

    /// Most recently listened first; books not started after, by title.
    private func recentFirst(_ books: [Book]) -> [Book] {
        let played = books.map { ($0, library.progress(of: $0).lastListened) }
        return played.filter { $0.1 != nil }.sorted { $0.1! > $1.1! }.map(\.0) + played.filter { $0.1 == nil }.map(\.0)
    }
}

struct BookTile: View {
    let book: Book
    @Environment(Library.self) private var library

    var body: some View {
        let progress = library.progress(of: book)
        NavigationLink(value: BookRef(id: book.id)) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(key: book.artworkKey, title: book.title)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .overlay(alignment: .bottom) {
                        if progress.isStarted, !progress.isFinished { ProgressBar(progress: progress.fraction).padding(10) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle(progress)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ progress: BookProgress) -> String {
        if progress.isFinished { return [book.author, "Finished"].compactMap { $0 }.joined(separator: " · ") }
        if progress.isStarted { return "\(Format.duration(progress.remaining)) left" }
        return [book.author, Format.duration(book.duration)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One entry in a book's chapter list: a chapter inside a file, or a whole file of a folder book.
private struct BookChapter: Identifiable {
    let id: Int
    let title: String
    let partIndex: Int
    let start: Double
    let duration: Double
}

struct BookDetailView: View {
    let book: Book
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var fileChapters: [FileMetadata.Chapter] = []
    @State private var showsBookmarks = false
    @State private var info: MediaDetails?

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private static let sleepMinutes = [5, 10, 15, 30, 45, 60]

    var body: some View {
        let progress = library.progress(of: book)
        let chapters = self.chapters
        let current = currentChapter(in: chapters, progress: progress)
        HStack(alignment: .top, spacing: 48) {
            nowListening(progress: progress, chapter: current.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil })
                .frame(width: 320)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $showsBookmarks) {
                        Text("Chapters").tag(false)
                        Text("Bookmarks · \(bookmarks.count)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Text("\(chapters.count) chapters · \(Format.duration(book.duration))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if showsBookmarks {
                            bookmarkList
                        } else {
                            ForEach(chapters) { chapter in
                                chapterRow(chapter, isCurrent: chapter.id == current, isDone: current.map { chapter.id < $0 } ?? false)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 32)
        .navigationTitle(book.title)
        .task(id: book.id) { info = await library.details(of: book) }
        .task(id: book.id) {
            guard book.parts.count == 1, let url = book.parts.first?.url else { return }
            fileChapters = await Task.detached { MetadataReader.read(url)?.chapters ?? [] }.value
        }
    }

    // MARK: Left column

    /// Which of this book's files is playing, by identity, not by queue
    /// position (the book may sit behind songs in the queue).
    private var playingPart: Int? {
        player.currentItem.flatMap { current in book.parts.firstIndex { $0.id == current.id } }
    }

    private var isPlayingThis: Bool { playingPart != nil }

    @ViewBuilder
    private func nowListening(progress: BookProgress, chapter: BookChapter?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ArtworkView(key: book.artworkKey, title: book.title, cornerRadius: 10)
                .frame(width: 300)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.title.weight(.bold)).lineLimit(2)
                if let author = book.author { Text(author).font(.title3).foregroundStyle(.secondary) }
                if let year = info?.year { Text(String(year)).font(.callout).foregroundStyle(.secondary) }
            }
            if let description = info?.overview {
                Text(description).font(.callout).lineLimit(6).help(description)
            }
            HStack(spacing: 8) {
                if let badge = book.parts.first.map({ $0.url.pathExtension.uppercased() }) { FormatBadge(text: badge) }
                Text(progressText(progress)).font(.callout).foregroundStyle(.secondary)
            }

            if isPlayingThis, let chapter {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chapter.title).font(.callout.weight(.semibold)).lineLimit(1)
                    let inChapter = player.position - chapter.start
                    Slider(value: Binding(get: { min(max(inChapter, 0), chapter.duration) }, set: { player.seek(to: chapter.start + $0) }),
                           in: 0...max(chapter.duration, 1))
                        .controlSize(.small)
                    HStack {
                        Text(Format.time(inChapter))
                        Spacer()
                        Text("-" + Format.time(chapter.duration - inChapter))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                BookTransportControls(large: true).frame(maxWidth: .infinity)
            } else {
                Button { player.play(book.parts, startAt: progress.partIndex) } label: {
                    Label(progress.isStarted && !progress.isFinished ? "Resume" : "Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                speedMenu
                sleepMenu
                Button { bookmarkHere() } label: { Label("Bookmark", systemImage: "bookmark") }
                    .disabled(!isPlayingThis)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var speedMenu: some View {
        let saved = UserDefaults.standard.double(forKey: Player.audiobookSpeedKey)
        let current = isPlayingThis ? player.speed : (saved > 0 ? saved : 1)
        return Menu {
            ForEach(Self.speeds, id: \.self) { speed in
                Toggle(speed.formatted() + "×", isOn: Binding(get: { current == speed }, set: { _ in
                    if isPlayingThis { player.setSpeed(speed) } else { UserDefaults.standard.set(speed, forKey: Player.audiobookSpeedKey) }
                }))
            }
        } label: {
            Text(current.formatted() + "×").monospacedDigit()
        }
        .fixedSize()
        .help("Playback Speed")
    }

    private var sleepMenu: some View {
        Menu {
            Toggle("Off", isOn: Binding(get: { player.sleepTimer == .off }, set: { _ in player.sleepTimer = .off }))
            ForEach(Self.sleepMinutes, id: \.self) { minutes in
                Button("\(minutes) Minutes") { player.sleepTimer = .at(Date(timeIntervalSinceNow: Double(minutes) * 60)) }
            }
            Toggle("End of Chapter", isOn: Binding(get: { player.sleepTimer == .endOfChapter }, set: { _ in player.sleepTimer = .endOfChapter }))
        } label: {
            Label(sleepLabel, systemImage: "moon")
        }
        .fixedSize()
        .disabled(!isPlayingThis)
        .help("Sleep Timer")
    }

    private var sleepLabel: String {
        switch player.sleepTimer {
        case .off: "Sleep"
        case .endOfChapter, .endOfItem: "End of Chapter"
        case .at(let date): "\(max(Int(date.timeIntervalSinceNow / 60), 1)) min"
        }
    }

    private func progressText(_ progress: BookProgress) -> String {
        if progress.isFinished { return "Finished" }
        if progress.isStarted { return "\(Int(progress.fraction * 100))% · \(Format.duration(progress.remaining)) left" }
        return Format.duration(book.duration)
    }

    private func bookmarkHere() {
        guard let item = player.currentItem else { return }
        library.addBookmark(at: player.position, in: item)
        showsBookmarks = true
    }

    // MARK: Chapters

    private var chapters: [BookChapter] {
        if book.parts.count == 1, let part = book.parts.first, !fileChapters.isEmpty {
            return fileChapters.enumerated().map { index, chapter in
                let end = index + 1 < fileChapters.count ? fileChapters[index + 1].start : part.duration
                return BookChapter(id: index, title: chapter.title, partIndex: 0, start: chapter.start, duration: end - chapter.start)
            }
        }
        return book.parts.enumerated().map { index, part in
            BookChapter(id: index, title: part.title, partIndex: index, start: 0, duration: part.duration)
        }
    }

    /// The chapter playing now, or where the book will resume.
    private func currentChapter(in chapters: [BookChapter], progress: BookProgress) -> Int? {
        guard progress.isStarted || isPlayingThis else { return nil }
        if book.parts.count == 1, !fileChapters.isEmpty {
            let position = isPlayingThis ? player.position : progress.elapsed
            return chapters.lastIndex { $0.start <= position + 0.5 }
        }
        return playingPart ?? progress.partIndex
    }

    private func chapterRow(_ chapter: BookChapter, isCurrent: Bool, isDone: Bool) -> some View {
        HStack(spacing: 14) {
            Text("\(chapter.id + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            Text(chapter.title).fontWeight(isCurrent ? .semibold : .regular).foregroundStyle(isDone ? .secondary : .primary).lineLimit(1)
            Spacer()
            if isCurrent, isPlayingThis {
                Text("\(Format.time(player.position - chapter.start)) of \(Format.time(chapter.duration))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
            } else if isDone {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
            Text(Format.time(chapter.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(isCurrent ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(chapter.partIndex, at: chapter.start) }
        .contextMenu { Button("Play from Here") { play(chapter.partIndex, at: chapter.start) } }
    }

    private func play(_ partIndex: Int, at time: Double) {
        if playingPart == partIndex {
            player.seek(to: time)
            if player.isPaused { player.togglePause() }
        } else {
            player.play(book.parts, startAt: partIndex, at: time)
        }
    }

    // MARK: Bookmarks

    private var bookmarks: [Bookmark] {
        let ids = Set(book.parts.compactMap(\.id))
        return library.bookmarks.filter { ids.contains($0.mediaItemId) }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if bookmarks.isEmpty {
            Text("While listening, click Bookmark to save your place.")
                .foregroundStyle(.secondary).padding(.top, 20)
        }
        ForEach(bookmarks) { bookmark in
            let partIndex = book.parts.firstIndex { $0.id == bookmark.mediaItemId } ?? 0
            HStack(spacing: 14) {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmarkTitle(bookmark, partIndex: partIndex)).lineLimit(1)
                    Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.time(bookmark.position)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { play(partIndex, at: bookmark.position) }
            .contextMenu {
                Button("Play from Here") { play(partIndex, at: bookmark.position) }
                Button("Delete Bookmark", role: .destructive) { library.deleteBookmark(bookmark) }
            }
        }
    }

    private func bookmarkTitle(_ bookmark: Bookmark, partIndex: Int) -> String {
        if book.parts.count == 1, let chapter = fileChapters.last(where: { $0.start <= bookmark.position }) {
            return chapter.title
        }
        return book.parts[partIndex].title
    }
}
