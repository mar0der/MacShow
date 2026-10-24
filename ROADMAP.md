# MacShow Roadmap

MacShow is one Mac app for the media you own: music, video and audiobooks. It
replaces Music, TV and Books for files on your disk, plays every common format,
and never asks you to prove you bought something. If a file isn't copy-protected,
it plays.

## Principles

- **Your files are the source of truth.** The library is an index over folders you
  choose. MacShow never moves, renames or rewrites your files.
- **Everything plays.** One engine ([libmpv](https://mpv.io) via
  [MPVKit](https://github.com/mpvkit/MPVKit)) for audio and video: MP3, AAC, ALAC,
  FLAC, Opus, WAV, DSD, MKV, MP4, AVI, HEVC, AV1, subtitles, chapters.
- **Feels native.** SwiftUI, the macOS dark look from the
  [design canvas](https://claude.ai/artifact/8cPJPydHhuWA93o4L6z94K) (private until shared),
  media keys, Now Playing, AirPlay.
- **Open source.** The app is MIT-licensed. It uses the LGPL build of libmpv and
  FFmpeg, linked statically; because MacShow's own source is public, anyone can
  rebuild it against modified versions of them, as the LGPL requires.

## Phases

Each phase ends with a check that proves it works on real files.

### Phase 0: Engine shell (done)

A window that opens a file and plays it with basic controls.
Done when it plays an MKV, a FLAC and an M4B. Verified on an HEVC/AC-3 MKV, a
24-bit/96 kHz FLAC and a chaptered M4B.

### Phase 1: Library foundation (done)

- Watched folders, the scanner and the database (see [Library](#library)).
- Home screen and a plain Albums / Movies / Books list, enough to browse and play.
- Real, sandboxed app bundle (built by a script) so it launches like any Mac app.

Done when pointing it at `~/Music` lists every album with its cover art, and a
file copied into a watched folder shows up within seconds without a restart.

### Phase 2: Music (done)

- Albums, Artists, Songs and Playlists screens from the design.
- Play queue, shuffle, repeat, gapless playback, ReplayGain.
- Media keys, Now Playing in Control Center, the mini player window.

Done when an album plays start to finish with no gaps and the keyboard's media
keys control it while another app is in front.

### Phase 3: Video (done)

- Movies and TV Shows, with episodes grouped from file names (`Show S01E02`).
- Resume where you stopped; "Jump back in" on Home.
- Subtitle and audio-track menus, external subtitle files, full screen.
- Picture in Picture last (not done yet): Apple's PiP only supports its own
  player, so this needs extra work, and differs between the two builds (see
  [Distribution](#distribution)).

Done when a season folder shows up as one show in episode order and each
episode resumes at the right spot.

### Phase 4: Audiobooks (done)

- Books from single M4B/M4A files with chapters, or from a folder of MP3s
  (one book, files in order).
- Chapter list, speed (0.5×–3×), sleep timer (minutes or end of chapter),
  bookmarks, 15 s back / 30 s forward.
- Position saved continuously, per book.

Done when a book resumes at the right chapter and second after quitting the app,
and a folder of numbered MP3s plays as one book.

### Phase 5: Purchases and import polish (done)

- Music app Media folder watched by default (see [Purchases](#purchases-from-apple)).
- External drives: remember their folders, grey items out when the drive is
  unplugged, bring them back when it's plugged in.
- Duplicate detection (same track in two folders).

Done when an album downloaded in the Music app appears in MacShow on its own.

### Phase 6: Ship (partly done)

Done: app icon, "Open With" for audio and video, the licenses screen
(Settings › About) and `scripts/make-dmg.sh`. Signing, notarization, Sparkle and
the Homebrew cask need a Developer ID; [RELEASING.md](RELEASING.md) has the steps.

The direct download first (see [Distribution](#distribution)):

- Developer ID signing, notarization, a DMG, auto-update (Sparkle) and a
  Homebrew cask.
- Third-party licenses shown in the app (libmpv, FFmpeg and its libraries).

Done when a fresh Mac can download, open and update MacShow with no warnings,
and see `~/Music` without being asked for permission.

### Later: Mac App Store

A second build of the same sandboxed app, without Sparkle and with the store-safe
Picture in Picture. Mostly packaging, because the app is sandboxed from the start.

## Library

### Where media comes from

Watched folders, set on first launch and editable in Settings:

| Folder | Why |
|---|---|
| `~/Music` | Music and audiobooks |
| `~/Movies` | Video |
| `~/Downloads` | Things you just downloaded |
| `~/Music/Music/Media.localized` | Music app downloads, including iTunes purchases |
| Any folder or drive you add | Everything else |

### How auto-import works

1. **On launch:** a full scan compares each file's path, size and modification
   date with the database, and only reads files that are new or changed.
2. **While running:** macOS file-system events (FSEvents) report changes in
   watched folders. Changes are batched for a couple of seconds, then only the
   affected folders are rescanned.
3. **Reading a file:** FFmpeg (already inside MPVKit) reads tags, duration,
   codecs, chapters and embedded cover art. A `cover.jpg` / `folder.jpg` next to
   the files is used when there's no embedded art.
4. **Sorting it:**
   - Video with a `S01E02`-style name → TV episode; other video → movie.
   - `.m4b`, an "Audiobook" genre tag, or a file under an `Audiobooks` folder →
     audiobook.
   - Everything else that's audio → music.
5. **Copy-protected files** are detected (encrypted `sinf`/`drms` atoms in
   MP4/M4A/M4P) and listed as "Protected", with a short reason, instead of
   failing silently.

Tags come only from the files. The one online lookup is cover art: albums
without any (iTunes purchases keep theirs in the Music app's database, not in
the file) get a cover from the iTunes Search API, sending only the album and
artist names. It can be turned off in Settings › Library.

### Storage

- SQLite database ([GRDB](#database)) in the app's Application Support folder.
- Stores the index, artwork thumbnails, play counts and playback positions.
- Deleting it loses only history and positions; a rescan rebuilds everything else.

## Purchases from Apple

Apple doesn't let third-party apps download iTunes Store purchases, so MacShow
uses the Music app as the downloader:

1. In the Music app, turn on **Automatic Downloads** once. Purchases you already
   own can be downloaded from **Account › Purchased**.
2. The Music app saves them in `~/Music/Music/Media.localized/Music/`.
3. MacShow watches that folder and adds them like any other music.

iTunes Store music sold since 2009 is DRM-free AAC (`.m4a`), so it plays
anywhere. This was checked on purchased Eminem albums: they carry the purchase
tag and have no encryption. Older protected `.m4p` purchases can be replaced
with DRM-free copies through iTunes Match.

Movies and TV bought from Apple are copy-protected, so they stay in the TV app.

## Out of scope

MacShow does not remove or work around copy protection (DRM). These files are
shown as "Protected" and left to the app that sold them:

- Apple Music subscription downloads and older `.m4p` iTunes purchases
- Movies and TV shows bought or rented from Apple
- Apple Books audiobooks
- Audible books (`.aax`, `.aaxc`)
- Any streaming service's downloads (Netflix, Spotify, etc.)

Also not planned for now: streaming catalogs, cloud sync between Macs, and an
iPhone app.

## Distribution

MacShow ships as a direct download first; a Mac App Store build can follow. Both
are sandboxed from day one, so there is one code path for file access and the
store build doesn't need a rewrite. Store-only differences sit behind an
`APPSTORE` build flag.

**Folder access in the sandbox:**

| Folder | How MacShow gets access |
|---|---|
| `~/Music` (including the Music app's downloads) | `com.apple.security.assets.music.read-only` entitlement; no prompt |
| `~/Movies` | `com.apple.security.assets.movies.read-only` entitlement; no prompt |
| `~/Downloads` | `com.apple.security.files.downloads.read-only` entitlement; no prompt |
| Any other folder or drive | Picked once in an Open panel, then remembered with a security-scoped bookmark |

**What differs between the two builds:**

| | Direct | App Store |
|---|---|---|
| Updates | Sparkle | App Store (apps there may not download code) |
| Picture in Picture | May use the approach IINA uses (private API) | Public AVKit API only |
| Donations, if any | Link to a donation page | In-app purchase "tip jar" |

**App Store rules to keep in mind:**

- Use only the LGPL builds of libmpv and FFmpeg (`MPVKit`, never `MPVKit-GPL`):
  the GPL doesn't fit the App Store's terms.
- No private APIs in the store build.
- Don't use Apple trademarks ("iTunes", "Apple Music") in the app's name or
  store listing.

## Database

SQLite through [GRDB](https://github.com/groue/GRDB.swift): plain SQLite with a
Swift API, fast and predictable for libraries of 100,000+ tracks.
