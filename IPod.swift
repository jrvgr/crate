import Foundation
import AVFoundation
import AppKit

// A mounted iPod: finds it, loads its database, copies/converts tracks and writes the database back.

/// Per-iPod choices, stored by serial number.
struct PodSettings: Codable, Equatable {
    init() {}
    /// Settings saved by older versions miss newer keys; those keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        let d = PodSettings()
        aacKbps = v(.aacKbps, d.aacKbps); convertHighMP3 = v(.convertHighMP3, d.convertHighMP3); mp3Limit = v(.mp3Limit, d.mp3Limit)
        importOnTheGo = v(.importOnTheGo, d.importOnTheGo); ejectAfterSync = v(.ejectAfterSync, d.ejectAfterSync)
        syncOnConnect = v(.syncOnConnect, d.syncOnConnect); fillTagsFromMetadata = v(.fillTagsFromMetadata, d.fillTagsFromMetadata)
        soundCheck = v(.soundCheck, d.soundCheck); calendars = v(.calendars, d.calendars); calendarIDs = v(.calendarIDs, d.calendarIDs)
        calendarPastDays = v(.calendarPastDays, d.calendarPastDays); calendarFutureDays = v(.calendarFutureDays, d.calendarFutureDays)
        reminders = v(.reminders, d.reminders); reminderIDs = v(.reminderIDs, d.reminderIDs)
    }
    var aacKbps = 256                 // for FLAC/WAV/AIFF and converted MP3s
    var convertHighMP3 = false        // re-encode MP3s above `mp3Limit` to save space
    var mp3Limit = 192
    var importOnTheGo = true          // On-The-Go lists become playlists on Sync
    var ejectAfterSync = false
    var syncOnConnect = true          // queued changes sync as soon as the iPod is plugged in
    var fillTagsFromMetadata = true   // year/genre from Find Metadata when the file has none
    var soundCheck = true             // measure loudness and fill in the iPod's Sound Check values
    var calendars = false             // Mac calendars → iPod_Control-free Calendars/ folder
    var calendarIDs: [String] = []    // empty = all
    var calendarPastDays = 30, calendarFutureDays = 180
    var reminders = false             // open reminders → To Do
    var reminderIDs: [String] = []

    func needsConversion(_ t: LibTrack) -> Bool {
        if t.needsConversion { return true }
        guard convertHighMP3, t.ext == "mp3", t.lengthMs > 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: t.path))?[.size] as? Int else { return false }
        return size * 8 / t.lengthMs > mp3Limit + 16       // kbps, with some room for tags and artwork
    }

    static func load(_ serial: String) -> PodSettings {
        guard let d = UserDefaults.standard.data(forKey: "pod." + serial),
              let s = try? JSONDecoder().decode(PodSettings.self, from: d) else { return PodSettings() }
        return s
    }
    static func save(_ s: PodSettings, serial: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "pod." + serial)
    }
}

/// The last iPod seen, its database and the queued changes, kept in Application Support so the
/// iPod can be browsed and changes queued while it's unplugged.
struct PodCache: Codable {
    var info: IPodInfo
    var seen: Date
    var toAdd: [String] = [], toRemove: [String] = []
    var playlistsToAdd: [Int] = [], playlistsToRemove: [UInt64] = []
    var pendingName: String?

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var url: URL { dir.appendingPathComponent("ipod.json") }
    static var dbURL: URL { dir.appendingPathComponent("iTunesDB.cached") }

    static func load() -> PodCache? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PodCache.self, from: $0) } }
    func save() { try? JSONEncoder().encode(self).write(to: Self.url) }
    static func loadDB() -> ITunesDB? { (try? Data(contentsOf: dbURL)).flatMap { try? ITunesDB.read($0) } }
    static func saveDB(from ipod: IPodInfo) {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.copyItem(at: ipod.dbURL, to: dbURL)
    }
}

struct IPodInfo: Codable {
    var mount: URL
    var model = "", firmware = "", serial = ""
    var capacity: Int64 = 0, free: Int64 = 0
    var control: URL { mount.appendingPathComponent("iPod_Control") }
    var dbURL: URL { control.appendingPathComponent("iTunes/iTunesDB") }
    var backupURL: URL { dbURL.appendingPathExtension("crate-backup") }
    var used: Int64 { capacity - free }
    var key: String { serial.isEmpty ? mount.lastPathComponent : serial }

