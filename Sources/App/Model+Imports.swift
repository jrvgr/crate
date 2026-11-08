import SwiftUI
import AppKit

extension Model {
    // MARK: imports

    /// Copies audio files into the import folder and adds them to the library; optionally queues them.
    @discardableResult
    func importFiles(_ urls: [URL], toIPod: Bool, job: UUID? = nil, title: String = "Importing", move: Bool = false) async -> Set<Album.ID> {
        let job = job ?? startJob(title, icon: "square.and.arrow.down")
        let root = importRoot
        guard !root.isEmpty else { finishJob(job, "Choose a folder to import into in Settings › Library"); return [] }
        updateJob(job) { $0.state = .running; $0.detail = "Copying into \((root as NSString).lastPathComponent)" }
        do {
            let r = try await Importer.run(urls, into: root, move: move)
            guard !r.tracks.isEmpty else {
                finishJob(job, r.skipped > 0 ? "Already in the library (\(r.skipped) files)" : "No audio files found")
                return []
            }
            await addToLibrary(r.tracks)
            let ids = Set(r.tracks.map { $0.album.lowercased() })
            if toIPod { for a in albums where ids.contains(a.id) && state(a) != .onIPod { toAdd.insert(a.id) } }
            finishJob(job, "\(r.tracks.count) files in \(ids.count) album\(ids.count == 1 ? "" : "s")"
                + (r.skipped > 0 ? ", \(r.skipped) already there" : "") + (toIPod ? ", queued for the iPod" : ""))
            return ids
        } catch {
            finishJob(job, "Import failed: \(error.localizedDescription)", failed: true)
            return []
        }
    }

    /// Copies albums from the iPod into the library (for music that only lives on the iPod).
    func copyFromIPod(_ albums: [Album]) async {
        guard let ipod, connected, let db else { notify("Connect the iPod to copy from it"); return }
        let keys = Set(albums.flatMap { $0.tracks.map(\.key) })
        // with renames waiting for the next sync applied, as podAlbums has them
        let songs = db.tracks.map { t in
            var t = t
            if let r = retags[t.key] { t.title = r.title; t.album = r.album; t.artist = r.artist; if let aa = r.albumArtist { t.albumArtist = aa } }
            return t
        }.filter { keys.contains($0.key) }
        guard !songs.isEmpty else { notify("None of those songs are on the iPod's list"); return }
        let job = startJob(albums.count == 1 ? "Copying \(albums[0].title) from the iPod" : "Copying \(albums.count) albums from the iPod", icon: "ipod")
        // Files Crate converted for the iPod carry no tags of their own (the iPod's list has them), so the
        // copies are named, filed and tagged from the list, not from the files.
        var copied: [LibTrack] = [], skipped = 0, failed: [String] = []
        let root = importRoot, mount = ipod.mount
        for (n, t) in songs.enumerated() {
            updateJob(job) { $0.detail = "\(n + 1) of \(songs.count): \(t.title)" }
            let r = await Task.detached { () -> Result<LibTrack?, Error> in
                do { return .success(try Self.copyOut(t, from: mount, into: root)) } catch { return .failure(error) }
            }.value
            switch r {
            case .success(let lt?): copied.append(lt)
            case .success(nil): skipped += 1
            case .failure(let e): failed.append("\(t.title): \(e.localizedDescription)")
            }
        }
        await addToLibrary(copied)
        finishJob(job, "\(copied.count) songs copied to the library" + (skipped > 0 ? ", \(skipped) already there" : "")
                  + (failed.isEmpty ? "" : ", \(failed.count) failed (\(failed[0]))"), failed: copied.isEmpty && !failed.isEmpty)
    }

