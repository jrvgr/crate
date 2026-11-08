import SwiftUI
import AppKit

extension Model {
    // MARK: metadata

    /// Stores a metadata match: year/genre into the files' tags, the cover next to the files.
    /// `step` reports each stage to the lookup dialog; returns a one-line summary.
    func apply(_ release: MBRelease, to album: Album, replaceCover: Bool, coverOnly: Bool = false, step: (String) -> Void) async -> String {
        if coverOnly { return await saveCover(release, to: album, replace: true, step: step) ?? "No cover found" }
        step("Fetching details from \(release.source)")
        let r = release.source == "MusicBrainz" ? await MusicBrainz.details(release) : release
        metadata[album.id] = r
        MetadataStore.save(metadata)
        var parts = ["Saved " + [r.year > 0 ? "\(r.year)" : "", r.genre].filter { !$0.isEmpty }.joined(separator: ", ")]
        step("Writing year and genre into \(album.tracks.count) files")
        let written = await writeTags(album, year: r.year, genre: r.genre)
        if written.files > 0 { parts.append("tags written to \(written.files) files") }
        if let e = written.error { parts.append(e) }
        if let c = await saveCover(r, to: album, replace: replaceCover, step: step) { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// Uses an image you dropped on an album's cover as its cover.jpg.
    func setCover(_ data: Data, for album: Album) async {
        guard let img = NSImage(data: data), !isPodOnly(album) else { notify("That isn't an image"); return }
        let folder = album.folder
        guard filesHere(album) else {           // only on the Subsonic server: embedded through Tagr, else shown in Crate only
            artwork[album.id] = img
            guard viaTagr else { notify("New cover for \(album.title), shown in Crate only (the album is only on the Subsonic server)"); return }
            let r = await saveTags(album.tracks.map { (path: $0.path, edit: TagEdit(cover: data)) })
            notify(r.failures.isEmpty ? "New cover for \(album.title)" : "New cover for \(album.title); \(r.failures.count) songs failed: \(r.failures[0])")
            return
        }
        guard await Self.writeCover(data, in: folder) else { notify("Couldn't write cover.jpg in \(folder)"); return }
        artwork[album.id] = await offMain { ArtCache.storeAlbum(data, folder: folder) ?? NSImage(data: data) }
        await rescanServers()
        notify("New cover for \(album.title)")
    }

    /// Saves the release's cover as cover.jpg (replacing folder.jpg/cover.png too, so it wins).
    func saveCover(_ r: MBRelease, to album: Album, replace: Bool, step: (String) -> Void) async -> String? {
        let folder = album.folder
        let names = ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "front.jpg"]
        let existing = await offMain { names.filter { FileManager.default.fileExists(atPath: folder + "/" + $0) } }
        guard existing.isEmpty || replace else { return nil }
        step("Downloading the cover")
        var coverData = r.source == "MusicBrainz" ? await MusicBrainz.cover(r.id)
            : (try? await URLSession.shared.data(from: URL(string: r.cover) ?? MusicBrainz.coverURL(r.id)))?.0
        if coverData == nil {     // MusicBrainz often has no picture for singles: the iTunes Store's, when it's the same release
            step("No cover on \(r.source); trying the iTunes Store")
            let hits = (try? await ITunesLookup.search(album: r.title, artist: r.artist)) ?? []
            if let hit = hits.first(where: { Self.looseMatch($0.title, r.title) }), let u = URL(string: hit.cover) {
                coverData = (try? await URLSession.shared.data(from: u))?.0
            }
        }
        guard let d = coverData, let img = NSImage(data: d) else { return "no cover found" }
        // shown right away, whether or not the file can be written
        artwork[album.id] = await offMain { ArtCache.storeAlbum(d, folder: folder) } ?? img
        guard !isPodOnly(album) else { return nil }
        // songs that are only on the server (not on the share, not downloaded) have no folder here to put it in
        let isDir = await offMain { () -> Bool in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &dir) && dir.boolValue
        }
        guard isDir else { return "cover shown in Crate (the files are only on the server)" }
        guard await Self.writeCover(d, in: folder) else { return "couldn't write cover.jpg (shown in Crate only)" }
        await offMain { _ = ArtCache.storeAlbum(d, folder: folder) }     // again, now that the folder's cover.jpg is this one
        if on(.ownTone) || on(.subsonic) { step("Asking the server to rescan"); await rescanServers() }
        return existing.isEmpty ? "cover saved" : "cover replaced"
    }

