import SwiftUI
import AVFoundation

// The YouTube plugin: searches YouTube and downloads with yt-dlp (from the nix profile or
// Homebrew), preferring the AAC (m4a) stream so the iPod needs no conversion. Songs get proper
// tags and the cover, then go through the Importer into the library. Also fetches Spotify albums
// and the Spotify-only songs of a playlist song by song, and splits a compilation video (one
// upload holding a whole album) into its songs by its chapters or the tracklist in its description.

struct YTResult: Identifiable, Hashable {
    var id: String
    var title, channel: String
    var duration: Int
    var url: String { "https://www.youtube.com/watch?v=\(id)" }
    var thumb: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
}

struct YTItem: Identifiable, Hashable {
    var id = UUID()
    var source: String                 // a URL or "ytsearch1:…"
    var title, artist, album, albumArtist: String
    var track = 0, trackCount = 0, year = 0
    var start = 0.0, end = 0.0         // seconds: a slice of the video (one song of a compilation); end 0 = all of it
    var state = "Waiting", progress = 0.0
    var done = false, failed = false, cancelled = false
    var video = "", videoTitle = "", channel = ""   // what yt-dlp actually picked
    var error = ""
    var log: [String] = []
}

struct YTJob: Identifiable, Hashable {
    var id = UUID()
    var title, subtitle: String
    var art: String
    var items: [YTItem]
    var started = Date()
    var finished: Bool { items.allSatisfy { $0.done || $0.failed } }
    var cancelled: Bool { items.contains(where: \.cancelled) }
    var progress: Double { items.isEmpty ? 0 : items.map { $0.done || $0.failed ? 1 : $0.progress }.reduce(0, +) / Double(items.count) }
}

@MainActor
final class YouTube: ObservableObject {
    @AppStorage("ytdlpPath") var customPath = ""
    @Published var query = ""
    @Published var results: [YTResult] = []
    @Published var searching = false
    @Published var error: String?
    @Published var jobs: [YTJob] = []
    private var running = false
    private var procs: [UUID: Process] = [:]     // item id → its running yt-dlp
    var onFiles: (([URL], UUID) async -> Void)?

    /// Crate's own copy (downloaded on request), then the usual places: Homebrew, nix, MacPorts.
    static var ownCopy: URL { PodCache.dir.appendingPathComponent("bin/yt-dlp") }
    static let candidates = [ownCopy.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                             "/etc/profiles/per-user/\(NSUserName())/bin", NSHomeDirectory() + "/.nix-profile/bin", "/run/current-system/sw/bin"]
    @Published var installing = false
    @Published var version = ""

