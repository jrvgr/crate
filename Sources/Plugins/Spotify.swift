import SwiftUI
import Network
import CryptoKit

// The Spotify plugin on its own: the Web API with your account (authorization code + PKCE, so no
// client secret; the browser hands the code back to a one-shot listener on 127.0.0.1). It reads
// your saved albums and your playlists. "Through OwnTone" (the older way) reads what OwnTone has.

enum SpotifyError: Error, LocalizedError {
    case noClientID, denied(String), http(Int), notConnected
    var errorDescription: String? {
        switch self {
        case .noClientID: return "Enter the Client ID of your Spotify app first"
        case .denied(let s): return "Spotify login failed: \(s)"
        case .http(let c): return c == 401 ? "Spotify needs you to connect again" : c == 403 ? "Spotify refused (403); is your account added to the app under User Management?" : "Spotify answered HTTP \(c)"
        case .notConnected: return "Not connected to Spotify"
        }
    }
}

@MainActor
final class SpotifyAPI: ObservableObject {
    static let port: UInt16 = 8765
    static var redirect: String { "http://127.0.0.1:\(port)/callback" }
    static let scopes = "user-library-read playlist-read-private playlist-read-collaborative"

    @AppStorage("spotifyMode") var mode = "account"            // "owntone" or "account"
    @AppStorage("spotifyClientID") var clientID = ""
    @AppStorage("spotifyUser") var user = ""
    @Published var connecting = false
    @Published var error: String?

    private var access = "", expires = Date.distantPast
    var direct: Bool { mode == "account" }
    var connected: Bool { !Keychain.get("spotify-refresh").isEmpty }

    // MARK: login

