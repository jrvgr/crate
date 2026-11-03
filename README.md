# Crate

Mac app (SwiftUI, Liquid Glass, macOS 26+) that manages the 3rd gen iPod, replacing iTunes/Finder
(which crash on this iPod on macOS 27).

The core is the library (music folders on disk), the iPod and metadata lookups. Everything that
talks to another service is a plugin (Settings › Plugins, `Plugins.swift`): **OwnTone** (its
library, playlists, playback, rescans), **Spotify** (saved albums via OwnTone), **Soulseek**
(slskd: search, download, import) and **Apple Music** (iTunes Match imports). With all of them off
Crate is a plain folder → iPod manager.

- **Sidebar**: Library (Recently Added, Albums, Artists, Songs), Playlists (OwnTone's, plus the
  ones only on the iPod), Sources (one per plugin). Search is at the top of the sidebar and looks
  through everything (library, playlists, Apple Music, Spotify) with a jump to Soulseek.
  Downloads and Activity are toolbar buttons; the iPod card at the bottom opens the iPod page.
- **Albums**: grid or Cover Flow (same geometry as `imac/CoverFlow`), filter On iPod / Not on
  iPod, sort by artist/title/year/added. Every item shows ✓ on the iPod, ◐ partly, + / − queued.
- **iPod page**: capacity (music/other/free), queued changes, per-iPod settings (name, AAC
  bitrate for lossless, shrink large MP3s, On-The-Go, fill tags, sync when connected, eject after
  sync), stray-file check and restore of `iTunesDB.crate-backup`.
- **Unplugged**: the last iPod's database and the queued changes are cached in
  `~/Library/Application Support/Crate/` (`ipod.json`, `iTunesDB.cached`); changes can be queued
  and sync by themselves when it's plugged in (when "Sync when connected" is on).
- **Sync** opens a sheet: review (what changes, size, fits?) → progress (phases, current song) →
  result. It re-reads the iPod's iTunesDB right before writing and applies only the queued
  changes, so changes made elsewhere stay; the iPod's `Play Counts` (plays, ratings, last played)
  are merged into the tracks and the file removed, like iTunes. Track/playlist records are kept
  byte for byte; FLAC/WAV are converted with `afconvert`.
- **Downloads**: one list for Soulseek folders and Apple Music imports (filter by source/state).
  Finished slskd folders (`/path/to/slskd/downloads/<folder>`) are copied into the import
  folder automatically. slskd logs in with your web username/password (password in the
  Keychain) or an API key; slskd's web port (5030 by default) has to be reachable from the Mac.
- **Apple Music**: filter, On This Mac / In iCloud, sort, group (A–Z with an index, artist,
  decade, genre). Imports are queued and done one at a time; the iTunes Store cover is saved as
  cover.jpg when the files bring none.
- **Find Metadata…**: MusicBrainz, iTunes and Discogs (token) results; "Use" saves year/genre into
  the tags and the cover if there is none (or always, with "Replace the current cover"); "Cover"
  only replaces the cover. Progress shows in the dialog.
- **Drag and drop** onto the window imports into the library; onto the iPod card also queues it.
- **Spotify** (plugin, `Spotify.swift`): reads your saved albums and playlists through the Web API
  (your own app on developer.spotify.com, PKCE login with a listener on 127.0.0.1:8765; refresh
  token in the Keychain), or OwnTone's library. "Get Missing Albums…" searches Soulseek for the
  saved albums you have no files for, picks folders by the quality rules, and downloads after
  you check them.
- **Soulseek quality rules**: format (any/lossless/MP3), minimum bit rate, free slot, queue length;
  a menu on the Soulseek page and in Settings.
- **Playback**: the toolbar's mini player plays on this Mac (AVFoundation) or on OwnTone's speakers
  (Settings › Library › Playback). Double-click a song on an album page to play from there.
- **Needs Attention** (sidebar): albums with no cover/year/genre, odd track numbers, duplicate
  songs, MP3s under 160 kbps, missing files; "Review Matches…" runs Find Metadata over all of them
  (MusicBrainz + iTunes, one a second) and saves what you tick.
- **Edit Tags…**: album and per-song fields and the cover, written into FLAC (Vorbis), MP3 (ID3v2)
  and M4A (AVFoundation passthrough, audio untouched).
- **Menu bar**: iPod status with Sync/Eject, now playing, downloads (Settings › Library to hide it).

Build: `./build.sh` (Command Line Tools only). It signs with the self-signed
"Crate Local Signing" identity in the login keychain so macOS keeps the privacy
permissions across builds. `@State` can't be used: its macro plugin isn't in the CLT
(use `@StateObject`/`@Published` instead).

Headless checks (`build/Crate.app/Contents/MacOS/Crate ...`):
`--selftest <iTunesDB>` (round trip, tracks and playlists), `--playlist-test <iTunesDB>`
(offline: playlists, On-The-Go import, pruning; use a copy), `--add-folder <dir>`,
`--remove-album <title>`, `--remove-playlist <name>`, `--model-test <album>` (remove + re-add
through the app's Model), `--lookup <album> <artist>`, `--write-tags <file> <year> <genre>`
(use a copy), `--import <root> <files/folders...>`, `--apple-music` (list albums),
`--apple-music-download <album>` (Music downloads it, no import).
When launching the app: `--open-lookup/--open-album <album>`, `--open-playlist <name>`,
`--open-artist <name>`, `--open-recent/-albums/-artists/-songs/-ipod/-spotify/-apple-music/-soulseek/-downloads`,
`--search <text>`, `--open-sync` (review sheet only), `--open-health`. `--playlist-test` also checks the Play Counts merge.
Tools: `--tag <file> title=… artist=… album=… year=… track=…` (use a copy), `--slskd-check [query]` (login + search, no
downloads), `--callback-test` (Spotify login listener), `--keychain-test`.
