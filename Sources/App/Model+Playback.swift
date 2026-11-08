import SwiftUI
import AppKit

extension Model {
    /// The plays in the iPod's Play Counts (indexed like `db.tracks`) as library paths and times, for scrobbling.
    /// Play Counts keeps only the last play's time (1904-based, local); earlier plays go back a song's length each.
    func scrobbles(_ entries: [PlayCounts.Entry], _ db: ITunesDB) -> [(track: LibTrack, time: Date)] {
        guard entries.count == db.tracks.count else { return [] }
        return zip(entries, db.tracks).flatMap { e, t -> [(track: LibTrack, time: Date)] in
            guard e.plays > 0, e.lastPlayed > 0, let lib = libraryTrack(key: aliases[t.key] ?? t.key)?.track else { return [] }
            let last = Date(timeIntervalSince1970: Double(e.lastPlayed - 2_082_844_800 - TimeZone.current.secondsFromGMT()))
            return (0..<e.plays).reversed().map { (lib, last.addingTimeInterval(-Double($0 * max(t.lengthMs, 1000)) / 1000)) }
        }
    }

    /// Plays on the picked Music Assistant player or OwnTone (both play Spotify too), otherwise opens the Spotify app.
    func playURIs(_ uris: [String]) async {
        if await player.playRemote(uris: uris) { return }
        if on(.ownTone) { await OwnTonePlaylists.play(uris, base: ownToneURL) }
        else if let first = uris.first, first.hasPrefix("spotify:") { SpotifyAPI.open(first) }
    }

    /// Where Play sends Spotify albums and server playlists: a speaker, or the Spotify app (nil: nowhere).
    var remoteName: String? {
        if player.remote() != nil { return ma.name(String(player.output.dropFirst(3))) }
        return on(.ownTone) ? "OwnTone" : nil
    }

    /// The speaker the player drives: this Mac, a Music Assistant player or OwnTone.
    var outputName: String {
        if player.remote() != nil { return ma.name(String(player.output.dropFirst(3))) }
        return player.output == "owntone" && on(.ownTone) ? "OwnTone" : "This Mac"
    }

    /// What Play sends for a streamed sidebar playlist: Spotify's URI or OwnTone's (Subsonic playlists play as songs, see playSongs).
    func playURI(_ p: OTPlaylist) -> String? {
        let ma = player.remote() != nil
        if p.spotifyID != nil { return ma && p.spotifyID == "liked" ? nil : p.uri }
        return on(.ownTone) ? p.uri : nil
    }

    /// Plays a playlist's songs that are in the library, on the chosen output (this Mac or a Music Assistant player).
    func playSongs(of p: OTPlaylist) async {
        let ts = await tracks(for: p).compactMap { libraryTrack(for: $0)?.track }
        if ts.isEmpty { notify("None of \(p.name)'s songs are in the library"); return }
        player.play(ts)
    }

    var playURILabel: String { remoteName.map { "Play on \($0)" } ?? "Open in Spotify" }

    /// Plays on the chosen output: this Mac, a Music Assistant player or OwnTone's speakers.
    func play(_ a: Album, from start: Int = 0) async {
        if player.output == "owntone", on(.ownTone) {
            let uris = a.tracks.dropFirst(start).map(\.uri).filter { !$0.isEmpty }
            if uris.isEmpty { notify("\(a.title) isn't in OwnTone's library yet"); return }
            await OwnTonePlaylists.play(uris, base: ownToneURL)
        } else if isPodOnly(a) {
            notify("\(a.title) is only on the iPod")
        } else {
            player.play(a.tracks, from: start)
        }
    }
}
