# MacShow

An open-source Mac app for the media you own: music, video and audiobooks in
one place. It plays almost any format (FLAC, ALAC, MP3, Opus, MKV, HEVC, AV1,
M4B…) through [mpv](https://mpv.io), finds your files on its own, and never
asks you to prove you bought them. If a file isn't copy-protected, it plays.

## What it does

- **Library that builds itself.** Watches `~/Music` (including the Music app's
  downloads, so DRM-free iTunes purchases appear on their own), `~/Movies`,
  `~/Downloads` and any folder or drive you add. New files show up within seconds.
- **Music.** Albums, artists, songs, playlists, gapless playback, ReplayGain,
  media keys, Now Playing, a mini player. Duplicate copies collapse to the best one.
- **Video.** Movies, TV shows grouped into seasons, home videos, resume where you
  stopped, subtitle and audio-track menus. Keep watching in a corner while you
  browse; Up Next at the end of an episode, Skip Intro on intro chapters.
- **Audiobooks.** Chaptered M4B files or folders of MP3s, chapters, speed,
  sleep timer, bookmarks, resume to the second.
- **Network folders.** Add folders from a NAS or shared Macs and PCs (Settings ›
  Library › + › Add Network Folder); they reconnect by themselves and are rescanned
  every 15 minutes.
- **Sorted the way you want.** Right-click › Move To: Movies, TV Shows, Home Videos,
  Music Videos. Music videos also sit in Songs, where they play as audio.
- **Artwork.** Get Info › Find Artwork Online (TMDB with your own key, Deezer, the
  iTunes Store, Wikipedia); Artists › Find Pictures gives every artist a photo.
- **TV niceties.** Mark where a show's recap ends and its credits start (right-click
  the video › Recap & Credits): Skip Recap, Up Next at the credits, another show
  after the last episode. Subtitle files next to a video load by themselves.
- **Yours to keep.** Edit titles, artists and artwork with Get Info (stored in
  MacShow, never written into your files). Import playlists from the Music app's
  exported library or M3U, export any playlist as M3U. Settings › Content lists
  any copy-protected (DRM) files and what they are.
- **Sound.** Bit-perfect output that switches your DAC to each file's sample rate
  (Settings › Playback), a 10-band equalizer with presets and per-album settings
  (⌥⌘E), drag to reorder Up Next. Audiobooks sort by title, author or recently played.
- **Content kept apart.** Right-click a video to mark its folder as Personal
  (Home Videos), Adult (hidden everywhere; its own section after Touch ID, locked
  again at every launch) or Never Scan, or hide single files. Settings › Content
  lists them.

### Keys

| Key | Does |
| --- | --- |
| Space | Play / pause (anywhere but a text field) |
| ← → | Back / forward 10 seconds, ⇧ for 30 (video) |
| ↑ ↓ | Volume (video); ⌘↑ ⌘↓ anywhere |
| Scroll / two-finger swipe | Volume (over a video) |
| ⌘← ⌘→ | Previous / next |
| Click | Show / hide the video controls |
| F or double-click | Full screen (video) |
| Right-click | Subtitles, audio track, speed, chapters, Fill Window… (video) |
| M | Mute (video) |
| S | Next subtitles (video) |
| , . | Step a frame back / forward (video) |
| Esc | Leave full screen, then back to the library (an episode opens its show) with the video in a corner |
| ⇧⌘A | Show / hide Adult content |

See the [roadmap](ROADMAP.md) for the plan and what's left.

## Build and run

Requires macOS 14+ and Xcode.

```bash
scripts/build-app.sh
```

```bash
open build/MacShow.app
```

`scripts/build-app.sh` builds a sandboxed `build/MacShow.app`. For quick
development runs without the sandbox, `swift run MacShow [file]` works too.
Tests: `swift test`. A distributable disk image: `scripts/make-dmg.sh`
(see [RELEASING.md](RELEASING.md) for signing and notarization).

## License

[MIT](LICENSE). Bundled open-source components and their licenses are listed in
the app under Settings › About.
