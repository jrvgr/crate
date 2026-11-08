import Foundation

// What Frogger's files on the iPod have in common (the frogger repo: docs/file-formats.md): the track key
// that names a song, the 20-byte header, and FroggerBookmarks. The files themselves are read in IPod.swift
// (FroggerHidden, FroggerSkips, FroggerPlaylist_*) and FroggerArt.swift.

/// How Frogger's files name a song (payload/tracks.h): 20 bytes from its mhit, the dbid (+0x70), track id
/// (+0x10), size (+0x24) and length in ms (+0x28). Older versions named songs by position instead, so they
/// only fit the iTunesDB they were written for (stamped); the keyed ones fit any database that kept the dbids,
/// which Crate does (records are kept byte for byte, new songs get a new, unique dbid: `ITunesDB.newDBID`).
struct FroggerKey: Hashable {
    var dbid: UInt64
    var id, size, ms: UInt32

    init(dbid: UInt64, id: UInt32, size: UInt32, ms: UInt32) { self.dbid = dbid; self.id = id; self.size = size; self.ms = ms }
    init(_ t: PodTrack) {
        self.init(dbid: t.dbid, id: t.id, size: UInt32(truncatingIfNeeded: t.size), ms: UInt32(truncatingIfNeeded: t.lengthMs))
    }
    /// The key at byte `o` of `d` (which must hold 20 bytes there).
    init(_ d: [UInt8], at o: Int) {
        self.init(dbid: FroggerFile.u64(d, o), id: UInt32(FroggerFile.u32(d, o + 8)),
                  size: UInt32(FroggerFile.u32(d, o + 12)), ms: UInt32(FroggerFile.u32(d, o + 16)))
    }
    var bytes: [UInt8] { FroggerFile.le64(dbid) + FroggerFile.le32(Int(id)) + FroggerFile.le32(Int(size)) + FroggerFile.le32(Int(ms)) }
}

/// Finds the track a key names in a database, the way Frogger does: the same dbid if the key has one (and a
/// track has it), else the same track id, size and length, as long as the key or the track has no dbid (two
/// different dbids never match). A key that matches nothing names a song that isn't on the iPod any more.
struct FroggerKeys {
    private let tracks: [PodTrack]
    private var byDBID: [UInt64: Int] = [:], byID: [UInt32: [Int]] = [:]

    init(_ db: ITunesDB) {
        tracks = db.tracks
        for (i, t) in tracks.enumerated() {
            let d = t.dbid
            if d != 0, byDBID[d] == nil { byDBID[d] = i }
            byID[t.id, default: []].append(i)
        }
    }

    /// The track's index in `db.tracks`, or nil.
    func index(_ k: FroggerKey) -> Int? {
        if k.dbid != 0, let i = byDBID[k.dbid] { return i }
        return (byID[k.id] ?? []).first { i in
            let t = tracks[i]
            return UInt32(truncatingIfNeeded: t.size) == k.size && UInt32(truncatingIfNeeded: t.lengthMs) == k.ms && (k.dbid == 0 || t.dbid == 0)
        }
    }
}

enum FroggerFile {
    static func u16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    static func u32(_ d: [UInt8], _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }
    static func u64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
    static func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (UInt64($0) * 8)) } }

    /// The common 20-byte header: magic, version (u16), entry size (u16), stamp, count, 0.
    struct Header { var version, size, stamp, count: Int }

    /// The header, when the magic is right and the file holds all `count` entries.
    static func header(_ d: [UInt8], _ magic: String) -> Header? {
        guard d.count >= 20, d[0..<4].elementsEqual(magic.utf8) else { return nil }
        let h = Header(version: u16(d, 4), size: u16(d, 6), stamp: u32(d, 8), count: u32(d, 12))
        guard h.size > 0, 20 + h.count * h.size <= d.count else { return nil }
        return h
    }

    static func header(_ magic: String, version: Int, size: Int, stamp: Int, count: Int) -> [UInt8] {
        Array(magic.utf8) + le16(version) + le16(size) + le32(stamp) + le32(count) + le32(0)
    }

    /// The iTunesDB's file time, which the old (positional) versions' stamps must match.
    static func dbTime(_ ipod: IPodInfo) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ipod.dbURL.path))?[.modificationDate] as? Date
    }
}