    /// Marketing name for the model number in SysInfo (classic iPods Crate can sync).
    var modelName: String {
        let m = model.uppercased().drop { $0 == "M" || $0 == "P" }.prefix(4)
        switch m {
        case "8976", "9244", "9245", "9460": return "iPod (3rd generation)"
        case "9282", "9787", "9268": return "iPod (4th generation)"
        case "9585", "9586", "9829", "9830": return "iPod photo"
        case "9160", "9434", "9435", "9436", "9437": return "iPod mini"
        case "8541", "8697", "8709", "8737", "8740", "8738", "8741": return "iPod (1st/2nd generation)"
        default: return "iPod"
        }
    }

    static func find() -> IPodInfo? {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in vols where FileManager.default.fileExists(atPath: v.appendingPathComponent("iPod_Control/Device/SysInfo").path) {
            var info = IPodInfo(mount: v)
            let sys = (try? String(contentsOf: info.control.appendingPathComponent("Device/SysInfo"), encoding: .utf8)) ?? ""
            for line in sys.split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "ModelNumStr": info.model = kv[1]
                case "buildID" where kv[1].contains("("):    // "0x02308000 (2.3)"
                    info.firmware = kv[1].components(separatedBy: "(").last.map { String($0.dropLast()) } ?? kv[1]
                case "pszSerialNumber": info.serial = kv[1]
                default: break
                }
            }
            if let r = try? v.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
                info.capacity = Int64(r.volumeTotalCapacity ?? 0); info.free = Int64(r.volumeAvailableCapacity ?? 0)
            }
            return info
        }
        return nil
    }
}

enum SyncError: Error, LocalizedError {
    case conversionFailed(String), missingSource(String)
    var errorDescription: String? {
        switch self {
        case .conversionFailed(let s): return "Converting \(s) failed"
        case .missingSource(let s): return "File not found: \(s) (is the share mounted?)"
        }
    }
}

enum Syncer {
    /// Duration, bitrate and sample rate of an audio file.
    static func audioInfo(_ url: URL) async -> (ms: Int, kbps: Int, rate: Int) {
        let asset = AVURLAsset(url: url)
        let secs = (try? await asset.load(.duration))?.seconds ?? 0
        var rate = 44100
        if let tr = try? await asset.loadTracks(withMediaType: .audio).first,
           let fmt = try? await tr.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            rate = Int(asbd.mSampleRate)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let kbps = secs > 0 ? Int(Double(size) * 8 / secs / 1000) : 0
        return (Int(secs * 1000), kbps, rate)
    }