    /// Copies one iPod song to <root>/<album artist>/<album>/<NN title>.ext and writes the iPod's tags
    /// into it; nil when that file is already there.
    nonisolated static func copyOut(_ t: PodTrack, from mount: URL, into root: String) throws -> LibTrack? {
        let fm = FileManager.default
        let src = mount.appendingPathComponent(t.relativePath).path
        let artist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
        let ext = (src as NSString).pathExtension
        let dir = root + "/" + Importer.safe(artist.isEmpty ? "Unknown Artist" : artist) + "/" + Importer.safe(t.album.isEmpty ? "Unknown Album" : t.album)
        let dst = dir + "/" + (t.trackNumber > 0 ? String(format: "%02d ", t.trackNumber) : "") + Importer.safe(t.title) + "." + ext
        if fm.fileExists(atPath: dst) { return nil }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fm.copyItem(atPath: src, toPath: dst)
        let some = { (s: String) in s.isEmpty ? nil : s }
        if TagWriter.canWrite(dst) {
            try? TagWriter.write(dst, TagEdit(title: some(t.title), artist: some(t.artist), albumArtist: some(artist), album: some(t.album),
                                              genre: some(t.genre), track: t.trackNumber > 0 ? t.trackNumber : nil))
        }
        return LibTrack(title: t.title, artist: artist, album: t.album, genre: t.genre, trackNumber: t.trackNumber, discNumber: 0,
                        year: 0, lengthMs: t.lengthMs, path: dst, trackArtist: t.artist == artist ? "" : t.artist, added: Date())
    }

    var podOnlyAlbums: [Album] { podAlbums.filter(isPodOnly) }

    /// Where a remote playlist comes from (a sidebar group of its own).
    func source(of p: OTPlaylist) -> String { p.spotifyID != nil ? "Spotify" : p.subsonicID != nil ? "Subsonic" : "OwnTone" }
    var remoteSources: [String] { ["Spotify", "OwnTone", "Subsonic"].filter { s in playlists.contains { source(of: $0) == s } } }

    /// Where a playlist on the iPod came from.
    enum PodOrigin { case spotify, ownTone, subsonic, smart, crate, onTheGo, ipod
        var icon: String {
            switch self {
            case .spotify: return "dot.radiowaves.left.and.right"
            case .ownTone: return "hifispeaker"
            case .subsonic: return "server.rack"
            case .smart: return "gearshape.2"
            case .crate: return "music.note.list"
            case .onTheGo: return "hand.tap"
            case .ipod: return "ipod"
            }
        }
        var help: String {
            switch self {
            case .spotify: return "Copied from a Spotify playlist"
            case .ownTone: return "Copied from an OwnTone playlist"
            case .subsonic: return "Copied from a Subsonic playlist"
            case .smart: return "Kept up to date from a smart playlist"
            case .crate: return "Kept up to date from a playlist in Crate"
            case .onTheGo: return "Made on the iPod (On-The-Go)"
            case .ipod: return "Only on the iPod"
            }
        }
    }
    func origin(of p: PodPlaylist) -> PodOrigin {
        if smartPlaylists.contains(where: { $0.name == p.name }) { return .smart }
        if cratePlaylists.contains(where: { $0.podID == p.id || $0.name == p.name }) { return .crate }
        if let r = playlists.first(where: { $0.name == p.name }) { return r.spotifyID != nil ? .spotify : r.subsonicID != nil ? .subsonic : .ownTone }
        return p.name.hasPrefix("On-The-Go") ? .onTheGo : .ipod
    }

    /// Drag and drop onto the window (library) or the iPod card (library + queue).
    func importDropped(_ urls: [URL], toIPod: Bool) async {
        let roots = libraryRoots
        let known = urls.filter { u in Organizer.root(of: u.path, roots: roots) != nil }
        if !known.isEmpty, known.count == urls.count {
            if toIPod {      // already in the library: just queue those albums
                let ids = Set(libTracks.filter { t in known.contains { t.path.hasPrefix($0.path) } }.map { $0.album.lowercased() })
                for a in albums where ids.contains(a.id) && state(a) != .onIPod { toAdd.insert(a.id) }
                notify("Queued \(ids.count) album\(ids.count == 1 ? "" : "s") for the iPod")
            }
            return
        }
        let ids = await importFiles(urls, toIPod: toIPod, title: "Importing dropped files")
        if let a = albums.first(where: { ids.contains($0.id) }) {
            notify("Added \(ids.count == 1 ? a.title : "\(ids.count) albums") to the library" + (toIPod ? " and the iPod queue" : ""))
        }
    }

    /// A finished Soulseek download: copy its folder into the library.
    func importDownloaded(_ job: SlskJob, folder: String) async {
        guard !slsk.downloadsFolder.isEmpty else { notify("Set slskd's downloads folder in Settings › Plugins › Soulseek to import downloads"); return }
        guard await offMain({ FileManager.default.fileExists(atPath: folder) }) else {
            notify("Can't find \(folder) – is the share with slskd's downloads mounted?")
            return
        }
        await importFiles([URL(fileURLWithPath: folder)], toIPod: false, title: "Importing \(job.name)", move: true)
    }
}
