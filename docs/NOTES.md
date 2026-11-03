# Crate

Mac app (SwiftUI, Liquid Glass, macOS 26+) that manages the 3rd gen iPod, replacing iTunes/Finder
(which crash on this iPod on macOS 27).

The core is the library (music folders on disk), the iPod and metadata lookups. Everything that
talks to another service is a plugin (Settings › Plugins, `Plugins.swift`), each with an on/off
switch there (kept in the defaults): **OwnTone** (its library, playlists, playback, rescans; off
means Crate doesn't contact it at all), **Subsonic** (Navidrome: library, playlists, covers,
rescans, scrobbles), **Music Assistant** (plays on its speakers and groups), **Spotify** (saved
albums via your account, or the older way through OwnTone), **Soulseek** (slskd:
search, download, import), **Apple Music** (iTunes Match imports) and **YouTube** (yt-dlp). With all
of them off Crate is a plain folder → iPod manager.

- **Sidebar**: Library (Recently Added, Albums, Artists, Songs, Playlists), Sources (one per plugin) and
  the playlists you pin (right-click › Pin to Sidebar; kept as `pinnedPlaylists`). The Playlists page shows them all
  as cards (Crate's, smart, only on the iPod, each server's), filtered by tab. Back/forward (⌘[ ⌘]) go through pages. Search is at the top of the sidebar and looks
  through everything (library, playlists, Apple Music, Spotify) with a jump to Soulseek.
  Downloads and Activity are toolbar buttons; the iPod card at the bottom opens the iPod page.
- **Albums**: grid or Cover Flow (same geometry as `imac/CoverFlow`), filter On iPod / Not on
  iPod, sort by artist/title/year/added. Every item shows ✓ on the iPod, ◐ partly, + / − queued.
- **iPod page**: capacity (music/other/free), queued changes, per-iPod settings (name, AAC
  bitrate for lossless, shrink large MP3s, On-The-Go, fill tags, sync when connected, eject after
  sync), stray-file check and restore of `iTunesDB.crate-backup`.
- **Cover Studio** (iPod page › Frogger card): tune how covers become the 72×72 four-grey pictures
  on Frogger's Now Playing page (levels, brightness, contrast, midtones, sharpen, dither method),
  previewed on a mock of the iPod's screen and on other albums. Saved as you go and used by every
  sync; "Write to iPod" redoes the covers now. Hovering an album page's cover wipes to its iPod picture.
- **Unplugged**: the last iPod's database and the queued changes are cached in
  `~/Library/Application Support/Crate/` (`ipod.json`, `iTunesDB.cached`); changes can be queued
  and sync by themselves when it's plugged in (when "Sync when connected" is on).
- **Sync** opens a sheet: review (what changes, size, fits?) → progress (every phase in a checklist, each with its own bar and count: songs removed, added, measured, covers read; a moving bar for the ones without a count) →
  result. It re-reads the iPod's iTunesDB right before writing and applies only the queued
  changes, so changes made elsewhere stay; the iPod's `Play Counts` (plays, ratings, last played)
  are merged into the tracks and the file removed, like iTunes; so are Frogger's `FroggerHidden`
  (songs hidden there, and ones shown again: a show choice over a hidden playlist's rule) and `FroggerSkips` (skips, added to Crate's own count: the Skips column and smart rule,
  as the 2.3 iTunesDB has no skip fields), each only when its stamp matches the iTunesDB. Track/playlist records are kept
  byte for byte; FLAC/WAV are converted with `afconvert`.
  M4A files the 3G's firmware can't read (index after the audio, or a 64-bit audio box, as some
  downloads have) are rearranged on the way, audio untouched (`MP4Layout.swift`), and copies already
  on the iPod are fixed in place at the next sync ("Fixing song files"), as are Apple Lossless songs,
  which become AAC.
  Every song also gets its library album's artist as album artist (iTunesDB mhod 22), on new songs
  and, through a retag, on ones already there; songs that are only on the iPod keep theirs.
  Apple's 2.3 firmware ignores it, but Frogger lists songs under it in Artists and Genres, so a
  compilation or a "feat." song stays under one name.
- **Downloads**: one list for Soulseek folders and Apple Music imports (filter by source/state).
  Finished slskd folders (from its downloads folder as this Mac sees it) are copied into the import
  folder automatically. slskd logs in with your web username/password (password in the
  Keychain) or an API key; slskd's web port (5030 by default) has to be reachable from the Mac.
