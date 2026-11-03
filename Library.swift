import Foundation
import AVFoundation

// The music on the shares: OwnTone's local files plus extra folders scanned directly.

struct LibTrack: Identifiable, Hashable, Codable {
    var id: String { path }
    var title, artist, album, genre: String          // artist = album artist (for grouping)
    var trackNumber, discNumber, year, lengthMs: Int
    var path: String
    var trackArtist = ""
    var uri = ""                                     // OwnTone's library:track:N, for playing
    var added: Date? = nil
    var key: String { TrackKey.make(album: album, title: title) }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var needsConversion: Bool { !["mp3", "m4a", "aac"].contains(ext) }
}

struct Album: Identifiable, Hashable {
    var id: String { title.lowercased() }
    var title, artist: String
    var tracks: [LibTrack]
    var year: Int { tracks.map(\.year).max() ?? 0 }
    var folder: String { (tracks.first?.path as NSString?)?.deletingLastPathComponent ?? "" }
    var added: Date? { tracks.compactMap(\.added).max() }
    var genre: String { tracks.first { !$0.genre.isEmpty }?.genre ?? "" }
    var lengthMs: Int { tracks.map(\.lengthMs).reduce(0, +) }
}

enum LibraryLoader {
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac"]

    /// OwnTone paths are inside the add-on (/share/..., /media/...); the Mac sees them under /Volumes.
    static func localPath(_ p: String) -> String {
        for (a, b) in [("/share/", "/Volumes/share/"), ("/media/", "/Volumes/media/")] where p.hasPrefix(a) {
            return b + p.dropFirst(a.count)
        }
        return p
    }

