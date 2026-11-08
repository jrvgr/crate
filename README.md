# Crate

A Mac app for the classic iPod (built for the 3rd generation): your music folders on one side, the iPod on the other, and a sync that keeps them together. It replaces iTunes/Finder syncing for iPods that macOS no longer manages well.

![Crate](docs/screenshot.png)

## What it does

- **Library**: reads your music folders (local or on network shares) by tags; albums, artists, songs, Cover Flow, Recently Added, Year in Review.
- **iPod sync**: queue albums, songs and playlists, review the changes, sync. Converts FLAC/ALAC to AAC, writes the iTunesDB directly, keeps play counts, ratings and On-The-Go playlists, and merges plays made on the iPod back in.
- **Smart playlists**, Sound Check, an organiser, a tag editor, cover tools and a library health check (missing covers, duplicates, low bit rates).
- **Playback** on this Mac, with the iPod drawn in the sidebar as the remote (wheel for volume), or on Music Assistant speakers.
- **Frogger**: optional patched-firmware support for the 3rd gen iPod (hidden playlists, skips).

## Plugins

Everything that talks to another service is a plugin you can switch off (Settings › Plugins). With all of them off, Crate is a plain folders → iPod manager that keeps its music in `~/Music/Crate`.

| Plugin | What it adds |
|---|---|
| Subsonic | A Navidrome/Subsonic server's library and playlists; rescans after imports; scrobbles the iPod's plays |
| Music Assistant | Its speakers and groups in the toolbar; Play and the controls drive its queue |
| Spotify | Your saved albums and playlists (Web API, your own Client ID): what you have files for, copy playlists to the iPod |
| Soulseek | Search and download through your slskd server, imported into the library |
| Apple Music | Import iTunes Match albums from the Music app |
| YouTube | Download songs, playlists or a playlist's missing songs with yt-dlp, tagged with covers |

## Install

Needs macOS 26 on an Apple Silicon Mac.

### Homebrew

```sh
brew tap jrvgr/crate
brew install --cask crate
```

### Download

Get `Crate-vX.Y.Z.dmg` from the [latest release](https://github.com/jrvgr/crate/releases/latest) and drag Crate into Applications.

Crate isn't notarised (that needs a paid Apple developer account), so macOS blocks it the first time you open it. Open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway** next to the message about Crate. You only do this once. Or, from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Crate.app
```

### Updates

Crate checks for new versions itself (**Crate › Check for Updates…**) and installs them; Homebrew users can also `brew upgrade`.

## Building

Needs Xcode 27.2 or later (the project uses Xcode's JSON project format). Open `Crate.xcodeproj` and press Run, or from Terminal:

```sh
./build.sh        # optimised build into build/Crate.app
./build.sh dev    # faster to compile, slower to run
open build/Crate.app
```

With a code-signing identity named "Crate Local Signing" in your keychain, builds keep their macOS permissions between rebuilds; otherwise they're signed ad hoc.

### Releasing

Push a version tag (`git tag v0.2.0 && git push origin v0.2.0`). The Release workflow builds the DMG, signs the update for Sparkle, publishes the GitHub release with its `appcast.xml` and moves the cask in [jrvgr/homebrew-crate](https://github.com/jrvgr/homebrew-crate) to the new version. It needs two repository secrets: `SPARKLE_PRIVATE_KEY` (Sparkle's `generate_keys -x`) and `TAP_DEPLOY_KEY` (the private half of a write deploy key on the tap).

## Layout

```
Sources/App       app entry, main window, settings, player, menu bar
Sources/Library   library loading, albums/artists/songs, tags, metadata, organiser, health
Sources/iPod      iTunesDB, iPod sync, artwork, Frogger, disk repair
Sources/Plugins   Subsonic, Music Assistant, Spotify, Soulseek, Apple Music, YouTube
Resources         Info.plist, icon, the iPod LCD font
Crate.xcodeproj   the Xcode project (JSON format; Sources is a synchronized folder)
.github           build on every push; releases from version tags
docs/NOTES.md     detailed notes, file formats and command-line test flags
```

## License

MIT, see [LICENSE](LICENSE). The ChicagoFLF font is in the public domain.
