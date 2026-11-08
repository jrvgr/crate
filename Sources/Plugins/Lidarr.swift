import SwiftUI

// The Lidarr plugin hands albums to Lidarr (lidarr.audio), which finds them through its indexers and download
// client and files them in its music folder; the Subsonic server (or the share Crate reads) picks them up from there.
// "Get with Lidarr" sits next to "Find on Soulseek"; Lidarr's queue shows in Downloads. It uses Lidarr's
// REST API (v1) with the API key from Lidarr's Settings › General.

/// One download in Lidarr's queue.
struct LidarrQueueItem: Identifiable, Equatable {
    var id: Int
    var artist, album, status, detail: String
    var progress: Double
    var cover: URL?
    var client = ""              // the download client it went to ("Slskd", a torrent client, …)
    var folder = ""              // the download's folder name (outputPath's last part), to find it in slskd
    var user = ""                // the Soulseek user, from the release title ("[👤 name ]")
    var finished = false         // downloaded; Lidarr imports it (or says why it can't)
    var warning: String?
}

/// An album Lidarr knows (monitored or not), keyed by its MusicBrainz release group.
struct LidarrAlbum: Identifiable, Equatable {
    var id: Int
    var mbid, title, artist, date: String
    var monitored: Bool
    var tracks, haveTracks: Int
    var cover: URL?
    var year: Int { Int(date.prefix(4)) ?? 0 }
    var complete: Bool { tracks > 0 && haveTracks >= tracks }
}

/// Something that happened in Lidarr: grabbed, imported, failed.
struct LidarrEvent: Identifiable, Equatable {
    var id: Int
    var kind, artist, album, detail: String
    var date: Date?
    var cover: URL?
    var failed: Bool { kind == "downloadFailed" || kind == "albumImportIncomplete" || kind == "importFailed" }
    var label: String {
        switch kind {
        case "grabbed": return "Grabbed"
        case "downloadImported": return "Imported"
        case "downloadFailed": return "Download failed"
        case "albumImportIncomplete": return "Import incomplete"
        case "importFailed": return "Import failed"
        case "trackFileDeleted": return "Deleted"
        case "trackFileRenamed": return "Renamed"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
    var icon: String {
        switch kind {
        case "grabbed": return "arrow.down.circle"
        case "downloadImported": return "checkmark.circle.fill"
        case "trackFileDeleted": return "trash"
        default: return failed ? "exclamationmark.triangle.fill" : "circle"
        }
    }
}

/// One release Lidarr's indexers found for an album (a Soulseek folder, a torrent, …), for picking by hand.
struct LidarrRelease: Identifiable, Equatable {
    var id: String { "\(indexerId)|\(guid)" }
    var guid: String
    var indexerId: Int
    var title, quality, indexer: String
    var size: Int
    var ageHours: Double
    var approved, allowed: Bool
    var rejections: [String]
}

/// A release group from a MusicBrainz search, for the Lidarr pane.
struct MBGroup: Identifiable, Hashable {
    var id, title, artist, type, date: String
    var year: Int { Int(date.prefix(4)) ?? 0 }
    var cover: URL? { URL(string: "https://coverartarchive.org/release-group/\(id)/front-250") }

    /// Albums, EPs and singles whose title or artist match the words.
    static func search(_ q: String) async throws -> [MBGroup] {
        let list = q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !list.isEmpty else { return [] }
        // every word in the title or the artist first ("radiohead ok computer" is OK Computer, not every "computer");
        // when nothing has them all (a song's name, "asap" for A$AP), any of them
        let all = list.map { "(releasegroup:\($0) OR artist:\($0))" }.joined(separator: " AND ")
        let any = list.joined(separator: " ")
        var found = try await query(all)
        if found.isEmpty, list.count > 1 {
            try? await Task.sleep(for: .seconds(1))         // MusicBrainz: one request a second
            found = try await query("releasegroup:(\(any)) OR artist:(\(any))")
        }
        return found
    }

    private static func query(_ lucene: String) async throws -> [MBGroup] {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        c.queryItems = [.init(name: "query", value: lucene), .init(name: "limit", value: "50"), .init(name: "fmt", value: "json")]
        let j = try await MusicBrainz.get(c.url!)
        return ((j["release-groups"] as? [[String: Any]]) ?? []).compactMap { g in
            guard let id = g["id"] as? String, let title = g["title"] as? String else { return nil }
            let credit = ((g["artist-credit"] as? [[String: Any]]) ?? []).map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
            return MBGroup(id: id, title: title, artist: credit, type: g["primary-type"] as? String ?? "", date: g["first-release-date"] as? String ?? "")
        }
    }
}

enum LidarrError: LocalizedError {
    case notConfigured, http(Int, String), notFound(String), noRootFolder
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Lidarr isn't set up"
        case .http(401, _): return "Lidarr didn't accept the API key"
        case .http(let code, let msg): return msg.isEmpty ? "Lidarr answered \(code)" : "Lidarr: \(msg)"
        case .notFound(let what): return "Lidarr can't find \(what) on MusicBrainz"
        case .noRootFolder: return "Lidarr has no root folder (add one under Settings › Media Management)"
        }
    }
}

