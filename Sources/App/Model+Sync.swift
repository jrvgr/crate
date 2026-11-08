import SwiftUI
import AppKit

extension Model {
    // MARK: sync

    /// Opens the sync sheet with what will happen.
    func reviewSync() {
        report = nil
        plan = makePlan()
        showSync = true
        brokenFiles = [:]
        Task { await estimateSizes() }
        Task { await checkQueuedFiles() }
    }

    /// Per album, the songs the next sync adds and removes (for the sync sheet's preview).
    func syncPreview() -> [(album: String, artist: String, add: [String], remove: [String])] {
        var out: [String: (album: String, artist: String, add: [String], remove: [String])] = [:]
        for (a, t) in addWork(have: podKeys) { out[a.id, default: (a.title, a.artist, [], [])].add.append(t.title) }
        let keys = removalKeys
        for t in (db?.tracks ?? []) where keys.contains(t.key) {
            out[t.album.lowercased(), default: (t.album, t.artist, [], [])].remove.append(t.title)
        }
        return out.values.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
    }

    func syncWork() -> [(Album, LibTrack)] { addWork(have: podKeys) }

    func addWork(have: Set<String>) -> [(Album, LibTrack)] {
        var work = albums.filter { toAdd.contains($0.id) }.flatMap { a in a.tracks.filter { !have.contains($0.key) }.map { (a, $0) } }
        let queued = Set(work.map(\.1.path))
        for a in albums { for t in a.tracks where songsToAdd.contains(t.path) && !queued.contains(t.path) && !have.contains(t.key) { work.append((a, t)) } }
        return work
    }

    /// Keys of the iPod songs that go on the next sync (whole albums and single songs).
    var removalKeys: Set<String> { Set(podAlbums.filter { toRemove.contains($0.id) }.flatMap { $0.tracks.map(\.key) }).union(songsToRemove) }

    func makePlan() -> SyncPlan {
        var p = SyncPlan()
        let have = podKeys
        p.addAlbums = albums.filter { toAdd.contains($0.id) }
        let work = addWork(have: have)
        p.addSongs = work.count
        p.convertSongs = work.filter { podSettings.needsConversion($0.1) }.count
        p.removeAlbums = podAlbums.filter { toRemove.contains($0.id) }
        let removeKeys = removalKeys
        p.removeSongs = (db?.tracks ?? []).filter { removeKeys.contains($0.key) }.count
        p.bytesOut = Int64((db?.tracks ?? []).filter { removeKeys.contains($0.key) }.map(\.size).reduce(0, +))
        p.playlistsAdd = playlists.filter { playlistsToAdd.contains($0.id) }.map(\.name) + smartPlaylists.filter(smartNeedsSync).map(\.name)
        let smartWork = smartPlaylists.filter(\.onIPod).flatMap(evaluate).filter { !have.contains($0.key) }
        p.addSongs += Set(smartWork.map(\.path)).subtracting(work.map(\.1.path)).count
        p.playlistsAdd += cratePlaylists.filter(crateNeedsSync).map(\.name)
        let crateWork = cratePlaylists.filter(\.onIPod).flatMap(songs).filter { !have.contains($0.key) }
        p.addSongs += Set(crateWork.map(\.path)).subtracting(work.map(\.1.path)).subtracting(smartWork.map(\.path)).count
        p.playlistsRemove = (db?.playlists ?? []).filter { playlistsToRemove.contains($0.id) }.map(\.name)
        p.playlistsEdit = (db?.playlists ?? []).compactMap { pl in
            podEdits[pl.id].map { e in e.name.map { "\(pl.name) → \($0)" } ?? pl.name }
        }
        p.onTheGo = podSavedLists.count
        p.rename = pendingName
        p.retag = (db?.tracks ?? []).filter { retags[$0.key] != nil }.count
        let rule = ruleHidden(db?.playlists ?? [])
        p.hide = (db?.tracks ?? []).filter { !$0.hidden && wantsHidden($0.key, rule) }.count
        p.unhide = (db?.tracks ?? []).filter { $0.hidden && !wantsHidden($0.key, rule) }.count
        p.markPlaylists = (db?.playlists ?? []).filter { $0.name != podName(forPlaylist: $0.name) }.map { "\($0.name) → \(podName(forPlaylist: $0.name))" }
        return p
    }