    static func convert(_ src: String, to dst: URL, kbps: Int) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", "-b", "\(kbps * 1000)", "-q", "127", src, dst.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SyncError.conversionFailed((src as NSString).lastPathComponent) }
    }

    /// Copies (or converts) one library track into iPod_Control/Music and returns its database entry.
    static func add(_ t: LibTrack, to ipod: IPodInfo, albumCount: Int, id: UInt32, settings: PodSettings = .init()) async throws -> PodTrack {
        guard FileManager.default.fileExists(atPath: t.path) else { throw SyncError.missingSource(t.path) }
        let convert = settings.needsConversion(t)
        let aac = convert || t.ext != "mp3"
        let ext = convert ? "m4a" : t.ext
        let folder = String(format: "F%02d", Int.random(in: 0..<50))
        let dir = ipod.control.appendingPathComponent("Music/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name: String, dst: URL
        repeat {
            name = String((0..<4).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! }) + "." + ext
            dst = dir.appendingPathComponent(name)
        } while FileManager.default.fileExists(atPath: dst.path)
        if convert {
            let src = t.path
            try await Task.detached { try Self.convert(src, to: dst, kbps: settings.aacKbps) }.value
        }
        else { try FileManager.default.copyItem(atPath: t.path, toPath: dst.path) }
        let info = await audioInfo(dst)
        let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        let location = ":iPod_Control:Music:\(folder):\(name)"
        let nt = NewTrack(title: t.title, artist: t.trackArtist.isEmpty ? t.artist : t.trackArtist, album: t.album, genre: t.genre,
                          trackNumber: t.trackNumber, trackCount: albumCount, discNumber: t.discNumber, year: t.year,
                          lengthMs: info.ms > 0 ? info.ms : t.lengthMs, bitrateKbps: info.kbps, sampleRate: info.rate,
                          size: size, location: location, isAAC: aac)
        let now = Int(Date().timeIntervalSince1970) + 2_082_844_800
        return PodTrack(id: id, title: t.title, artist: nt.artist, album: t.album, genre: t.genre, location: location,
                        trackNumber: t.trackNumber, size: size, lengthMs: nt.lengthMs,
                        raw: ITunesDB.mhit(id: id, nt, now: now))
    }

    /// Files in iPod_Control/Music that no track in the database points at (left by failed syncs).
    static func orphans(_ ipod: IPodInfo, db: ITunesDB) -> [URL] {
        let known = Set(db.tracks.map { $0.relativePath.lowercased() })
        let music = ipod.control.appendingPathComponent("Music")
        var out: [URL] = []
        for case let rel as String in FileManager.default.enumerator(atPath: music.path) ?? .init() {
            let full = music.appendingPathComponent(rel)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full.path, isDirectory: &dir), !dir.boolValue,
                  !rel.hasPrefix("."), !(rel as NSString).lastPathComponent.hasPrefix(".") else { continue }
            if !known.contains("ipod_control/music/" + rel.lowercased()) { out.append(full) }
        }
        return out
    }

    static func remove(_ t: PodTrack, from ipod: IPodInfo) {
        try? FileManager.default.removeItem(at: ipod.mount.appendingPathComponent(t.relativePath))
    }

    /// Writes the database atomically and keeps the previous one as iTunesDB.crate-backup.
    static func write(_ db: ITunesDB, to ipod: IPodInfo) throws {
        let fm = FileManager.default
        let url = ipod.dbURL, tmp = url.appendingPathExtension("new"), bak = url.appendingPathExtension("crate-backup")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try db.serialize().write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak)
            try fm.copyItem(at: url, to: bak)
        }
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }

    static func eject(_ ipod: IPodInfo) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: ipod.mount)
    }
}

/// On-The-Go playlists made on the iPod itself. The firmware keeps them outside the iTunesDB in
/// iTunes/OTGPlaylistInfo (later ones in OTGPlaylistInfo_1, _2...) as positions in the track list;
/// iTunes turns them into "On-The-Go N" playlists on sync and deletes the files.
struct OnTheGo: Hashable {
    var url: URL
    var trackIDs: [UInt32]

    static func load(_ ipod: IPodInfo, db: ITunesDB) -> [OnTheGo] {
        let dir = ipod.dbURL.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 == "OTGPlaylistInfo" || $0.hasPrefix("OTGPlaylistInfo_") }.sorted()
        return names.compactMap { n in
            let url = dir.appendingPathComponent(n)
            guard let d = try? Data(contentsOf: url), let positions = parse(d) else { return nil }
            let ids = positions.compactMap { $0 < db.tracks.count ? db.tracks[$0].id : nil }
            return ids.isEmpty ? nil : OnTheGo(url: url, trackIDs: ids)
        }
    }

    /// "mhpo" header (header length, entry length, entry count), then one 32-bit position per entry.
    static func parse(_ data: Data) -> [Int]? {
        let d = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 }
        guard d.count >= 16, d[0..<4].elementsEqual("mhpo".utf8) else { return nil }
        let hl = u32(4), el = max(u32(8), 4), n = u32(12)
        return (0..<n).compactMap { i in hl + i * el + 4 <= d.count ? u32(hl + i * el) : nil }
    }

    static func make(_ positions: [Int]) -> Data {
        let le = { (v: Int) in (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
        return Data(Array("mhpo".utf8) + le(0x14) + le(4) + le(positions.count) + le(0) + positions.flatMap(le))
    }
}

/// What the iPod recorded itself since the last sync: iTunes/Play Counts holds one entry per track
/// (in track list order) with plays, last played and rating. iTunes adds them to the database
/// and deletes the file; Crate does the same so plays and ratings made on the iPod are kept.
enum PlayCounts {
    struct Entry { var plays, lastPlayed, rating: Int }

    static func url(_ ipod: IPodInfo) -> URL { ipod.dbURL.deletingLastPathComponent().appendingPathComponent("Play Counts") }

    static func parse(_ data: Data) -> [Entry]? {
        let d = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 }
        guard d.count >= 16, d[0..<4].elementsEqual("mhdp".utf8) else { return nil }
        let hl = u32(4), el = u32(8), n = u32(12)
        guard el >= 12, hl + n * el <= d.count else { return nil }
        return (0..<n).map { i in
            let o = hl + i * el
            return Entry(plays: u32(o), lastPlayed: u32(o + 4), rating: el >= 16 ? u32(o + 12) : 0)
        }
    }
}

