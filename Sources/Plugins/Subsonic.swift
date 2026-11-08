import SwiftUI
import CryptoKit

// The Subsonic plugin reads a Subsonic server (Navidrome; the OpenSubsonic JSON API, token login):
// its songs join the library and its playlists show in the sidebar, like OwnTone's. Songs whose files
// this Mac sees in the music folder (on the share) are used from there; that needs the server to
// report real paths (Navidrome: Settings › Players › Crate › Report Real Path). The rest are
// downloaded when a sync needs them and streamed when played here. Covers the files don't carry
// come from getCoverArt. After imports Crate asks the server to rescan (startScan, an admin call),
// and plays from the iPod's Play Counts are scrobbled back on Sync.

enum SubsonicError: Error, LocalizedError {
    case notConfigured, unreachable(String), http(Int), notSubsonic, server(Int, String), noSongs
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter the server, username and password in Settings › Plugins › Subsonic"
        case .unreachable(let why): return "Can't reach the Subsonic server: \(why)"
        case .http(let c): return "The server answered HTTP \(c); is this a Subsonic server?"
        case .notSubsonic: return "The server doesn't answer like a Subsonic server; check the address"
        case .server(40, _): return "The server didn't accept the username or password"
        case .server(41, _): return "The server doesn't take token logins (an LDAP user?)"
        case .server(50, _): return "This user isn't allowed to do that"
        case .server(let c, let m): return m.isEmpty ? "The server answered with error \(c)" : m
        case .noSongs: return "The server listed no songs"
        }
    }
}

/// A song on the server, by library path.
struct SubsonicSong: Hashable { var id, albumID, cover: String; var rating = 0 }     // rating: the server's stars, 0 for none

@MainActor
final class Subsonic: ObservableObject {
    @AppStorage("subsonicURL") var url = ""
    @AppStorage("subsonicUser") var user = ""
    @AppStorage("subsonicMusicFolder") var musicFolder = ""      // learnt from the paths the server reports (see library())
    /// false: everything goes through the API (songs are downloaded when a sync needs them), no share needed;
    /// changing the files themselves (tags, covers, deleting) then isn't possible from Crate.
    @AppStorage("subsonicUseShare") var useShare = true

    @Published var status = ""
    @Published var error: String?

    var password: String {
        get { Keychain.get("subsonic") }
        set {
            objectWillChange.send()
            let status = Keychain.set("subsonic", newValue)
            if status != errSecSuccess { error = "Couldn't save the password (\(status))" }
        }
    }

    /// Library path → the server's song, from the last load.
    private(set) var songs: [String: SubsonicSong] = [:]
    private(set) var rawPaths: [String] = []         // a few paths as the server reports them (--subsonic-check)
    private var paths: [String: String] = [:]          // song id → library path
    /// Album + title → the server's song: matches files Crate found itself when the server doesn't report real paths.
    private var byKey: [String: SubsonicSong] = [:]

    /// The server's copy of a library song: by path, else by album and title.
    func song(for t: LibTrack) -> SubsonicSong? { songs[t.path] ?? byKey[t.key] }

