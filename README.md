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
  stopped, subtitle and audio-track menus.
- **Audiobooks.** Chaptered M4B files or folders of MP3s, chapters, speed,
  sleep timer, bookmarks, resume to the second.

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
