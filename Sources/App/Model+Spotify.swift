import SwiftUI
import AppKit

extension Model {
    // MARK: Spotify

    /// Spotify albums you have files for (matched on album title).
    func hasFiles(_ s: SpotifyAlbum) -> Bool { libraryIDs.contains(s.name.lowercased()) }

    /// Fetches a Spotify album from YouTube, song by song.
    func albumFromYouTube(_ a: SpotifyAlbum) async {
        guard on(.youtube) else { return }
        guard spotifyAPI.direct, spotifyAPI.connected else { notify("Connect your Spotify account to fetch whole albums from YouTube"); return }
        do {
            let r = try await spotifyAPI.album(a.uri)
            yt.fetch(r.tracks, album: a.name, art: r.art, year: r.year)
            notify("Fetching “\(a.name)” from YouTube (\(r.tracks.count) songs)")
        } catch { notify(error.localizedDescription) }
    }

    /// One song of an album you have no files for, from Soulseek: the best single file that passes the
    /// quality rules (with its folder's cover), imported when it's done. Whether one was queued.
    func songFromSoulseek(_ t: OTTrack, artist: String, album: String) async -> Bool {
        guard on(.soulseek) else { notify("Turn on the Soulseek plugin in Settings to download songs"); return false }
        do {
            let q = (artist == "Various Artists" ? t.artist : artist) + " " + t.title
            let found = slsk.songCandidates(try await slsk.find(q), title: t.title, album: album)
            // one file per user: a second copy from someone who just failed would fail the same way
            var seen = Set<String>()
            let tries = Array(found.filter { seen.insert($0.0.username).inserted }.prefix(5))
            guard !tries.isEmpty else {
                notify("“\(t.title)” isn't on Soulseek in a format that passes your rules"); return false
            }
            try await slsk.download(tries[0].0, only: tries[0].1)
            notify("Downloading “\(t.title)” from Soulseek")
            Task { await keepTrying(t.title, tries) }
            return true
        } catch { notify(error.localizedDescription); return false }
    }

    /// Follows a song's download and, when the user it came from fails it (offline, refused, timed out) or keeps it
    /// in their queue for 2 minutes, drops it and tries the next one: a single song has no folder to pick from by hand.
    private func keepTrying(_ title: String, _ tries: [(SlskFolder, SlskFile)]) async {
        for (n, (folder, file)) in tries.enumerated() {
            if n > 0 {
                notify("“\(title)” failed from \(tries[n - 1].0.username); trying \(folder.username) (\(n + 1) of \(tries.count))")
                do { try await slsk.download(folder, only: file) } catch { continue }
            }
            let started = Date()
            while true {
                try? await Task.sleep(for: .seconds(3))
                await slsk.refreshDownloads()
                guard let job = slsk.jobs.first(where: { $0.username == folder.username && $0.directory == folder.directory }),
                      let f = job.files.first(where: { $0.filename == file.filename }) else {
                    if Date().timeIntervalSince(started) > 60 { break }       // never showed up in slskd: next
                    continue
                }
                if f.succeeded { return }
                if f.failed { await slsk.cancel(job, remove: true); break }
                // still waiting in their queue (not started): someone else may send it now
                if !f.state.hasPrefix("InProgress"), f.bytes == 0, Date().timeIntervalSince(started) > 120 {
                    await slsk.cancel(job, remove: true); break
                }
            }
        }
        notify("Couldn't get “\(title)” from Soulseek: \(tries.count) user\(tries.count == 1 ? "" : "s") tried, none sent it")
    }

    /// One song of an album, from YouTube, tagged with its place on the album.
    func songFromYouTube(_ t: OTTrack, number: Int, of total: Int, artist: String, album: String, art: String, year: Int) {
        guard on(.youtube) else { notify("Turn on the YouTube plugin in Settings to download songs"); return }
        var t = t; t.album = album; t.albumArtist = artist
        yt.fetch([t], album: album, art: art, year: year, numbers: [number], total: total)
        notify("Fetching “\(t.title)” from YouTube")
    }

    /// Looks the album up on Soulseek (the Soulseek pane, search started).
    func findOnSoulseek(_ artist: String, _ album: String, songs: Int = 0) {
        guard on(.soulseek) else { notify("Turn on the Soulseek plugin in Settings to download albums"); return }
        search = ""
        pane = .soulseek
        path = []            // the album page it was asked from would stay on top of the Soulseek page
        slsk.wantSongs = songs
        slsk.search([artist == "Various Artists" ? "" : artist, album].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// How many songs the full album has, when the library copy has fewer: gaps in the track
    /// numbers, or more songs on the release picked with Find Metadata.
    func expectedSongs(_ a: Album) -> Int? {
        let have = a.tracks.count
        let byNumbers = Set(a.tracks.map(\.discNumber)).count <= 1 ? (a.tracks.map(\.trackNumber).max() ?? 0) : 0
        let full = max(byNumbers, metadata[a.id]?.trackCount ?? 0)
        return full > have ? full : nil
    }
}
