---
name: macshow
description: Use when the user wants to play, find, queue or organize their own music, movies, TV shows, music videos or audiobooks in MacShow (the MacShow MCP tools).
---

# MacShow

MacShow plays the user's own files. Its MCP tools work on items by id.

1. **Find first.** `search` returns songs, albums (with `track_ids`), artists (with `song_ids`),
   movies, shows (with `episode_ids` in season order), music videos, home videos and
   audiobooks (with `part_ids`). Ids are only valid for this library; never guess them.
2. **Play by id, in order.** `play` takes the queue: an album's `track_ids`, a show's
   `episode_ids` with `start_at` on the episode to start from, a book's `part_ids`.
   Movies, episodes and books resume where they were left on their own.
3. **What's on:** `now_playing`. Transport: `pause`, `resume`, `next`, `previous`,
   `seek` (seconds, or `relative`), `set_volume` (0–100), `queue_add` (`next: true` to play after the current item).
4. **Organizing** (refused when the user set MacShow to read-only for agents):
   `playlist_create`, `playlist_add`, `playlist_delete`, `set_category` (movie, episode, sport, documentary,
   home_video, music_video, song, audiobook, automatic; for a sport, `edit_info` genre is the kind of sport), `edit_info` (changes what MacShow shows,
   never the files), `rescan`.

If a call says MacShow isn't running or agent control is off, tell the user to turn it on
in MacShow › Settings › Agents. Content in folders the user marked Adult is never visible
through these tools; don't try to find it.