    func sync() async {
        guard let ipod, let known = db, connected, !syncing else { return }
        syncing = true; report = nil
        // at launch the library shown may still be last time's: sync against the one the scan finds
        while loading { try? await Task.sleep(for: .milliseconds(250)) }
        // Start from what's on the iPod right now, not what Crate read earlier: anything another app
        // (or the iPod itself) changed in the meantime is kept, and only the queued changes are applied.
        // Only a database that truly isn't there yet starts from what Crate knows; one that can't be
        // read (I/O error) stops the sync, or an empty database would be written over the real one.
        let current: ITunesDB?
        switch await Task.detached(operation: { Model.readDB(ipod.dbURL) }).value {
        case .ok(let d): current = d
        case .missing: current = known.tracks.isEmpty ? known : nil
        case .failed(let why): current = nil; podReadError = why
        }
        guard var db = current else {
            report = SyncReport(error: "Couldn't read the iPod's database (\(podReadError ?? "it's missing")); nothing was changed")
            syncing = false
            return
        }
        let before = Set(known.tracks.map(\.key)), now = Set(db.tracks.map(\.key))
        let elsewhere = before.symmetricDifference(now).count
            + Set(known.playlists.map(\.name)).symmetricDifference(Set(db.playlists.map(\.name))).count
        var playCountsMerged = false
        let start = Date()
        var rep = SyncReport()
        defer {
            rep.seconds = Date().timeIntervalSince(start)
            report = rep; syncing = false; syncCurrent = ""
            loadIPod()
            if rep.error == nil, podSettings.ejectAfterSync, connected { eject() }
        }
        syncPhase = "Preparing"; syncDone = 0; syncTotal = 0
        rep.changedElsewhere = elsewhere
        var plays: [(track: LibTrack, time: Date)] = []      // for the Subsonic server, once they're safely in the database
        if let entries = await Task.detached(operation: { (try? Data(contentsOf: PlayCounts.url(ipod))).flatMap(PlayCounts.parse) }).value {
            if on(.subsonic) { plays = scrobbles(entries, db) }
            if let n = db.mergePlayCounts(entries) { rep.playCounts = n; playCountsMerged = true } else { plays = [] }
        }
        if let n = pendingName, !n.isEmpty { db.name = n }
        // what the iPod saved, read again against this database (its playlists still as the iPod knows them)
        let otg = OnTheGo.load(ipod, db: db).filter { $0.kind != .onTheGo || podSettings.importOnTheGo }
        keepFromPod(otg, in: &db)
        rep.playlists += otg.count
        let podHides = PodHides.load(ipod, db: db)      // songs hidden or shown on the iPod become your hide choice
        for (k, v) in PodHides.choices(podHides, db: db) { hides[k] = v }
        let podSkips = PodSkips.load(ipod, db: db).map { (db.tracks[$0.index].key, $0) }     // added once the database is written
        let podMarks = PodBookmarks.load(ipod, db: db)      // Resume Mixes positions, into the records (where Play Counts had none)
        PodBookmarks.apply(podMarks, to: &db, playCountsMerged: playCountsMerged)
        db.playlists.removeAll { playlistsToRemove.contains($0.id) }
        rep.playlists += applyPodEdits(&db)

        syncPhase = "Removing songs"
        let removeKeys = removalKeys
        let removing = db.tracks.filter { removeKeys.contains($0.key) }
        syncTotal = removing.count; syncDone = 0
        for t in removing {
            syncCurrent = "\(t.artist) – \(t.title)"
            await Task.detached { Syncer.remove(t, from: ipod) }.value; rep.removed += 1; syncDone += 1
        }
        syncCurrent = ""
        db.tracks.removeAll { removeKeys.contains($0.key) }
        let left = Set(db.tracks.map(\.id))     // new tracks may reuse the ids of removed ones
        for i in db.playlists.indices { db.playlists[i].items.removeAll { !left.contains($0.trackID) } }
        // write now (before the track order changes again), so On-The-Go lists and play counts can't be imported twice
        if !otg.isEmpty || rep.removed > 0 || pendingName != nil || playCountsMerged || !podHides.isEmpty || !podSkips.isEmpty || !podMarks.isEmpty {
            do {
                try await Syncer.save(db, to: ipod)
                // (a skips file left behind is stale now: the database's stamp moved on)
                let used = otg.map(\.url) + (podHides.isEmpty ? [] : [PodHides.url(ipod)]) + (podSkips.isEmpty ? [] : [PodSkips.url(ipod)])
                    + (podMarks.isEmpty ? [] : [PodBookmarks.url(ipod)])
                    + (playCountsMerged ? [PlayCounts.url(ipod)] : [])
                await offMain { used.forEach { try? FileManager.default.removeItem(at: $0) } }
                if !podSkips.isEmpty { skips = PodSkips.add(podSkips, to: skips) }
                if playCountsMerged { unmergedPlays = nil }
            } catch { rep.error = "Writing the database failed: \(error.localizedDescription)"; return }
            if !plays.isEmpty {
                syncPhase = "Sending plays to Subsonic"
                let sent = await subsonic.scrobble(plays)
                if sent < plays.count { rep.failures.append("Subsonic took \(sent) of \(plays.count) plays") }
            }
        }
        pendingName = nil; toRemove = []; songsToRemove = []; playlistsToRemove = []
        let renames = retags
        for (old, r) in renames where hides[old] != nil { hides[r.key] = hides.removeValue(forKey: old) }     // choices follow renamed songs
        for (old, r) in renames where skips[old] != nil { skips[r.key] = skips.removeValue(forKey: old) }
        for i in db.tracks.indices { if let r = renames[db.tracks[i].key] { db.retag(i, r) } }
        await replaceLossless(&db, ipod: ipod, report: &rep)

        let have = Set(db.tracks.map { aliases[$0.key] ?? $0.key })
        var work = addWork(have: have).filter { brokenFiles[$0.1.path] == nil }
        for (_, t) in addWork(have: have) where brokenFiles[t.path] != nil { rep.failures.append("\(t.title): skipped, \(brokenFiles[t.path]!)") }
        var queued = Set(work.map(\.1.path))
        var lists: [(OTPlaylist, [OTTrack])] = []
        for p in playlists where playlistsToAdd.contains(p.id) {      // playlists bring the tracks there are files for
            syncPhase = "Reading playlist \(p.name)"; syncTotal = 0
            let ts = await tracks(for: p)
            lists.append((p, ts))
            for t in ts {
                if let m = libraryTrack(for: t), !have.contains(m.track.key), queued.insert(m.track.path).inserted { work.append(m) }
            }
        }
        var smart: [(SmartPlaylist, [LibTrack])] = []
        for sp in smartPlaylists where sp.onIPod {     // smart playlists bring their songs too
            let ts = evaluate(sp)
            smart.append((sp, ts))
            for t in ts where !have.contains(t.key) && queued.insert(t.path).inserted {
                if let a = albums.first(where: { $0.id == t.album.lowercased() }) { work.append((a, t)) }
            }
        }
        var mine: [(CratePlaylist, [LibTrack])] = []
        for cp in cratePlaylists where cp.onIPod {      // and Crate's playlists
            let ts = songs(cp)
            mine.append((cp, ts))
            for t in ts where !have.contains(t.key) && queued.insert(t.path).inserted {
                if let a = libraryTrack(key: t.key)?.album { work.append((a, t)) }
            }
        }
        // Frogger's cover art is checked now, while songs are copied, so the Cover art phase at the end is quick
        let artPrep: Task<Void, Never>? = froggerFeatures ? {
            let podTracks = db.tracks, adding = Array(Set(work.map(\.0))), all = albums
            return Task.detached(priority: .utility) { await FroggerArt.prepare(podTracks, adding: adding, ipod: ipod, albums: all) }
        }() : nil
        defer { artPrep?.cancel() }
        let remote = work.filter { subsonic.needsDownload($0.1.path) }     // server songs this Mac has no file for
        if !remote.isEmpty {
            syncPhase = "Downloading from Subsonic"; syncTotal = remote.count; syncDone = 0
            for (n, (_, t)) in remote.enumerated() {
                syncCurrent = "\(t.trackArtist.isEmpty ? t.artist : t.trackArtist) – \(t.title)"
                do { try await subsonic.download(t.path) } catch { rep.failures.append("\(t.title): \(error.localizedDescription)") }
                syncDone = n + 1
            }
            work.removeAll { subsonic.needsDownload($0.1.path) }
        }
        syncPhase = "Adding songs"; syncTotal = work.count; syncDone = 0
        // Conversions run ahead, several at once on this Mac; the iPod gets one copy at a time, in order.
        let settings = podSettings
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crate-convert-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let slots = Slots(max(2, cores - 2))
        let ahead = max(4, cores * 2)       // how far conversions may run ahead of the copying
        var prepared: [Int: Task<URL?, Error>] = [:]
        func schedule(_ i: Int) {
            guard i < work.count, prepared[i] == nil else { return }
            let t = work[i].1
            prepared[i] = Task.detached {
                guard settings.needsConversion(t) else { return nil }
                await slots.take()
                defer { Task { await slots.give() } }
                return try await Syncer.prepare(t, settings: settings, in: tmp)
            }
        }
        for (n, (album, var t)) in work.enumerated() {
            for i in n...min(n + ahead, work.count - 1) { schedule(i) }
            syncCurrent = (settings.needsConversion(t) ? "Converting " : "Copying ") + "\(t.trackArtist.isEmpty ? t.artist : t.trackArtist) – \(t.title)"
            let ready: URL?
            do { ready = try await prepared[n]?.value } catch { rep.failures.append("\(t.title): \(error.localizedDescription)"); syncDone = n + 1; continue }
            prepared[n] = nil
            if podSettings.fillTagsFromMetadata, let mb = metadata[album.id] {
                if t.year == 0 { t.year = mb.year }
                if t.genre.isEmpty { t.genre = mb.genre }
            }
            do {
                db.tracks.append(try await Syncer.add(t, to: ipod, albumCount: album.tracks.count, id: db.nextID, dbid: db.newDBID(), settings: podSettings, prepared: ready))
                rep.added += 1
                if n % 10 == 9 { try await Syncer.save(db, to: ipod) }    // keep the database current during long syncs
            } catch { rep.failures.append("\(t.title): \(error.localizedDescription)") }
            syncDone = n + 1
        }
        if podSettings.soundCheck {       // measured on the iPod's own copies (local and already AAC/MP3)
            let todo = db.tracks.indices.filter { db.soundCheck($0) == 0 }
            if !todo.isEmpty {
                syncPhase = "Measuring loudness"; syncTotal = todo.count; syncDone = 0
                var cache = Loudness.load()
                for (n, i) in todo.enumerated() {
                    let t = db.tracks[i], path = ipod.mount.appendingPathComponent(t.relativePath).path
                    syncCurrent = "\(t.artist) – \(t.title)"
                    let key = "\(path)|\(t.size)"
                    var lufs = cache[key]?.first
                    if lufs == nil { lufs = await Task.detached { Loudness.measure(path) }.value; if let l = lufs { cache[key] = [l] } }
                    if let l = lufs { db.setSoundCheck(i, Loudness.soundCheck(l)) }
                    syncDone = n + 1
                }
                Loudness.save(cache)
            }
        }
        syncPhase = "Writing playlists"; syncCurrent = ""; syncTotal = 0
        let idByKey = Dictionary(db.tracks.flatMap { t in [(t.key, t.id)] + (aliases[t.key].map { [($0, t.id)] } ?? []) }, uniquingKeysWith: { a, _ in a })
        for (p, ts) in lists {
            let items = ts.compactMap { t in libraryTrack(for: t).flatMap { idByKey[$0.track.key] } ?? idByKey[t.key] }
                .map { PodPlaylist.Item(trackID: $0) }
            if let i = db.playlists.firstIndex(where: { samePlaylist($0.name, p.name) }) { db.playlists[i].items = items }
            else { db.playlists.append(PodPlaylist(name: p.name, items: items)) }
            rep.playlists += 1
        }
        for (sp, ts) in smart {
            let items = ts.compactMap { idByKey[$0.key] }.map { PodPlaylist.Item(trackID: $0) }
            if let i = db.playlists.firstIndex(where: { samePlaylist($0.name, sp.name) }) { db.playlists[i].items = items }
            else { db.playlists.append(PodPlaylist(name: sp.name, items: items)) }
            rep.playlists += 1
        }
        for (cp, _) in mine {      // by key, so songs that are only on the iPod (added there) stay
            let items = cp.keys.compactMap { idByKey[$0] }.map { PodPlaylist.Item(trackID: $0) }
            let id: UInt64
            if let i = db.playlists.firstIndex(where: { $0.id == cp.podID }) ?? db.playlists.firstIndex(where: { samePlaylist($0.name, cp.name) }) {
                db.playlists[i].items = items
                if !samePlaylist(db.playlists[i].name, cp.name) { db.playlists[i].rename(cp.name) }
                id = db.playlists[i].id
            } else {
                let new = PodPlaylist(name: cp.name, items: items)
                db.playlists.append(new); id = new.id
            }
            if let i = cratePlaylist(cp.id) { cratePlaylists[i].podID = id }
            rep.playlists += 1
        }
        for i in db.playlists.indices {       // the hidden-playlist mark, then the hide flags it implies
            let want = podName(forPlaylist: db.playlists[i].name)
            if db.playlists[i].name != want { db.playlists[i].rename(want) }
        }
        let rule = ruleHidden(db.playlists, tracks: db.tracks)
        for i in db.tracks.indices {
            let want = wantsHidden(db.tracks[i].key, rule)
            if db.tracks[i].hidden != want { db.setHidden(i, want) }
        }
        for i in db.tracks.indices {        // ratings set in Crate or on the Subsonic server
            let k = aliases[db.tracks[i].key] ?? db.tracks[i].key
            if let lib = libraryTrack(key: k)?.track, let r = serverRating(lib), r > 0 { db.setRating(i, r) }
            else if let r = ratings[k] { db.setRating(i, r) }
        }
        let solo = Set(db.tracks.map { $0.artist.lowercased() } + artists.map { $0.name.lowercased() })
        for i in db.tracks.indices {        // collaborations under their main artist, or back to the full credit
            let t = db.tracks[i]
            let found = index[aliases[t.key] ?? t.key]
            let lib = found?.1.artist
            let full = lib.map { ArtistCredit.main($0, solo: solo) == t.artist } == true ? lib! : t.artist
            let want = podSettings.mainArtistOnly ? ArtistCredit.main(full, solo: solo) : full
            // the library album's artist, which Frogger lists the track under (one name per album);
            // songs that are only on the iPod keep theirs
            let album = found.map { $0.0.artist }.flatMap { $0.isEmpty ? nil : $0 }
            if want != t.artist || (album != nil && album != t.albumArtist) {
                db.retag(i, PodRetag(title: t.title, album: t.album, artist: want, albumArtist: album))
            }
        }
        if podSettings.calendars || podSettings.reminders {
            syncPhase = "Calendars and To Do"; syncCurrent = ""; syncTotal = 0
            rep.calendars = await CalendarSync.write(to: ipod, settings: podSettings)
        }
        syncPhase = "Writing the database"; syncCurrent = ""; syncTotal = 0
        do {
            try await Syncer.save(db, to: ipod)
            retags = retags.filter { renames[$0.key] == nil }
            if froggerFeatures {
                syncPhase = "Cover art"; syncCurrent = ""; syncTotal = 0
                await artPrep?.value
                await FroggerArt.write(db, to: ipod, albums: albums) { done, total, album in     // for Frogger's Now Playing page
                    self.syncDone = done; self.syncTotal = total; self.syncCurrent = album
                }
            }
            syncCurrent = ""
        }
        catch { rep.error = "Writing the database failed: \(error.localizedDescription)" }
        toAdd = []; songsToAdd = []; playlistsToAdd = []
        syncPhase = "Done"
    }

    /// Calendars and To Do onto the iPod (the files only, no database change).
    func writeCalendars() async -> String {
        guard let ipod, connected, podSettings.calendars || podSettings.reminders else { return "" }
        return await CalendarSync.write(to: ipod, settings: podSettings)
    }

    func eject() {
        guard let ipod, connected else { return }
        do { try Syncer.eject(ipod); notify("Ejected – safe to unplug") }
        catch { notify("Eject failed: \(error.localizedDescription)") }
        loadIPod()
    }

    /// Apple Lossless songs on the iPod (too big for its memory buffer, hard on the battery) become AAC: the
    /// library file is converted and goes over the iPod's copy at the same place, and the record gets the new
    /// size, bit rate and file type, so play counts, ratings and playlists stay. Songs only on the iPod keep theirs.
    func replaceLossless(_ db: inout ITunesDB, ipod: IPodInfo, report rep: inout SyncReport) async {
        let source = { (t: PodTrack) in self.index[self.aliases[t.key] ?? t.key]?.1.path }
        // AAC copies in a layout the iPod can't read (MP4Layout.swift): rearranged where they are, audio untouched
        syncPhase = "Fixing song files"; syncTotal = 0; syncDone = 0
        let file = { (t: PodTrack) in ipod.mount.appendingPathComponent(t.relativePath) }
        let aacs = db.tracks.indices.filter { !db.tracks[$0].isLossless && db.tracks[$0].relativePath.lowercased().hasSuffix(".m4a") }
            .map { ($0, file(db.tracks[$0]).path) }
        let unreadable = await offMain { aacs.filter { !MP4Layout.iPodReady($0.1) }.map(\.0) }
        if !unreadable.isEmpty { syncTotal = unreadable.count }
        for i in unreadable {
            let t = db.tracks[i], dst = file(t)
            syncCurrent = "Rearranging \(t.artist) – \(t.title)"
            let staged = dst.deletingLastPathComponent().appendingPathComponent(".crate-new-" + dst.lastPathComponent)
            do {
                let size = try await offMain { () throws -> Int in
                    try? FileManager.default.removeItem(at: staged)
                    try MP4Layout.remux(dst.path, to: staged)
                    _ = try FileManager.default.replaceItemAt(dst, withItemAt: staged)
                    return (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
                }
                let info = await Syncer.audioInfo(dst)
                db.replaceFile(i, size: size, kbps: info.kbps, ms: info.ms)
                rep.replaced += 1
            } catch {
                await offMain { try? FileManager.default.removeItem(at: staged) }
                rep.failures.append("\(t.title): \(error.localizedDescription)")
            }
            syncDone += 1
        }
        let todo = db.tracks.indices.filter { db.tracks[$0].isLossless && source(db.tracks[$0]) != nil }
        guard !todo.isEmpty else { return }
        syncTotal = todo.count; syncDone = 0
        // as in Adding songs: conversions run ahead, several at once; the iPod gets one copy at a time, in order
        let kbps = podSettings.aacKbps
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crate-lossless-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let slots = Slots(max(2, cores - 2)), ahead = max(4, cores * 2)
        var converted: [Int: Task<URL, Error>] = [:]
        func schedule(_ n: Int) {
            guard n < todo.count, converted[n] == nil else { return }
            let src = source(db.tracks[todo[n]])!, out = tmp.appendingPathComponent("\(n).m4a")
            converted[n] = Task.detached {
                await slots.take()
                defer { Task { await slots.give() } }
                guard FileManager.default.fileExists(atPath: src) else { throw SyncError.missingSource(src) }
                try Syncer.convert(src, to: out, kbps: kbps)
                return out
            }
        }
        for (n, i) in todo.enumerated() {
            for k in n...min(n + ahead, todo.count - 1) { schedule(k) }
            let t = db.tracks[i]
            syncCurrent = "Converting \(t.artist) – \(t.title)"
            let dst = ipod.mount.appendingPathComponent(t.relativePath)
            do {
                let aac = try await converted[n]!.value
                converted[n] = nil
                let info = await Syncer.audioInfo(aac)
                let staged = dst.deletingLastPathComponent().appendingPathComponent(".crate-new-" + dst.lastPathComponent)
                let size = try await offMain { () throws -> Int in
                    let fm = FileManager.default
                    try? fm.removeItem(at: staged)
                    try fm.copyItem(at: aac, to: staged)
                    _ = try fm.replaceItemAt(dst, withItemAt: staged)
                    try? fm.removeItem(at: aac)
                    return (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
                }
                db.replaceFile(i, size: size, kbps: info.kbps, ms: info.ms)
                rep.replaced += 1
                if rep.replaced % 10 == 0 { try? await Syncer.save(db, to: ipod) }    // the records follow the replaced files
            } catch { converted[n] = nil; rep.failures.append("\(t.title): still lossless, \(error.localizedDescription)") }
            syncDone = n + 1
        }
        syncCurrent = ""
    }
}
