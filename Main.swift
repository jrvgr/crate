import SwiftUI
import EventKit

struct CrateApp: App {
    @StateObject private var model = Model()
    @AppStorage("menuBarExtra") private var menuBar = true
    var body: some Scene {
        WindowGroup("Crate", id: "main") {
            ContentView().environmentObject(model).environmentObject(model.slsk).environmentObject(model.spotifyAPI).environmentObject(model.player).environmentObject(model.yt).frame(minWidth: 900, minHeight: 580)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Recently Added") { model.search = ""; model.pane = .recent }.keyboardShortcut("1")
                Button("Albums") { model.search = ""; model.pane = .albums }.keyboardShortcut("2")
                Button("Artists") { model.search = ""; model.pane = .artists }.keyboardShortcut("3")
                Button("Songs") { model.search = ""; model.pane = .songs }.keyboardShortcut("4")
                Button("iPod") { model.search = ""; model.pane = .ipod }.keyboardShortcut("5").disabled(model.ipod == nil)
                Button("Downloads") { model.search = ""; model.pane = .downloads }.keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Controls") {
                Button(model.player.playing ? "Pause" : "Play") { model.player.toggle() }      // Space too (see Main.spaceKey)
                    .disabled(model.player.current == nil)
                Button("Next Song") { model.player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Song") { model.player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Search") { model.focusSearch += 1 }.keyboardShortcut("f")
                Button("Edit Tags…") { model.editAlbum = model.focusAlbum }.keyboardShortcut("i").disabled(model.focusAlbum == nil)
                Button("Find Metadata…") { model.lookupAlbum = model.focusAlbum }.keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(model.focusAlbum == nil)
                Button("Quick Look Cover") { if let a = model.focusAlbum { model.quickLookCover(a) } }.keyboardShortcut("y").disabled(model.focusAlbum == nil)
                Button("Play Album") { if let a = model.focusAlbum { Task { await model.play(a) } } }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.focusAlbum == nil)
                Divider()
                Button("Refresh Library") { Task { await model.reload() } }.keyboardShortcut("r")
            }
            CommandMenu("iPod") {
                Button("Sync…") { model.reviewSync() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.connected || model.pendingCount == 0)
                Button("Discard Changes") { model.discardChanges() }.disabled(model.pendingCount == 0)
                Divider()
                Button("Eject") { model.eject() }.keyboardShortcut("e").disabled(!model.connected || model.syncing)
            }
        }
        MenuBarExtra(isInserted: $menuBar) {
            MenuBarView().environmentObject(model).environmentObject(model.slsk).environmentObject(model.player).environmentObject(model.yt)
        } label: {
            Image(systemName: model.syncing ? "arrow.triangle.2.circlepath" : model.ipod == nil ? "ipod" : model.pendingCount > 0 ? "ipod.badge.plus" : "ipod")
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView().environmentObject(model).environmentObject(model.slsk).environmentObject(model.spotifyAPI).environmentObject(model.player).environmentObject(model.yt) }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), args.count > i + 1 { selftest(args[i + 1]); return }
        if let i = args.firstIndex(of: "--add-folder"), args.count > i + 1 { addFolder(args[i + 1]); return }
        if let i = args.firstIndex(of: "--remove-album"), args.count > i + 1 { removeAlbum(args[i + 1]); return }
        if let i = args.firstIndex(of: "--playlist-test"), args.count > i + 1 { playlistTest(args[i + 1]); return }
        if let i = args.firstIndex(of: "--remove-playlist"), args.count > i + 1 { removePlaylist(args[i + 1]); return }
        if let i = args.firstIndex(of: "--model-test"), args.count > i + 1 { modelTest(args[i + 1]); return }
        if let i = args.firstIndex(of: "--apple-music-download"), args.count > i + 1 { appleMusicDownload(args[i + 1]); return }
        if args.contains("--apple-music") { appleMusic(); return }
        if args.contains("--callback-test") {     // the Spotify login's local listener, fed a fake redirect
            Task { @MainActor in
                let cb = Callback(port: SpotifyAPI.port)
                try cb.start()
                let q = try await cb.wait()
                print("query:", q.sorted { $0.key < $1.key }); exit(q["code"] == "abc" ? 0 : 1)
            }
            RunLoop.main.run()
        }
        if args.contains("--privacy-status") {     // what macOS currently allows (run it as the app: open --stdout)
            let names = ["notDetermined", "restricted", "denied", "authorized", "fullAccess", "writeOnly"]
            print("calendars:", names[safe: EKEventStore.authorizationStatus(for: .event).rawValue] ?? "?",
                  "reminders:", names[safe: EKEventStore.authorizationStatus(for: .reminder).rawValue] ?? "?")
            return
        }
        if args.contains("--keychain-test") {
            print("set:", Keychain.set("crate-test", "dummy"), "get:", Keychain.get("crate-test") == "dummy")
            Keychain.set("crate-test", ""); return
        }
        if let i = args.firstIndex(of: "--slskd-check") { slskdCheck(args.count > i + 1 ? args[i + 1] : ""); return }
        if let i = args.firstIndex(of: "--import"), args.count > i + 2 { importFiles(Array(args[(i + 2)...]), into: args[i + 1]); return }
        if let i = args.firstIndex(of: "--tag"), args.count > i + 1 { tag(args[i + 1], Array(args[(i + 2)...])); return }
        if let i = args.firstIndex(of: "--organize-test"), args.count > i + 1 {     // plans and runs the organiser on a scratch folder
            let dir = args[i + 1]
            Task { @MainActor in
                let albums = LibraryLoader.albums(await LibraryLoader.scan(dir))
                let moves = Organizer.plan(albums, roots: [dir], withYear: true)
                moves.forEach { print(($0.conflict ? "SKIP " : "move ") + $0.from.dropFirst(dir.count) + " -> " + $0.to.dropFirst(dir.count)) }
                let r = Organizer.apply(moves)
                print("moved \(r.done.count), failed \(r.failed)")
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--organize-test"), args.count > i + 1 {     // plans and runs the organiser on a scratch folder
            let dir = args[i + 1], done = DispatchSemaphore(value: 0)
            Task {
                let albums = LibraryLoader.albums(await LibraryLoader.scan(dir))
                let moves = Organizer.plan(albums, roots: [dir], withYear: true)
                moves.forEach { print(($0.conflict ? "SKIP " : "move ") + $0.from.dropFirst(dir.count) + " -> " + $0.to.dropFirst(dir.count)) }
                let r = Organizer.apply(moves)
                print("moved \(r.done.count), failed \(r.failed)")
                done.signal()
            }
            done.wait(); return
        }
        if let i = args.firstIndex(of: "--yt-test"), args.count > i + 1 {     // one YouTube search hit, downloaded and tagged, not imported
            let q = args[i + 1]
            Task { @MainActor in
                let yt = YouTube()
                let saved = yt.customPath
                if let b = ProcessInfo.processInfo.environment["YTDLP"] { yt.customPath = b }     // test with a given binary
                defer { yt.customPath = saved }
                print("yt-dlp:", yt.binary ?? "none")
                yt.onFiles = { files, _ in
                    for f in files {
                        let t = await LibraryLoader.track(f.path, relative: f.lastPathComponent)
                        print("file: \(f.lastPathComponent) | \(t.title) | \(t.trackArtist) | \(t.album) | #\(t.trackNumber) | \(t.lengthMs) ms")
                        try? FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: NSTemporaryDirectory() + f.lastPathComponent))
                    }
                }
                yt.fetch([OTTrack(id: 0, title: q, artist: "Aphex Twin", album: "Test Album", albumArtist: "Aphex Twin", dataKind: "", uri: "", artworkPath: "", lengthMs: 0)],
                         album: "Test Album", art: "https://coverartarchive.org/release-group/1a0a8b5c-e0cb-3a18-a2f0-29ba7e6fd8ec/front-250")
                while yt.jobs.contains(where: { !$0.finished }) { try? await Task.sleep(for: .seconds(1)) }
                try? await Task.sleep(for: .seconds(2))
                for i in yt.jobs[0].items { print("item:", i.state, i.done) }
                yt.customPath = saved
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--pull-test"), args.count > i + 1 {     // copies the iPod-only albums into <root> (reads the iPod only)
            let root = args[i + 1]
            Task { @MainActor in
                let m = Model(); await m.reload()
                let albums = m.podOnlyAlbums
                print("only on the iPod:", albums.map(\.title))
                let keys = Set(albums.flatMap { $0.tracks.map(\.key) })
                let urls = (m.db?.tracks ?? []).filter { keys.contains($0.key) }.map { m.ipod!.mount.appendingPathComponent($0.relativePath) }
                let r = try await Importer.run(urls, into: root, rename: true)
                r.tracks.forEach { print(String($0.path.dropFirst(root.count))) }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--convert-bench"), args.count > i + 1 {     // FLAC → AAC of a folder: one by one, then in parallel (temp files only)
            let dir = args[i + 1]
            Task { @MainActor in
                let ts = await LibraryLoader.scan(dir).filter(\.needsConversion)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crate-bench"); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let s = PodSettings()
                var t0 = Date()
                for t in ts { _ = try? await Syncer.prepare(t, settings: s, in: tmp) }
                print("\(ts.count) songs one by one: \(Int(Date().timeIntervalSince(t0))) s")
                t0 = Date()
                let slots = Slots(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
                await withTaskGroup(of: Void.self) { g in
                    for t in ts { g.addTask { await slots.take(); _ = try? await Syncer.prepare(t, settings: s, in: tmp); await slots.give() } }
                }
                print("in parallel: \(Int(Date().timeIntervalSince(t0))) s")
                try? FileManager.default.removeItem(at: tmp)
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--match-test") {     // pairing suggestions and a file check (read only)
            Task { @MainActor in
                let m = Model(); await m.reload()
                let s = m.matchSuggestions()
                print("\(s.count) suggested pairs")
                for p in s.prefix(8) { print("  iPod: \(p.pod.artist) – \(p.pod.album) – \(p.pod.title)  ⇄  lib: \(p.lib.album) – \(p.lib.title)") }
                for f in args.drop { $0 != "--match-test" }.dropFirst() { print(f.split(separator: "/").last ?? "", "→", FileCheck.problem(f) ?? "ok") }
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--spotify-test") {     // read only: playlists and the songs of the first few
            Task { @MainActor in
                let sp = SpotifyAPI()
                do {
                    let lists = try await sp.playlists()
                    print("\(lists.count) playlists")
                    for p in lists.prefix(3) {
                        print("  \(p.name) [\(p.count)] art: \(p.artwork.isEmpty ? "none" : "yes")")
                        do { let ts = try await sp.tracks(p.spotifyID!); print("    \(ts.count) songs, first: \(ts.first.map { "\($0.artist) – \($0.title) (\($0.album))" } ?? "-")") }
                        catch { print("    tracks error: \(error.localizedDescription)") }
                    }
                    if let p = lists.first {
                        for path in ["/playlists/\(p.spotifyID!)/items?limit=2", "/playlists/\(p.spotifyID!)?limit=2", "/me/tracks?limit=2", "/me"] {
                            do {
                                let raw = try await sp.get(path) as? [String: Any]
                                let items = (raw?["items"] as? [Any]) ?? ((raw?["tracks"] as? [String: Any])?["items"] as? [Any]) ?? ((raw?["items"] as? [String: Any])?["items"] as? [Any])
                                print("\(path): ok, keys \(raw?.keys.sorted().prefix(12) ?? []), items \(items?.count ?? -1)")
                                if let first = items?.first as? [String: Any] { print("   item keys:", first.keys.sorted()) }
                            } catch { print("\(path): \(error.localizedDescription)") }
                        }
                    }
                } catch { print("error: \(error.localizedDescription)") }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--write-tags"), args.count > i + 3 { writeTags(args[i + 1], args[i + 2], args[i + 3]); return }
        if let i = args.firstIndex(of: "--lookup"), args.count > i + 2 { lookup(args[i + 1], args[i + 2]); return }
        spaceKey()
        CrateApp.main()
    }

    /// Space plays/pauses unless something you type into has the keyboard (search, tag fields...).
    static func spaceKey() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText), NSApp.keyWindow?.attachedSheet == nil,
                  let model = Model.shared, model.player.current != nil else { return e }
            model.player.toggle()
            return nil
        }
    }

    /// Reads an iTunesDB, writes it back to memory, reads that again and compares.
    static func selftest(_ path: String) {
        do {
            let original = try ITunesDB.read(Data(contentsOf: URL(fileURLWithPath: path)))
            let again = try ITunesDB.read(original.serialize())
            let same = original.tracks.count == again.tracks.count
                && zip(original.tracks, again.tracks).allSatisfy { $0.raw == $1.raw && $0.key == $1.key && $0.location == $1.location }
                && original.playlists == again.playlists
            print("name: \(original.name) -> \(again.name)")
            print("tracks: \(original.tracks.count) -> \(again.tracks.count), playlists: \(original.playlists.count) -> \(again.playlists.count), records identical: \(same)")
            for t in again.tracks.prefix(3) { print("  \(t.id) \(t.artist) – \(t.title) [\(t.location)] \(t.lengthMs) ms") }
            exit(same && original.name == again.name ? 0 : 1)
        } catch { print("error: \(error)"); exit(1) }
    }

    /// Adds every audio file in a folder to the connected iPod (headless test of the sync path).
    static func addFolder(_ folder: String) {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            guard let ipod = IPodInfo.find() else { print("no iPod mounted"); return }
            var db = (try? ITunesDB.read(Data(contentsOf: ipod.dbURL))) ?? .empty(name: ipod.mount.lastPathComponent)
            let have = Set(db.tracks.map(\.key))
            let tracks = await LibraryLoader.scan(folder).filter { !have.contains($0.key) }
            for t in tracks {
                do {
                    db.tracks.append(try await Syncer.add(t, to: ipod, albumCount: tracks.count, id: db.nextID))
                    print("added \(t.artist) – \(t.title)")
                } catch { print("failed \(t.title): \(error.localizedDescription)") }
            }
            do { try Syncer.write(db, to: ipod); print("\(db.tracks.count) tracks in iTunesDB") }
            catch { print("write failed: \(error)") }
        }
        done.wait()
    }

    /// Removes one album (by title) from the connected iPod.
    static func removeAlbum(_ title: String) {
        guard let ipod = IPodInfo.find(), var db = try? ITunesDB.read(Data(contentsOf: ipod.dbURL)) else { print("no iPod/database"); return }
        let gone = db.tracks.filter { $0.album.lowercased() == title.lowercased() }
        gone.forEach { Syncer.remove($0, from: ipod) }
        db.tracks.removeAll { $0.album.lowercased() == title.lowercased() }
        do { try Syncer.write(db, to: ipod); print("removed \(gone.count), \(db.tracks.count) tracks left") }
        catch { print("write failed: \(error)") }
    }

    /// Offline playlist checks on a copy of a database: a new playlist and an On-The-Go list survive a
    /// round trip, a removed track drops out of them, and a kept playlist stays byte for byte.
    static func playlistTest(_ path: String) {
        func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { exit(1) } }
        guard var db = try? ITunesDB.read(Data(contentsOf: URL(fileURLWithPath: path))), db.tracks.count >= 4 else {
            print("need a database with 4+ tracks"); exit(1)
        }
        let ids = db.tracks.map(\.id)
        db.playlists.append(PodPlaylist(name: "Crate Test", items: [ids[0], ids[1], ids[2], ids[0]].map { .init(trackID: $0) }))
        let otg = OnTheGo.parse(OnTheGo.make([3, 1]))
        check(otg == [3, 1], "On-The-Go file parses: \(otg ?? [])")
        db.importOnTheGo([OnTheGo(url: URL(fileURLWithPath: "/dev/null"), trackIDs: otg!.map { ids[$0] })])
        var back = try! ITunesDB.read(db.serialize())
        check(back.playlists.map(\.name) == db.playlists.map(\.name), "names: \(back.playlists.map(\.name))")
        check(back.playlists[back.playlists.count - 2].items.map(\.trackID) == [ids[0], ids[1], ids[2], ids[0]], "items kept, duplicates too")
        check(back.playlists.last!.items.map(\.trackID) == [ids[3], ids[1]], "On-The-Go imported in order")
        let kept = back.playlists
        let again = try! ITunesDB.read(back.serialize())
        check(again.playlists == kept, "playlist records identical after a second round trip")
        back.tracks.removeAll { $0.id == ids[1] }
        let pruned = try! ITunesDB.read(back.serialize())
        check(pruned.playlists[pruned.playlists.count - 2].items.map(\.trackID) == [ids[0], ids[2], ids[0]], "removed track dropped from playlist")
        check(pruned.playlists.last!.items.map(\.trackID) == [ids[3]], "removed track dropped from On-The-Go")
        check(pruned.tracks.count == db.tracks.count - 1, "tracks: \(pruned.tracks.count)")
        // Play Counts from the iPod: 3 plays + 4 stars on track 2, a mismatched file is ignored
        var pc = pruned
        let le = { (v: Int) in (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
        func file(_ n: Int) -> Data {
            var d: [UInt8] = Array("mhdp".utf8)
            d += le(0x60); d += le(0x10); d += le(n)
            d += [UInt8](repeating: 0, count: 0x60 - 16)
            for i in 0..<n {
                let e: [Int] = i == 1 ? [3, 3_000_000_000, 0, 80] : [0, 0, 0, 0]
                for v in e { d += le(v) }
            }
            return Data(d)
        }
        func plays(_ t: PodTrack) -> Int { let b = [UInt8](t.raw!); return Int(b[0x50]) | Int(b[0x51]) << 8 }
        let p0 = plays(pc.tracks[1])
        check(pc.mergePlayCounts(PlayCounts.parse(file(pc.tracks.count + 1))!) == nil, "mismatched Play Counts ignored")
        check(pc.mergePlayCounts(PlayCounts.parse(file(pc.tracks.count))!) == 1, "Play Counts merged into one track")
        let merged = try! ITunesDB.read(pc.serialize())
        check(plays(merged.tracks[1]) == p0 + 3 && [UInt8](merged.tracks[1].raw!)[0x1F] == 80, "plays +3 and rating kept after a round trip")
        exit(0)
    }

    /// Removes one playlist (by name) from the connected iPod.
    static func removePlaylist(_ name: String) {
        guard let ipod = IPodInfo.find(), var db = try? ITunesDB.read(Data(contentsOf: ipod.dbURL)) else { print("no iPod/database"); return }
        let before = db.playlists.count
        db.playlists.removeAll { $0.name == name }
        do { try Syncer.write(db, to: ipod); print("removed \(before - db.playlists.count), \(db.playlists.count) playlists left") }
        catch { print("write failed: \(error)") }
    }

    /// Runs the window's own Model: removes an album via Sync, then adds it back via Sync.
    static func modelTest(_ title: String) {
        Task { @MainActor in
            let m = Model()
            await m.reload()
            print("library: \(m.albums.count) albums, iPod: \(m.db?.tracks.count ?? -1) tracks")
            guard let pod = m.podAlbums.first(where: { $0.title == title }),
                  let lib = m.albums.first(where: { $0.title == title }) else { print("album not found"); exit(1) }
            m.toggleRemove(pod); await m.sync()
            print("after remove: \(m.db?.tracks.count ?? -1) tracks, state \(m.state(lib)) | \(m.report?.error ?? "ok, \(m.report?.failures.count ?? 0) failures")")
            m.toggleAdd(lib); await m.sync()
            print("after add: \(m.db?.tracks.count ?? -1) tracks, state \(m.state(lib)) | \(m.report?.error ?? "ok, \(m.report?.failures.count ?? 0) failures")")
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Logs in to slskd with the saved settings, optionally searches (never downloads) and lists downloads.
    static func slskdCheck(_ query: String) {
        Task { @MainActor in
            let s = Slskd()
            await s.check()
            print("server:", s.serverState, "error:", s.error ?? "none")
            if !query.isEmpty {
                s.search(query)
                try? await Task.sleep(for: .seconds(2))
                while s.searching { try? await Task.sleep(for: .seconds(1)) }
                print("\(s.results.count) folders", s.error ?? "")
                for f in s.results.prefix(5) { print("  \(f.username) | \(f.name) | \(f.audio.count) tracks \(f.formats) \(f.quality) | free \(f.freeSlot) speed \(f.speed)") }
            }
            await s.refreshDownloads()
            print("downloads: \(s.jobs.count) folders", s.error ?? "")
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Lists the Apple Music (iTunes Match) albums Crate can import.
    static func appleMusic() {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let a = try await AppleMusic.albums()
                print("\(a.count) albums, \(a.map(\.tracks.count).reduce(0, +)) tracks, \(a.filter { $0.downloaded == $0.tracks.count }.count) fully on this Mac")
                for x in a.prefix(6) { print("  \(x.artist) – \(x.title) (\(x.year)) \(x.downloaded)/\(x.tracks.count) \(Set(x.tracks.map(\.cloud)).sorted())") }
                if let f = a.first { print("art:", await AppleMusic.artworkURL(f)?.absoluteString ?? "none") }
            } catch { print("error: \(error.localizedDescription)") }
        }
        done.wait()
    }

    /// Has Music download one iTunes Match album and prints where its files are (no import).
    static func appleMusicDownload(_ title: String) {
        Task { @MainActor in
            do {
                guard let a = try await AppleMusic.albums().first(where: { $0.title == title }) else { print("album not found"); exit(1) }
                let paths = try await AppleMusic.download(a) { print("downloaded \($0)/\($1)") }
                paths.forEach { print($0) }
                exit(0)
            } catch { print("error: \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }

    /// Runs the drag-and-drop import: copies files/folders into <root>/<Artist>/<Album>/.
    static func importFiles(_ paths: [String], into root: String) {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let r = try await Importer.run(paths.map { URL(fileURLWithPath: $0) }, into: root)
                for t in r.tracks { print("\(t.artist) | \(t.album) | \(t.trackNumber) \(t.title) -> \(t.path)") }
                print("imported \(r.tracks.count), skipped \(r.skipped)")
            } catch { print("error: \(error.localizedDescription)") }
        }
        done.wait()
    }

    /// Writes year and genre into one FLAC or MP3 file (test it on a copy).
    static func writeTags(_ path: String, _ year: String, _ genre: String) {
        do { print(try TagWriter.write(path, year: Int(year) ?? 0, genre: genre) ? "written" : "unchanged"); exit(0) }
        catch { print("error: \(error.localizedDescription)"); exit(1) }
    }

    /// Writes key=value tags (title, artist, albumartist, album, genre, year, track, disc) into a file
    /// and prints what Crate reads back (test it on a copy).
    static func tag(_ path: String, _ pairs: [String]) {
        var e = TagEdit()
        for p in pairs {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init); guard kv.count == 2 else { continue }
            switch kv[0] {
            case "title": e.title = kv[1]; case "artist": e.artist = kv[1]; case "albumartist": e.albumArtist = kv[1]
            case "album": e.album = kv[1]; case "genre": e.genre = kv[1]; case "year": e.year = Int(kv[1])
            case "track": e.track = Int(kv[1]); case "disc": e.disc = Int(kv[1]); default: break
            }
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            do { print(try TagWriter.write(path, e) ? "written" : "unchanged") } catch { print("error: \(error.localizedDescription)") }
            let t = await LibraryLoader.track(path, relative: (path as NSString).lastPathComponent)
            print("read back: \(t.title) | \(t.trackArtist) | album artist \(t.artist) | \(t.album) | \(t.genre) | \(t.year) | #\(t.trackNumber) | \(t.lengthMs) ms")
            done.signal()
        }
        done.wait()
    }

    /// Prints MusicBrainz/Discogs matches for an album.
    static func lookup(_ album: String, _ artist: String) {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let r = try await MusicBrainz.search(album: album, artist: artist)
                for x in r.prefix(4) { print("MB \(x.score) \(x.artist) – \(x.title) \(x.date) \(x.country) \(x.trackCount) tracks") }
                if let first = r.first { let d = await MusicBrainz.details(first); print("details: year \(d.year) genre \(d.genre)") }
                print("cover bytes:", await MusicBrainz.cover(r.first?.id ?? "")?.count ?? 0)
                print("discogs results:", (try? await Discogs.search(album: album, artist: artist).count) ?? -1)
            } catch { print("error: \(error)") }
        }
        done.wait()
    }
}