- **Apple Music**: filter, On This Mac / In iCloud, sort, group (A–Z with an index, artist,
  decade, genre). Imports are queued and done one at a time; the iTunes Store cover is saved as
  cover.jpg when the files bring none.
- **Find Metadata…**: MusicBrainz, iTunes and Discogs (token) results; "Use" saves year/genre into
  the tags and the cover if there is none (or always, with "Replace the current cover"); "Cover"
  only replaces the cover. Progress shows in the dialog.
- **Drag and drop** onto the window imports into the library; onto the iPod card also queues it.
- **Subsonic** (plugin, `Subsonic.swift`): a Subsonic server's songs join the library and its
  playlists show in the sidebar (OpenSubsonic JSON API, token login; server, username, music folder
  in Settings, the password in `secrets.json`). Songs whose files are in the music folder as this
  Mac sees it (set in Settings) are used from there; that needs real paths (Navidrome:
  Settings › Players › Crate › Report Real Path; without it the folder still matches and Crate takes the file in it
  whose name ends with or has the title). Others are downloaded (`download`, original file)
  into `~/Library/Caches/nl.jrvgr.crate/Subsonic` when a sync needs them, stream when played
  here and take their cover from `getCoverArt`. Imports, tag and cover edits ask for a `startScan`
  (admin users only), and Sync scrobbles the iPod's plays (Play Counts) to the server.
  Its playlists are read-only; Play plays their songs that are in the library. With OwnTone on as well, OwnTone's copy of a song wins (for playback there).
- **Music Assistant** (plugin, `MusicAssistant.swift`): MA's players and groups join the toolbar's
  speaker menu. With one picked, Play sends the songs to MA (`player_queues/play_media`,
  replace) as `opensubsonic://track/<id>` (MA has the same Navidrome as a provider) or Spotify URIs;
  songs not on the Subsonic server can't go. The iPod's buttons, wheel (volume), Space and the menu
  bar drive MA's queue, and Crate reads the queue back once a second to show it; when the queue is
  replaced elsewhere Crate lets go. Picking another speaker moves what's playing there (same song and spot); picking
  one that's already playing something else picks that up instead (its current song shows, the controls drive it). HTTP `POST /api` with a long-lived token (MA › profile), kept in
  secrets.json.
- **Spotify** (plugin, `Spotify.swift`): reads your saved albums and playlists through the Web API
  (your own app on developer.spotify.com, PKCE login with a listener on 127.0.0.1:8765; refresh
  token in the Keychain), or OwnTone's library. "Get Missing Albums…" searches Soulseek for the
  saved albums you have no files for, picks folders by the quality rules, and downloads after
  you check them.
- **Soulseek quality rules**: format (any/lossless/MP3), minimum bit rate, free slot, queue length;
  a menu on the Soulseek page and in Settings.
- **Playback**: the toolbar's mini player plays on this Mac (AVFoundation), on a Music Assistant player or on OwnTone's speakers
  (the toolbar's speaker menu, shown when Music Assistant or OwnTone is on). Double-click a song on an album page to play from there.
- **Needs Attention** (sidebar): albums with no cover/year/genre, odd track numbers, duplicate
  songs, MP3s under 160 kbps, missing files; "Review Matches…" runs Find Metadata over all of them
  (MusicBrainz + iTunes, one a second) and saves what you tick. "Review Duplicates…" finds the same
  song in more than one file (same artist and title, within 3 s): the best copy stays (lossless,
  then bit rate), the rest go to the Trash after you check them. Copies on other albums aren't ticked.
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
`--apple-music-download <album>` (Music downloads it, no import), `--dupes <folder>` (duplicate songs, read only).
When launching the app: `--open-lookup/--open-album <album>`, `--open-playlist <name>`,
`--open-artist <name>`, `--open-recent/-albums/-artists/-songs/-ipod/-spotify/-apple-music/-soulseek/-downloads`,
`--search <text>`, `--open-sync` (review sheet only), `--open-health`. `--playlist-test` also checks the Play Counts merge.
Tools: `--tag <file> title=… artist=… album=… year=… track=…` (use a copy), `--slskd-check [query]` (login + search, no
downloads), `--subsonic-check` (login, library and playlists; no downloads), `--callback-test` (Spotify login listener), `--keychain-test`.
