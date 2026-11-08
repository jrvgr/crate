import Foundation

// `Crate --frogger-fixtures DIR`: checks Crate against the sample files of Frogger's formats (the frogger repo's
// tests/fixtures/, docs/file-formats.md) copied into DIR: Crate reads every version of each file (the old,
// positional ones only with the iTunesDB's stamp), writes the current versions byte for byte like the fixtures,
// and keeps the fixture iTunesDB's dbids and persistent ids through a round trip. Reads DIR only (copies the
// playlist files into a temporary folder for OnTheGo.load).

extension Main {
    static func froggerFixtures(_ path: String) {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failed += 1 } }
        let dir = URL(fileURLWithPath: path)
        func file(_ name: String) -> Data { (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data() }
        guard let db = try? ITunesDB.read(file("iTunesDB")) else { print("no iTunesDB in \(path)"); exit(1) }

        // what mkfixtures.py put in (tests/fixtures/mkfixtures.py)
        let stamp = 0xc0ffee01, keyedStamp = 0x0badf00d, mix: UInt64 = 0xabcdf0
        let apple = FroggerKey(dbid: 0x5eed0000000000a1, id: 101, size: 1000, ms: 180000)
        let bravo = FroggerKey(dbid: 0, id: 102, size: 2000, ms: 240000)
        let long = FroggerKey(dbid: 0x5eed0000000000a3, id: 103, size: 3000, ms: 25 * 60 * 1000)
        let gone = FroggerKey(dbid: 0xdead, id: 104, size: 4000, ms: 200000)
        let dbTime = Date(timeIntervalSince1970: Double(stamp)), later = dbTime.addingTimeInterval(86_400)

        // the iTunesDB: keys, persistent ids, and records kept through a round trip
        check(db.tracks.map(FroggerKey.init) == [apple, bravo, long], "iTunesDB: track keys (dbid at mhit +0x70)")
        check(db.playlists.map(\.id) == [mix] && db.masterID == 0xabcdef, "iTunesDB: playlist persistent ids (mhyp +0x1c)")
        let back = try! ITunesDB.read(db.serialize())
        check(back.tracks.map(\.raw) == db.tracks.map(\.raw), "round trip: track records byte for byte")
        check(back.playlists == db.playlists && back.masterID == db.masterID, "round trip: playlists and their persistent ids kept")
        let keys = FroggerKeys(db)
        check(keys.index(apple) == 0 && keys.index(bravo) == 1 && keys.index(long) == 2 && keys.index(gone) == nil,
              "keys match by dbid, else by id, size and length; a gone song matches nothing")
        check(keys.index(FroggerKey(dbid: 0, id: 101, size: 1000, ms: 180000)) == 0
              && keys.index(FroggerKey(dbid: 0x1234, id: 101, size: 1000, ms: 180000)) == nil
              && keys.index(FroggerKey(dbid: 0x1234, id: 102, size: 2000, ms: 240000)) == 1
              && keys.index(FroggerKey(dbid: 0, id: 101, size: 1001, ms: 180000)) == nil,
              "no dbid matches by id, size and length; two different dbids never match")
        var grown = db
        let fresh = grown.newDBID()
        check(fresh != 0 && !db.tracks.map(\.dbid).contains(fresh), "a new song's dbid is unique and not 0")
        let nt = NewTrack(title: "New", artist: "A", album: "B", genre: "", trackNumber: 1, trackCount: 1, discNumber: 1, year: 2026,
                          lengthMs: 1000, bitrateKbps: 128, sampleRate: 44100, size: 10, location: ":iPod_Control:Music:F00:NEWS.mp3", isAAC: false)
        grown.tracks.append(PodTrack(id: grown.nextID, size: 10, lengthMs: 1000, raw: ITunesDB.mhit(id: grown.nextID, nt, now: 0, dbid: fresh)))
        let grownBack = try! ITunesDB.read(grown.serialize())
        check(grownBack.tracks.map(\.dbid) == db.tracks.map(\.dbid) + [fresh] && grownBack.tracks.prefix(3).map(\.raw) == db.tracks.map(\.raw),
              "a song added: its dbid written, the others' records untouched")

        // FroggerHidden
        let hidden = [("FroggerHidden.v1", [PodHides.Entry(index: 0, shown: false)]),
                      ("FroggerHidden.v2", [.init(index: 0, shown: false), .init(index: 2, shown: true)]),
                      ("FroggerHidden.v3", [.init(index: 0, shown: false), .init(index: 1, shown: true)])]
        for (name, want) in hidden { check(PodHides.parse(file(name), db: db, dbTime: dbTime) == want, "\(name) read") }
        check(PodHides.parse(file("FroggerHidden.v1"), db: db, dbTime: later) == nil && PodHides.parse(file("FroggerHidden.v2"), db: db, dbTime: later) == nil,
              "FroggerHidden v1, v2 ignored for another iTunesDB")
        check(PodHides.parse(file("FroggerHidden.v3"), db: db, dbTime: later) == hidden[2].1, "FroggerHidden v3 read for any iTunesDB")
        check(PodHides.make([(apple, false), (bravo, true), (gone, false)], stamp: keyedStamp) == file("FroggerHidden.v3"), "FroggerHidden v3 written byte for byte")
        check(PodHides.makeByPosition([(0, 101, false)], stamp: stamp, version: 1) == file("FroggerHidden.v1")
              && PodHides.makeByPosition([(0, 101, false), (2, 103, true)], stamp: stamp) == file("FroggerHidden.v2"), "FroggerHidden v1, v2 written byte for byte")

        // FroggerSkips
        let last = Date(timeIntervalSince1970: Double(0xe0000000 - 2_082_844_800))
        for name in ["FroggerSkips.v1", "FroggerSkips.v2"] {
            check(PodSkips.parse(file(name), db: db, dbTime: dbTime) == [PodSkips.Entry(index: 1, count: 3, last: last)], "\(name) read")
        }
        check(PodSkips.parse(file("FroggerSkips.v1"), db: db, dbTime: later) == nil, "FroggerSkips v1 ignored for another iTunesDB")
        check(PodSkips.parse(file("FroggerSkips.v2"), db: db, dbTime: later)?.count == 1, "FroggerSkips v2 read for any iTunesDB")
        check(PodSkips.make([(bravo, 3, 0xe0000000), (gone, 1, 0xe0000100)], stamp: keyedStamp) == file("FroggerSkips.v2")
              && PodSkips.makeByPosition([(1, 102, 3, 0xe0000000)], stamp: stamp) == file("FroggerSkips.v1"), "FroggerSkips v1, v2 written byte for byte")

        // FroggerBookmarks, with and without Play Counts (which has Long Mix at 90 s)
        let marks = PodBookmarks.parse(file("FroggerBookmarks.v1"), db: db)
        check(marks == [PodBookmarks.Entry(index: 2, ms: 120000)], "FroggerBookmarks.v1 read")
        check(PodBookmarks.make([(long, 120000), (gone, 5000)], stamp: keyedStamp) == file("FroggerBookmarks.v1"), "FroggerBookmarks written byte for byte")
        var noCounts = db
        PodBookmarks.apply(marks ?? [], to: &noCounts, playCountsMerged: false)
        var withCounts = db
        let merged = PlayCounts.parse(file("Play Counts")).flatMap { withCounts.mergePlayCounts($0) } != nil
        PodBookmarks.apply(marks ?? [], to: &withCounts, playCountsMerged: merged)
        check(noCounts.bookmark(2) == 120000 && noCounts.bookmark(0) == 0, "bookmark into the record (mhit +0x6c) without Play Counts")
        check(merged && withCounts.bookmark(2) == 90000, "Play Counts' own bookmark wins when it was merged")
        check(try! ITunesDB.read(noCounts.serialize()).bookmark(2) == 120000, "bookmark kept through a round trip")

        // FroggerPlaylist_<id> and the old FroggerPlaylist_I
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crate-fixtures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        func lists(_ files: [(String, String)], _ time: Date) -> [OnTheGo] {
            try? FileManager.default.removeItem(at: tmp)
            try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for (from, to) in files { try! file(from).write(to: tmp.appendingPathComponent(to)) }
            return OnTheGo.load(dir: tmp, db: db, dbTime: time)
        }
        let keyedName = OnTheGo.keyedName(mix)
        check(keyedName == "FroggerPlaylist_0000000000ABCDF0", "FroggerPlaylist_<id> named by the persistent id")
        let both = lists([(keyedName, keyedName), ("FroggerPlaylist_1.mhpo", "FroggerPlaylist_1")], dbTime)
        check(both.map(\.kind) == [.syncedID(mix)] && both.first?.trackIDs == [101, 102], "FroggerPlaylist_<id> read (gone song left out), wins over FroggerPlaylist_1")
        let old = lists([("FroggerPlaylist_1.mhpo", "FroggerPlaylist_1")], dbTime)
        check(old.map(\.kind) == [.synced(1)] && old.first?.trackIDs == [103, 101], "FroggerPlaylist_1 read in the master playlist's order")
        check(lists([("FroggerPlaylist_1.mhpo", "FroggerPlaylist_1")], later).isEmpty, "FroggerPlaylist_1 ignored for another iTunesDB")
        check(lists([(keyedName, keyedName)], later).map(\.kind) == [.syncedID(mix)], "FroggerPlaylist_<id> read for any iTunesDB")
        check(lists([(keyedName, OnTheGo.keyedName(0x1234))], dbTime).isEmpty, "a FroggerPlaylist_<id> holding another id ignored")
        var applied = db
        let (_, synced) = applied.applyFromPod(both)
        check(synced == [mix] && applied.playlists[0].items.map(\.trackID) == [101, 102] && applied.playlists[0].id == mix,
              "Mix takes the iPod's songs and keeps its persistent id")
        check(OnTheGo.makeKeyed(mix, [apple, bravo, gone], stamp: keyedStamp) == file(keyedName)
              && OnTheGo.make([2, 0], stamp: stamp) == file("FroggerPlaylist_1.mhpo"), "FroggerPlaylist files written byte for byte")

        // FroggerArt: the two covers of mkfixtures.py
        func image(_ level: (Int, Int) -> Int) -> Data {
            var px = Data(count: FroggerArt.imageBytes)
            for y in 0..<FroggerArt.size { for x in 0..<FroggerArt.size { px[y * FroggerArt.row + x / 4] |= UInt8(level(x, y) << (6 - 2 * (x & 3))) } }
            return px
        }
        let covers = [image { x, y in 3 * (((x / 9) + (y / 9)) & 1) }, image { x, _ in x * 4 / 72 }]
        for name in ["FroggerArt.v1", "FroggerArt.v2"] {
            let art = FroggerArt.parse(file(name), db: db)
            check(art?.covers == [0: 0, 2: 1] && art?.images == covers, "\(name) read")
        }
        var fewer = db; fewer.tracks.removeLast()
        check(FroggerArt.parse(file("FroggerArt.v1"), db: fewer) == nil, "FroggerArt v1 ignored for another track count")
        check(FroggerArt.parse(file("FroggerArt.v2"), db: fewer)?.covers == [0: 0], "FroggerArt v2 read for another database")
        check(FroggerArt.encode([(apple, 0), (long, 1), (gone, 0)], images: covers) == file("FroggerArt.v2"), "FroggerArt v2 written byte for byte")
        let entries = db.tracks.enumerated().compactMap { i, t in [0: UInt16(0), 2: 1][i].map { (key: FroggerKey(t), image: $0) } }
        check(FroggerArt.encode(entries, images: covers) == FroggerArt.encode([(apple, 0), (long, 1)], images: covers),
              "FroggerArt entries keyed from the iTunesDB's records")

        print(failed == 0 ? "all Frogger fixture checks passed" : "\(failed) Frogger fixture check\(failed == 1 ? "" : "s") failed")
        exit(failed == 0 ? 0 : 1)
    }
}