extension ITunesDB {
    /// Adds the iPod's own plays/ratings to the track records. Returns how many tracks changed;
    /// nil when the file doesn't line up with this database (then nothing is touched).
    mutating func mergePlayCounts(_ entries: [PlayCounts.Entry]) -> Int? {
        guard entries.count == tracks.count else { return nil }
        func get(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }
        func put(_ b: inout [UInt8], _ o: Int, _ v: Int) { for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (k * 8)) } }
        var changed = 0
        for (i, e) in entries.enumerated() where e.plays > 0 || e.rating > 0 {
            guard var b = tracks[i].raw.map({ [UInt8]($0) }), b.count >= 0x5C else { continue }
            if e.plays > 0 {
                put(&b, 0x50, get(b, 0x50) + e.plays)          // play count
                put(&b, 0x54, get(b, 0x54) + e.plays)          // play count since last sync
                if e.lastPlayed > get(b, 0x58) { put(&b, 0x58, e.lastPlayed) }
            }
            if e.rating > 0, e.rating <= 100 { b[0x1F] = UInt8(e.rating) }
            tracks[i].raw = Data(b)
            changed += 1
        }
        return changed
    }

    /// Turns On-The-Go lists into regular playlists, like iTunes does; their files go after the write.
    mutating func importOnTheGo(_ lists: [OnTheGo]) {
        for l in lists {
            var n = 1
            while playlists.contains(where: { $0.name == "On-The-Go \(n)" }) { n += 1 }
            playlists.append(PodPlaylist(name: "On-The-Go \(n)", items: l.trackIDs.map { .init(trackID: $0) }))
        }
    }
}

/// How full the iPod was over time: one sample a day, taken when it's connected.
struct PodSample: Codable, Hashable { var date: Date; var used, music: Int64; var songs: Int }

enum PodHistory {
    static func url(_ key: String) -> URL { PodCache.dir.appendingPathComponent("history-\(key).json") }
    static func load(_ key: String) -> [PodSample] { (try? Data(contentsOf: url(key))).flatMap { try? JSONDecoder().decode([PodSample].self, from: $0) } ?? [] }
    static func record(_ i: IPodInfo, db: ITunesDB) {
        var h = load(i.key)
        let s = PodSample(date: Date(), used: i.used, music: Int64(db.tracks.map(\.size).reduce(0, +)), songs: db.tracks.count)
        if let last = h.last, Calendar.current.isDateInToday(last.date) { h[h.count - 1] = s } else { h.append(s) }
        try? JSONEncoder().encode(h).write(to: url(i.key))
    }
}

/// Songs in the database whose file is gone or doesn't have the size the database says.
struct PodCheck { var missing: [PodTrack] = []; var wrongSize: [PodTrack] = []; var stray: [URL] = [] }

extension Syncer {
    static func check(_ ipod: IPodInfo, db: ITunesDB) -> PodCheck {
        var c = PodCheck()
        for t in db.tracks {
            let path = ipod.mount.appendingPathComponent(t.relativePath).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { c.missing.append(t); continue }
            if t.size > 0, size != t.size { c.wrongSize.append(t) }
        }
        c.stray = orphans(ipod, db: db)
        return c
    }
}