    /// Downloads for songs this Mac can't see on the share, one folder per album.
    nonisolated static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("nl.jrvgr.crate/Subsonic")
    }
    nonisolated static let cachePrefix = cache.path + "/"

    /// A library song Crate only has through the API: its file is (or will be) a download in the cache, not one it can change.
    nonisolated static func serverOnly(_ path: String) -> Bool { path.hasPrefix(cachePrefix) }

    var base: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
    var configured: Bool { !url.isEmpty && !user.isEmpty && !password.isEmpty }

    // MARK: HTTP

    // one salt per launch, so cover and stream URLs stay the same (and cacheable) while Crate runs
    private let salt = (0..<12).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()

    func endpoint(_ method: String, _ params: [URLQueryItem] = []) -> URL? {
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var c = URLComponents(string: base + "/rest/" + method + ".view")
        c?.queryItems = [.init(name: "u", value: user), .init(name: "t", value: token), .init(name: "s", value: salt),
                         .init(name: "v", value: "1.16.1"), .init(name: "c", value: "Crate"), .init(name: "f", value: "json")] + params
        return c?.url
    }

    /// One call; the "subsonic-response" object, or the server's error.
    /// `post`: the parameters go in a form body instead of the URL (a long playlist's song ids don't fit in one).
    func call(_ method: String, _ params: [URLQueryItem] = [], post: Bool = false) async throws -> [String: Any] {
        guard configured, let u = endpoint(method, params) else { throw SubsonicError.notConfigured }
        var r = URLRequest(url: u); r.timeoutInterval = 20
        if post, var c = URLComponents(url: u, resolvingAgainstBaseURL: false), let body = c.percentEncodedQuery {
            c.query = nil
            if let bare = c.url { r.url = bare }
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.utf8)
        }
        let d: Data, resp: URLResponse
        do { (d, resp) = try await URLSession.shared.data(for: r) }
        catch { throw SubsonicError.unreachable(error.localizedDescription) }
        return try Self.parse(d, resp)
    }

    nonisolated static func parse(_ d: Data, _ resp: URLResponse) throws -> [String: Any] {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let root = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["subsonic-response"] as? [String: Any]
        guard let root else { throw code == 200 ? SubsonicError.notSubsonic : SubsonicError.http(code) }
        guard root["status"] as? String == "ok" else {
            let e = root["error"] as? [String: Any]
            throw SubsonicError.server(e?["code"] as? Int ?? 0, e?["message"] as? String ?? "")
        }
        return root
    }

    /// Logs in with ping and says which server answered.
    func check() async {
        do {
            let r = try await call("ping")
            let name = (r["type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Subsonic server"
            status = "Connected to \(name) \((r["serverVersion"] as? String ?? "").split(separator: " ").first ?? "")"
            error = nil
        } catch {
            status = ""
            self.error = error.localizedDescription
        }
    }

    // MARK: library

    /// Every song on the server, as library tracks (at their path on this Mac, or their download spot).
    func library() async throws -> [LibTrack] {
        var raw: [[String: Any]] = []
        // an empty search lists everything on Navidrome ("" is how clients usually ask for it)
        for q in ["\"\"", ""] where raw.isEmpty { raw = try await searchAll(q) }
        if raw.isEmpty { raw = try await songsByAlbum() }
        if raw.isEmpty { throw SubsonicError.noSongs }
        // the server's music folder as this Mac sees it: where all the paths it reports start (when it reports real paths)
        if useShare, musicFolder.isEmpty, let root = Self.commonFolder(raw.compactMap { $0["path"] as? String }.filter { $0.hasPrefix("/") }) {
            musicFolder = LibraryLoader.localPath(root)
        }
        rawPaths = raw.prefix(5).map { ($0["path"] as? String) ?? "" }
        let folder = useShare ? musicFolder : "", cache = Self.cache.path
        let found = await Task.detached { Self.tracks(raw, folder: folder, cache: cache) }.value
        songs = Dictionary(found.map { ($0.0.path, $0.1) }, uniquingKeysWith: { a, _ in a })
        paths = Dictionary(found.map { ($0.1.id, $0.0.path) }, uniquingKeysWith: { a, _ in a })
        byKey = Dictionary(found.map { ($0.0.key, $0.1) }, uniquingKeysWith: { a, _ in a })
        return found.map(\.0)
    }

    nonisolated static func commonFolder(_ paths: [String]) -> String? {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent.split(separator: "/") }) else { return nil }
        for p in paths.dropFirst() {
            let parts = p.split(separator: "/").dropLast()
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
            if common.isEmpty { return nil }
        }
        return "/" + common.joined(separator: "/")
    }

    private func searchAll(_ query: String) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        while true {
            let r = try await call("search3", [.init(name: "query", value: query), .init(name: "artistCount", value: "0"),
                                               .init(name: "albumCount", value: "0"), .init(name: "songCount", value: "500"),
                                               .init(name: "songOffset", value: "\(out.count)")])
            let page = ((r["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]]) ?? []
            out += page
            if page.count < 500 { return out }
        }
    }

    /// For servers that don't list everything on an empty search: every album, then its songs.
    private func songsByAlbum() async throws -> [[String: Any]] {
        var ids: [String] = []
        while true {
            let r = try await call("getAlbumList2", [.init(name: "type", value: "alphabeticalByName"), .init(name: "size", value: "500"),
                                                     .init(name: "offset", value: "\(ids.count)")])
            let page = ((r["albumList2"] as? [String: Any])?["album"] as? [[String: Any]]) ?? []
            ids += page.compactMap { $0["id"] as? String }
            if page.count < 500 { break }
        }
        var out: [[String: Any]] = []
        for id in ids {
            let r = try await call("getAlbum", [.init(name: "id", value: id)])
            out += ((r["album"] as? [String: Any])?["song"] as? [[String: Any]]) ?? []
        }
        return out
    }

    /// Server songs → library tracks. A song is used from the share when its album's first file is
    /// there (one look per folder, not per song); otherwise it gets a path in the download cache.
    /// `folder` empty: API only, every song gets its download spot.
    nonisolated static func tracks(_ raw: [[String: Any]], folder: String, cache: String) -> [(LibTrack, SubsonicSong)] {
        var listings: [String: [String]] = [:]      // each folder's files, read once
        let bare = { (x: String) in x.lowercased().filter { $0.isLetter || $0.isNumber } }
        return raw.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            let str = { (k: String) in (s[k] as? String) ?? "" }
            let num = { (k: String) in (s[k] as? Int) ?? 0 }
            let p = str("path")
            let local = p.hasPrefix("/") ? LibraryLoader.localPath(p) : folder + "/" + p
            let dir = (local as NSString).deletingLastPathComponent
            if listings[dir] == nil { listings[dir] = p.isEmpty || folder.isEmpty ? [] : (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] }
            let files = listings[dir]!
            // without Report Real Path the server makes up file names ("01-01 - Title.mp3"): the folder is right, so
            // take the file in it whose name has the title
            var onShare: String?
            if files.contains((local as NSString).lastPathComponent) { onShare = local }
            else if !files.isEmpty, !str("title").isEmpty {
                let ext = (p as NSString).pathExtension.lowercased(), title = bare(str("title"))
                let hits = files.filter { ($0 as NSString).pathExtension.lowercased() == ext && bare(($0 as NSString).deletingPathExtension).contains(title) }
                // "… - 05 - Title.flac": a name ending in the title beats one that only has it (the album's name can be in every file)
                let ends = hits.filter { bare(($0 as NSString).deletingPathExtension).hasSuffix(title) }
                if let f = (ends.isEmpty ? hits : ends).min(by: { $0.count < $1.count }) { onShare = dir + "/" + f }
            }
            let albumID = str("albumId").isEmpty ? "unknown" : str("albumId")
            let suffix = str("suffix").isEmpty ? (p as NSString).pathExtension : str("suffix")
            let path = onShare ?? cache + "/" + albumID + "/" + id + "." + suffix
            let albumArtist = [str("displayAlbumArtist"), ((s["albumArtists"] as? [[String: Any]])?.first?["name"] as? String) ?? "", str("artist")]
                .first { !$0.isEmpty } ?? ""
            let added = ISO8601DateFormatter().date(from: String(str("created").prefix(19)) + "Z")
            let t = LibTrack(title: str("title"), artist: albumArtist, album: str("album"), genre: str("genre"),
                             trackNumber: num("track"), discNumber: num("discNumber"), year: num("year"),
                             lengthMs: num("duration") * 1000, path: path, trackArtist: str("artist"), added: added)
            return (t, SubsonicSong(id: id, albumID: albumID, cover: str("coverArt"), rating: num("userRating")))
        }
    }

    // MARK: playlists

    /// A stable id for a server playlist (the sidebar and the sync queue use Ints), far from OwnTone's and Spotify's.
    static func playlistID(_ id: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return -(1 << 33) - Int(h)
    }

    func playlists() async throws -> [OTPlaylist] {
        let r = try await call("getPlaylists")
        let items = ((r["playlists"] as? [String: Any])?["playlist"] as? [[String: Any]]) ?? []
        return items.compactMap { p in
            guard let id = p["id"] as? String, let n = p["songCount"] as? Int, n > 0 else { return nil }
            return OTPlaylist(id: Self.playlistID(id), name: p["name"] as? String ?? "", uri: "", count: n,
                              subsonicID: id, artwork: coverURL(p["coverArt"] as? String)?.absoluteString ?? "")
        }
    }

    func tracks(_ playlistID: String) async throws -> [OTTrack] {
        let r = try await call("getPlaylist", [.init(name: "id", value: playlistID)])
        let items = ((r["playlist"] as? [String: Any])?["entry"] as? [[String: Any]]) ?? []
        return items.enumerated().map { n, s in
            let str = { (k: String) in (s[k] as? String) ?? "" }
            return OTTrack(id: n, title: str("title"), artist: str("artist"), album: str("album"),
                           albumArtist: str("displayAlbumArtist"), dataKind: "file", uri: "",
                           artworkPath: coverURL(str("coverArt"))?.absoluteString ?? "",
                           lengthMs: ((s["duration"] as? Int) ?? 0) * 1000, path: paths[str("id")] ?? "")
        }
    }

    /// Puts these songs in the playlist, in this order (createPlaylist with an id replaces its songs).
    func setSongs(_ songIDs: [String], ofPlaylist id: String) async throws {
        _ = try await call("createPlaylist", [.init(name: "playlistId", value: id)] + songIDs.map { .init(name: "songId", value: $0) }, post: true)
    }

    func renamePlaylist(_ id: String, to name: String) async throws {
        _ = try await call("updatePlaylist", [.init(name: "playlistId", value: id), .init(name: "name", value: name)])
    }

    func deletePlaylist(_ id: String) async throws {
        _ = try await call("deletePlaylist", [.init(name: "id", value: id)])
    }

    /// Stars (0 clears them), on the server too, so other clients and the next load see them.
    func setRating(_ songID: String, _ stars: Int) async throws {
        _ = try await call("setRating", [.init(name: "id", value: songID), .init(name: "rating", value: "\(stars)")])
    }

    /// The song's id for a library path.
    func id(forPath path: String) -> String? { songs[path]?.id }

    /// The server's stars for a library song; nil when it isn't the server's.
    func rating(of t: LibTrack) -> Int? { song(for: t)?.rating }

    /// Rates the song on the server, and in the copy Crate keeps until the next load.
    func rate(_ t: LibTrack, _ stars: Int) async throws {
        guard let s = song(for: t) else { return }
        try await setRating(s.id, stars)
        for (k, v) in songs where v.id == s.id { songs[k]?.rating = stars }
        for (k, v) in byKey where v.id == s.id { byKey[k]?.rating = stars }
        objectWillChange.send()
    }

    // MARK: files

    func coverURL(_ id: String?, size: Int = 600) -> URL? {
        guard let id, !id.isEmpty, configured else { return nil }
        return endpoint("getCoverArt", [.init(name: "id", value: id), .init(name: "size", value: "\(size)")])
    }

    /// The album cover for a library track from the server, for albums whose files carry none.
    func cover(forPath path: String) async -> Data? {
        guard let u = coverURL(songs[path]?.cover),
              let (d, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200,
              resp.mimeType?.hasPrefix("image/") == true else { return nil }
        return d
    }

    /// Where a song that isn't on this Mac plays from.
    func streamURL(forPath path: String) -> URL? {
        songs[path].flatMap { endpoint("stream", [.init(name: "id", value: $0.id)]) }
    }

    /// Whether this library path is one of the server's songs still waiting to be downloaded.
    /// Library files that are a server song under another path (the server copy was dropped for the file).
    func link(_ files: [String: String]) {
        for (file, server) in files { if let s = songs[server] { songs[file] = s; paths[s.id] = file } }
    }

    func needsDownload(_ path: String) -> Bool { songs[path] != nil && !FileManager.default.fileExists(atPath: path) }

    /// Downloads the original file to the track's path in the cache.
    func download(_ path: String) async throws {
        guard let s = songs[path], let u = endpoint("download", [.init(name: "id", value: s.id)]) else { throw SubsonicError.notConfigured }
        let tmp: URL, resp: URLResponse
        do { (tmp, resp) = try await URLSession.shared.download(from: u) }
        catch { throw SubsonicError.unreachable(error.localizedDescription) }
        // errors come back as a 200 with a JSON body instead of the file
        if resp.mimeType?.contains("json") == true || (resp as? HTTPURLResponse)?.statusCode != 200 {
            _ = try Self.parse((try? Data(contentsOf: tmp)) ?? Data(), resp)
            throw SubsonicError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let dst = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    // MARK: server

    /// Asks the server to rescan its folder (after files were added to it). Navidrome only lets admins.
    func startScan() async { _ = try? await call("startScan") }

    /// Sends plays (library path, when) as scrobbles. Returns how many the server took.
    func scrobble(_ plays: [(track: LibTrack, time: Date)]) async -> Int {
        let known = plays.compactMap { p in song(for: p.track).map { ($0.id, p.time) } }
        var sent = 0
        for chunk in stride(from: 0, to: known.count, by: 50).map({ Array(known[$0..<min($0 + 50, known.count)]) }) {
            let params = chunk.flatMap { [URLQueryItem(name: "id", value: $0.0), URLQueryItem(name: "time", value: "\(Int64($0.1.timeIntervalSince1970 * 1000))")] }
            if (try? await call("scrobble", params + [.init(name: "submission", value: "true")])) != nil { sent += chunk.count }
        }
        return sent
    }
}
