import Foundation

// Reads and writes the classic iPod iTunesDB (mhbd/mhsd/mhlt/mhit/mhlp/mhyp/mhip/mhod).
// Existing track and playlist records are kept byte for byte; only the track list and the
// master playlist are rebuilt, so data written by iTunes or iOpenPod survives a sync.

struct PodTrack: Identifiable, Hashable {
    var id: UInt32
    var title = "", artist = "", album = "", genre = "", location = ""
    var trackNumber = 0, size = 0, lengthMs = 0
    var raw: Data? = nil          // original mhit record (header + mhods)

    var key: String { TrackKey.make(album: album, title: title) }
    var relativePath: String { location.split(separator: ":").joined(separator: "/") }
}

enum TrackKey {
    static func make(album: String, title: String) -> String {
        [album, title].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.joined(separator: "\u{1}")
    }
}

/// A playlist other than the master playlist. Playlists read from the iPod keep their
/// header and mhods (name, smart rules, ...) and their items as they were; items of
/// tracks that are no longer on the iPod are dropped when writing.
struct PodPlaylist: Identifiable, Hashable {
    struct Item: Hashable { var trackID: UInt32; var raw: Data? = nil }
    var id: UInt64 = UInt64.random(in: 1...UInt64.max)     // persistent id
    var name: String
    var items: [Item]
    var raw: Data? = nil          // original mhyp header + mhods (without the items)
}

struct NewTrack {
    var title, artist, album, genre: String
    var trackNumber, trackCount, discNumber, year: Int
    var lengthMs, bitrateKbps, sampleRate, size: Int
    var location: String          // ":iPod_Control:Music:F00:ABCD.m4a"
    var isAAC: Bool
}

enum ITunesDBError: Error, LocalizedError {
    case malformed(String)
    var errorDescription: String? { if case .malformed(let s) = self { return "iTunesDB: \(s)" }; return nil }
}

struct ITunesDB {
    var header: Data              // mhbd header bytes, reused when writing
    var tracks: [PodTrack]
    var name: String              // master playlist name = iPod name
    var playlists: [PodPlaylist] = []

    // MARK: reading

