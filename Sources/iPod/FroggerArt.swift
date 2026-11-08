import Foundation
import AppKit
import AVFoundation
import CryptoKit

// Cover art for Frogger's Now Playing page on the iPod (the frogger repo: docs/nowplaying.md,
// payload/nowplaying.h). iPod_Control/iTunes/FroggerArt holds one small 4-grey picture per album,
// indexed by each track's position in the iTunesDB, so it's written after the database at the end
// of a sync, and deleted whenever the database is written (Syncer.write): its positions are only
// right for the database it was made with. The firmware checks the track count too.
//
// Layout, little-endian: a 24-byte header ("FRGA", version 1 and the picture size as halfwords,
// then track count, image count, bytes per image, 0), a halfword per track (its image, or 0xffff),
// padded to 4 bytes, then the images: 2-bit pixels in the firmware's BMap rows (3 = black, the
// leftmost pixel in the top bits, rows padded to 4 bytes).

enum FroggerArt {
    static let size = 72                                     // payload/nowplaying.h NP_ART_SIZE
    static let row = (size / 4 + 3) & ~3
    static let imageBytes = row * size
    static let none: UInt16 = 0xffff

    static func url(_ ipod: IPodInfo) -> URL { ipod.dbURL.deletingLastPathComponent().appendingPathComponent("FroggerArt") }

    /// The database changed, so the positions in the file don't match any more.
    static func invalidate(_ ipod: IPodInfo) {
        try? FileManager.default.removeItem(at: url(ipod))
    }