@MainActor
final class Lidarr: ObservableObject {
    @AppStorage("lidarrURL") var url = ""
    @Published var status = ""
    @Published var error: String?
    @Published private(set) var queue: [LidarrQueueItem] = []
    @Published private(set) var getting: Set<String> = []          // albums being handed over ("artist|album")
    @Published private(set) var albums: [String: LidarrAlbum] = [:]   // every album in Lidarr, by release group MBID
    @Published private(set) var wanted: [LidarrAlbum] = []
    @Published private(set) var history: [LidarrEvent] = []
    @Published private(set) var loading = false
    // picking a release by hand (Get with Lidarr): the album, what the indexers found, how far it got
    @Published var picking: LidarrAlbum?
    @Published private(set) var releases: [LidarrRelease] = []
    @Published private(set) var releaseState = ""
    @Published private(set) var releaseError: String?
    @Published private(set) var grabbed: Set<String> = []
    @Published private(set) var grabbing: Set<String> = []
    private var pickTask: Task<Void, Never>?

    var apiKey: String {
        get { Keychain.get("lidarr") }
        set {
            objectWillChange.send()
            let s = Keychain.set("lidarr", newValue)
            if s != errSecSuccess { error = "Couldn't save the API key (\(s))" }
        }
    }

    var configured: Bool { !url.isEmpty && !apiKey.isEmpty }
    private var base: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
    private var polling = false

    // MARK: HTTP

