import SwiftUI

// The YouTube plugin: searches YouTube and downloads with yt-dlp (from the nix profile or
// Homebrew), preferring the AAC (m4a) stream so the iPod needs no conversion. Songs get proper
// tags and the cover, then go through the Importer into the library. Also fetches Spotify albums
// and the Spotify-only songs of a playlist song by song.

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
    var state = "Waiting", progress = 0.0
    var done = false, failed = false
}

struct YTJob: Identifiable, Hashable {
    var id = UUID()
    var title, subtitle: String
    var art: String
    var items: [YTItem]
    var started = Date()
    var finished: Bool { items.allSatisfy { $0.done || $0.failed } }
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
    func run(_ args: [String], line: (@MainActor (String) -> Void)? = nil) async throws -> String {
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
            do { try p.run() } catch { cont.resume(throwing: error) }
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
    func fetch(_ songs: [OTTrack], album: String?, art: String, year: Int = 0) {
        let items = songs.enumerated().map { n, t in
            YTItem(source: "ytsearch1:\(t.artist) - \(t.title) audio", title: t.title, artist: t.artist, album: t.album,
                   albumArtist: t.albumArtist.isEmpty ? t.artist : t.albumArtist, track: album == nil ? 0 : n + 1,
                   trackCount: album == nil ? 0 : songs.count, year: year)
        }
        add(YTJob(title: album ?? "\(songs.count) songs", subtitle: album == nil ? "from YouTube" : (songs.first?.albumArtist ?? ""), art: art, items: items))
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
        for item in job.items where !item.done && !item.failed {
            func set(_ f: (inout YTItem) -> Void) {
                guard let j = jobs.firstIndex(where: { $0.id == id }), let i = jobs[j].items.firstIndex(where: { $0.id == item.id }) else { return }
                f(&jobs[j].items[i])
            }
            set { $0.state = "Downloading" }
            do {
                let out = try await run(["-f", "bestaudio[ext=m4a]/bestaudio", "--no-playlist", "--newline", "--no-warnings",
                                         "--progress-template", "download:%(progress._percent_str)s", "-o", dir.path + "/%(id)s.%(ext)s",
                                         "--print", "after_move:filepath", item.source]) { line in
                    if let p = Double(line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) { set { $0.progress = p / 100 } }
                }
                guard let path = out.split(separator: "\n").last(where: { $0.hasPrefix("/") }).map(String.init) else { throw SyncError.missingSource("no file") }
                var url = URL(fileURLWithPath: path)
                if url.pathExtension.lowercased() != "m4a" { url = try await convert(url) }
                set { $0.state = "Tagging" }
                let e = TagEdit(title: item.title, artist: item.artist, albumArtist: item.albumArtist, album: item.album,
                                year: item.year > 0 ? item.year : nil, track: item.track > 0 ? item.track : nil,
                                trackCount: item.trackCount > 0 ? item.trackCount : nil, cover: cover)
                let u = url
                _ = try await Task.detached { try TagWriter.write(u.path, e) }.value
                // a readable file name, so the import folder looks sane
                let named = dir.appendingPathComponent((item.track > 0 ? String(format: "%02d ", item.track) : "") + Organizer.clean(item.title) + ".m4a")
                try? FileManager.default.moveItem(at: url, to: named)
                files.append(FileManager.default.fileExists(atPath: named.path) ? named : url)
                set { $0.state = "Done"; $0.done = true; $0.progress = 1 }
            } catch { set { $0.state = error.localizedDescription; $0.failed = true } }
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

    static func coverData(_ s: String) async -> Data? {
        guard let u = URL(string: s), !s.isEmpty, let (d, _) = try? await URLSession.shared.data(from: u), NSImage(data: d) != nil else { return nil }
        return d
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

struct YouTubeView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var yt: YouTube

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
                                       description: Text("Downloads the AAC audio (no conversion for the iPod), tags it and adds it to the library."))
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
                                AsyncImage(url: r.thumb) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                                    .frame(width: 96, height: 54).clipShape(.rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.headline).lineLimit(1)
                                    Text("\(r.channel)" + (r.duration > 0 ? " · \(duration(r.duration * 1000))" : "")).font(.callout).foregroundStyle(.secondary)
                                    Text("Saved as “\(s.title)” by \(s.artist)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
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
        .task { if yt.binary != nil, yt.version.isEmpty { await yt.update() } }
    }
}
