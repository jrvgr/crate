import Foundation
import AVFoundation

// Writes year and genre into the files themselves: Vorbis comments in FLAC, ID3v2 frames in MP3.
// The audio is never touched. When the new tags fit in the space the old ones (plus padding)
// took, only the header is overwritten; otherwise the file is rewritten next to the original
// and swapped in.

enum TagError: Error, LocalizedError {
    case unsupported(String), malformed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Can't write tags to \(s)"
        case .malformed(let s): return "Unexpected tag layout in \(s)"
        }
    }
}

/// The fields Crate can write; nil (or empty) leaves a field as it is.
struct TagEdit: Equatable {
    var title, artist, albumArtist, album, genre: String?
    var year, track, trackCount, disc: Int?
    var cover: Data?

    var flac: [String: String] {
        var f: [String: String] = [:]
        f["TITLE"] = title; f["ARTIST"] = artist; f["ALBUMARTIST"] = albumArtist; f["ALBUM"] = album; f["GENRE"] = genre
        if let y = year, y > 0 { f["DATE"] = "\(y)" }
        if let t = track, t > 0 { f["TRACKNUMBER"] = "\(t)" }
        if let d = disc, d > 0 { f["DISCNUMBER"] = "\(d)" }
        return f.compactMapValues { $0 }
    }
}

enum TagWriter {
    /// Sets the given fields (empty values are skipped). Returns false when nothing changed.
    @discardableResult
    static func write(_ path: String, year: Int, genre: String) throws -> Bool {
        try write(path, TagEdit(genre: genre, year: year))
    }