    func connect() async {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else { error = SpotifyError.noClientID.localizedDescription; return }
        connecting = true; error = nil
        defer { connecting = false }
        let verifier = (0..<64).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".randomElement()! }.map(String.init).joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [.init(name: "client_id", value: clientID.trimmingCharacters(in: .whitespaces)), .init(name: "response_type", value: "code"),
                        .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
                        .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
                        .init(name: "state", value: state)]
        do {
            let server = Callback(port: Self.port)
            try server.start()
            NSWorkspace.shared.open(c.url!)
            let query = try await server.wait()
            guard query["state"] == state else { throw SpotifyError.denied("the answer didn't match") }
            guard let code = query["code"] else { throw SpotifyError.denied(query["error"] ?? "no code") }
            try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect, "code_verifier": verifier])
            // logged in; the name is a nicety (dev-mode apps answer 403 here until the account is added in the dashboard)
            if let me = (try? await get("/me")) as? [String: Any] { user = me["display_name"] as? String ?? me["id"] as? String ?? "" }
            objectWillChange.send()
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() {
        Keychain.set("spotify-refresh", ""); access = ""; user = ""
        objectWillChange.send()
    }

    private func token(_ form: [String: String]) async throws {
        var r = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = form; all["client_id"] = clientID.trimmingCharacters(in: .whitespaces)
        r.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let a = j["access_token"] as? String else {
            if form["grant_type"] == "refresh_token" { disconnect() }
            throw SpotifyError.denied(j["error_description"] as? String ?? j["error"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        access = a
        expires = Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 3600) - 60)
        if let r = j["refresh_token"] as? String { Keychain.set("spotify-refresh", r) }
        objectWillChange.send()
    }

    // MARK: API

    func get(_ path: String) async throws -> Any? {
        let refresh = Keychain.get("spotify-refresh")
        guard !refresh.isEmpty else { throw SpotifyError.notConnected }
        if access.isEmpty || Date() > expires { try await token(["grant_type": "refresh_token", "refresh_token": refresh]) }
        let url = path.hasPrefix("http") ? URL(string: path)! : URL(string: "https://api.spotify.com/v1" + path)!
        var r = URLRequest(url: url); r.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        for _ in 0..<3 {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let h = resp as? HTTPURLResponse, code = h?.statusCode ?? 0
            if code == 429 {     // rate limited: wait as long as Spotify asks
                try await Task.sleep(for: .seconds(Double(h?.value(forHTTPHeaderField: "Retry-After") ?? "2") ?? 2))
                continue
            }
            guard code == 200 else { throw SpotifyError.http(code) }
            return try JSONSerialization.jsonObject(with: d)
        }
        throw SpotifyError.http(429)
    }

    /// Follows "next" links of a paged list.
    private func all(_ path: String, limit: Int = 2000) async throws -> [[String: Any]] {
        var out: [[String: Any]] = [], next: String? = path
        while let n = next, out.count < limit {
            let j = try await get(n) as? [String: Any]
            out += (j?["items"] as? [[String: Any]]) ?? []
            next = j?["next"] as? String
        }
        return out
    }

    static func image(_ o: [String: Any]?) -> String {
        let imgs = (o?["images"] as? [[String: Any]]) ?? []
        return (imgs.first { ($0["width"] as? Int ?? 0) <= 640 && ($0["width"] as? Int ?? 0) >= 250 } ?? imgs.first)?["url"] as? String ?? ""
    }

    /// The releases with a song matching `song` by `artist`, from Spotify's search (its first 30 songs).
    func albums(withSong song: String, by artist: String) async throws -> [String] {
        var names: [String] = []
        for offset in [0, 10, 20] {
            var c = URLComponents(string: "https://api.spotify.com/v1/search")!
            c.queryItems = [.init(name: "q", value: "track:\(song) artist:\(artist)"), .init(name: "type", value: "track"),
                            .init(name: "limit", value: "10"), .init(name: "offset", value: "\(offset)")]
            let j = try await get(c.url!.absoluteString) as? [String: Any]
            let items = ((j?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            names += items.compactMap { ($0["album"] as? [String: Any])?["name"] as? String }
            if items.count < 10 { break }
        }
        return names
    }

    /// A release's Spotify URI from its title and artist, when Spotify has it.
    func albumURI(_ title: String, by artist: String) async -> String? {
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [.init(name: "q", value: "album:\(title) artist:\(artist)"), .init(name: "type", value: "album"), .init(name: "limit", value: "10")]
        guard let j = try? await get(c.url!.absoluteString) as? [String: Any] else { return nil }
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let items = ((j["albums"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.first { loose($0["name"] as? String ?? "") == loose(title) }?["uri"] as? String
    }

    /// An album as a library folder names it ("Humanz [Deluxe], Disc 1"): the same title, else the edition's
    /// (without the disc), else the plain title ("Humanz").
    func albumURI(loosely title: String, by artist: String) async -> String? {
        let edition = AlbumTitle.withoutDisc(title), base = AlbumTitle.base(title)
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [.init(name: "q", value: "album:\(base) artist:\(artist)"), .init(name: "type", value: "album"), .init(name: "limit", value: "20")]
        guard let j = try? await get(c.url!.absoluteString) as? [String: Any] else { return nil }
        let items = ((j["albums"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let names = items.map { Release.loose($0["name"] as? String ?? "") }
        for want in [title, edition, base].map(Release.loose) where !want.isEmpty {
            if let i = names.firstIndex(of: want) { return items[i]["uri"] as? String }
        }
        return nil
    }

    func savedAlbums() async throws -> [SpotifyAlbum] {
        try await all("/me/albums?limit=50").compactMap { i in
            guard let a = i["album"] as? [String: Any] else { return nil }
            let artists = ((a["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return SpotifyAlbum(name: a["name"] as? String ?? "", artist: artists.first ?? "", uri: a["uri"] as? String ?? "",
                                artworkPath: Self.image(a), trackCount: a["total_tracks"] as? Int ?? 0,
                                year: Int((a["release_date"] as? String ?? "").prefix(4)) ?? 0)
        }
    }

    /// Your playlists, with negative ids so they can't clash with OwnTone's.
    func playlists() async throws -> [OTPlaylist] {
        try await all("/me/playlists?limit=50").enumerated().compactMap { n, p in
            guard let id = p["id"] as? String else { return nil }
            let count = ((p["tracks"] as? [String: Any])?["total"] as? Int) ?? ((p["items"] as? [String: Any])?["total"] as? Int) ?? 0
            guard count > 0 else { return nil }
            return OTPlaylist(id: -(n + 1), name: p["name"] as? String ?? "", uri: p["uri"] as? String ?? "", count: count,
                              spotifyID: id, artwork: Self.image(p))
        }
    }

    /// Liked Songs (the library's saved tracks), shown as a playlist.
    func likedPlaylist() async throws -> OTPlaylist? {
        let j = try await get("/me/tracks?limit=1") as? [String: Any]
        let n = j?["total"] as? Int ?? 0
        return n > 0 ? OTPlaylist(id: -10_000, name: "Liked Songs", uri: "spotify:collection:tracks", count: n, spotifyID: "liked") : nil
    }

    func tracks(_ playlistID: String) async throws -> [OTTrack] {
        if playlistID == "liked" { return try await songs(all("/me/tracks?limit=50", limit: 10_000)) }
        // /items with "item" is the current form; /tracks with "track" is what older apps still get
        let items: [[String: Any]]
        do { items = try await all("/playlists/\(playlistID)/items?limit=50&additional_types=track", limit: 5000) }
        catch { items = try await all("/playlists/\(playlistID)/tracks?limit=100&additional_types=track", limit: 5000) }
        return songs(items)
    }

    /// Playlist or library items → songs (the song is under "item" now, "track" before).
    func songs(_ items: [[String: Any]]) -> [OTTrack] {
        items.enumerated().compactMap { n, i in
            guard let t = (i["item"] ?? i["track"]) as? [String: Any], (t["type"] as? String ?? "track") == "track" else { return nil }
            let a = t["album"] as? [String: Any]
            let artists = ((t["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            let albumArtists = ((a?["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return OTTrack(id: n, title: t["name"] as? String ?? "", artist: artists.joined(separator: ", "), album: a?["name"] as? String ?? "",
                           albumArtist: albumArtists.first ?? "", dataKind: "spotify", uri: t["uri"] as? String ?? "",
                           artworkPath: Self.image(a), lengthMs: t["duration_ms"] as? Int ?? 0)
        }
    }

    /// Opens an album, playlist or track in the Spotify app.
    static func open(_ uri: String) {
        if let u = URL(string: uri), NSWorkspace.shared.urlForApplication(toOpen: u) != nil { NSWorkspace.shared.open(u) }
        else if let u = URL(string: "https://open.spotify.com/" + uri.replacingOccurrences(of: "spotify:", with: "").replacingOccurrences(of: ":", with: "/")) {
            NSWorkspace.shared.open(u)
        }
    }
}

/// Answers the one browser request Spotify's login redirects to and hands back its query.
final class Callback: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init(port: UInt16) { listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) }

    func start() throws {
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                guard target.hasPrefix("/callback") else { c.cancel(); return }
                var q: [String: String] = [:]
                for item in URLComponents(string: target)?.queryItems ?? [] { q[item.name] = item.value ?? "" }
                let ok = q["code"] != nil
                let html = "<html><body style='font:16px -apple-system;text-align:center;padding-top:80px'><h2>"
                    + (ok ? "Crate is connected to Spotify" : "Spotify login didn't work") + "</h2><p>You can close this tab.</p></body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
                self?.finish(.success(q))
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(.failure(SpotifyError.denied("timed out"))) }
    }

    func wait() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.main.async {
                if let r = self.result { c.resume(with: r) } else { self.continuation = c }
            }
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        listener.cancel()
        continuation?.resume(with: r); continuation = nil
    }
}

// MARK: album page

@MainActor
final class SpotifyAlbumState: ObservableObject {
    @Published var tracks: [OTTrack] = []
    @Published var year = 0
    @Published var loading = true
    @Published var error: String?
    @Published var found: SpotifyAlbum?              // a MusicBrainz release that Spotify has too
    @Published var searching: Set<Int> = []           // songs (by place) being looked up on Soulseek
    @Published var getting: Set<Int> = []             // … and the ones queued, from either
}

/// Library folder names for an album against the release's title.
enum AlbumTitle {
    /// "Humanz [Deluxe], Disc 1" → "Humanz [Deluxe]"
    static func withoutDisc(_ t: String) -> String {
        t.replacingOccurrences(of: #"[,:\- ]*[\(\[]?\b(disc|cd|disk)\s*\d+[\)\]]?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
    /// "Humanz [Deluxe], Disc 1" → "Humanz"
    static func base(_ t: String) -> String {
        withoutDisc(t).replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Where a song you have no file for is put when it's fetched on its own: the album (as it's tagged), its
/// artist, the song's number and the album's song count, cover and year.
struct SongTarget {
    var album, artist, art: String
    var total, year: Int
}

/// A song you have no file for: get it on its own, from Soulseek or YouTube (whichever are on; a menu when both are).
struct GetSongButton: View {
    @EnvironmentObject var model: Model
    @ObservedObject var s: SpotifyAlbumState
    var track: OTTrack
    var number: Int                                   // its place on the album, from 1
    var to: SongTarget

    var body: some View {
        let soulseek = model.on(.soulseek), youtube = model.on(.youtube)
        if s.searching.contains(number) {
            ProgressView().controlSize(.small).frame(width: 18).help("Looking for “\(track.title)” on Soulseek…")
        } else if s.getting.contains(number) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Downloading; it shows up in the library when it's done")
        } else if soulseek && youtube {
            Menu { GetSongItems(s: s, track: track, number: number, to: to) } label: { Image(systemName: "arrow.down.circle") }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize().help("Get this song")
        } else if soulseek || youtube {
            Button { GetSongItems.get(model, s, track, number, to, soulseek: soulseek) } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.plain).help(soulseek ? "Get this song from Soulseek" : "Get this song from YouTube")
        }
    }
}

/// The menu items for getting a song, for the button's menu and the row's context menu.
struct GetSongItems: View {
    @EnvironmentObject var model: Model
    @ObservedObject var s: SpotifyAlbumState
    var track: OTTrack
    var number: Int
    var to: SongTarget

    var body: some View {
        if model.on(.soulseek) { Button("Get Song from Soulseek", systemImage: "arrow.down.circle") { Self.get(model, s, track, number, to, soulseek: true) } }
        if model.on(.youtube) { Button("Get Song from YouTube", systemImage: "play.rectangle") { Self.get(model, s, track, number, to, soulseek: false) } }
    }

    @MainActor
    static func get(_ model: Model, _ s: SpotifyAlbumState, _ t: OTTrack, _ n: Int, _ to: SongTarget, soulseek: Bool) {
        guard !s.searching.contains(n), !s.getting.contains(n) else { return }
        if !soulseek {
            model.songFromYouTube(t, number: n, of: to.total, artist: to.artist, album: to.album, art: to.art, year: to.year)
            s.getting.insert(n); return
        }
        s.searching.insert(n)
        Task {
            let ok = await model.songFromSoulseek(t, artist: to.artist, album: to.album)
            s.searching.remove(n)
            if ok { s.getting.insert(n) }
        }
    }
}

/// The songs of a library album you have no files for (it came in a song at a time, or is incomplete): the
/// whole album from Spotify, else MusicBrainz, less the ones in the library, each to get on its own.
struct MissingSongs: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var spot: SpotifyAPI
    var album: Album
    @StateObject private var s = SpotifyAlbumState()

    var body: some View {
        let have = Set(album.tracks.map { Release.loose($0.title) })
        let missing = s.tracks.enumerated().filter { !have.contains(Release.loose($0.element.title)) && model.libraryTrack(for: $0.element) == nil }
        let to = SongTarget(album: album.title, artist: album.artist, art: s.found?.artworkPath ?? "", total: s.tracks.count, year: album.year > 0 ? album.year : s.year)
        Group {
            if s.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.artistLoading.contains(album.artist.lowercased()) ? "Looking up \(album.artist)'s releases on MusicBrainz…"
                         : "Looking for the rest of the album…")
                }
                .foregroundStyle(.secondary)
            } else if !missing.isEmpty, model.on(.soulseek) || model.on(.youtube) || model.on(.spotify) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Not downloaded").font(.title3.bold())
                        Text("\(missing.count) of \(s.tracks.count) songs" + (s.found != nil ? " · from Spotify" : " · from MusicBrainz")).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(missing.enumerated()), id: \.element.offset) { row, m in
                            let t = m.element, n = m.offset + 1
                            HStack(spacing: 12) {
                                Text("\(n)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).lineLimit(1)
                                    if t.artist != album.artist { Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                GetSongButton(s: s, track: t, number: n, to: to)
                                Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(row % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                            .opacity(0.75)
                            .contextMenu {
                                GetSongItems(s: s, track: t, number: n, to: to)
                                if !t.uri.isEmpty { LinkMenu(track: t) }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
            }
        }
        .task(id: album.id) {
            s.tracks = []; s.found = nil; s.loading = true
            defer { s.loading = false }
            if model.on(.spotify), spot.direct, spot.connected, let uri = await spot.albumURI(loosely: album.title, by: album.artist),
               let r = try? await spot.album(uri) {
                s.tracks = r.tracks; s.year = r.year
                s.found = SpotifyAlbum(name: album.title, artist: album.artist, uri: uri, artworkPath: r.art, trackCount: r.tracks.count, year: r.year)
                return
            }
            await model.loadArtistInfo(album.artist)
            let releases = model.artistInfo[album.artist.lowercased()]?.releases ?? []
            let wants = [album.title, AlbumTitle.withoutDisc(album.title), AlbumTitle.base(album.title)].map(Release.loose)
            guard let g = wants.lazy.compactMap({ w in releases.first { Release.loose($0.title) == w } }).first,
                  let list = await ArtistLookup.tracks(g.id) else { return }
            s.tracks = list.map { OTTrack(id: $0.number, title: $0.title, artist: album.artist, album: album.title, albumArtist: album.artist,
                                          dataKind: "", uri: "", artworkPath: "", lengthMs: $0.lengthMs) }
        }
    }
}

/// An album you have no files for: a saved Spotify album, or a release from an artist's MusicBrainz discography.
/// Its songs (and which you have), play it, and ways to get it.
struct SpotifyAlbumView: View {
    enum Source { case spotify(SpotifyAlbum), release(ReleaseGroup, artist: String) }
    @EnvironmentObject var model: Model
    @EnvironmentObject var spot: SpotifyAPI
    var source: Source
    @StateObject private var s = SpotifyAlbumState()

    init(album: SpotifyAlbum) { source = .spotify(album) }
    init(release: ReleaseGroup, artist: String) { source = .release(release, artist: artist) }

    private var name: String { switch source { case .spotify(let a): a.name; case .release(let g, _): g.title } }
    private var artist: String { switch source { case .spotify(let a): a.artist; case .release(_, let a): a } }
    private var id: String { switch source { case .spotify(let a): a.uri; case .release(let g, _): g.id } }
    private var spotifyAlbum: SpotifyAlbum? { if case .spotify(let a) = source { a } else { s.found } }

    var body: some View {
        let lib = model.albums.first { $0.id == name.lowercased() }
        let loose = { (t: String) in t.lowercased().filter { $0.isLetter || $0.isNumber } }
        let songs = Set((model.libraryArtist(artist)?.albums ?? []).flatMap(\.tracks).map { loose($0.title) })
        let fromSpotify: Bool = { if case .spotify = source { true } else { false } }()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    Group {
                        switch source {
                        case .spotify(let a): CachedImage(url: model.artURL(a.artworkPath), seed: a.uri)
                        case .release(let g, _): CachedImage(url: URL(string: "https://coverartarchive.org/release-group/\(g.id)/front-500"), seed: g.id)
                        }
                    }
                    .frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        if fromSpotify {
                            Label { Text("Spotify") } icon: { SpotifyMark().frame(width: 14, height: 14) }
                                .font(.caption.weight(.semibold)).foregroundStyle(PluginID.spotify.tint)
                        } else {
                            Text("Not in your library").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        }
                        Text(name).font(.largeTitle.bold()).lineLimit(2)
                        Button { model.path.append(.artist(artist)) } label: {
                            Text(artist).font(.title2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Go to artist")
                        let year: Int = { switch source { case .spotify(let a): a.year > 0 ? a.year : s.year; case .release(let g, _): g.year } }()
                        let kind: String = { if case .release(let g, _) = source { g.type } else { "" } }()
                        Text([year > 0 ? String(year) : "", kind, s.tracks.isEmpty ? "" : "\(s.tracks.count) songs",
                              s.tracks.contains { $0.lengthMs > 0 } ? totalDuration(s.tracks.map(\.lengthMs).reduce(0, +)) : "",
                              lib != nil ? "in your library" : "no files yet"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if let lib {
                                Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(lib)) }.buttonStyle(.glassProminent)
                            } else {
                                LidarrButton(artist: artist, album: name).buttonStyle(.glass)
                                if model.on(.soulseek) {
                                    Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(artist, name, songs: s.tracks.count) }
                                        .buttonStyle(.glassProminent)
                                }
                                if model.on(.youtube), spot.direct, let a = spotifyAlbum {
                                    Button("Get from YouTube", systemImage: "play.rectangle") { Task { await model.albumFromYouTube(a) } }
                                }
                            }
                            if let a = spotifyAlbum {
                                Button(model.remoteName == nil ? "Open in Spotify" : "Play", systemImage: "play.fill") { Task { await model.playURIs([a.uri]) } }
                            }
                        }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).fixedSize()
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                if s.loading { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
                else if let e = s.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                else {
                    VStack(spacing: 0) {
                        ForEach(Array(s.tracks.enumerated()), id: \.offset) { i, t in
                            let have = model.libraryTrack(for: t) != nil || songs.contains(loose(t.title))
                            HStack(spacing: 12) {
                                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).lineLimit(1)
                                    if t.artist != artist { Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if !have { GetSongButton(s: s, track: t, number: i + 1, to: target) }
                                Group {
                                    if have { Image(systemName: "music.note").foregroundStyle(.tint) }
                                    else if fromSpotify { SpotifyMark().frame(width: 14, height: 14) }
                                }
                                .help(have ? "You have this song as a file" : "Only on Spotify")
                                Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                            .opacity(have ? 1 : 0.75)
                            .contextMenu {
                                if !have { GetSongItems(s: s, track: t, number: i + 1, to: target) }
                                if fromSpotify { LinkMenu(track: t) }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
            }
            .padding(28).padding(.bottom, 60)
        }
        .pageTitle(name)
        .task(id: id) {
            defer { s.loading = false }
            switch source {
            case .spotify(let a):
                guard spot.direct, spot.connected else { s.error = "Connect your Spotify account (Settings › Plugins) to see the songs"; return }
                do { let r = try await spot.album(a.uri); s.tracks = r.tracks; s.year = r.year }
                catch { s.error = error.localizedDescription }
            case .release(let g, let artist):
                async let list = ArtistLookup.tracks(g.id)
                if model.on(.spotify), spot.direct, spot.connected, let uri = await spot.albumURI(g.title, by: artist) {
                    s.found = SpotifyAlbum(name: g.title, artist: artist, uri: uri, artworkPath: "", trackCount: 0, year: g.year)
                }
                let t = await list ?? []
                s.tracks = t.map { OTTrack(id: $0.number, title: $0.title, artist: artist, album: g.title, albumArtist: artist,
                                           dataKind: "", uri: "", artworkPath: "", lengthMs: $0.lengthMs) }
                if t.isEmpty { s.error = "MusicBrainz has no song list for this release" }
            }
        }
    }

    private var year: Int { switch source { case .spotify(let a): a.year > 0 ? a.year : s.year; case .release(let g, _): g.year } }
    private var art: String {
        switch source {
        case .spotify(let a): model.artURL(a.artworkPath)?.absoluteString ?? ""
        case .release(let g, _): "https://coverartarchive.org/release-group/\(g.id)/front-500"
        }
    }
    private var target: SongTarget { SongTarget(album: name, artist: artist, art: art, total: s.tracks.count, year: year) }
}
