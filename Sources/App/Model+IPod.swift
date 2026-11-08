import SwiftUI
import AppKit

extension Model {
    // MARK: iPod

    enum State { case none, partial, onIPod }
    func state(_ a: Album) -> State {
        let keys = podKeys
        let n = a.tracks.filter { keys.contains($0.key) }.count
        return n == 0 ? .none : n == a.tracks.count ? .onIPod : .partial
    }

    var podName: String { pendingName ?? db?.name ?? "iPod" }

    /// The sidebar, toolbar, menu bar and iPod page all show these several times per redraw, and covers loading
    /// redraw once per album: worked out once and kept until something they depend on changes (hiddenCache's
    /// inputs, the queue, playlists, smart playlists, file sizes).
    var pendingCount: Int {
        if let c = syncCache.pending { return c }
        let n = pendingCountNow
        syncCache.pending = n
        return n
    }
    func invalidateSyncCache() { syncCache = (nil, nil); syncVersion += 1 }

    var pendingCountNow: Int {
        toAdd.count + toRemove.count + songsToAdd.count + songsToRemove.count + playlistsToAdd.count + playlistsToRemove.count
            + podSavedLists.count + (pendingName == nil ? 0 : 1) + smartPending + retags.count + hidePending
            + cratePlaylists.filter(crateNeedsSync).count + podEditsPending
    }

    var usedFraction: Double {
        guard let i = ipod, i.capacity > 0 else { return 0 }
        return Double(i.used) / Double(i.capacity)
    }

    var musicBytes: Int64 { Int64((db?.tracks ?? []).map(\.size).reduce(0, +)) }

    enum DBRead { case ok(ITunesDB), missing, failed(String) }

    /// Reads the iPod's database, telling "not there" (a new iPod) apart from "can't be read".
    nonisolated static func readDB(_ url: URL) -> DBRead {
        do {
            let d = try Data(contentsOf: url)
            do { return .ok(try ITunesDB.read(d)) } catch { return .failed("the database is damaged") }
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            return .missing
        } catch {
            let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
            return .failed("the disk reported: \(posix ?? error.localizedDescription)")
        }
    }

    /// Finds the iPod; when it's unplugged, the last one seen is shown from the cache (read only).
    /// Looks for the iPod (and reads it) in the background; see loadIPodNow.
    func loadIPod() { Task { await loadIPodNow() } }

    /// What finding and reading the iPod (or the copy from last time) turned up; worked out off the main thread.
    enum PodLoad {
        case connected(IPodInfo, DBRead, plays: [PlayCounts.Entry]?, cached: ITunesDB?, otg: [OnTheGo], history: [PodSample])
        case cached(PodCache, ITunesDB?, history: [PodSample])
        case none
    }

    /// Finds the iPod, reads its database, Play Counts and On-The-Go lists off the main thread (USB disk,
    /// mounted volumes), then shows them. When several run at once (mounts come in bursts) the last one wins.
    func loadIPodNow() async {
        guard !syncing else { return }      // a sync reads the iPod itself and loads it again when done
        podLoads += 1
        let mine = podLoads
        let found = await Task.detached { () -> PodLoad in
            if let i = IPodInfo.find() {
                DiskRepair.keepSpotlightOff(i.mount)
                let read = Model.readDB(i.dbURL)
                var plays: [PlayCounts.Entry]?, cached: ITunesDB?, parsed: ITunesDB
                switch read {
                case .ok(let d): plays = (try? Data(contentsOf: PlayCounts.url(i))).flatMap(PlayCounts.parse); PodCache.saveDB(from: i); parsed = d
                case .missing: parsed = .empty(name: i.mount.lastPathComponent)      // a fresh iPod: start a database
                case .failed: cached = PodCache.loadDB(); parsed = cached ?? .empty(name: i.mount.lastPathComponent)
                }
                PodHistory.record(i, db: parsed)
                return .connected(i, read, plays: plays, cached: cached, otg: OnTheGo.load(i, db: parsed), history: PodHistory.load(i.key))
            }
            if let c = PodCache.load() { return .cached(c, PodCache.loadDB(), history: PodHistory.load(c.info.key)) }
            return .none
        }.value
        guard mine == podLoads else { return }
        let wasConnected = connected, had = ipod?.key
        switch found {
        case let .connected(i, read, plays, cached, otg, hist):
            ipod = i; connected = true; lastSeen = nil
            podReadError = nil
            switch read {
            case .ok(let parsed): unmergedPlays = plays; db = parsed
            case .missing: db = .empty(name: i.mount.lastPathComponent)
            case .failed(let why):
                podReadError = why
                db = cached ?? .empty(name: i.mount.lastPathComponent)
            }
            onTheGo = otg
            if !loading { Task { await loadPodArtwork() } }
            Task { await refreshBackup() }
            history = hist
            refreshSmartPending()
        case let .cached(c, cachedDB, hist):
            ipod = c.info; connected = false; lastSeen = c.seen
            history = hist
            db = cachedDB ?? db; onTheGo = []; orphans = nil
        case .none:
            ipod = nil; db = nil; connected = false; onTheGo = []; orphans = nil
            return
        }
        guard let i = ipod else { return }
        if had != i.key {
            podSettings = PodSettings.load(i.key); orphans = nil
            restorePending()
        }
        savePending()
        if connected, !wasConnected, had != nil || lastSeenAtLaunch, podSettings.syncOnConnect, pendingCount > 0, !syncing, podReadError == nil {
            notify("\(podName) connected – syncing \(pendingCount) queued changes")
            reviewSync()
            Task { await sync() }
        }
        lastSeenAtLaunch = true
    }