    static func read(_ data: Data) throws -> ITunesDB {
        let d = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 }
        func tag(_ o: Int) -> String { String(bytes: d[o..<o+4], encoding: .ascii) ?? "" }
        guard d.count >= 0x68, tag(0) == "mhbd" else { throw ITunesDBError.malformed("no mhbd") }
        func str(_ o: Int) -> (type: Int, text: String) {
            let type = u32(o + 12)
            guard type < 50, o + 40 <= d.count else { return (type, "") }
            let len = u32(o + 28)
            let s = String(bytes: d[(o + 40)..<min(o + 40 + len, d.count)], encoding: .utf16LittleEndian) ?? ""
            return (type, s)
        }
        var db = ITunesDB(header: Data(d[0..<u32(4)]), tracks: [], name: "iPod")
        var o = u32(4)
        while o + 16 <= d.count, tag(o) == "mhsd" {
            let total = u32(o + 8), type = u32(o + 12)
            let list = o + u32(o + 4)
            if type == 1, tag(list) == "mhlt" {
                var p = list + u32(list + 4)
                for _ in 0..<u32(list + 8) {
                    guard tag(p) == "mhit" else { throw ITunesDBError.malformed("bad mhit at \(p)") }
                    let tl = u32(p + 8)
                    var t = PodTrack(id: UInt32(u32(p + 16)))
                    t.size = u32(p + 36); t.lengthMs = u32(p + 40); t.trackNumber = u32(p + 44)
                    var q = p + u32(p + 4)
                    for _ in 0..<u32(p + 12) {
                        let s = str(q)
                        switch s.type { case 1: t.title = s.text; case 2: t.location = s.text
                        case 3: t.album = s.text; case 4: t.artist = s.text; case 5: t.genre = s.text; default: break }
                        q += u32(q + 8)
                    }
                    t.raw = Data(d[p..<p + tl])
                    db.tracks.append(t)
                    p += tl
                }
            } else if type == 2, tag(list) == "mhlp" {
                var pl = list + u32(list + 4)
                for _ in 0..<u32(list + 8) {
                    guard pl + 0x30 <= d.count, tag(pl) == "mhyp" else { throw ITunesDBError.malformed("bad mhyp at \(pl)") }
                    let hl = u32(pl + 4), master = d[pl + 20] != 0
                    var name = "", q = pl + hl
                    for _ in 0..<u32(pl + 12) where tag(q) == "mhod" {
                        let s = str(q); if s.type == 1 { name = s.text }
                        q += u32(q + 8)
                    }
                    if master {
                        if !name.isEmpty { db.name = name }
                    } else {
                        var p = PodPlaylist(name: name, items: [], raw: Data(d[pl..<q]))
                        if hl >= 36 { p.id = UInt64(u32(pl + 28)) | UInt64(u32(pl + 32)) << 32 }
                        for _ in 0..<u32(pl + 16) {
                            guard tag(q) == "mhip" else { throw ITunesDBError.malformed("bad mhip at \(q)") }
                            p.items.append(.init(trackID: UInt32(u32(q + 24)), raw: Data(d[q..<q + u32(q + 8)])))
                            q += u32(q + 8)
                        }
                        db.playlists.append(p)
                    }
                    pl += u32(pl + 8)
                }
            }
            o += total
        }
        return db
    }

    // MARK: writing

    private static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    private static func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    private static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (UInt64($0) * 8)) } }

    private static func block(_ tag: String, _ headerLen: Int, _ fields: [UInt8], _ children: [UInt8] = []) -> [UInt8] {
        var h = Array(tag.utf8) + le32(headerLen) + le32(headerLen + children.count) + fields
        h += [UInt8](repeating: 0, count: max(0, headerLen - h.count))
        return h + children
    }

    private static func list(_ tag: String, _ count: Int, _ children: [UInt8]) -> [UInt8] {
        var h = Array(tag.utf8) + le32(0x5C) + le32(count)
        h += [UInt8](repeating: 0, count: 0x5C - h.count)
        return h + children
    }

    private static func mhodString(_ type: Int, _ text: String) -> [UInt8] {
        let s = Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return block("mhod", 0x18, le32(type) + le32(0) + le32(0), le32(1) + le32(s.count) + le32(0) + le32(0) + s)
    }

    static func mhit(id: UInt32, _ t: NewTrack, now: Int) -> Data {
        var mhods = [mhodString(1, t.title), mhodString(2, t.location),
                     mhodString(6, t.isAAC ? "AAC audio file" : "MPEG audio file")]
        if !t.album.isEmpty { mhods.append(mhodString(3, t.album)) }
        if !t.artist.isEmpty { mhods.append(mhodString(4, t.artist)) }
        if !t.genre.isEmpty { mhods.append(mhodString(5, t.genre)) }
        var f = le32(mhods.count) + le32(Int(id)) + le32(1)
        f += t.isAAC ? Array(" A4M".utf8) + [0, 0, 0, 0] : Array(" 3PM".utf8) + [0, 1, 0, 0]
        for v in [now, t.size, t.lengthMs, t.trackNumber, t.trackCount, t.year, t.bitrateKbps, t.sampleRate << 16, 0,
                  0, 0, 0, 0, 0, 0, t.discNumber, 0, 0, now, 0] { f += le32(v) }
        f += le64(UInt64.random(in: 1...UInt64.max))
        // iTunes 7 header size; later fields stay zero
        return Data(block("mhit", 0x184, f, mhods.flatMap { $0 }))
    }

    private static func mhip(_ trackID: UInt32, index i: Int, now: Int) -> [UInt8] {
        var pos = Array("mhod".utf8) + le32(0x18) + le32(0x2C) + le32(100) + le32(0) + le32(0) + le32(i)
        pos += [UInt8](repeating: 0, count: 0x2C - pos.count)
        return block("mhip", 0x4C, le32(1) + le32(0) + le32(i + 1) + le32(Int(trackID)) + le32(now), pos)
    }

    private static func mhyp(_ name: String, master: Bool, id: UInt64, items: [UInt32], now: Int) -> [UInt8] {
        block("mhyp", 0x6C, le32(1) + le32(items.count) + [master ? 1 : 0, 0, 0, 0] + le32(now) + le64(id),
              mhodString(1, name) + items.enumerated().flatMap { mhip($1, index: $0, now: now) })
    }

    private func playlistRecord(_ p: PodPlaylist, onPod: Set<UInt32>, now: Int) -> [UInt8] {
        let items = p.items.filter { onPod.contains($0.trackID) }
        guard var h = p.raw.map({ [UInt8]($0) }) else { return Self.mhyp(p.name, master: false, id: p.id, items: items.map(\.trackID), now: now) }
        let body = items.enumerated().flatMap { i, item in item.raw.map { [UInt8]($0) } ?? Self.mhip(item.trackID, index: i, now: now) }
        h.replaceSubrange(8..<12, with: Self.le32(h.count + body.count))
        h.replaceSubrange(16..<20, with: Self.le32(items.count))
        return h + body
    }

    func serialize() -> Data {
        let now = Int(Date().timeIntervalSince1970) + 2_082_844_800
        let mhits = tracks.compactMap { $0.raw }.flatMap { [UInt8]($0) }
        let mhlt = Self.list("mhlt", tracks.count, mhits)
        let onPod = Set(tracks.map(\.id))
        let master = Self.mhyp(name, master: true, id: UInt64.random(in: 1...UInt64.max), items: tracks.map(\.id), now: now)
        let mhlp = Self.list("mhlp", 1 + playlists.count, master + playlists.flatMap { playlistRecord($0, onPod: onPod, now: now) })
        let sections = Self.block("mhsd", 0x60, Self.le32(1), mhlt) + Self.block("mhsd", 0x60, Self.le32(3), mhlp)
                     + Self.block("mhsd", 0x60, Self.le32(2), mhlp)
        var h = [UInt8](header)
        if h.count < 0x68 {   // fresh database: iTunes 7 style header
            h = Self.block("mhbd", 0xBC, Self.le32(1) + Self.le32(0x13) + Self.le32(3)
                           + Self.le64(UInt64.random(in: 1...UInt64.max)) + Self.le16(2))
        }
        h.replaceSubrange(8..<12, with: Self.le32(h.count + sections.count))
        h.replaceSubrange(20..<24, with: Self.le32(3))
        return Data(h + sections)
    }

    var nextID: UInt32 { (tracks.map(\.id).max() ?? 0) + 1 }

    static func empty(name: String) -> ITunesDB { ITunesDB(header: Data(), tracks: [], name: name) }
}