    /// Writes year/genre into the album's FLAC and MP3 files (off the main thread).
    func writeTags(_ album: Album, year: Int, genre: String) async -> (files: Int, error: String?) {
        let all = album.tracks.map(\.path)
        let paths = await offMain { all.filter { TagWriter.canWrite($0) && FileManager.default.fileExists(atPath: $0) } }
        guard year > 0 || !genre.isEmpty else { return (0, nil) }
        // the Subsonic server's songs that aren't here: through Tagr
        let remote = viaTagr ? album.tracks.map(\.path).filter(Subsonic.serverOnly) : []
        if !remote.isEmpty {
            let r = await saveTags(remote.map { ($0, TagEdit(genre: genre.isEmpty ? nil : genre, year: year > 0 ? year : nil)) })
            if paths.isEmpty { return (r.written.count, r.failures.first) }
        }
        guard !paths.isEmpty else { return (0, nil) }
        let result = await Task.detached { () -> (Int, String?) in
            var n = 0, err: String?
            for p in paths {
                do { if try TagWriter.write(p, year: year, genre: genre) { n += 1 } }
                catch { err = err ?? error.localizedDescription }
            }
            return (n, err)
        }.value
        if result.0 > 0 { await rescanServers() }
        return result
    }
}

// MARK: writing tags: here or through Tagr

extension Model {
    /// Tagr writes tags for the Subsonic server's songs that aren't on a share here.
    var viaTagr: Bool { on(.subsonic) && tagr.enabled && tagr.configured }

    /// Whether the album's tags can be changed: its files are here, or Tagr writes them on the server.
    func tagsEditable(_ a: Album) -> Bool { filesHere(a) || (!isPodOnly(a) && viaTagr) }

    /// Writes tag edits: files on this Mac directly, the Subsonic server's songs through Tagr (then the server
    /// is asked to rescan, and Crate's copy of those songs shows the new tags right away). The paths written,
    /// and what failed.
    func saveTags(_ edits: [(path: String, edit: TagEdit)], each: (() -> Void)? = nil) async -> (written: [String], failures: [String]) {
        var written: [String] = [], failures: [String] = []
        tagr.forget()
        for (p, e) in edits {
            defer { each?() }
            let name = libraryTrack(path: p)?.track.title ?? (p as NSString).lastPathComponent
            if Subsonic.serverOnly(p) {
                guard viaTagr, let t = libraryTrack(path: p)?.track, let s = subsonic.songs[p] else {
                    failures.append("\(name): only on the Subsonic server"); continue
                }
                do {
                    let song = try await tagr.find(t, serverPath: subsonic.relativePath(s))
                    try await tagr.update(song.id, e)
                    written.append(p)
                } catch { failures.append("\(name): \(error.localizedDescription)") }
            } else {
                guard TagWriter.canWrite(p) else { continue }
                let err = await offMain { () -> String? in
                    do { _ = try TagWriter.write(p, e); return nil } catch { return error.localizedDescription }
                }
                if let err { failures.append("\(name): \(err)") } else { written.append(p) }
            }
        }
        let remote = Set(written.filter(Subsonic.serverOnly))
        if !remote.isEmpty {
            let byPath = Dictionary(edits.map { ($0.path, $0.edit) }, uniquingKeysWith: { _, b in b })
            for i in libTracks.indices where remote.contains(libTracks[i].path) {
                let e = byPath[libTracks[i].path]!
                if let v = e.title { libTracks[i].title = v }
                if let v = e.artist { libTracks[i].trackArtist = v }
                if let v = e.albumArtist { libTracks[i].artist = v }
                if let v = e.album { libTracks[i].album = v }
                if let v = e.genre { libTracks[i].genre = v }
                if let v = e.year { libTracks[i].year = v }
                if let v = e.track { libTracks[i].trackNumber = v }
                if let v = e.disc { libTracks[i].discNumber = v }
            }
            rebuild()
            Task { await rescanServers() }
        }
        return (written, failures)
    }
}