    /// Downloads the official standalone macOS build from yt-dlp's GitHub releases.
    func install() async {
        installing = true; error = nil; defer { installing = false }
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.missingSource("yt-dlp download (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))") }
            let dst = Self.ownCopy
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            objectWillChange.send()
            await checkVersion()
        } catch { self.error = "Couldn't get yt-dlp: \(error.localizedDescription)" }
    }

    func checkVersion() async {
        version = ((try? await run(["--version"])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Crate's own copy updates itself (YouTube changes often; old versions stop working).
    func update() async {
        guard binary == Self.ownCopy.path else { return }
        _ = try? await run(["-U"])
        await checkVersion()
    }
    var binary: String? {
        if !customPath.isEmpty { return FileManager.default.isExecutableFile(atPath: customPath) ? customPath : nil }
        return Self.candidates.map { $0 + "/yt-dlp" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs yt-dlp; `line` gets every output line as it comes.
    func run(_ args: [String], line: (@MainActor (String) -> Void)? = nil, started: ((Process) -> Void)? = nil) async throws -> String {
        guard let bin = binary else { throw SyncError.missingSource("yt-dlp (get it in Settings › Plugins › YouTube)") }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment     // so yt-dlp finds ffmpeg when it needs it
            env["PATH"] = (Self.candidates + ["/usr/bin", "/bin"]).joined(separator: ":")
            p.environment = env
            p.standardOutput = out; p.standardError = out
            var all = Data(), pending = Data()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                all.append(d); pending.append(d)
                while let nl = pending.firstIndex(of: 10) {
                    let s = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    if let line { Task { @MainActor in line(s) } }
                }
            }
            p.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                all.append(out.fileHandleForReading.readDataToEndOfFile())
                let text = String(decoding: all, as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume(returning: text) }
                else { cont.resume(throwing: SyncError.missingSource(text.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? "yt-dlp failed")) }
            }
            do { try p.run(); started?(p) } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: search and links

    func search(_ q: String) async {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; error = nil; defer { searching = false }
        do {
            let isLink = q.hasPrefix("http")
            let out = try await run(["--flat-playlist", "-J", "--no-warnings", isLink ? q : "ytsearch25:\(q)"])
            let j = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
            let entries = (j["entries"] as? [[String: Any]]) ?? (j["id"] != nil ? [j] : [])
            results = entries.compactMap { e in
                guard let id = e["id"] as? String else { return nil }
                return YTResult(id: id, title: e["title"] as? String ?? "", channel: e["channel"] as? String ?? e["uploader"] as? String ?? "",
                                duration: Int(e["duration"] as? Double ?? 0))
            }
            if isLink, results.count > 1 { linkTitle = j["title"] as? String ?? "" } else { linkTitle = "" }
        } catch { self.error = error.localizedDescription }
    }
    @Published var linkTitle = ""      // set when a playlist link was opened

    /// "Artist - Title (Official Video)" → ("Artist", "Title").
    static func split(_ title: String, channel: String) -> (artist: String, title: String) {
        var t = title
        for junk in ["(Official Video)", "(Official Music Video)", "(Official Audio)", "(Audio)", "(Lyrics)", "(Lyric Video)", "[Official Video]",
                     "[Official Audio]", "(HQ)", "[HQ]", "(HD)", "(Visualizer)", "(Official Visualizer)"] {
            t = t.replacingOccurrences(of: junk, with: "", options: .caseInsensitive)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        for sep in [" - ", " – ", " — "] where t.contains(sep) {
            let parts = t.components(separatedBy: sep)
            return (parts[0].trimmingCharacters(in: .whitespaces), parts.dropFirst().joined(separator: sep).trimmingCharacters(in: .whitespaces))
        }
        return (channel.replacingOccurrences(of: " - Topic", with: ""), t)
    }

    /// Downloads search results or a playlist's videos as one job.
    func download(_ rs: [YTResult], album: String? = nil) {
        let items = rs.enumerated().map { n, r -> YTItem in
            let s = Self.split(r.title, channel: r.channel)
            return YTItem(source: r.url, title: s.title, artist: s.artist, album: album ?? s.title, albumArtist: album == nil ? s.artist : "Various Artists",
                          track: album == nil ? 0 : n + 1, trackCount: album == nil ? 0 : rs.count)
        }
        let artists = Set(items.map(\.artist))
        var fixed = items
        if album != nil, artists.count == 1 { for i in fixed.indices { fixed[i].albumArtist = artists.first! } }
        add(YTJob(title: album ?? fixed.first?.title ?? "YouTube", subtitle: album == nil ? (fixed.first?.artist ?? "") : "\(rs.count) videos",
                  art: rs.first?.thumb?.absoluteString ?? "", items: fixed))
    }

    /// Songs known by artist/title/album (from Spotify): each one is the top YouTube search hit.
    /// Songs from an album are numbered in order, or by `numbers` (of `total`) when only some of it is fetched.
    func fetch(_ songs: [OTTrack], album: String?, art: String, year: Int = 0, numbers: [Int]? = nil, total: Int? = nil) {
        let items = songs.enumerated().map { n, t in
            YTItem(source: "ytsearch1:\(t.artist) - \(t.title) audio", title: t.title, artist: t.artist, album: t.album,
                   albumArtist: t.albumArtist.isEmpty ? t.artist : t.albumArtist, track: album == nil ? 0 : numbers?[n] ?? n + 1,
                   trackCount: album == nil ? 0 : total ?? songs.count, year: year)
        }
        add(YTJob(title: songs.count == 1 && numbers != nil ? songs[0].title : album ?? "\(songs.count) songs", subtitle: album == nil ? "from YouTube" : (songs.first?.albumArtist ?? ""), art: art, items: items))
    }

    private func add(_ j: YTJob) {
        jobs.insert(j, at: 0)
        guard !running else { return }
        running = true
        Task {
            while let j = jobs.first(where: { !$0.finished }) { await work(j.id) }
            running = false
        }
    }

    private func work(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crate-yt-\(id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cover = await Self.coverData(job.art)
        var files: [URL] = []
        var whole: [String: URL] = [:]      // source → its full download, for the songs that are slices of it
        for itemID in job.items.map(\.id) {
            func current() -> YTItem? { jobs.first { $0.id == id }?.items.first { $0.id == itemID } }
            guard let item = current(), !item.done, !item.failed else { continue }
            func set(_ f: (inout YTItem) -> Void) {
                guard let j = jobs.firstIndex(where: { $0.id == id }), let i = jobs[j].items.firstIndex(where: { $0.id == itemID }) else { return }
                f(&jobs[j].items[i])
            }
            do {
                var url: URL
                if item.end > 0, let w = whole[item.source] { url = w } else {
                set { $0.state = "Downloading" }
                defer { procs[itemID] = nil }
                let out = try await run(["-f", "bestaudio[ext=m4a]/bestaudio", "--no-playlist", "--newline", "--no-warnings", "--progress",
                                         "--progress-template", "download:%(progress._percent_str)s", "-o", dir.path + "/%(id)s.%(ext)s",
                                         "--print", "before_dl:@@%(webpage_url)s\t%(title)s\t%(channel)s",
                                         "--print", "after_move:filepath", item.source], line: { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if let p = Double(t.replacingOccurrences(of: "%", with: "")) { set { $0.progress = p / 100 }; return }
                    if t.hasPrefix("@@") {
                        let f = t.dropFirst(2).components(separatedBy: "\t")
                        set { $0.video = f[0]; $0.videoTitle = f.count > 1 ? f[1] : ""; $0.channel = f.count > 2 ? f[2] : "" }
                        return
                    }
                    set { $0.log.append(line); if $0.log.count > 300 { $0.log.removeFirst() } }
                }, started: { [weak self] p in self?.procs[itemID] = p })
                guard current()?.cancelled != true else { continue }
                guard let path = out.split(separator: "\n").last(where: { $0.hasPrefix("/") }).map(String.init) else { throw SyncError.missingSource("no file") }
                url = URL(fileURLWithPath: path)
                if url.pathExtension.lowercased() != "m4a" { set { $0.state = "Converting" }; url = try await convert(url) }
                if item.end > 0 { whole[item.source] = url }
                }
                if item.end > 0 {
                    set { $0.state = "Cutting" }
                    url = try await Self.cut(url, from: item.start, to: item.end, into: dir.appendingPathComponent(itemID.uuidString + ".m4a"))
                }
                set { $0.state = "Tagging" }
                let e = TagEdit(title: item.title, artist: item.artist, albumArtist: item.albumArtist, album: item.album,
                                year: item.year > 0 ? item.year : nil, track: item.track > 0 ? item.track : nil,
                                trackCount: item.trackCount > 0 ? item.trackCount : nil, cover: cover)
                let u = url
                _ = try await Task.detached { try TagWriter.write(u.path, e) }.value
                guard current()?.cancelled != true else { continue }
                // a readable file name, so the import folder looks sane
                let named = dir.appendingPathComponent((item.track > 0 ? String(format: "%02d ", item.track) : "") + Organizer.clean(item.title) + ".m4a")
                try? FileManager.default.moveItem(at: url, to: named)
                files.append(FileManager.default.fileExists(atPath: named.path) ? named : url)
                set { $0.state = "Done"; $0.done = true; $0.progress = 1 }
            } catch {
                set { if !$0.cancelled { $0.state = error.localizedDescription; $0.error = error.localizedDescription; $0.failed = true } }
            }
        }
        if !files.isEmpty { await onFiles?(files, id) }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Non-AAC streams (Opus/WebM) become 256 kbps AAC through ffmpeg.
    private func convert(_ url: URL) async throws -> URL {
        guard let ff = (Self.candidates.map { $0 + "/ffmpeg" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SyncError.missingSource("ffmpeg (needed for this video's audio format)")
        }
        let dst = url.deletingPathExtension().appendingPathExtension("m4a")
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-y", "-loglevel", "error", "-i", url.path, "-vn", "-c:a", "aac", "-b:a", "256k", dst.path]
        try p.run()
        await Task.detached { p.waitUntilExit() }.value
        guard p.terminationStatus == 0 else { throw SyncError.conversionFailed(url.lastPathComponent) }
        try? FileManager.default.removeItem(at: url)
        return dst
    }

    /// One song out of a compilation's download, copied as is (no re-encoding, so no ffmpeg needed).
    static func cut(_ url: URL, from: Double, to: Double, into dst: URL) async throws -> URL {
        guard let s = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough) else {
            throw SyncError.conversionFailed(url.lastPathComponent)
        }
        s.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 1000), end: CMTime(seconds: to, preferredTimescale: 1000))
        try? FileManager.default.removeItem(at: dst)
        try await s.export(to: dst, as: .m4a)
        return dst
    }

    // MARK: compilations

    struct Chapter: Hashable { var start: Double; var title: String }

    /// A video's chapters (YouTube makes them from the description's timestamps), its description
    /// for when there are none, and its length.
    func info(_ r: YTResult) async throws -> (chapters: [Chapter], description: String, duration: Double, year: Int) {
        let out = try await run(["-J", "--no-warnings", "--skip-download", "--no-playlist", r.url])
        let j = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
        let chapters = ((j["chapters"] as? [[String: Any]]) ?? []).compactMap { c -> Chapter? in
            guard let t = c["title"] as? String, let s = c["start_time"] as? Double else { return nil }
            return Chapter(start: s, title: t)
        }
        let desc = j["description"] as? String ?? ""
        return (chapters, desc, j["duration"] as? Double ?? Double(r.duration), j["release_year"] as? Int ?? Self.year(in: r.title + "\n" + desc))
    }

    /// The first plausible year ("Recorded during April 1996 …").
    static func year(in text: String) -> Int {
        guard let m = text.firstMatch(of: #/\b(19[5-9]\d|20[0-2]\d)\b/#) else { return 0 }
        return Int(m.1) ?? 0
    }

    static func timestamp(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Reads a tracklist: every line with a timestamp is a song ("0:00 Title", "1. Title (2:54)",
    /// "[1:02:03] Title", "0:00 - 2:54 Title"). Needs at least two songs, in order.
    static func tracklist(_ text: String) -> [Chapter] {
        let stamp = #/(?:(\d{1,2}):)?(\d{1,2}):(\d{2})/#
        var out: [Chapter] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let m = line.firstMatch(of: stamp) else { continue }
            let start = Double(Int(m.1 ?? "0")! * 3600 + Int(m.2)! * 60 + Int(m.3)!)
            var t = String(line).replacing(stamp, with: "")
            t = t.replacing(#/[\[\(]\s*[\-\x{2013}\x{2014}]?\s*[\]\)]/#, with: "")                  // the brackets the timestamp was in
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-–—|:•·~").union(.whitespaces))
            t = t.replacing(#/^(?:\d{1,2}[.)]\s+|\d{1,2}\s+[\-\x{2013}\x{2014}]\s+)/#, with: "")     // "1. " / "01 - " numbering
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-–—|:•·~").union(.whitespaces))
            guard !t.isEmpty, start >= (out.last?.start ?? -1) else { continue }
            out.append(Chapter(start: start, title: t))
        }
        return out.count >= 2 ? out : []
    }

    /// Downloads a compilation once and cuts it into its songs. When every title reads
    /// "Artist - Title" (a various-artists mix) the artists come from there.
    func split(_ r: YTResult, songs: [Chapter], duration: Double, album: String, artist: String, year: Int) {
        let various = songs.allSatisfy { t in [" - ", " – ", " — "].contains { t.title.contains($0) } }
        let items = songs.enumerated().map { n, c -> YTItem in
            let s = various ? Self.split(c.title, channel: artist) : (artist: artist, title: c.title)
            return YTItem(source: r.url, title: s.title, artist: s.artist, album: album, albumArtist: various ? "Various Artists" : artist,
                          track: n + 1, trackCount: songs.count, year: year,
                          start: c.start, end: n + 1 < songs.count ? songs[n + 1].start : duration)
        }
        add(YTJob(title: album, subtitle: "\(items.count) songs from one video", art: r.thumb?.absoluteString ?? "", items: items))
    }

    /// The cover to tag with. A video thumbnail is the square cover letterboxed in 16:9, so it gets
    /// the biggest size YouTube has (maxres 1280×720, missing on old videos) and is cut to its square.
    static func coverData(_ s: String) async -> Data? {
        var urls = [s]
        if s.contains("i.ytimg.com"), let size = s.split(separator: "/").last {
            urls = ["maxresdefault.jpg", "hqdefault.jpg"].map { s.replacingOccurrences(of: size, with: $0) } + urls
        }
        for s in urls {
            guard let u = URL(string: s), !s.isEmpty, let (d, r) = try? await URLSession.shared.data(from: u),
                  (r as? HTTPURLResponse)?.statusCode ?? 200 == 200, NSImage(data: d) != nil else { continue }
            return square(d) ?? d
        }
        return nil
    }

    /// Trims dark bars off every side, then centre-crops what's left to a square (if it isn't one).
    static func square(_ d: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w != h, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // a row or column counts as bar when nearly all of it is near-black (JPEG noise allowed)
        func dark(_ x: Int, _ y: Int) -> Bool { let p = (y * w + x) * 4; return max(px[p], px[p + 1], px[p + 2]) < 28 }
        func barCol(_ x: Int) -> Bool { (0..<h).filter { dark(x, $0) }.count > h * 97 / 100 }
        func barRow(_ y: Int) -> Bool { (0..<w).filter { dark($0, y) }.count > w * 97 / 100 }
        var l = 0, r = w - 1, t = 0, b = h - 1
        while l < r, barCol(l) { l += 1 }
        while r > l, barCol(r) { r -= 1 }
        // only trim rows when the picture isn't already taller than wide (dark covers have dark edges)
        if r - l + 1 > h { while t < b, barRow(t) { t += 1 }; while b > t, barRow(b) { b -= 1 } }
        var rect = CGRect(x: l, y: t, width: r - l + 1, height: b - t + 1)
        let side = min(rect.width, rect.height)
        rect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side).integral
        guard side >= 100, let sq = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: sq).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    /// Stops a job (or one song of it): waiting songs are skipped and a running yt-dlp is killed.
    /// Songs that already finished stay and are still imported.
    func cancel(_ id: UUID, item: UUID? = nil) {
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        for i in jobs[j].items.indices where !jobs[j].items[i].done && !jobs[j].items[i].failed && (item == nil || jobs[j].items[i].id == item) {
            jobs[j].items[i].cancelled = true; jobs[j].items[i].failed = true; jobs[j].items[i].state = "Cancelled"
            procs[jobs[j].items[i].id]?.terminate()
        }
    }

    func remove(_ id: UUID) { jobs.removeAll { $0.id == id && $0.finished } }
}

extension SpotifyAPI {
    /// An album's songs (for fetching it from YouTube).
    func album(_ uri: String) async throws -> (tracks: [OTTrack], art: String, year: Int) {
        let id = uri.split(separator: ":").last.map(String.init) ?? uri
        guard let a = try await get("/albums/\(id)") as? [String: Any] else { return ([], "", 0) }
        let name = a["name"] as? String ?? ""
        let albumArtist = ((a["artists"] as? [[String: Any]]) ?? []).first?["name"] as? String ?? ""
        let items = ((a["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let tracks = items.enumerated().map { n, t in
            OTTrack(id: n, title: t["name"] as? String ?? "", artist: ((t["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", "),
                    album: name, albumArtist: albumArtist, dataKind: "spotify", uri: t["uri"] as? String ?? "", artworkPath: Self.image(a),
                    lengthMs: t["duration_ms"] as? Int ?? 0)
        }
        return (tracks, Self.image(a), Int((a["release_date"] as? String ?? "").prefix(4)) ?? 0)
    }
}

/// The split sheet's state: one compilation video and the tracklist it's cut by (free text, so
/// a tracklist from anywhere can be pasted in).
@MainActor
final class SplitUI: ObservableObject {
    @Published var video: YTResult?
    @Published var loading = false
    @Published var error: String?
    @Published var text = ""
    @Published var album = ""
    @Published var artist = ""
    @Published var year = ""
    var duration = 0.0
    var songs: [YouTube.Chapter] { YouTube.tracklist(text) }

    func open(_ r: YTResult, _ yt: YouTube) async {
        video = r; loading = true; error = nil; text = ""; duration = Double(r.duration)
        let s = YouTube.split(r.title, channel: r.channel)
        artist = s.artist; album = s.title; year = ""
        defer { loading = false }
        do {
            let i = try await yt.info(r)
            duration = i.duration
            let chapters = i.chapters.count >= 2 ? i.chapters : YouTube.tracklist(i.description)
            text = chapters.map { YouTube.timestamp($0.start) + " " + $0.title }.joined(separator: "\n")
            if i.year > 0 { year = String(i.year) }
        } catch { self.error = error.localizedDescription }
    }
}

struct SplitSheet: View {
    @ObservedObject var ui: SplitUI
    @EnvironmentObject var model: Model
    @EnvironmentObject var yt: YouTube
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let songs = ui.songs
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CachedImage(url: ui.video?.thumb, seed: "YouTube.swift:9")
                    .frame(width: 96, height: 54).clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split into Songs").font(.title3.bold())
                    Text(ui.video?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Form {
                TextField("Album", text: $ui.album)
                TextField("Artist", text: $ui.artist)
                TextField("Year", text: $ui.year)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracklist").font(.headline)
                    Text("One song per line with its start time. Edit freely, or paste one from elsewhere.").font(.caption).foregroundStyle(.secondary)
                    ZStack {
                        TextEditor(text: $ui.text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden)
                            .padding(6).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                        if ui.loading { ProgressView() }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(songs.isEmpty ? "No songs yet" : "\(songs.count) songs").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(songs.enumerated()), id: \.offset) { n, c in
                                let end = n + 1 < songs.count ? songs[n + 1].start : ui.duration
                                HStack {
                                    Text("\(n + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                    Text(c.title).lineLimit(1)
                                    Spacer()
                                    Text(YouTube.timestamp(max(0, end - c.start))).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(width: 280)
            }
            .frame(maxHeight: .infinity)
            if let e = ui.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download \(songs.count) Songs", systemImage: "scissors") {
                    guard let v = ui.video else { return }
                    let album = ui.album.trimmingCharacters(in: .whitespaces)
                    yt.split(v, songs: songs, duration: ui.duration, album: album.isEmpty ? v.title : album,
                             artist: ui.artist.trimmingCharacters(in: .whitespaces), year: Int(ui.year) ?? 0)
                    model.notify("Downloading “\(album)” from YouTube")
                    dismiss()
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(songs.isEmpty || ui.loading || songs.last.map { $0.start >= ui.duration } == true)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 600)
    }
}

struct YouTubeView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var yt: YouTube
    @StateObject private var split = SplitUI()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search YouTube, or paste a video or playlist link", text: $yt.query)
                    .textFieldStyle(.plain).font(.title3)
                    .onSubmit { Task { await yt.search(yt.query) } }
                if yt.searching { ProgressView().controlSize(.small) }
                Button("Search") { Task { await yt.search(yt.query) } }.buttonStyle(.glassProminent)
                    .disabled(yt.query.trimmingCharacters(in: .whitespaces).isEmpty || yt.searching)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24).padding(.vertical, 18)
            if yt.binary == nil {
                VStack(spacing: 14) {
                    Image(systemName: PluginID.youtube.icon).font(.system(size: 40, weight: .light)).foregroundStyle(PluginID.youtube.tint)
                    Text("Crate needs yt-dlp").font(.title2.bold())
                    Text("The free tool that does the downloading. Crate can get the official build (about 35 MB) and keep it up to date.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button { Task { await yt.install() } } label: {
                        if yt.installing { ProgressView().controlSize(.small) } else { Text("Download yt-dlp") }
                    }
                    .buttonStyle(.glassProminent).disabled(yt.installing)
                    if let e = yt.error { Text(e).font(.caption).foregroundStyle(.red) }
                    Text("Already have it through Homebrew (brew install yt-dlp)? Crate finds that by itself.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 70)
            } else if let e = yt.error {
                ContentUnavailableView("YouTube", systemImage: "exclamationmark.triangle", description: Text(e))
            } else if yt.results.isEmpty {
                ContentUnavailableView("Search YouTube", systemImage: PluginID.youtube.icon,
                                       description: Text("Downloads the song, tags it with its cover and adds it to your library."))
            } else {
                if !yt.linkTitle.isEmpty {
                    HStack {
                        Text(yt.linkTitle).font(.headline)
                        Text("\(yt.results.count) videos").foregroundStyle(.secondary)
                        Spacer()
                        Button("Download as Album", systemImage: "arrow.down") { yt.download(yt.results, album: yt.linkTitle); model.notify("Downloading “\(yt.linkTitle)” from YouTube") }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 28).padding(.bottom, 8)
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(yt.results) { r in
                            let s = YouTube.split(r.title, channel: r.channel)
                            HStack(spacing: 12) {
                                CachedImage(url: r.thumb, seed: "YouTube.swift:9")
                                    .frame(width: 96, height: 54).clipShape(.rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.headline).lineLimit(1)
                                    Text("\(r.channel)" + (r.duration > 0 ? " · \(duration(r.duration * 1000))" : "")).font(.callout).foregroundStyle(.secondary)
                                    Text("Saved as “\(s.title)” by \(s.artist)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                                if r.duration == 0 || r.duration >= 600 {     // long enough to be a compilation
                                    Button("Split", systemImage: "scissors") { Task { await split.open(r, yt) } }
                                        .buttonStyle(.glass).help("Download as an album, cut into its songs by the tracklist")
                                }
                                Button("Download", systemImage: "arrow.down") { yt.download([r]); model.notify("Downloading “\(s.title)” from YouTube") }
                                    .buttonStyle(.glass)
                            }
                            .padding(10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 60)
                }
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("YouTube")
        .sheet(isPresented: Binding(get: { split.video != nil }, set: { if !$0 { split.video = nil } })) {
            SplitSheet(ui: split).environmentObject(model).environmentObject(yt)
        }
        .task { if yt.binary != nil, yt.version.isEmpty { await yt.update() } }
    }
}