    static func fromOwnTone(_ base: String) async throws -> [LibTrack] {
        var c = URLComponents(string: base + "/api/search")!
        c.queryItems = [.init(name: "type", value: "tracks"), .init(name: "expression", value: "data_kind is file"),
                        .init(name: "limit", value: "20000")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = ((root?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        return items.compactMap { i in
            guard let p = i["path"] as? String else { return nil }
            let s = { (k: String) in (i[k] as? String) ?? "" }
            let n = { (k: String) in (i[k] as? Int) ?? 0 }
            let artist = s("album_artist").isEmpty ? s("artist") : s("album_artist")
            return LibTrack(title: s("title"), artist: artist, album: s("album"), genre: s("genre"),
                            trackNumber: n("track_number"), discNumber: n("disc_number"), year: n("year"),
                            lengthMs: n("length_ms"), path: localPath(p), trackArtist: s("artist"), uri: s("uri"),
                            added: iso.date(from: s("time_added")))
        }
    }

    /// Scans a folder; tags come from AVFoundation where it can read them, otherwise from
    /// the Artist/Album/NN Title layout.
    /// A scanned file's tags, kept while its date and size stay the same.
    struct Scanned: Codable { var modified: Double; var size: Int; var track: LibTrack }

    /// Reads the folder's songs: files that haven't changed since the last scan come from the cache,
    /// the rest are read eight at a time (a network share mostly waits).
    static func scan(_ folder: String, skipping known: Set<String> = []) async -> [LibTrack] {
        guard let e = FileManager.default.enumerator(atPath: folder) else { return [] }
        var files: [(rel: String, modified: Double, size: Int)] = []
        while let rel = e.nextObject() as? String {
            if (rel as NSString).lastPathComponent.hasPrefix(".") { e.skipDescendants(); continue }     // .crate-trash and friends
            guard audioExts.contains((rel as NSString).pathExtension.lowercased()), !known.contains(folder + "/" + rel) else { continue }
            let a = e.fileAttributes      // from the listing itself, no extra trip to the disk
            files.append((rel, (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (a?[.size] as? Int) ?? 0))
        }
        var cache: [String: Scanned] = Store.load("scan-cache.json", [:])
        var out = [LibTrack?](repeating: nil, count: files.count), todo: [Int] = []
        for (i, f) in files.enumerated() {
            if let c = cache[folder + "/" + f.rel], c.modified == f.modified, c.size == f.size { out[i] = c.track } else { todo.append(i) }
        }
        let names = files.map(\.rel)
        await withTaskGroup(of: (Int, LibTrack).self) { g in
            var next = 0
            for _ in 0..<min(8, todo.count) {
                let i = todo[next]; next += 1
                g.addTask { (i, await track(folder + "/" + names[i], relative: names[i])) }
            }
            while let (i, t) = await g.next() {
                out[i] = t
                if next < todo.count {
                    let j = todo[next]; next += 1
                    g.addTask { (j, await track(folder + "/" + names[j], relative: names[j])) }
                }
            }
        }
        if !todo.isEmpty {
            for i in todo { if let t = out[i] { cache[folder + "/" + files[i].rel] = Scanned(modified: files[i].modified, size: files[i].size, track: t) } }
            Store.save("scan-cache.json", cache)
        }
        return out.compactMap { $0 }
    }

    /// One file's tags; without tags the Artist/Album/NN Title layout of `relative` fills in.
    static func track(_ path: String, relative rel: String) async -> LibTrack {
            let parts = rel.split(separator: "/").map(String.init)
            var name = ((parts.last ?? "") as NSString).deletingPathExtension
            var num = 0
            let digits = name.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3 {
                let rest = name.dropFirst(digits.count).drop { " .-_".contains($0) }
                if !rest.isEmpty { num = Int(digits) ?? 0; name = String(rest) }
            }
            var t = LibTrack(title: name, artist: parts.count >= 3 ? parts[parts.count - 3] : "Unknown Artist",
                             album: parts.count >= 2 ? parts[parts.count - 2] : "Unknown Album", genre: "",
                             trackNumber: num, discNumber: 0, year: 0, lengthMs: 0, path: path)
            t.added = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
            if let f = FLACMeta.read(path) {
                let g = { (k: String) in f.tags[k] ?? "" }
                if !g("TITLE").isEmpty { t.title = g("TITLE") }
                if !g("ARTIST").isEmpty { t.trackArtist = g("ARTIST"); t.artist = g("ARTIST") }
                if !g("ALBUMARTIST").isEmpty { t.artist = g("ALBUMARTIST") }
                if !g("ALBUM").isEmpty { t.album = g("ALBUM") }
                t.genre = g("GENRE")
                t.trackNumber = Int(g("TRACKNUMBER").split(separator: "/").first ?? "") ?? t.trackNumber
                t.discNumber = Int(g("DISCNUMBER").split(separator: "/").first ?? "") ?? 0
                t.year = Int(g("DATE").prefix(4)) ?? 0
                t.lengthMs = f.lengthMs
                return t
            }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            if let meta = try? await asset.load(.commonMetadata) {
                for item in meta {
                    guard let v = try? await item.load(.stringValue), !v.isEmpty else { continue }
                    switch item.commonKey {
                    case .commonKeyTitle?: t.title = v
                    case .commonKeyArtist?: t.artist = v; t.trackArtist = v
                    case .commonKeyAlbumName?: t.album = v
                    case .commonKeyType?: t.genre = v
                    default: break
                    }
                }
            }
            if let d = try? await asset.load(.duration), d.isNumeric { t.lengthMs = Int(d.seconds * 1000) }
            // AVFoundation has no album-artist or track-number common key; read them from ID3/iTunes metadata
            if let all = try? await asset.load(.metadata) {
                for item in all {
                    let id = item.identifier
                    if id == .id3MetadataBand || id == .iTunesMetadataAlbumArtist, let v = try? await item.load(.stringValue), !v.isEmpty { t.artist = v }
                    if id == .id3MetadataTrackNumber, let v = try? await item.load(.stringValue), let n = Int(v.split(separator: "/").first ?? "") { t.trackNumber = n }
                    if id == .id3MetadataRecordingTime || id == .id3MetadataYear || id == .iTunesMetadataReleaseDate,
                       let v = try? await item.load(.stringValue), let y = Int(v.prefix(4)) { t.year = y }
                    if id == .id3MetadataPartOfASet, let v = try? await item.load(.stringValue), let n = Int(v.split(separator: "/").first ?? "") { t.discNumber = n }
                    if id == .iTunesMetadataUserGenre || id == .id3MetadataContentType, let v = try? await item.load(.stringValue), !v.isEmpty { t.genre = v }
                    if id == .iTunesMetadataTrackNumber || id == .iTunesMetadataDiscNumber, let d = try? await item.load(.dataValue), d.count >= 4 {
                        let n = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                        if id == .iTunesMetadataTrackNumber { t.trackNumber = n } else { t.discNumber = n }
                    }
                }
            }
            return t
    }

    static func albums(_ tracks: [LibTrack]) -> [Album] {
        Dictionary(grouping: tracks) { $0.album.lowercased() }.values.map { ts in
            Album(title: ts[0].album,
                  artist: Set(ts.map(\.artist)).count > 2 ? "Various Artists"
                      : Dictionary(grouping: ts, by: \.artist).max { $0.value.count < $1.value.count }!.key,
                  tracks: ts.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) })
        }.sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    /// Artist picture in the folder above the albums (artist.jpg, or folder.jpg as some downloaders save it),
    /// when that folder is named after the artist.
    static func artistImage(_ a: Artist) -> Data? {
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        for al in a.albums where !al.folder.isEmpty && al.folder.hasPrefix("/") {
            let dir = (al.folder as NSString).deletingLastPathComponent
            let name = loose((dir as NSString).lastPathComponent), artist = loose(a.name)
            guard !artist.isEmpty, name.contains(artist) || artist.contains(name) else { continue }
            for n in ["artist.jpg", "artist.png", "folder.jpg", "folder.png"] {
                if let d = FileManager.default.contents(atPath: dir + "/" + n) { return d }
            }
        }
        return nil
    }

    /// Album cover: folder.jpg/cover.jpg next to the tracks, else embedded artwork.
    static func artwork(for album: Album) async -> Data? {
        for n in ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "front.jpg"] {
            if let d = FileManager.default.contents(atPath: album.folder + "/" + n) { return d }
        }
        // other names: one with front/cover/folder in it ("… Cover Front.jpg", not a back cover), or the only image
        let images = ((try? FileManager.default.contentsOfDirectory(atPath: album.folder)) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }.sorted()
        let named = images.first { n in
            let l = n.lowercased()
            return ["front", "cover", "folder"].contains { l.contains($0) } && !["back", "inlay", "cd.", "disc", "tray"].contains { l.contains($0) }
        }
        if let n = named ?? (images.count == 1 ? images[0] : nil), let d = FileManager.default.contents(atPath: album.folder + "/" + n) { return d }
        guard let first = album.tracks.first else { return nil }
        if let pic = FLACMeta.read(first.path)?.picture { return pic }
        let asset = AVURLAsset(url: URL(fileURLWithPath: first.path))
        for item in (try? await asset.load(.commonMetadata)) ?? [] where item.commonKey == .commonKeyArtwork {
            if let d = try? await item.load(.dataValue) { return d }
        }
        return nil
    }
}

/// Asks OwnTone to rescan its library (after files were added to its folder).
func ownToneRescan(_ base: String) async {
    var r = URLRequest(url: URL(string: base + "/api/update")!); r.httpMethod = "PUT"
    _ = try? await URLSession.shared.data(for: r)
}

/// Minimal FLAC metadata reader: Vorbis comments (tags) and the front-cover picture.
enum FLACMeta {
    static func read(_ path: String) -> (tags: [String: String], picture: Data?, lengthMs: Int)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard fh.readData(ofLength: 4) == Data("fLaC".utf8) else { return nil }
        var tags: [String: String] = [:], picture: Data?, lengthMs = 0
        var last = false
        while !last {
            let h = [UInt8](fh.readData(ofLength: 4)); guard h.count == 4 else { break }
            last = h[0] & 0x80 != 0
            let type = h[0] & 0x7F, len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            let b = [UInt8](fh.readData(ofLength: len)); guard b.count == len else { break }
            func le(_ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }
            func be(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o+1]) << 16 | Int(b[o+2]) << 8 | Int(b[o+3]) }
            switch type {
            case 0 where len >= 18:   // STREAMINFO: sample rate (20 bits) + total samples (36 bits)
                let rate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
                let samples = (Int(b[13]) & 0x0F) << 32 | Int(b[14]) << 24 | Int(b[15]) << 16 | Int(b[16]) << 8 | Int(b[17])
                if rate > 0 { lengthMs = samples * 1000 / rate }
            case 4:
                var o = 4 + le(0)
                let n = le(o); o += 4
                for _ in 0..<n where o + 4 <= len {
                    let l = le(o); o += 4
                    if let s = String(bytes: b[o..<min(o + l, len)], encoding: .utf8), let eq = s.firstIndex(of: "=") {
                        let k = s[..<eq].uppercased(), v = String(s[s.index(after: eq)...])
                        if tags[k] == nil { tags[k] = v }
                    }
                    o += l
                }
            case 6 where picture == nil || be(0) == 3:
                var o = 4; o += 4 + be(o); o += 4 + be(o); o += 16
                let dl = be(o); o += 4
                if o + dl <= len { picture = Data(b[o..<o + dl]) }
            default: break
            }
        }
        return (tags, picture, lengthMs)
    }
}