    /// Saves the queue a moment after the last change (clicking through albums shouldn't wait on disk writes).
    func savePending() {
        invalidateSyncCache()
        guard !restoring, ipod != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard let self, !Task.isCancelled, let i = self.ipod else { return }
            let seen = self.connected ? Date() : (self.lastSeen ?? Date())
            let c = PodCache(info: i, seen: seen, toAdd: self.toAdd.sorted(), toRemove: self.toRemove.sorted(),
                             playlistsToAdd: self.playlistsToAdd.sorted(), playlistsToRemove: self.playlistsToRemove.sorted(),
                             pendingName: self.pendingName, songsToAdd: self.songsToAdd.sorted(), songsToRemove: self.songsToRemove.sorted())
            Task.detached { c.save() }
        }
    }

    func restorePending() {
        guard let c = PodCache.load(), c.info.key == ipod?.key else { return }
        restoring = true; defer { restoring = false }
        toAdd = Set(c.toAdd); toRemove = Set(c.toRemove)
        songsToAdd = Set(c.songsToAdd ?? []); songsToRemove = Set(c.songsToRemove ?? [])
        playlistsToAdd = Set(c.playlistsToAdd); playlistsToRemove = Set(c.playlistsToRemove)
        pendingName = c.pendingName
    }

    func addAll(_ a: Artist) { for al in a.albums where !isPodOnly(al) && state(al) != .onIPod { toAdd.insert(al.id) } }
    func removeAll(_ a: Artist) { for al in a.albums where state(al) != .none { toRemove.insert(al.id) } }

    func toggleAdd(_ p: OTPlaylist) {
        if playlistsToAdd.contains(p.id) { playlistsToAdd.remove(p.id) } else { playlistsToAdd.insert(p.id) }
    }
    func toggleRemove(_ p: PodPlaylist) {
        if playlistsToRemove.contains(p.id) { playlistsToRemove.remove(p.id) } else { playlistsToRemove.insert(p.id) }
    }
    func toggleAdd(_ a: Album) {
        if toAdd.contains(a.id) { toAdd.remove(a.id) } else if state(a) != .onIPod { toAdd.insert(a.id) }
    }
    func toggleRemove(_ a: Album) {
        if toRemove.contains(a.id) { toRemove.remove(a.id) } else { toRemove.insert(a.id) }
    }

    /// The album that ⌘I, ⌘Y and friends act on: the open album page, else Cover Flow's middle one.
    var focusAlbum: Album? {
        if case .album(let a)? = path.last { return albums.first { $0.id == a.id } ?? a }
        return pane == .albums && search.isEmpty ? flowAlbum : nil
    }

    /// Goes to an album's page, unless it's already showing.
    /// The same recording whatever album name it's under: artist, title, disc and track (lengths are compared
    /// apart, within 3 s: the server and the file's own tags round them differently).
    nonisolated static func songIdentity(_ t: LibTrack) -> String {
        [Dedupe.loose(t.trackArtist.isEmpty ? t.artist : t.trackArtist), Dedupe.loose(t.title), "\(t.discNumber)", "\(t.trackNumber)"]
            .joined(separator: "|")
    }

    func showAlbumPage(_ a: Album?) {
        guard let a else { return }
        if case .album(let shown)? = path.last, shown.id == a.id { return }
        search = ""
        path.append(.album(a))
    }

    /// A song's album page when the album isn't in the library: the saved Spotify album, else the artist's
    /// MusicBrainz release (whose page finds it on Spotify); nil when neither knows it.
    func outsideAlbum(_ title: String, artist: String) async -> Route? {
        let t = Release.loose(title), a = artist.lowercased()
        guard !t.isEmpty else { return nil }
        if on(.spotify), let s = spotify.first(where: { Release.loose($0.name) == t && $0.artist.lowercased() == a })
            ?? spotify.first(where: { Release.loose($0.name) == t }) { return .spotifyAlbum(s) }
        await loadArtistInfo(artist)
        if let g = artistInfo[a]?.releases.first(where: { Release.loose($0.title) == t }) { return .release(g, artist: artist) }
        return nil
    }

    /// An album on its artist's page, for Model.highlight: the page's releases go by title.
    static func releaseHighlight(_ title: String) -> String { "release:" + Release.loose(title) }

    /// Shows an album's cover in Quick Look (the cover file, or the embedded art saved to a temp file).
    /// An album's cover as image data: its cover file, else the artwork Crate shows for it.
    func coverData(_ a: Album) async -> Data? {
        let folder = a.folder, img = artwork[a.id]
        return await offMain {
            if let d = Model.coverFile(in: folder).flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) { return d }
            guard let tiff = img?.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
    }

    /// The album folder's cover image file, the one readers pick first.
    nonisolated static func coverFile(in folder: String) -> String? {
        ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "front.jpg"].lazy.map { folder + "/" + $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Makes `data` the folder's cover.jpg; the other cover images get .old, as some readers would still pick them first.
    nonisolated static func writeCover(_ data: Data, in folder: String) async -> Bool {
        await offMain {
            let fm = FileManager.default
            for n in ["folder.jpg", "cover.png", "folder.png", "front.jpg"] where fm.fileExists(atPath: folder + "/" + n) {
                try? fm.moveItem(atPath: folder + "/" + n, toPath: folder + "/" + n + ".old")
            }
            try? fm.removeItem(atPath: folder + "/cover.jpg")
            return fm.createFile(atPath: folder + "/cover.jpg", contents: data)
        }
    }

    func quickLookCover(_ a: Album) async {
        let folder = a.folder, img = artwork[a.id], name = Organizer.clean(a.title)
        let url = await offMain { () -> URL? in
            if let p = Model.coverFile(in: folder) { return URL(fileURLWithPath: p) }
            guard let tiff = img?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
            try? png.write(to: url)
            return url
        }
        if let url { quickLook = url }
    }

    func deleteSmart(_ p: SmartPlaylist) {
        smartPlaylists.removeAll { $0.id == p.id }
        saveSmart()
        if pane == .smart(p.id) { pane = .albums }
    }

    func discardChanges() {
        toAdd = []; toRemove = []; songsToAdd = []; songsToRemove = []; playlistsToAdd = []; playlistsToRemove = []; pendingName = nil
    }

    func scanOrphans() async {
        guard let ipod, let db, connected else { return }
        let c = await offMain { Syncer.check(ipod, db: db) }
        let stray = c.stray
        strayBytes = await offMain {
            Int64(stray.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int }.reduce(0, +))
        }
        podCheck = c; orphans = c.stray
    }

    /// Takes songs whose file is gone out of the iPod's database (read fresh, written right away).
    func removeMissing() async {
        guard let ipod, connected, let gone = podCheck?.missing, !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        let said = await offMain { () -> String? in
            guard var fresh = (try? Data(contentsOf: ipod.dbURL)).flatMap({ try? ITunesDB.read($0) }) else { return nil }
            fresh.tracks.removeAll { ids.contains($0.id) }
            do { try Syncer.write(fresh, to: ipod); return "Removed \(gone.count) songs without a file from the iPod's list" }
            catch { return "Writing the database failed: \(error.localizedDescription)" }
        }
        guard let said else { return }
        notify(said)
        podCheck?.missing = []
        loadIPod()
    }

    func deleteOrphans() async {
        let gone = orphans ?? []
        await offMain { gone.forEach { try? FileManager.default.removeItem(at: $0) } }
        orphans = []; strayBytes = 0
        loadIPod()
        notify("Removed \(gone.count) stray files from the iPod")
    }

    var hasBackup: Bool { connected && backupOnPod }

    func refreshBackup() async {
        guard let p = ipod?.backupURL.path else { backupOnPod = false; return }
        backupOnPod = await offMain { FileManager.default.fileExists(atPath: p) }
    }

    /// Puts iTunesDB.crate-backup back (the database from before the last Crate write).
    func restoreBackup() async {
        guard let i = ipod, connected else { return }
        let failed = await offMain { () -> String? in
            do {
                _ = try ITunesDB.read(Data(contentsOf: i.backupURL))
                let tmp = i.dbURL.appendingPathExtension("restore")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: i.backupURL, to: tmp)
                _ = try FileManager.default.replaceItemAt(i.dbURL, withItemAt: tmp)
                return nil
            } catch { return error.localizedDescription }
        }
        if let failed { notify("Restore failed: \(failed)"); return }
        loadIPod()
        notify("Restored the previous iPod database")
    }
}