    private func call(_ method: String = "GET", _ path: String, _ query: [URLQueryItem] = [], body: Any? = nil, timeout: Double = 30) async throws -> Any {
        guard configured, var c = URLComponents(string: base + "/api/v1/" + path) else { throw LidarrError.notConfigured }
        if !query.isEmpty { c.queryItems = query }
        guard let u = c.url else { throw LidarrError.notConfigured }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = d.isEmpty ? [String: Any]() : (try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)) ?? [String: Any]()
        guard (200..<300).contains(code) else {
            // Lidarr's errors: {"message": …} or a list of validation failures [{"errorMessage": …}]
            let msg = (json as? [String: Any])?["message"] as? String
                ?? ((json as? [[String: Any]])?.compactMap { $0["errorMessage"] as? String }.joined(separator: "; ")) ?? ""
            throw LidarrError.http(code, msg)
        }
        return json
    }

    private func list(_ path: String, _ query: [URLQueryItem] = []) async throws -> [[String: Any]] {
        (try await call(path, query) as? [[String: Any]]) ?? []
    }
    private func call(_ path: String, _ query: [URLQueryItem]) async throws -> Any { try await call("GET", path, query) }

    // MARK: status

    /// Connects, and says whether Lidarr can actually get anything: it needs indexers and a download client.
    func check() async {
        guard configured else { status = ""; error = nil; return }
        do {
            let s = try await call("GET", "system/status") as? [String: Any]
            let clients = try await list("downloadclient").filter { $0["enable"] as? Bool ?? false }.count
            let indexers = try await list("indexer").filter { ($0["enableAutomaticSearch"] as? Bool ?? false) || ($0["enableInteractiveSearch"] as? Bool ?? false) }.count
            let folders = try await list("rootfolder").count
            let version = s?["version"] as? String ?? ""
            var problems: [String] = []
            if clients == 0 { problems.append("no download client") }
            if indexers == 0 { problems.append("no indexers") }
            if folders == 0 { problems.append("no root folder") }
            status = "Lidarr \(version)" + (problems.isEmpty ? ", \(indexers) indexers, \(clients) download clients"
                                                             : ": \(problems.joined(separator: ", ")), so it can't get albums yet")
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    // MARK: getting an album

    /// Hands an album to Lidarr: monitored and searched for. Already in Lidarr: monitored and searched again;
    /// new: added with its artist (the artist itself isn't monitored, so Lidarr doesn't go and get everything else).
    /// What happened, for a notice.
    /// With a MusicBrainz release group ID it's that exact album; without one Lidarr's search has to guess it from the names.
    func get(artist: String, album: String, mbid: String? = nil) async throws -> String {
        let key = artist + "|" + album
        getting.insert(key); defer { getting.remove(key) }
        var a = try await resolve(artist: artist, album: album, mbid: mbid)
        let title = a["title"] as? String ?? album
        let said = try await add(&a, title: title)
        Task { await refreshAlbums() }
        return said
    }

    /// The album as Lidarr knows it: by MusicBrainz ID when there is one, else by its names.
    private func resolve(artist: String, album: String, mbid: String?) async throws -> [String: Any] {
        var found: [String: Any]?
        if let mbid, !mbid.isEmpty { found = try await list("album/lookup", [.init(name: "term", value: "lidarr:" + mbid)]).first }
        if found == nil { found = try await lookup(artist: artist, album: album) }
        guard let found else { throw LidarrError.notFound("“\(album)”") }
        return found
    }

    // MARK: picking a release by hand

    /// Like Find on Soulseek: puts the album in Lidarr (wanted, without searching on its own), has its indexers
    /// look for it and lists what they found, so one can be picked with `grab`.
    func choose(artist: String, album: String, mbid: String? = nil) {
        pickTask?.cancel()
        picking = LidarrAlbum(id: 0, mbid: mbid ?? "", title: album, artist: artist, date: "", monitored: true, tracks: 0, haveTracks: 0,
                              cover: mbid.flatMap { URL(string: "https://coverartarchive.org/release-group/\($0)/front-250") })
        releases = []; releaseError = nil; grabbed = []
        releaseState = "Finding “\(album)” on MusicBrainz…"
        pickTask = Task {
            do {
                var a = try await resolve(artist: artist, album: album, mbid: mbid)
                let id = try await ensure(&a, search: false)
                let known = Self.album(a).map { var k = $0; k.id = id; return k }
                if let known, !Task.isCancelled { picking = known }
                releaseState = "Lidarr is searching its indexers for “\(known?.title ?? album)” (about 20 seconds)…"
                let found = try await list("release", [.init(name: "albumId", value: String(id))], timeout: 180)
                guard !Task.isCancelled else { return }
                releases = found.compactMap(Self.release).sorted { ($0.approved ? 0 : 1) < ($1.approved ? 0 : 1) }
                let ok = releases.filter(\.approved).count
                releaseState = releases.isEmpty ? "" : "\(releases.count) releases, \(ok) Lidarr would take on its own"
                Task { await refreshAlbums() }
            } catch {
                guard !Task.isCancelled else { return }
                releaseError = error.localizedDescription; releaseState = ""
            }
        }
    }

    func stopChoosing() { pickTask?.cancel(); picking = nil; releases = []; releaseState = ""; releaseError = nil }

    /// Has Lidarr download this release (even one it would turn down by itself).
    func grab(_ r: LidarrRelease) async throws {
        grabbing.insert(r.id); defer { grabbing.remove(r.id) }
        _ = try await call("POST", "release", body: ["guid": r.guid, "indexerId": r.indexerId], timeout: 60)
        grabbed.insert(r.id)
        await refreshQueue()
    }

    private static func release(_ r: [String: Any]) -> LidarrRelease? {
        guard let guid = r["guid"] as? String, let indexerId = r["indexerId"] as? Int else { return nil }
        let q = ((r["quality"] as? [String: Any])?["quality"] as? [String: Any])?["name"] as? String ?? ""
        return LidarrRelease(guid: guid, indexerId: indexerId, title: r["title"] as? String ?? "", quality: q,
                             indexer: r["indexer"] as? String ?? "", size: r["size"] as? Int ?? 0, ageHours: r["ageHours"] as? Double ?? 0,
                             approved: r["approved"] as? Bool ?? false, allowed: r["downloadAllowed"] as? Bool ?? true,
                             rejections: r["rejections"] as? [String] ?? [])
    }

    private func list(_ path: String, _ query: [URLQueryItem], timeout: Double) async throws -> [[String: Any]] {
        (try await call("GET", path, query, timeout: timeout) as? [[String: Any]]) ?? []
    }

    /// The album as Lidarr finds it on MusicBrainz (with an "id" when it's already in Lidarr); nil when it doesn't.
    func lookup(artist: String, album: String) async throws -> [String: Any]? {
        let bare = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let found = try await list("album/lookup", [.init(name: "term", value: [artist, album].filter { !$0.isEmpty && $0 != "Various Artists" }.joined(separator: " "))])
        let artistOf = { (a: [String: Any]) in ((a["artist"] as? [String: Any])?["artistName"] as? String) ?? "" }
        let match = found.first { bare($0["title"] as? String ?? "") == bare(album) && (artist.isEmpty || bare(artistOf($0)) == bare(artist)) }
            ?? found.first { bare($0["title"] as? String ?? "") == bare(album) }
            ?? found.first { Model.looseMatch(album, $0["title"] as? String ?? "") && (artist.isEmpty || Model.looseMatch(artist, artistOf($0))) }
        return match
    }

    private func add(_ a: inout [String: Any], title: String) async throws -> String {
        let known = (a["id"] as? Int ?? 0) > 0
        _ = try await ensure(&a, search: true)
        Task { await refreshQueue() }
        return known ? "Lidarr is searching for “\(title)”" : "Added “\(title)” to Lidarr; it's searching for it"
    }

    /// Makes sure the album is in Lidarr and wanted (`search`: and has Lidarr look for it straight away); its Lidarr ID.
    private func ensure(_ a: inout [String: Any], search: Bool) async throws -> Int {
        if let id = a["id"] as? Int, id > 0 {                       // already in Lidarr
            _ = try await call("PUT", "album/monitor", body: ["albumIds": [id], "monitored": true])
            if search { _ = try await call("POST", "command", body: ["name": "AlbumSearch", "albumIds": [id]]) }
            return id
        }

        // new: the album with its artist, filed like Lidarr's first root folder says
        guard let root = try await list("rootfolder").first, let path = root["path"] as? String else { throw LidarrError.noRootFolder }
        var quality = root["defaultQualityProfileId"] as? Int ?? 0, metadata = root["defaultMetadataProfileId"] as? Int ?? 0
        if quality == 0 { quality = try await list("qualityprofile").first?["id"] as? Int ?? 1 }
        if metadata == 0 { metadata = try await list("metadataprofile").first?["id"] as? Int ?? 1 }
        var art = a["artist"] as? [String: Any] ?? [:]
        if let mbid = art["foreignArtistId"] as? String, let existing = try await list("artist", [.init(name: "mbId", value: mbid)]).first {
            art = existing
        } else {
            art["qualityProfileId"] = quality
            art["metadataProfileId"] = metadata
            art["rootFolderPath"] = path
            art["monitored"] = true
            art["monitorNewItems"] = "none"
            art["addOptions"] = ["monitor": "none", "searchForMissingAlbums": false]
        }
        a["artist"] = art
        a["monitored"] = true
        a["addOptions"] = ["searchForNewAlbum": search]
        let added = try await call("POST", "album", body: a) as? [String: Any]
        guard let id = added?["id"] as? Int else { throw LidarrError.http(0, "it didn't say what it added") }
        a["id"] = id
        return id
    }

    // MARK: queue

    func refreshQueue() async {
        guard configured else { if !queue.isEmpty { queue = [] }; return }
        guard let page = try? await call("queue", [.init(name: "pageSize", value: "100"), .init(name: "includeArtist", value: "true"),
                                                    .init(name: "includeAlbum", value: "true")]) as? [String: Any] else { return }
        let items: [LidarrQueueItem] = ((page["records"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let size = r["size"] as? Double ?? 0, left = r["sizeleft"] as? Double ?? 0
            let album = r["album"] as? [String: Any], artist = r["artist"] as? [String: Any]
            let cover = ((album?["images"] as? [[String: Any]]) ?? []).first { $0["coverType"] as? String == "cover" }
            let warning = ((r["statusMessages"] as? [[String: Any]]) ?? []).compactMap { ($0["messages"] as? [String])?.first }.first
            let title = r["title"] as? String ?? ""
            let user = title.range(of: #"👤\s*([^\s\]]+)"#, options: .regularExpression).map {
                String(title[$0].dropFirst()).trimmingCharacters(in: .whitespaces)
            } ?? ""
            return LidarrQueueItem(id: id, artist: artist?["artistName"] as? String ?? "", album: album?["title"] as? String ?? title,
                                   status: Self.stateName(r["trackedDownloadState"] as? String ?? r["status"] as? String ?? ""),
                                   detail: (r["timeleft"] as? String).map { "\($0) left" } ?? "",
                                   progress: size > 0 ? (size - left) / size : 0,
                                   cover: (cover?["remoteUrl"] as? String ?? cover?["url"] as? String).flatMap(URL.init(string:)),
                                   client: r["downloadClient"] as? String ?? "",
                                   folder: ((r["outputPath"] as? String ?? "") as NSString).lastPathComponent,
                                   user: user, finished: (r["status"] as? String ?? "").lowercased() == "completed", warning: warning)
        }
        let gone = !queue.isEmpty && items.count < queue.count
        if items != queue { queue = items; Model.shared?.objectWillChange.send() }
        // an album finished: Lidarr has filed it, so the servers and the library can pick it up
        if gone, let m = Model.shared { Task { await m.rescanServers(); try? await Task.sleep(for: .seconds(20)); await m.reload() } }
    }

    /// Lidarr's state names ("importPending") as words.
    private static func stateName(_ s: String) -> String {
        switch s {
        case "downloading": return "Downloading"
        case "importPending": return "Waiting to import"
        case "importBlocked": return "Import blocked"
        case "importing": return "Importing"
        case "imported": return "Imported"
        case "failedPending", "failed": return "Failed"
        case "ignored": return "Ignored"
        case "queued", "delay": return "Queued"
        case "paused": return "Paused"
        case "completed": return "Downloaded"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    /// Takes a download out of Lidarr's queue and the download client; `findAnother` blocklists the release
    /// so Lidarr searches for a different one.
    func remove(_ q: LidarrQueueItem, findAnother: Bool) async throws {
        _ = try await call("DELETE", "queue/\(q.id)", [.init(name: "removeFromClient", value: "true"),
                                                       .init(name: "blocklist", value: findAnother ? "true" : "false")])
        await refreshQueue()
    }

    // MARK: albums, wanted, history (the Lidarr pane)

    private static func cover(_ a: [String: Any]?, mbid: String) -> URL? {
        let img = ((a?["images"] as? [[String: Any]]) ?? []).first { $0["coverType"] as? String == "cover" }
        if let s = img?["remoteUrl"] as? String, let u = URL(string: s) { return u }
        return mbid.isEmpty ? nil : URL(string: "https://coverartarchive.org/release-group/\(mbid)/front-250")
    }

    private static func album(_ a: [String: Any], artists: [Int: String] = [:]) -> LidarrAlbum? {
        guard let id = a["id"] as? Int else { return nil }
        let stats = a["statistics"] as? [String: Any]
        let mbid = a["foreignAlbumId"] as? String ?? ""
        let artist = (a["artist"] as? [String: Any])?["artistName"] as? String ?? (a["artistId"] as? Int).flatMap { artists[$0] } ?? ""
        return LidarrAlbum(id: id, mbid: mbid, title: a["title"] as? String ?? "", artist: artist,
                           date: a["releaseDate"] as? String ?? "", monitored: a["monitored"] as? Bool ?? false,
                           tracks: stats?["totalTrackCount"] as? Int ?? stats?["trackCount"] as? Int ?? 0,
                           haveTracks: stats?["trackFileCount"] as? Int ?? 0, cover: cover(a, mbid: mbid))
    }

    private static let iso: (String) -> Date? = { s in
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    func refreshAlbums() async {
        guard configured else { return }
        do {
            let artists = Dictionary(try await list("artist").compactMap { a in (a["id"] as? Int).map { ($0, a["artistName"] as? String ?? "") } }) { a, _ in a }
            let all = try await list("album").compactMap { Self.album($0, artists: artists) }
            albums = Dictionary(all.map { ($0.mbid, $0) }) { a, _ in a }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refreshWanted() async {
        guard configured else { return }
        do {
            let page = try await call("wanted/missing", [.init(name: "pageSize", value: "250"), .init(name: "includeArtist", value: "true"),
                                                         .init(name: "sortKey", value: "releaseDate"), .init(name: "sortDirection", value: "descending"),
                                                         .init(name: "monitored", value: "true")]) as? [String: Any]
            wanted = ((page?["records"] as? [[String: Any]]) ?? []).compactMap { Self.album($0) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refreshHistory() async {
        guard configured else { return }
        do {
            let page = try await call("history", [.init(name: "pageSize", value: "150"), .init(name: "sortKey", value: "date"),
                                                  .init(name: "sortDirection", value: "descending"),
                                                  .init(name: "includeAlbum", value: "true"), .init(name: "includeArtist", value: "true")]) as? [String: Any]
            var seen = Set<String>()
            history = ((page?["records"] as? [[String: Any]]) ?? []).compactMap { r in
                guard let id = r["id"] as? Int, let kind = r["eventType"] as? String, kind != "trackFileImported" else { return nil }
                let album = r["album"] as? [String: Any], artist = r["artist"] as? [String: Any]
                // one line per album and event, not one per track
                guard seen.insert("\(r["albumId"] ?? 0)|\(kind)|\(r["downloadId"] ?? id)").inserted else { return nil }
                let data = r["data"] as? [String: Any]
                let detail = (data?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? [data?["downloadClient"] as? String, r["sourceTitle"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return LidarrEvent(id: id, kind: kind, artist: artist?["artistName"] as? String ?? "", album: album?["title"] as? String ?? r["sourceTitle"] as? String ?? "",
                                   detail: detail, date: (r["date"] as? String).flatMap(Self.iso),
                                   cover: Self.cover(album, mbid: album?["foreignAlbumId"] as? String ?? ""))
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refreshAll() async {
        loading = true; defer { loading = false }
        async let a: Void = refreshAlbums(), w: Void = refreshWanted(), h: Void = refreshHistory(), q: Void = refreshQueue()
        _ = await (a, w, h, q)
    }

    /// Lidarr searches its indexers for these albums again.
    func search(_ ids: [Int]) async throws {
        _ = try await call("POST", "command", body: ["name": "AlbumSearch", "albumIds": ids])
    }

    func searchAllWanted() async throws {
        _ = try await call("POST", "command", body: ["name": "MissingAlbumSearch"])
    }

    /// Stops wanting an album: Lidarr no longer looks for it.
    func unmonitor(_ a: LidarrAlbum) async throws {
        _ = try await call("PUT", "album/monitor", body: ["albumIds": [a.id], "monitored": false])
        wanted.removeAll { $0.id == a.id }
        albums[a.mbid]?.monitored = false
    }

    /// Follows the queue while the plugin is on (faster while something is downloading).
    func poll(while on: @escaping () -> Bool) async {
        guard !polling else { return }
        polling = true; defer { polling = false }
        while !Task.isCancelled {
            if on() && configured { await refreshQueue() } else if !queue.isEmpty { queue = [] }
            try? await Task.sleep(for: .seconds(queue.isEmpty ? 30 : 5))
        }
    }
}

extension Model {
    /// Hands the album to Lidarr (the plugin), with a notice of how it went.
    func getWithLidarr(_ artist: String, _ album: String, mbid: String? = nil) {
        guard on(.lidarr) else { notify("Turn on the Lidarr plugin in Settings to get albums with it"); return }
        guard lidarr.configured else { notify("Set Lidarr's address and API key in Settings › Plugins › Lidarr"); return }
        Task {
            do { notify(try await lidarr.get(artist: artist, album: album, mbid: mbid)) }
            catch { notify("Lidarr: \(error.localizedDescription)") }
        }
    }

    /// Like Find on Soulseek: the Lidarr pane, with what its indexers find for the album to pick from.
    func chooseWithLidarr(_ artist: String, _ album: String, mbid: String? = nil) {
        guard on(.lidarr) else { notify("Turn on the Lidarr plugin in Settings to get albums with it"); return }
        guard lidarr.configured else { notify("Set Lidarr's address and API key in Settings › Plugins › Lidarr"); return }
        search = ""
        pane = .lidarr
        path = []            // the album page it was asked from would stay on top of the Lidarr page
        lidarr.choose(artist: artist, album: album, mbid: mbid)
    }

    /// The slskd transfer behind a Lidarr download that went to slskd: same folder (and user), for its songs.
    func slskJob(for q: LidarrQueueItem) -> SlskJob? {
        guard q.client.lowercased().contains("slsk") || !q.user.isEmpty else { return nil }
        return slsk.jobs.first { !q.folder.isEmpty && $0.name == q.folder && (q.user.isEmpty || $0.username == q.user) }
            ?? slsk.jobs.first { !q.user.isEmpty && $0.username == q.user && Self.looseMatch(q.album, $0.name) }
    }

    /// slskd transfers Lidarr started: they show (and are imported) as Lidarr's, not as Soulseek downloads of their own.
    var lidarrSlskJobs: Set<String> {
        guard on(.lidarr) else { return [] }
        return Set(lidarr.queue.compactMap { slskJob(for: $0)?.id })
    }

    /// "song 4 of 10 · Name": where an slskd transfer is.
    static func slskProgress(_ j: SlskJob) -> String {
        let done = j.files.filter(\.done).count
        if let now = j.files.first(where: { $0.state.hasPrefix("InProgress") }) {
            return "song \(min(done + 1, j.files.count)) of \(j.files.count): \(now.name)"
        }
        return "\(done) of \(j.files.count) songs"
    }

    func lidarrEntries() -> [DownloadEntry] {
        guard on(.lidarr) else { return [] }
        return lidarr.queue.map { q in
            let j = slskJob(for: q)
            let speed = j.map { $0.finished ? "" : ByteCountFormatter.string(fromByteCount: Int64($0.speed), countStyle: .file) + "/s" } ?? ""
            let via = q.client.isEmpty ? "" : "via \(q.client)" + (q.user.isEmpty ? "" : " from \(q.user)")
            let failed = q.status == "Failed" || q.status == "Import blocked"
            return DownloadEntry(
                id: "lidarr:\(q.id)", source: .lidarr, title: q.album,
                subtitle: [q.artist, via, j.map(Self.slskProgress) ?? "", speed, j == nil ? q.detail : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                state: q.warning.map { "\(q.status): \($0)" } ?? q.status,
                progress: j.map { $0.finished ? 1 : $0.progress } ?? q.progress,
                finished: false, failed: failed,
                artURL: q.cover,
                files: (j?.files ?? []).map { f in
                    .init(name: f.name, state: f.done ? f.state.replacingOccurrences(of: "Completed, ", with: "") : "\(Int(f.percent))%",
                          ok: f.succeeded, failed: f.failed)
                },
                cancel: { [weak self] in Task { try? await self?.lidarr.remove(q, findAnother: false) } },
                reimport: q.warning != nil && q.finished && j != nil ? { [weak self] in
                    // Lidarr couldn't import it: Crate imports slskd's folder the way it does its own Soulseek downloads
                    guard let self, let j else { return }
                    slsk.markImported(j); Task { await self.importDownloaded(j, folder: self.slsk.localFolder(j)) }
                } : nil)
        }
    }
}

struct LidarrSettings: View {
    @ObservedObject var lidarr: Lidarr
    @State private var key = ""
    @State private var testing = false

    var body: some View {
        TextField("Server", text: lidarr.$url, prompt: Text("http://host:8686"))
        LabeledContent("API key") {
            HStack {
                SecureField("", text: $key, prompt: Text(lidarr.apiKey.isEmpty ? "Lidarr › Settings › General › API Key" : "Saved – type to change"))
                    .onSubmit(save)
                Button("Save", action: save).disabled(key.isEmpty)
            }
        }
        LabeledContent("Status") {
            HStack {
                if testing { ProgressView().controlSize(.small) }
                Text(lidarr.error ?? (lidarr.status.isEmpty ? (lidarr.configured ? "Not checked" : "Not set up") : lidarr.status))
                    .foregroundStyle(lidarr.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(2)
                Button("Test") { testing = true; Task { await lidarr.check(); testing = false } }.disabled(!lidarr.configured)
            }
        }
        Text("Albums you get with Lidarr are added without monitoring their artist, so Lidarr doesn't go and get the rest of their albums too. Lidarr files them in its root folder; when that's the music folder your Subsonic server or Crate reads, they show up here.")
            .font(.caption).foregroundStyle(.secondary)
    }

    func save() {
        lidarr.apiKey = key
        key = ""
        testing = true
        Task { await lidarr.check(); testing = false }
    }
}

// MARK: the Lidarr pane

/// Lidarr as a source: search MusicBrainz and get exact albums, what Lidarr still wants, its queue and what it did.
struct LidarrView: View {
    enum Tab: String, CaseIterable { case search = "Search", wanted = "Wanted", queue = "Queue", history = "History" }

    @EnvironmentObject var model: Model
    @ObservedObject var lidarr: Lidarr
    @AppStorage("lidarrTab") private var tab = Tab.search
    @State private var query = ""
    @State private var results: [MBGroup] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var albumsOnly = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Album or artist on MusicBrainz", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
                Button("Search", action: search)
                    .buttonStyle(.glassProminent).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24).padding(.top, 18)

            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in Text(title(t)).tag(t) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                switch tab {
                case .search:
                    Toggle("Albums only", isOn: $albumsOnly).toggleStyle(.checkbox)
                case .wanted:
                    Button("Search All", systemImage: "magnifyingglass") { act("Lidarr is searching for everything it wants") { try await lidarr.searchAllWanted() } }
                        .disabled(lidarr.wanted.isEmpty)
                default: EmptyView()
                }
                Button { Task { await lidarr.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh from Lidarr").disabled(lidarr.loading)
            }
            .padding(.horizontal, 30).padding(.vertical, 10)

            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: lidarr.configured) { await lidarr.refreshAll() }
        .onChange(of: tab) { if lidarr.picking != nil { lidarr.stopChoosing() } }
        .onAppear { if tab == .search && results.isEmpty { focused = true } }
    }

    private func title(_ t: Tab) -> String {
        switch t {
        case .wanted: return lidarr.wanted.isEmpty ? t.rawValue : "\(t.rawValue) (\(lidarr.wanted.count))"
        case .queue: return lidarr.queue.isEmpty ? t.rawValue : "\(t.rawValue) (\(lidarr.queue.count))"
        default: return t.rawValue
        }
    }

    @ViewBuilder private var content: some View {
        if !lidarr.configured {
            PluginSetupNotice(plugin: .lidarr, text: "Add your Lidarr address and API key to get albums with it.")
        } else if let a = lidarr.picking {
            releasePicker(a)
        } else if let e = lidarr.error, tab != .search {
            ContentUnavailableView("Lidarr unreachable", systemImage: "wifi.exclamationmark", description: Text(e))
        } else {
            switch tab {
            case .search: searchList
            case .wanted: wantedList
            case .queue: queueList
            case .history: historyList
            }
        }
    }

    // MARK: search

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        tab = .search
        searching = true; searchError = nil
        Task {
            do { results = try await MBGroup.search(q) } catch { searchError = "MusicBrainz didn't answer: \(error.localizedDescription)" }
            searching = false
        }
    }

    private func inLibrary(_ g: MBGroup) -> Bool {
        model.allAlbums.contains { Model.looseMatch(g.title, $0.title) && Model.looseMatch(g.artist, $0.artist) }
    }

    @ViewBuilder private var searchList: some View {
        let shown = albumsOnly ? results.filter { $0.type == "Album" || $0.type == "EP" } : results
        if let e = searchError {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.magnifyingglass", description: Text(e))
        } else if shown.isEmpty {
            ContentUnavailableView(searching ? "Searching MusicBrainz…" : results.isEmpty ? "Find an album" : "Only singles and other releases",
                                   systemImage: PluginID.lidarr.icon,
                                   description: Text(results.isEmpty ? "Search MusicBrainz for an album or artist; Lidarr gets exactly the release you pick and files it in your music folder."
                                                                     : "Turn off Albums only to see them."))
        } else {
            List(shown) { g in
                LidarrRow(cover: g.cover, seed: g.id, title: g.title,
                          subtitle: [g.artist, g.year > 0 ? String(g.year) : "", g.type == "Album" ? "" : g.type].filter { !$0.isEmpty }.joined(separator: " · "),
                          open: { open(g.id, g.title, g.artist, type: g.type, date: g.date) }) {
                    searchStatus(g)
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private func searchStatus(_ g: MBGroup) -> some View {
        let known = lidarr.albums[g.id]
        if inLibrary(g) || known?.complete == true {
            Label(inLibrary(g) ? "In library" : "In Lidarr", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        } else if let a = known, a.monitored {
            Text(a.haveTracks > 0 ? "Wanted · \(a.haveTracks)/\(a.tracks)" : "Wanted").font(.callout).foregroundStyle(.secondary)
            Button("Search Again") { act("Lidarr is searching for “\(a.title)”") { try await lidarr.search([a.id]) } }
        } else {
            // like Get with Lidarr everywhere else: its releases to pick from
            Button("Get…", systemImage: PluginID.lidarr.icon) { lidarr.choose(artist: g.artist, album: g.title, mbid: g.id) }
                .buttonStyle(.glass)
        }
    }

    // MARK: picking a release

    @ViewBuilder private func releasePicker(_ a: LidarrAlbum) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { lidarr.stopChoosing() } label: { Image(systemName: "chevron.left") }.help("Back")
                CachedImage(url: a.cover, seed: a.mbid).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.title3.bold()).lineLimit(1)
                    Text([a.artist, a.year > 0 ? String(a.year) : ""].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                Spacer()
                if !lidarr.releases.isEmpty, lidarr.grabbed.isEmpty {
                    Button("Let Lidarr Pick", systemImage: "wand.and.stars") {
                        act("Lidarr is getting the release it likes best for “\(a.title)”") { try await lidarr.search([a.id]) }
                    }
                    .disabled(a.id == 0).help("Lidarr picks the best release that passes its quality profile")
                }
            }
            .padding(.horizontal, 30).padding(.bottom, 8)

            if let e = lidarr.releaseError {
                ContentUnavailableView("Lidarr couldn't search", systemImage: "exclamationmark.triangle", description: Text(e))
            } else if lidarr.releases.isEmpty {
                VStack(spacing: 10) {
                    if !lidarr.releaseState.isEmpty { ProgressView() }
                    Text(lidarr.releaseState.isEmpty ? "Lidarr's indexers found nothing for this album" : lidarr.releaseState)
                        .font(.headline)
                    if lidarr.releaseState.isEmpty { Text("It stays in Wanted; Lidarr keeps looking for it.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                Text(lidarr.releaseState).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 30).padding(.bottom, 4)
                List(lidarr.releases) { r in releaseRow(r) }
                    .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
    }

    private func releaseRow(_ r: LidarrRelease) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).lineLimit(2)
                // no age: for Soulseek it's the album's release date, not when the folder was shared
                Text([r.quality, ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file), r.indexer]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !r.rejections.isEmpty {
                    Text(r.rejections.joined(separator: "; ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if lidarr.grabbed.contains(r.id) {
                Label("Downloading", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else if lidarr.grabbing.contains(r.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") { act("Lidarr is downloading “\(r.title)”") { try await lidarr.grab(r) } }
                    .buttonStyle(.glass).disabled(!r.allowed)
                    .help(r.approved ? "Lidarr would pick this one too" : "Lidarr wouldn't take this one on its own; it downloads it anyway")
            }
        }
        .padding(.vertical, 3)
        .opacity(r.approved ? 1 : 0.75)
    }

    // MARK: wanted, queue, history

    @ViewBuilder private var wantedList: some View {
        if lidarr.wanted.isEmpty {
            ContentUnavailableView("Nothing wanted", systemImage: "checkmark.circle", description: Text("Every album Lidarr monitors has its files."))
        } else {
            List(lidarr.wanted) { a in
                LidarrRow(cover: a.cover, seed: a.mbid, title: a.title,
                          subtitle: [a.artist, a.year > 0 ? String(a.year) : "", a.haveTracks > 0 ? "\(a.haveTracks) of \(a.tracks) songs" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                          open: a.mbid.isEmpty ? nil : { open(a.mbid, a.title, a.artist, type: "", date: a.date) }) {
                    Button { act("Lidarr is searching for “\(a.title)”") { try await lidarr.search([a.id]) } } label: { Image(systemName: "magnifyingglass") }
                        .help("Search again")
                    Button { act("Lidarr stopped looking for “\(a.title)”") { try await lidarr.unmonitor(a) } } label: { Image(systemName: "bookmark.slash") }
                        .help("Stop wanting it: Lidarr no longer looks for this album")
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var queueList: some View {
        if lidarr.queue.isEmpty {
            ContentUnavailableView("Nothing downloading", systemImage: "tray", description: Text("Albums Lidarr grabs show up here until they're filed."))
        } else {
            List(lidarr.queue) { q in
                let j = model.slskJob(for: q)
                LidarrRow(cover: q.cover, seed: "\(q.id)", title: q.album,
                          subtitle: [q.artist, q.client.isEmpty ? "" : "via \(q.client)" + (q.user.isEmpty ? "" : " from \(q.user)"),
                                     j.map(Model.slskProgress) ?? q.detail, q.warning.map { "\(q.status): \($0)" } ?? q.status]
                              .filter { !$0.isEmpty }.joined(separator: " · "),
                          progress: j.map { $0.finished ? 1 : $0.progress } ?? q.progress) {
                    Menu {
                        Button("Remove and Find Another") { act("Removed “\(q.album)”; Lidarr is looking for another release") { try await lidarr.remove(q, findAnother: true) } }
                        Button("Remove") { act("Removed “\(q.album)” from Lidarr's queue") { try await lidarr.remove(q, findAnother: false) } }
                    } label: { Image(systemName: "xmark.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Remove from the queue")
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var historyList: some View {
        if lidarr.history.isEmpty {
            ContentUnavailableView("No history yet", systemImage: "clock", description: Text("What Lidarr grabs and imports shows up here."))
        } else {
            List(lidarr.history) { e in
                LidarrRow(cover: e.cover, seed: "h\(e.id)", title: e.album,
                          subtitle: [e.artist, e.detail].filter { !$0.isEmpty }.joined(separator: " · ")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(e.label, systemImage: e.icon).foregroundStyle(e.failed ? .red : e.kind == "downloadImported" ? .green : .secondary)
                        if let d = e.date { Text(d.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
        }
    }

    /// The album's page from MusicBrainz: its songs, which ones the library has, Get with Lidarr.
    private func open(_ mbid: String, _ title: String, _ artist: String, type: String, date: String) {
        model.path.append(.release(ReleaseGroup(id: mbid, title: title, type: type, date: date), artist: artist))
    }

    /// Runs a Lidarr action with a notice of how it went.
    private func act(_ done: String, _ f: @escaping () async throws -> Void) {
        Task {
            do { try await f(); model.notify(done) } catch { model.notify("Lidarr: \(error.localizedDescription)") }
        }
    }
}

/// A row in the Lidarr pane: cover, two lines, optional progress, controls on the right.
struct LidarrRow<Trailing: View>: View {
    var cover: URL?
    var seed, title, subtitle: String
    var progress: Double? = nil
    var open: (() -> Void)? = nil        // the album's page (its songs), from a click on the cover or titles
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                CachedImage(url: cover, seed: seed)
                    .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let progress { ProgressView(value: progress).controlSize(.small) }
                }
                Spacer(minLength: 8)
            }
            .contentShape(.rect)
            .onTapGesture { open?() }
            .pointerStyle(open == nil ? nil : .link)
            .help(open == nil ? "" : "Show the album's songs")
            trailing()
        }
        .padding(.vertical, 2)
    }
}
