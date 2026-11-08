import SwiftUI
import AppKit

extension Model {
    // MARK: library
    /// The library album a song is on.
    func album(of t: LibTrack) -> Album? { albumByID[t.album.lowercased()] }

    func refreshPod() {
        hiddenCache = nil
        let tracks = (db?.tracks ?? []).map { t in     // renames waiting for the next sync already count
            var t = t
            if let r = retags[t.key] { t.title = r.title; t.album = r.album; t.artist = r.artist }
            return t
        }
        podKeys = Set(tracks.map { aliases[$0.key] ?? $0.key })
        podKeyByID = Dictionary((db?.tracks ?? []).map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        podKeyByLib = Dictionary(aliases.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        podAlbums = LibraryLoader.albums(tracks.map {
            LibTrack(title: $0.title, artist: $0.artist, album: $0.album, genre: $0.genre, trackNumber: $0.trackNumber,
                     discNumber: 0, year: 0, lengthMs: $0.lengthMs, path: $0.relativePath)
        })
        refreshDerived()
    }

    func refreshDerived() {
        hiddenCache = nil
        libraryIDs = Set(albums.map(\.id))
        albumByID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// Library albums plus albums that are only on the iPod (so they can be opened and removed).
        allAlbums = (albums + podAlbums.filter { !libraryIDs.contains($0.id) })
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
        // an album by several artists ("Kyuss & Queens of the Stone Age") goes under each of them when each is an
        // artist with albums of their own; otherwise under its credit as it is ("Roni Size & Reprazent")
        var names: [String: String] = [:]
        for a in allAlbums { names[a.artist.lowercased()] = names[a.artist.lowercased()] ?? a.artist }
        let solo = Array(names.values)
        var byArtist: [String: [Album]] = [:]
        for a in allAlbums {
            let parts = ArtistsField.split(a.artist, known: solo)
            let own = parts.count > 1 && parts.allSatisfy { names[$0.lowercased()] != nil }
            for p in own ? parts : [a.artist] { byArtist[p.lowercased(), default: []].append(a) }
        }
        artists = byArtist.map { key, albums in
            Artist(name: names[key] ?? albums[0].artist, albums: albums.sorted { ($0.year, $0.title) < ($1.year, $1.title) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var recentlyAdded: [Album] {
        albums.filter { $0.added != nil }.sorted { $0.added! > $1.added! }
    }

    func artistMark(_ a: Artist) -> SyncMark {
        let marks = a.albums.map { mark($0) }
        if marks.allSatisfy({ $0 == .onIPod }) { return .onIPod }
        if marks.contains(.adding) { return .adding }
        if marks.contains(.removing) { return .removing }
        return marks.contains { $0 == .onIPod || $0 == .partial } ? .partial : .none
    }

    func isPodOnly(_ a: Album) -> Bool { !libraryIDs.contains(a.id) }

    /// Whether Crate can change the album's files: some are on this Mac, not only on the iPod or only on the
    /// Subsonic server (whose API can't change tags, covers or files).
    func filesHere(_ a: Album) -> Bool { !isPodOnly(a) && a.tracks.contains { !Subsonic.serverOnly($0.path) } }
    static let serverOnlyHelp = "Only on the Subsonic server: its files can't be changed from Crate"

    static func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    func rebuild() {
        var seen = Set<String>()
        libTracks = libTracks.filter { seen.insert($0.path).inserted }
        albums = LibraryLoader.albums(libTracks)
        index = [:]; pathIndex = [:]
        for a in albums { for t in a.tracks {
            index[t.key] = (a, t); pathIndex[t.path] = (a, t)
            let k = "~" + Self.loose(t.album) + "|" + Self.loose(t.title)
            if index[k] == nil { index[k] = (a, t) }
        } }
    }

    /// The file for a playlist track: the one you linked it to, same album and title, or the same once punctuation is ignored.
    func libraryTrack(key k: String) -> (album: Album, track: LibTrack)? { index[k] }

    func libraryTrack(for t: OTTrack) -> (album: Album, track: LibTrack)? {
        if let p = linkedPath(t), let m = pathIndex[p] { return m }
        return index[t.key] ?? index["~" + Self.loose(t.album) + "|" + Self.loose(t.title)]
    }

    func libraryTrack(path p: String) -> (album: Album, track: LibTrack)? { pathIndex[p] }

    enum Availability { case onIPod, file, streamOnly }
    func availability(_ t: OTTrack) -> Availability {
        let keys = podKeys
        if keys.contains(t.key) { return .onIPod }
        guard let lt = libraryTrack(for: t) else { return .streamOnly }
        return keys.contains(lt.track.key) ? .onIPod : .file
    }

    func podPlaylist(for p: OTPlaylist) -> PodPlaylist? { db?.playlists.first { samePlaylist($0.name, p.name) } }

    /// iPod playlists that don't come from an OwnTone playlist (On-The-Go, made elsewhere).
    var podOnlyPlaylists: [PodPlaylist] {
        let names = Set((playlists.map(\.name) + smartPlaylists.map(\.name) + cratePlaylists.map(\.name)).map(baseName))
        return (db?.playlists ?? []).filter { !names.contains(baseName($0.name)) }
    }

    func tracks(for p: OTPlaylist) async -> [OTTrack] {
        if let t = playlistTracks[p.id] { return t }
        let t = p.spotifyID != nil ? ((try? await spotifyAPI.tracks(p.spotifyID!)) ?? [])
            : p.subsonicID != nil ? ((try? await subsonic.tracks(p.subsonicID!)) ?? [])
            : ((try? await OwnTonePlaylists.tracks(p.id, base: ownToneURL)) ?? [])
        playlistTracks[p.id] = t
        return t
    }

    func reload() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let job = startJob("Loading library", icon: "square.stack")
        // at launch: the library as it was last time, with the covers this Mac has, while the folders and
        // servers are read (shares can take a while); the scan below replaces it
        if libTracks.isEmpty {
            let last = await Task.detached { Store.load("library.json", [LibTrack]()) }.value
            if !last.isEmpty { libTracks = last; rebuild(); await showCachedArtwork() }
        }
        await loadIPodNow()
        var tracks: [LibTrack] = []
        libraryError = nil
        if on(.ownTone) {
            updateJob(job) { $0.detail = "Reading OwnTone" }
            do { tracks = try await LibraryLoader.fromOwnTone(ownToneURL) }
            catch { libraryError = "OwnTone unreachable: \(error.localizedDescription)" }
        }
        var serverFailed = false
        if on(.subsonic) {
            updateJob(job) { $0.detail = "Reading Subsonic" }
            do {
                let known = Set(tracks.map(\.path))      // OwnTone's copy of a file keeps its uri (for playing there)
                tracks += try await subsonic.library().filter { !known.contains($0.path) }
                subsonic.error = nil
            } catch { subsonic.error = error.localizedDescription; serverFailed = true }
        }
        // the import folder is scanned directly too, so new files show up before OwnTone has indexed them;
        // when OwnTone doesn't answer, its whole music folder (the import folder's parent) is, so nothing goes missing
        let ownToneRoot = on(.ownTone) && libraryError != nil ? [(importRoot as NSString).deletingLastPathComponent] : []
        let subsonicRoot = serverFailed && subsonic.useShare ? [subsonic.musicFolder] : []
        let fromServer = tracks.count
        for f in folders + [importRoot] + ownToneRoot + subsonicRoot where !f.isEmpty {
            updateJob(job) { $0.detail = "Scanning \((f as NSString).lastPathComponent)" }
            tracks += await LibraryLoader.scan(f, skipping: Set(tracks.map(\.path)))
        }
        // a server song that also turned up as a file here is the same song: the file and its tags win, and the
        // server's copy stays linked to it (for streaming and Music Assistant). Matched without the album: Navidrome
        // adds an album version to the name ("… (remastered)"), which made the same songs a second album
        var files: [String: [LibTrack]] = [:]                   // identity → the scanned files
        for t in tracks[fromServer...] { files[Self.songIdentity(t), default: []].append(t) }
        var linked: [String: String] = [:]                      // the file's path → the server copy's
        tracks = tracks.enumerated().filter { i, t in
            guard i < fromServer, subsonic.songs[t.path] != nil,
                  let file = files[Self.songIdentity(t)]?.first(where: { abs($0.lengthMs - t.lengthMs) <= 3000 }), file.path != t.path
            else { return true }
            linked[file.path] = t.path
            return false
        }.map(\.element)
        subsonic.link(linked)
        libTracks = tracks
        if !tracks.isEmpty { Task.detached { Store.save("library.json", tracks) } }     // for the next launch
        rebuild()
        if on(.subsonic), !serverFailed { Task { await moveRatingsToServer() } }
        await showCachedArtwork()
        playlistTracks = [:]
        var lists: [OTPlaylist] = on(.ownTone) ? ((try? await OwnTonePlaylists.all(ownToneURL)) ?? []) : []
        if on(.subsonic), !serverFailed { lists += (try? await subsonic.playlists()) ?? [] }
        spotify = []
        if on(.spotify) {
            if spotifyAPI.direct {
                if spotifyAPI.connected {
                    updateJob(job) { $0.detail = "Reading Spotify" }
                    do {
                        spotify = try await spotifyAPI.savedAlbums()
                        var own = try await spotifyAPI.playlists()
                        if let liked = try? await spotifyAPI.likedPlaylist() { own.insert(liked, at: 0) }
                        let names = Set(own.map { $0.name.lowercased() })
                        lists = lists.filter { !names.contains($0.name.lowercased()) } + own    // OwnTone mirrors the same playlists
                        spotifyAPI.error = nil
                    } catch { spotifyAPI.error = error.localizedDescription }
                }
            } else if on(.ownTone) {
                spotify = (try? await SpotifyLibrary.albums(ownToneURL)) ?? []
            }
        }
        playlists = lists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        finishJob(job, "\(libTracks.count) songs in \(albums.count) albums")
        applyKeptArtists()
        refreshSmartPending()
        Task { await loadSizes() }
        await loadArtwork()
    }

    /// Covers this Mac already has, shown as soon as the albums are known: only the local cache is read, not the
    /// shares. loadArtwork checks them against the folders afterwards and replaces any that changed.
    func showCachedArtwork() async {
        let quick = await Task.detached { [albums] in
            albums.compactMap { a in ArtCache.image("album:" + a.folder).map { (a.id, $0) } }
        }.value
        let fresh = quick.filter { artwork[$0.0] == nil }
        artwork.merge(fresh, uniquingKeysWith: { a, _ in a })
        unchecked.formUnion(fresh.map(\.0))
    }

    func loadArtwork() async {
        // all file reading and image decoding happens off the main thread (the files live on shares). Covers are
        // handed to the views in batches: one assignment per cover redrew everything thousands of times
        var batch = ArtBatch()
        // cached copies that still match their folder's cover file (quick), then whatever is missing from the files themselves
        let cached = await Task.detached { [albums] in
            albums.compactMap { a in ArtCache.albumImage(a.folder).map { (a.id, $0) } }
        }.value
        let checked = Set(cached.map(\.0))
        artwork.merge(cached.filter { artwork[$0.0] == nil || unchecked.contains($0.0) }, uniquingKeysWith: { _, new in new })
        let stale = unchecked.subtracting(checked)               // shown from the cache, but the folder's cover changed
        unchecked = []
        for a in albums where artwork[a.id] == nil || stale.contains(a.id) {
            var data = await LibraryLoader.artwork(for: a)
            let first = a.tracks[0].path
            if data == nil, subsonic.songs[first] != nil, !(await Task.detached { FileManager.default.fileExists(atPath: first) }.value) {
                data = await subsonic.cover(forPath: first)      // a server album not downloaded yet (checked off the main thread: the share)
            }
            if let d = data,
               let img = await Task.detached(operation: { ArtCache.storeAlbum(d, folder: a.folder) ?? NSImage(data: d) }).value {
                batch.albums[a.id] = img
                if batch.due { flush(&batch) }
            }
        }
        flush(&batch)
        // artists' photos after the covers: they're read from the shares one by one
        for ar in artists where artistArt[ar.id] == nil {
            if let img = await Task.detached(operation: { LibraryLoader.artistImage(ar).flatMap { NSImage(data: $0) } }).value {
                batch.artists[ar.id] = img
                if batch.due { flush(&batch) }
            }
        }
        flush(&batch)
        await loadPodArtwork()
    }

    /// Covers found but not shown yet: shown every 40 or half a second, whichever comes first.
    struct ArtBatch {
        var albums: [Album.ID: NSImage] = [:], artists: [Artist.ID: NSImage] = [:]
        var since = Date()
        var due: Bool { albums.count + artists.count >= 40 || Date().timeIntervalSince(since) > 0.5 }
    }
    func flush(_ b: inout ArtBatch) {
        if !b.albums.isEmpty { artwork.merge(b.albums, uniquingKeysWith: { _, new in new }) }
        if !b.artists.isEmpty { artistArt.merge(b.artists, uniquingKeysWith: { _, new in new }) }
        b = ArtBatch()
    }

    /// Covers for albums that only exist on the iPod: the art in its own files, else the iTunes catalogue.
    func loadPodArtwork() async {
        var batch = ArtBatch()
        defer { flush(&batch) }
        for a in podAlbums where isPodOnly(a) && artwork[a.id] == nil {
            let key = "pod:" + a.id
            if let img = await Task.detached(operation: { ArtCache.image(key) }).value { batch.albums[a.id] = img; if batch.due { flush(&batch) }; continue }
            var data: Data?
            if let ipod, connected, let first = a.tracks.first {
                var onPod = a; onPod.tracks = [first]
                onPod.tracks[0].path = ipod.mount.appendingPathComponent(first.path).path
                data = await LibraryLoader.artwork(for: onPod)
            }
            if data == nil {
                let am = AMAlbum(title: a.title, artist: a.artist, tracks: [])
                if let u = await AppleMusic.artworkURL(am), let (d, _) = try? await URLSession.shared.data(from: u) { data = d }
            }
            if let d = data, let img = await Task.detached(operation: { ArtCache.store(d, for: key) }).value { batch.albums[a.id] = img; if batch.due { flush(&batch) } }
        }
    }

    /// Reads these files' tags again after they were edited (the album may have a new name now).
    func refreshFiles(_ paths: [String], cover: Data? = nil, oldID: Album.ID? = nil, rescan: Bool = true) async {
        var fresh: [String: LibTrack] = [:]
        for p in paths {
            // a missing file would get its tags guessed from its path ("Subsonic/<album id>/<song id>"): keep what we had
            guard await Task.detached(operation: { FileManager.default.fileExists(atPath: p) }).value else { continue }
            let parts = p.split(separator: "/").suffix(3).joined(separator: "/")
            var t = await LibraryLoader.track(p, relative: parts)
            if let old = libTracks.first(where: { $0.path == p }) {
                t.uri = old.uri; t.added = old.added
                if old.key != t.key || old.artist != t.artist { followOnIPod(old, t) }
            }
            fresh[p] = t
        }
        libTracks = libTracks.map { fresh[$0.path] ?? $0 }
        let oldArt = oldID.flatMap { artwork[$0] }
        rebuild()
        if let newID = fresh.values.first?.album.lowercased() {
            let folder = albums.first { $0.id == newID }?.folder ?? ""
            if let d = cover, let img = ArtCache.storeAlbum(d, folder: folder) ?? NSImage(data: d) { artwork[newID] = img }
            else if artwork[newID] == nil { artwork[newID] = oldArt }
        }
        if rescan { await rescanServers() }
    }

    /// A song whose tags changed: its copy on the iPod gets the same title/album/artist at the next sync,
    /// so it stays one song instead of turning into an "only on iPod" leftover plus a new copy.
    func followOnIPod(_ old: LibTrack, _ new: LibTrack) {
        guard let db else { return }
        let podKey = retags.first { $0.value.key == old.key }?.key     // renamed before, not synced yet
            ?? aliases.first { $0.value == old.key }?.key
            ?? old.key
        guard db.tracks.contains(where: { $0.key == podKey }) else { return }
        let r = PodRetag(title: new.title, album: new.album, artist: new.artist)
        if aliases[podKey] != nil { aliases[podKey] = r.key; Store.save("matches.json", aliases) }
        retags[podKey] = r
    }

    /// Files the organiser moved: same songs, new paths (the iPod's copies are matched on tags, not paths).
    func moved(_ moves: [FileMove], rescan: Bool = true) async {
        let to = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        libTracks = libTracks.map { t in var n = t; if let p = to[t.path] { n.path = p }; return n }
        let art = artwork
        rebuild()
        artwork = art
        if rescan { await rescanServers() }
    }

    /// Adds freshly imported files without rescanning everything.
    func addToLibrary(_ tracks: [LibTrack]) async {
        libTracks += tracks
        rebuild()
        await rescanServers()
        await loadArtwork()
    }

    /// Asks OwnTone and the Subsonic server (the ones switched on) to rescan, after files changed in their folder.
    func rescanServers() async {
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
        if on(.subsonic) { await subsonic.startScan() }
    }

    /// Artwork paths are relative to OwnTone, Spotify's and Subsonic's are full URLs.
    func artURL(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        guard !path.isEmpty else { return nil }
        return URL(string: ownToneURL + (path.hasPrefix("/") ? "" : "/") + path.replacingOccurrences(of: "./", with: ""))
    }

}