    /// Writes the file for this database (to `dst`, the iPod's FroggerArt by default); returns how
    /// many covers it has. `progress` gets (tracks done, tracks, the album being read) for each album.
    @discardableResult
    static func write(_ db: ITunesDB, to ipod: IPodInfo, albums: [Album], dst: URL? = nil,
                      progress: @MainActor (Int, Int, String) -> Void = { _, _, _ in }) async -> Int {
        let tracks = db.tracks.filter { $0.raw != nil }          // what serialize() puts in the mhlt, in order
        var imageOf: [String: UInt16] = [:], images: [Data] = [], table: [UInt16] = []
        var same: [Data: UInt16] = [:]                            // identical pictures (singles of one release) are stored once
        let look = Look.saved
        for (n, t) in tracks.enumerated() {
            let key = albumKey(t)
            if imageOf[key] == nil {
                await progress(n, tracks.count, t.album.isEmpty ? t.title : t.album)
                var image = none
                if images.count < Int(none), let px = await picture(t, ipod: ipod, albums: albums, look: look) {
                    if let i = same[px] { image = i } else { image = UInt16(images.count); images.append(px); same[px] = image }
                }
                imageOf[key] = image
            }
            table.append(imageOf[key] ?? none)
        }
        var out = Data()
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("FRGA".utf8))
        le16(1); le16(size); le32(tracks.count); le32(images.count); le32(imageBytes); le32(0)
        table.forEach { le16(Int($0)) }
        await progress(tracks.count, tracks.count, "")
        out.append(Data(count: (4 - out.count % 4) % 4))
        images.forEach { out.append($0) }
        let dst = dst ?? url(ipod), tmp = dst.appendingPathExtension("new")
        do {
            try out.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            await prepared.clear()
            return 0
        }
        await prepared.clear()                                    // a later write checks the covers again
        return images.count
    }

    /// Tracks of one album share a picture; one without an album gets its own.
    static func albumKey(_ t: PodTrack) -> String {
        t.album.isEmpty ? "file:" + t.location : t.artist.lowercased() + "\u{1f}" + t.album.lowercased()
    }

    /// Dithered pictures from earlier syncs, so a sync only reads and dithers the covers that are new or changed:
    /// one file per album and look, holding the folder's stamp (`folderStamp`) and the pixels (none: no cover).
    static let cacheDir: URL = {
        let d = ArtCache.dir.appendingPathComponent("froggerart")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// The track's picture with `look`: the one `prepare` checked for this sync, else `fresh`.
    static func picture(_ t: PodTrack, ipod: IPodInfo, albums: [Album], look: Look) async -> Data? {
        let album = libraryAlbum(t, albums), podID = "pod:\(t.location)|\(t.size)"
        if let px = await prepared.get(cacheKey(album, podID, look)) { return px }
        return await fresh(album, podID, look) { await cover(t, ipod: ipod, albums: albums) }
    }

    /// Pictures checked ahead of the Cover art phase (`prepare`), by cache key; nil inside: checked, no cover.
    actor Prepared {
        private var px: [String: Data?] = [:]
        func get(_ k: String) -> Data?? { px[k] }
        func set(_ k: String, _ v: Data?) { px[k] = v }
        func clear() { px = [:] }
    }
    static let prepared = Prepared()

    /// Checks every album's picture while the sync is still removing, copying and converting songs (one look at
    /// the share per album, and the reading and dithering of covers that are new or changed), so the Cover art
    /// phase only puts the file together: `tracks` are the iPod's songs, `adding` the library albums going on it.
    /// `write` uses what this found and forgets it afterwards; cancelling stops it early (the rest is made then).
    static func prepare(_ tracks: [PodTrack], adding: [Album], ipod: IPodInfo, albums: [Album]) async {
        await prepared.clear()
        let look = Look.saved
        var seen = Set<String>()
        for t in tracks where t.raw != nil && seen.insert(albumKey(t)).inserted {
            if Task.isCancelled { return }
            let album = libraryAlbum(t, albums), podID = "pod:\(t.location)|\(t.size)"
            let px = await fresh(album, podID, look) { await cover(t, ipod: ipod, albums: albums) }
            await prepared.set(cacheKey(album, podID, look), px)
        }
        for a in adding where seen.insert(a.artist.lowercased() + "\u{1f}" + a.title.lowercased()).inserted {
            if Task.isCancelled { return }
            // its songs aren't on the iPod yet: the library's cover (which includes the art in its files) is all there is
            let px = await fresh(a, "", look) {
                if let d = await LibraryLoader.artwork(for: a) { return d }
                return try? Data(contentsOf: ArtCache.file("album:" + a.folder))
            }
            await prepared.set(cacheKey(a, "", look), px)
        }
    }

    static func cacheKey(_ album: Album?, _ podID: String, _ look: Look) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let id = album.map { "lib:" + $0.folder } ?? podID          // an iPod file's picture never changes
        return id + "|" + (String(data: (try? enc.encode(look)) ?? Data(), encoding: .utf8) ?? "") + "|\(size)"
    }

    /// The picture with `look`, from the disk cache when its album's stamp still matches (or the library can't be
    /// reached right now), else made from `cover()` and cached.
    static func fresh(_ album: Album?, _ podID: String, _ look: Look, cover: () async -> Data?) async -> Data? {
        let stamp = album.map(folderStamp) ?? ""                                        // nil: the album's folder isn't there now
        let key = cacheKey(album, podID, look)
        let file = cacheDir.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined())
        if let c = try? Data(contentsOf: file), c.count >= 2 {
            let n = Int(c[c.startIndex]) | Int(c[c.startIndex + 1]) << 8
            if c.count >= 2 + n, stamp == nil || String(data: c[c.startIndex + 2..<c.startIndex + 2 + n], encoding: .utf8) == stamp {
                let px = c.dropFirst(2 + n)
                return px.isEmpty ? nil : Data(px)
            }
        }
        let px = await cover().flatMap { pixels($0, look: look) }
        if let stamp, px != nil || album != nil {         // made offline (from Crate's art cache): not kept, to try again
            let s = Data(stamp.utf8)
            try? (Data([UInt8(s.count & 0xff), UInt8(s.count >> 8 & 0xff)]) + s + (px ?? Data())).write(to: file)
        }
        return px
    }

    /// What the album's cover comes from, cheaply: the album folder's modification date (one look at the share per
    /// album), which changes when a cover or song in it is added, removed or replaced (Crate's own tag and cover
    /// writes replace the file); nil when the folder can't be read (the share isn't mounted).
    static func folderStamp(_ a: Album) -> String? {
        guard let at = try? FileManager.default.attributesOfItem(atPath: a.folder), let d = at[.modificationDate] as? Date else { return nil }
        return "\(d.timeIntervalSince1970)"
    }

    /// The library album a track on the iPod belongs to (title and artist, else title alone).
    static func libraryAlbum(_ t: PodTrack, _ albums: [Album]) -> Album? {
        let title = t.album.lowercased(), artist = t.artist.lowercased()
        guard !title.isEmpty else { return nil }
        return albums.first(where: { $0.title.lowercased() == title && $0.artist.lowercased() == artist })
            ?? albums.first(where: { $0.title.lowercased() == title })
    }

    /// The library album's cover (LibraryLoader.artwork), else the copy Crate keeps of it (ArtCache, so a sync
    /// while the library's share is unreachable still has covers), else the picture embedded in the song file on
    /// the iPod, else the cover Crate found for an album that's only on the iPod.
    static func cover(_ t: PodTrack, ipod: IPodInfo, albums: [Album]) async -> Data? {
        let title = t.album.lowercased()
        if let a = libraryAlbum(t, albums) {
            if let d = await LibraryLoader.artwork(for: a) { return d }
            if let d = try? Data(contentsOf: ArtCache.file("album:" + a.folder)) { return d }
        }
        let asset = AVURLAsset(url: ipod.mount.appendingPathComponent(t.relativePath))
        for item in (try? await asset.load(.commonMetadata)) ?? [] where item.commonKey == .commonKeyArtwork {
            if let d = try? await item.load(.dataValue) { return d }
        }
        if !title.isEmpty, let d = try? Data(contentsOf: ArtCache.file("pod:" + title)) { return d }
        return nil
    }

    /// How a cover becomes four greys. Set in the Cover Studio (CoverStudio.swift) and used by every
    /// sync; the defaults are what Crate always did (levels stretched, Floyd–Steinberg).
    struct Look: Codable, Equatable {
        enum Dither: String, Codable, CaseIterable { case floydSteinberg = "Floyd–Steinberg", atkinson = "Atkinson", ordered = "Ordered", none = "None" }
        var autoLevels = true           // stretch the 2nd–98th percentile to white…black
        var brightness = 0.0            // −0.5 … 0.5, added to the lightness
        var contrast = 1.0              // 0.5 … 2.5, around mid grey
        var gamma = 1.0                 // 0.4 … 2.5; above 1 lightens the midtones
        var sharpen = 0.0               // 0 … 2, unsharp mask over the 3×3 neighbours
        var dither = Dither.floydSteinberg

        static let key = "froggerArtLook"
        static var saved: Look {
            get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Look.self, from: $0) } ?? Look() }
            set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
        }
    }

    /// The picture as size×size 2-bit pixels, with `look`.
    static func pixels(_ data: Data, look: Look = .saved) -> Data? {
        gray(data).map { render($0, look: look) }
    }

    /// The picture scaled to fill the square (centre crop), as size×size lightnesses (1 = white), top row first.
    static func gray(_ data: Data) -> [Double]? {
        guard let src = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let w = CGFloat(src.width), h = CGFloat(src.height), s = CGFloat(size) / min(w, h)
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(src, in: CGRect(x: (CGFloat(size) - w * s) / 2, y: (CGFloat(size) - h * s) / 2, width: w * s, height: h * s))
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (0..<size * size).map { Double(buf[$0]) / 255 }      // the context's row 0 is the top
    }

    /// Lightnesses → BMap rows: sharpen, stretch the levels, brightness/contrast/gamma, then dither
    /// to the LCD's four greys.
    static func render(_ gray: [Double], look: Look) -> Data {
        var g = gray
        if look.sharpen > 0 {
            g = (0..<g.count).map { i in
                let x = i % size, y = i / size
                var sum = 0.0, n = 0.0
                for dy in -1...1 where y + dy >= 0 && y + dy < size {
                    for dx in -1...1 where x + dx >= 0 && x + dx < size { sum += gray[i + dy * size + dx]; n += 1 }
                }
                return min(1, max(0, gray[i] + look.sharpen * (gray[i] - sum / n)))
            }
        }
        if look.autoLevels {
            let sorted = g.sorted(), lo = sorted[g.count / 50], hi = sorted[g.count - 1 - g.count / 50]
            if hi - lo > 0.05 { g = g.map { min(1, max(0, ($0 - lo) / (hi - lo))) } }
        }
        if look.brightness != 0 || look.contrast != 1 || look.gamma != 1 {
            g = g.map { v in
                let c = min(1, max(0, (v - 0.5) * look.contrast + 0.5 + look.brightness))
                return pow(c, 1 / look.gamma)
            }
        }
        let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        var out = Data(count: imageBytes)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x, want = (1 - g[i]) * 3              // 0 white … 3 black
                let level: Int
                switch look.dither {
                case .ordered: level = Int(min(3, max(0, (want + (bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16 - 0.5).rounded())))
                default: level = Int(min(3, max(0, want.rounded())))
                }
                let err = (want - Double(level)) / 3
                func spread(_ dx: Int, _ dy: Int, _ f: Double) {
                    if x + dx >= 0 && x + dx < size && y + dy < size { g[i + dy * size + dx] -= err * f }
                }
                switch look.dither {
                case .floydSteinberg:
                    spread(1, 0, 7 / 16); spread(-1, 1, 3 / 16); spread(0, 1, 5 / 16); spread(1, 1, 1 / 16)
                case .atkinson:                                          // spreads 6/8 of the error: lighter, crisper
                    for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] { spread(dx, dy, 1 / 8) }
                case .ordered, .none: break
                }
                out[y * row + x / 4] |= UInt8(level << (6 - 2 * (x & 3)))
            }
        }
        return out
    }

    /// The level (0 white … 3 black) of pixel x, y in BMap rows.
    static func level(_ px: Data, _ x: Int, _ y: Int) -> Int {
        Int(px[px.startIndex + y * row + x / 4] >> (6 - 2 * (x & 3))) & 3
    }
}
