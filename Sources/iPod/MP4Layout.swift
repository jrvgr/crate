import Foundation

// The 3rd gen iPod's firmware (2.3, from 2004) reads an MP4/M4A only when its index (`moov`) comes before
// the audio (`mdat`) and the audio box has a plain 32-bit size: every file it plays has that layout. Some
// downloads have the index at the end and a 64-bit `mdat` (and AVFoundation's passthrough export writes
// the 64-bit form too); those don't play on it. `remux` rewrites such a file with the iPod's layout: the
// audio bytes are untouched, only the boxes move and the chunk offsets in the index (`stco`/`co64`) follow.

enum MP4Layout {
    private struct Box { var type: String; var start: Int; var header: Int; var size: Int }

    /// The top-level boxes, reading headers only (seeks, so it's cheap on big files).
    private static func boxes(_ path: String) -> [Box]? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        guard let end = try? f.seekToEnd() else { return nil }
        var out: [Box] = [], o = 0
        while o + 8 <= Int(end) {
            try? f.seek(toOffset: UInt64(o))
            let h = [UInt8](f.readData(ofLength: 16))
            guard h.count >= 8 else { return nil }
            var size = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3]), header = 8
            if size == 1 {
                guard h.count == 16 else { return nil }
                size = h[8..<16].reduce(0) { $0 << 8 | Int($1) }; header = 16
            } else if size == 0 {
                size = Int(end) - o
            }
            guard size >= header else { return nil }
            out.append(Box(type: String(bytes: h[4..<8], encoding: .ascii) ?? "", start: o, header: header, size: size))
            o += size
        }
        return out
    }

    /// Whether the file has the layout the iPod plays: `moov` before `mdat`, neither with a 64-bit size.
    static func iPodReady(_ path: String) -> Bool {
        guard let b = boxes(path), let moov = b.firstIndex(where: { $0.type == "moov" }),
              let mdat = b.firstIndex(where: { $0.type == "mdat" }) else { return true }      // not ours to judge
        return moov < mdat && b[moov].header == 8 && b[mdat].header == 8
    }

    enum Failure: Error, LocalizedError {
        case unexpected(String)
        var errorDescription: String? { if case .unexpected(let s) = self { return "Can't rearrange \(s) for the iPod" }; return nil }
    }

    /// Writes `src` to `dst` as ftyp, moov, mdat (32-bit), dropping padding boxes (free, skip, wide).
    static func remux(_ src: String, to dst: URL) throws {
        let name = (src as NSString).lastPathComponent
        guard let b = boxes(src), let ftyp = b.first(where: { $0.type == "ftyp" }), let moov = b.first(where: { $0.type == "moov" }),
              b.filter({ $0.type == "mdat" }).count == 1, let mdat = b.first(where: { $0.type == "mdat" }),
              mdat.size - mdat.header + 8 <= Int(UInt32.max) else { throw Failure.unexpected(name) }
        let data = try Data(contentsOf: URL(fileURLWithPath: src), options: .mappedIfSafe)
        var index = [UInt8](data[moov.start + moov.header..<moov.start + moov.size])   // moov's children
        let moovSize = 8 + index.count
        let newAudio = ftyp.size + moovSize + 8, oldAudio = mdat.start + mdat.header
        try shift(&index, by: newAudio - oldAudio, name: name)
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        var out = Data(data[ftyp.start..<ftyp.start + ftyp.size])
        out += be32(moovSize) + Array("moov".utf8) + index
        out += be32(mdat.size - mdat.header + 8) + Array("mdat".utf8)
        out += data[oldAudio..<mdat.start + mdat.size]
        try out.write(to: dst)
    }

    /// Adds `delta` to every chunk offset in the index's sample tables.
    private static func shift(_ b: inout [UInt8], by delta: Int, name: String) throws {
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        func walk(_ from: Int, _ to: Int) throws {
            var o = from
            while o + 8 <= to {
                let size = u32(o), type = String(bytes: b[o + 4..<o + 8], encoding: .ascii) ?? ""
                guard size >= 8, o + size <= to else { throw Failure.unexpected(name) }
                switch type {
                case "trak", "mdia", "minf", "stbl", "edts": try walk(o + 8, o + size)
                case "stco":
                    for i in 0..<u32(o + 12) {
                        let p = o + 16 + 4 * i, v = u32(p) + delta
                        guard v >= 0, v <= Int(UInt32.max) else { throw Failure.unexpected(name) }
                        b.replaceSubrange(p..<p + 4, with: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
                    }
                case "co64":
                    for i in 0..<u32(o + 12) {
                        let p = o + 16 + 8 * i
                        let v = b[p..<p + 8].reduce(0) { $0 << 8 | Int($1) } + delta
                        b.replaceSubrange(p..<p + 8, with: (0..<8).map { UInt8(v >> (56 - 8 * $0) & 0xff) })
                    }
                default: break
                }
                o += size
            }
        }
        try walk(0, b.count)
    }
}