/// iTunes/FroggerBookmarks: where Frogger's Resume Mixes left long songs (20 minutes or more), version 1: the
/// header ("FRGB", 1, 24), then per song its key and the bookmark in ms. Frogger writes it with Play Counts and
/// uses it itself only after a sync (stamp not the iTunesDB's) for songs that came without a bookmark. Crate puts
/// the bookmarks into the songs' records (mhit +0x6c) on Sync and deletes the file: where Play Counts was merged
/// (it has the same positions) only for songs still without one, else all of them.
enum PodBookmarks {
    struct Entry: Equatable { var index, ms: Int }

    static func url(_ ipod: IPodInfo) -> URL { ipod.dbURL.deletingLastPathComponent().appendingPathComponent("FroggerBookmarks") }

    static func load(_ ipod: IPodInfo, db: ITunesDB) -> [Entry] {
        (try? Data(contentsOf: url(ipod))).flatMap { parse($0, db: db) } ?? []
    }

    /// The bookmarks by index in `db.tracks`; nil when the file is broken or of a version Crate doesn't know.
    static func parse(_ data: Data, db: ITunesDB) -> [Entry]? {
        let d = [UInt8](data)
        guard let h = FroggerFile.header(d, "FRGB"), h.version == 1, h.size == 24 else { return nil }
        let keys = FroggerKeys(db)
        return (0..<h.count).compactMap { k in
            let o = 20 + k * h.size
            guard let i = keys.index(FroggerKey(d, at: o)) else { return nil }
            return Entry(index: i, ms: FroggerFile.u32(d, o + 20))
        }
    }

    static func make(_ entries: [(key: FroggerKey, ms: Int)], stamp: Int) -> Data {
        Data(FroggerFile.header("FRGB", version: 1, size: 24, stamp: stamp, count: entries.count)
             + entries.flatMap { $0.key.bytes + FroggerFile.le32($0.ms) })
    }

    /// Puts the bookmarks into the records; `playCountsMerged`: only where a song has none yet. Returns how many changed.
    @discardableResult
    static func apply(_ entries: [Entry], to db: inout ITunesDB, playCountsMerged: Bool) -> Int {
        var n = 0
        for e in entries where e.ms > 0 && db.bookmark(e.index) != e.ms && !(playCountsMerged && db.bookmark(e.index) != 0) {
            if db.setBookmark(e.index, e.ms) { n += 1 }
        }
        return n
    }
}

extension PodTrack {
    /// The persistent id (mhit +0x70), 0 when the record has none (or is too short for one).
    var dbid: UInt64 {
        guard let raw, raw.count >= 0x78 else { return 0 }
        let d = [UInt8](raw.prefix(0x78))
        guard FroggerFile.u32(d, 4) >= 0x78 else { return 0 }
        return FroggerFile.u64(d, 0x70)
    }
}

extension ITunesDB {
    /// A dbid for a new song: not 0 and no other song's.
    func newDBID(avoiding more: Set<UInt64> = []) -> UInt64 {
        let have = Set(tracks.map(\.dbid)).union(more)
        var d: UInt64
        repeat { d = UInt64.random(in: 1...UInt64.max) } while have.contains(d)
        return d
    }

    /// The bookmark in ms (mhit +0x6c), 0 when the record has none.
    func bookmark(_ i: Int) -> Int {
        guard let raw = tracks[i].raw, raw.count >= 0x70 else { return 0 }
        let d = [UInt8](raw.prefix(0x70))
        return FroggerFile.u32(d, 4) >= 0x70 ? FroggerFile.u32(d, 0x6c) : 0
    }

    @discardableResult
    mutating func setBookmark(_ i: Int, _ ms: Int) -> Bool {
        guard var b = tracks[i].raw.map({ [UInt8]($0) }), b.count >= 0x70, FroggerFile.u32(b, 4) >= 0x70 else { return false }
        b.replaceSubrange(0x6c..<0x70, with: FroggerFile.le32(ms))
        tracks[i].raw = Data(b)
        return true
    }
}