    @discardableResult
    static func write(_ path: String, _ e: TagEdit) throws -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "flac": return try FLACTags.write(path, e.flac)
        case "mp3": return try ID3Tags.write(path, e)
        case "m4a", "aac", "mp4": return try M4ATags.write(path, e)
        default: throw TagError.unsupported((path as NSString).lastPathComponent)
        }
    }

    static func canWrite(_ path: String) -> Bool { ["flac", "mp3", "m4a", "aac", "mp4"].contains((path as NSString).pathExtension.lowercased()) }

    /// Puts `head` in place of the first `oldLength` bytes of the file.
    static func replaceHead(_ path: String, oldLength: Int, with head: Data) throws {
        if head.count == oldLength {
            let fh = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            try fh.seek(toOffset: 0)
            try fh.write(contentsOf: head)
            return
        }
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).crate-tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp), src = try FileHandle(forReadingFrom: url)
        defer { try? out.close(); try? src.close() }
        do {
            try out.write(contentsOf: head)
            try src.seek(toOffset: UInt64(oldLength))
            while let chunk = try src.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try out.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

enum FLACTags {
    static func write(_ path: String, _ fields: [String: String]) throws -> Bool {
        let name = (path as NSString).lastPathComponent
        guard let fh = FileHandle(forReadingAtPath: path) else { throw TagError.unsupported(name) }
        defer { try? fh.close() }
        guard fh.readData(ofLength: 4) == Data("fLaC".utf8) else { throw TagError.malformed(name) }
        var blocks: [(type: UInt8, body: Data)] = []
        var last = false, end = 4
        while !last {
            let h = [UInt8](fh.readData(ofLength: 4)); guard h.count == 4 else { throw TagError.malformed(name) }
            last = h[0] & 0x80 != 0
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            let body = fh.readData(ofLength: len); guard body.count == len else { throw TagError.malformed(name) }
            blocks.append((h[0] & 0x7F, body))
            end += 4 + len
        }
        guard blocks.first?.type == 0 else { throw TagError.malformed(name) }

        // current Vorbis comment: vendor + KEY=value entries, in order
        var vendor = Data("Crate".utf8), entries: [String] = []
        if let vc = blocks.first(where: { $0.type == 4 })?.body {
            let b = [UInt8](vc)
            func le(_ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }
            let vl = le(0); vendor = Data(b[4..<4 + vl])
            var o = 4 + vl; let n = le(o); o += 4
            for _ in 0..<n {
                let l = le(o); o += 4
                entries.append(String(bytes: b[o..<o + l], encoding: .utf8) ?? ""); o += l
            }
        }
        var changed = false
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            let current = entries.filter { $0.uppercased().hasPrefix(k + "=") }
            if current == ["\(k)=\(v)"] { continue }
            entries.removeAll { $0.uppercased().hasPrefix(k + "=") }
            entries.append("\(k)=\(v)")
            changed = true
        }
        guard changed else { return false }

        let le32 = { (v: Int) in Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
        var vc = le32(vendor.count) + vendor + le32(entries.count)
        for e in entries { let d = Data(e.utf8); vc += le32(d.count) + d }
        var out = blocks.filter { $0.type != 4 && $0.type != 1 }       // padding gets recomputed
        out.insert((4, vc), at: 1)
        let used = 4 + out.map { 4 + $0.body.count }.reduce(0, +)
        let room = end - used
        // fill the old space exactly when there's room for a padding block, else leave 4 KB for next time
        let pad = room >= 4 ? room - 4 : 4096
        out.append((1, Data(count: pad)))
        var head = Data("fLaC".utf8)
        for (i, b) in out.enumerated() {
            let t = b.type | (i == out.count - 1 ? 0x80 : 0), n = b.body.count
            head += Data([t, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + b.body
        }
        try TagWriter.replaceHead(path, oldLength: end, with: head)
        return true
    }
}

enum ID3Tags {
    static func write(_ path: String, _ e: TagEdit) throws -> Bool {
        let name = (path as NSString).lastPathComponent
        guard let fh = FileHandle(forReadingAtPath: path) else { throw TagError.unsupported(name) }
        let h = [UInt8](fh.readData(ofLength: 10))
        var version: UInt8 = 3, frames: [(id: String, body: Data, flags: Data)] = [], oldLength = 0
        if h.count == 10, h[0...2].elementsEqual("ID3".utf8) {
            version = h[3]
            guard version >= 2 && version <= 4, h[5] & 0xC0 == 0 else {     // no unsynchronisation, extended header/compression
                try? fh.close(); throw TagError.malformed(name)
            }
            let size = Int(h[6]) << 21 | Int(h[7]) << 14 | Int(h[8]) << 7 | Int(h[9])
            oldLength = 10 + size + (h[5] & 0x10 != 0 ? 10 : 0)
            let b = [UInt8](fh.readData(ofLength: size))
            var o = 0
            if version == 2 {       // ID3v2.2 (3-letter ids, 3-byte sizes): the frames v2.3 has a name for, written back as v2.3
                while o + 6 <= b.count, b[o] != 0 {
                    let id = String(bytes: b[o..<o + 3], encoding: .ascii) ?? ""
                    let n = Int(b[o+3]) << 16 | Int(b[o+4]) << 8 | Int(b[o+5])
                    guard o + 6 + n <= b.count else { try? fh.close(); throw TagError.malformed(name) }
                    var body = Data(b[o + 6..<o + 6 + n])
                    if id == "PIC", body.count > 5 {        // encoding, 3-letter image format → MIME type, then the same
                        let mime = String(bytes: body[body.startIndex + 1..<body.startIndex + 4], encoding: .ascii)?.uppercased() == "PNG" ? "image/png" : "image/jpeg"
                        body = Data([body[body.startIndex]]) + Data(mime.utf8) + Data([0]) + body.dropFirst(4)
                    }
                    if let id3 = Self.v22[id] { frames.append((id3, body, Data([0, 0]))) }
                    o += 6 + n
                }
                version = 3
            }
            while h[3] != 2, o + 10 <= b.count, b[o] != 0 {
                let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
                let n = version == 4 ? Int(b[o+4]) << 21 | Int(b[o+5]) << 14 | Int(b[o+6]) << 7 | Int(b[o+7])
                                     : Int(b[o+4]) << 24 | Int(b[o+5]) << 16 | Int(b[o+6]) << 8 | Int(b[o+7])
                guard o + 10 + n <= b.count else { try? fh.close(); throw TagError.malformed(name) }
                frames.append((id, Data(b[o + 10..<o + 10 + n]), Data(b[o + 8..<o + 10])))
                o += 10 + n
            }
        }
        try? fh.close()

        func text(_ s: String) -> Data {
            version == 4 ? Data([3]) + Data(s.utf8)                                       // UTF-8
                         : Data([1, 0xFF, 0xFE]) + Data(s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        }
        func current(_ id: String) -> String? {
            guard let f = frames.first(where: { $0.id == id }), let enc = f.body.first else { return nil }
            let rest = f.body.dropFirst()
            let s: String? = switch enc {
            case 0: String(bytes: rest, encoding: .isoLatin1)
            case 1: String(bytes: rest, encoding: .utf16)
            case 2: String(bytes: rest, encoding: .utf16BigEndian)
            default: String(bytes: rest, encoding: .utf8)
            }
            return s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        var changed = false
        func set(_ id: String, _ value: String) {
            guard !value.isEmpty, current(id) != value else { return }
            frames.removeAll { $0.id == id }
            frames.append((id, text(value), Data([0, 0])))
            changed = true
        }
        let yearID = version == 4 ? "TDRC" : "TYER"
        // A file whose title, album… are only in the old ID3v1 tag at its end: carry them into the v2 tag, or
        // players (which read v2 first) would see a tag without them once it has the edited fields.
        if let v1 = id1(path) {
            for (id, value) in [("TIT2", v1.title), ("TPE1", v1.artist), ("TALB", v1.album), (yearID, v1.year), ("TRCK", v1.track)]
            where !value.isEmpty && current(id) == nil {
                frames.append((id, text(value), Data([0, 0]))); changed = true
            }
        }
        if let year = e.year, year > 0, current(yearID).map({ Int($0.prefix(4)) }) != year { set(yearID, "\(year)") }
        set("TCON", e.genre ?? "")
        set("TIT2", e.title ?? ""); set("TPE1", e.artist ?? ""); set("TPE2", e.albumArtist ?? ""); set("TALB", e.album ?? "")
        if let t = e.track, t > 0 { set("TRCK", e.trackCount.map { "\(t)/\($0)" } ?? "\(t)") }
        if let d = e.disc, d > 0 { set("TPOS", "\(d)") }
        guard changed else { return false }

        var body = Data()
        for f in frames {
            let n = f.body.count
            let size: [UInt8] = version == 4 ? [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)]
                                             : [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            body += Data(f.id.utf8) + Data(size) + f.flags + f.body
        }
        // keep the tag the same size when it fits, so only the header is rewritten
        let total = oldLength >= 10 + body.count ? oldLength - 10 : body.count + 2048
        body += Data(count: total - body.count)
        let head = Data("ID3".utf8) + Data([version, 0, 0,
                    UInt8(total >> 21 & 0x7F), UInt8(total >> 14 & 0x7F), UInt8(total >> 7 & 0x7F), UInt8(total & 0x7F)]) + body
        try TagWriter.replaceHead(path, oldLength: oldLength, with: head)
        return true
    }
}

extension ID3Tags {
    /// ID3v2.2 frame ids and their v2.3 names (the ones Crate or a player cares about).
    static let v22: [String: String] = ["TT2": "TIT2", "TP1": "TPE1", "TP2": "TPE2", "TAL": "TALB", "TYE": "TYER",
        "TRK": "TRCK", "TPA": "TPOS", "TCO": "TCON", "TCM": "TCOM", "TEN": "TENC", "TBP": "TBPM", "TT1": "TIT1",
        "TT3": "TIT3", "TP3": "TPE3", "COM": "COMM", "ULT": "USLT", "PIC": "APIC"]

    /// The ID3v1 tag in a file's last 128 bytes ("TAG", then 30-byte title, artist, album, a 4-byte year, a
    /// 30-byte comment whose last byte is the track number when the one before it is 0, and a genre byte).
    static func id1(_ path: String) -> (title: String, artist: String, album: String, year: String, track: String)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd(), end >= 128 else { return nil }
        try? fh.seek(toOffset: end - 128)
        let b = [UInt8](fh.readData(ofLength: 128))
        guard b.count == 128, b[0...2].elementsEqual("TAG".utf8) else { return nil }
        func field(_ o: Int, _ n: Int) -> String {
            let bytes = b[o..<o + n].prefix { $0 != 0 }
            return (String(bytes: bytes, encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespaces)
        }
        let track = b[125] == 0 && b[126] != 0 ? "\(b[126])" : ""
        return (field(3, 30), field(33, 30), field(63, 30), field(93, 4), track)
    }
}

/// MP4/M4A (AAC, ALAC): rewritten through AVFoundation with the audio passed through untouched.
enum M4ATags {
    static func write(_ path: String, _ e: TagEdit) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let done = DispatchSemaphore(value: 0)
        var existing: [AVMetadataItem] = []
        Task.detached { existing = (try? await asset.load(.metadata)) ?? []; done.signal() }
        done.wait()
        func item(_ id: AVMetadataIdentifier, _ v: Any) -> AVMetadataItem {
            let m = AVMutableMetadataItem(); m.identifier = id; m.value = v as? NSCopying & NSObjectProtocol
            if v is Data, id != .iTunesMetadataCoverArt { m.dataType = kCMMetadataBaseDataType_RawData as String }
            return m
        }
        func pair(_ n: Int, _ total: Int) -> Data { Data([0, 0, UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF), 0, 0]) }
        var set: [(AVMetadataIdentifier, Any)] = []
        if let v = e.title, !v.isEmpty { set.append((.iTunesMetadataSongName, v)) }
        if let v = e.artist, !v.isEmpty { set.append((.iTunesMetadataArtist, v)) }
        if let v = e.albumArtist, !v.isEmpty { set.append((.iTunesMetadataAlbumArtist, v)) }
        if let v = e.album, !v.isEmpty { set.append((.iTunesMetadataAlbum, v)) }
        if let v = e.genre, !v.isEmpty { set.append((.iTunesMetadataUserGenre, v)) }
        if let v = e.year, v > 0 { set.append((.iTunesMetadataReleaseDate, "\(v)")) }
        if let v = e.track, v > 0 { set.append((.iTunesMetadataTrackNumber, pair(v, e.trackCount ?? 0))) }
        if let v = e.disc, v > 0 { set.append((.iTunesMetadataDiscNumber, pair(v, 0))) }
        if let v = e.cover { set.append((.iTunesMetadataCoverArt, v)) }
        guard !set.isEmpty else { return false }
        let replaced = Set(set.map(\.0))
        // the common-key twins of what's being set would win in some readers, so they go too
        let twins: [AVMetadataIdentifier: AVMetadataIdentifier] = [.commonIdentifierTitle: .iTunesMetadataSongName,
            .commonIdentifierArtist: .iTunesMetadataArtist, .commonIdentifierAlbumName: .iTunesMetadataAlbum]
        let kept = existing.filter { m in
            guard let id = m.identifier else { return true }
            return !replaced.contains(id) && !(twins[id].map(replaced.contains) ?? false)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).crate-tmp.m4a")
        try? FileManager.default.removeItem(at: tmp)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw TagError.unsupported(url.lastPathComponent) }
        ex.outputURL = tmp; ex.outputFileType = .m4a
        // moov before mdat: without it the export puts moov last, and the 3rd gen iPod skips such files
        ex.shouldOptimizeForNetworkUse = true
        ex.metadata = kept + set.map { item($0.0, $0.1) }
        var failure: Error?
        let finished = DispatchSemaphore(value: 0)
        Task.detached { do { try await ex.export(to: tmp, as: .m4a) } catch { failure = error }; finished.signal() }
        finished.wait()
        if let failure { try? FileManager.default.removeItem(at: tmp); throw failure }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return true
    }
}