/// A Spotify album from OwnTone's library (streaming only; it can't be copied to the iPod).
struct SpotifyAlbum: Identifiable, Hashable {
    var id: String { uri }
    var name, artist, uri, artworkPath: String
    var trackCount, year: Int
}

enum SpotifyLibrary {
    static func albums(_ base: String) async throws -> [SpotifyAlbum] {
        var c = URLComponents(string: base + "/api/search")!
        c.queryItems = [.init(name: "type", value: "albums"), .init(name: "expression", value: "data_kind is spotify"),
                        .init(name: "limit", value: "10000")]
        let (d, _) = try await URLSession.shared.data(from: c.url!)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        let items = ((j?["albums"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.map { a in
            SpotifyAlbum(name: a["name"] as? String ?? "", artist: a["artist"] as? String ?? "",
                         uri: a["uri"] as? String ?? "", artworkPath: a["artwork_url"] as? String ?? "",
                         trackCount: a["track_count"] as? Int ?? 0, year: a["year"] as? Int ?? 0)
        }.sorted { ($0.trackCount, $1.name) > ($1.trackCount, $0.name) }
    }

    /// Starts the album on OwnTone's current outputs (e.g. the iMac).
    static func play(_ a: SpotifyAlbum, base: String) async {
        var c = URLComponents(string: base + "/api/queue/items/add")!
        c.queryItems = [.init(name: "uris", value: a.uri), .init(name: "clear", value: "true"), .init(name: "playback", value: "start")]
        var r = URLRequest(url: c.url!); r.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: r)
    }
}

/// A playlist in OwnTone's library (mostly Spotify playlists). Its tracks go to the iPod
/// as far as there are files for them.
struct OTPlaylist: Identifiable, Hashable {
    var id: Int
    var name, uri: String
    var count: Int
    var spotifyID: String? = nil      // read from Spotify itself (the Spotify plugin) instead of OwnTone
    var artwork = ""
    var path = ""                     // OwnTone's: the .m3u it reads the playlist from
}

struct OTTrack: Identifiable, Hashable {
    var id: Int
    var title, artist, album, albumArtist, dataKind, uri, artworkPath: String
    var lengthMs: Int
    var path = ""                     // OwnTone's file path (or URL)
    var key: String { TrackKey.make(album: album, title: title) }
}

enum OwnTonePlaylists {
    static func all(_ base: String) async throws -> [OTPlaylist] {
        let (d, _) = try await URLSession.shared.data(from: URL(string: base + "/api/library/playlists?limit=1000")!)
        let items = ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.compactMap { p in
            guard let id = p["id"] as? Int, (p["item_count"] as? Int ?? 0) > 0 else { return nil }
            return OTPlaylist(id: id, name: p["name"] as? String ?? "", uri: p["uri"] as? String ?? "", count: p["item_count"] as? Int ?? 0,
                              path: p["path"] as? String ?? "")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func tracks(_ id: Int, base: String) async throws -> [OTTrack] {
        let (d, _) = try await URLSession.shared.data(from: URL(string: base + "/api/library/playlists/\(id)/tracks")!)
        let items = ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.map { t in
            let s = { (k: String) in (t[k] as? String) ?? "" }
            return OTTrack(id: t["id"] as? Int ?? 0, title: s("title"), artist: s("artist"), album: s("album"),
                           albumArtist: s("album_artist"), dataKind: s("data_kind"), uri: s("uri"),
                           artworkPath: s("artwork_url"), lengthMs: t["length_ms"] as? Int ?? 0, path: s("path"))
        }
    }

    /// Replaces OwnTone's queue with these items and starts playing.
    static func play(_ uris: [String], base: String) async {
        var c = URLComponents(string: base + "/api/queue/items/add")!
        c.queryItems = [.init(name: "uris", value: uris.joined(separator: ",")), .init(name: "clear", value: "true"),
                        .init(name: "playback", value: "start")]
        var r = URLRequest(url: c.url!); r.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: r)
    }
}

/// Copies dropped audio files (or folders of them) into OwnTone's music folder as
/// <import folder>/<Album Artist>/<Album>/<file>, with any cover images from the dropped folders.
enum Importer {
    static let images: Set<String> = ["jpg", "jpeg", "png"]

    static func audioFiles(_ urls: [URL]) -> [(path: String, relative: String)] {
        var out: [(String, String)] = []
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue {
                let base = u.deletingLastPathComponent().path
                for case let rel as String in FileManager.default.enumerator(atPath: u.path) ?? .init()
                where LibraryLoader.audioExts.contains((rel as NSString).pathExtension.lowercased()) {
                    let p = u.path + "/" + rel
                    out.append((p, String(p.dropFirst(base.count + 1))))
                }
            } else if LibraryLoader.audioExts.contains(u.pathExtension.lowercased()) {
                out.append((u.path, u.lastPathComponent))
            }
        }
        return out
    }

    static func safe(_ s: String) -> String {
        let t = s.map { "/:\\".contains($0) ? "-" : $0 }.reduce("") { $0 + String($1) }.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix(".") ? "Unknown" : t
    }

    /// Returns the copied tracks (at their new paths) and how many files were already there.
    /// `rename` names files "01 Title.ext" from their tags (for the iPod's own "ABCD.mp3" names) and
    /// skips copying covers from the source folder.
    static func run(_ urls: [URL], into root: String, rename: Bool = false) async throws -> (tracks: [LibTrack], skipped: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) || (try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)) != nil else {
            throw SyncError.missingSource(root)
        }
        var out: [LibTrack] = [], skipped = 0, coversDone = Set<String>()
        for f in audioFiles(urls) {
            let t = await LibraryLoader.track(f.path, relative: f.relative)
            let dir = root + "/" + safe(t.artist) + "/" + safe(t.album)
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let ext = (f.path as NSString).pathExtension
            let dst = dir + "/" + (rename ? (t.trackNumber > 0 ? String(format: "%02d ", t.trackNumber) : "") + safe(t.title) + "." + ext
                                          : (f.path as NSString).lastPathComponent)
            if fm.fileExists(atPath: dst) { skipped += 1; continue }
            try await Task.detached { try fm.copyItem(atPath: f.path, toPath: dst) }.value
            var copied = t; copied.path = dst
            out.append(copied)
            let srcDir = (f.path as NSString).deletingLastPathComponent
            if !rename, coversDone.insert(srcDir).inserted {
                for n in (try? fm.contentsOfDirectory(atPath: srcDir)) ?? []
                where images.contains((n as NSString).pathExtension.lowercased()) && !fm.fileExists(atPath: dir + "/" + n) {
                    try? fm.copyItem(atPath: srcDir + "/" + n, toPath: dir + "/" + n)
                }
            }
        }
        return (out, skipped)
    }
}
