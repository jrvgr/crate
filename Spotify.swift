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

    @AppStorage("spotifyMode") var mode = "owntone"            // "owntone" or "account"
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
}

/// A saved Spotify album: its songs (and which you have as files), play, and ways to get it.
struct SpotifyAlbumView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var spot: SpotifyAPI
    var album: SpotifyAlbum
    @StateObject private var s = SpotifyAlbumState()

    var body: some View {
        let lib = model.albums.first { $0.id == album.name.lowercased() }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    CachedImage(url: model.artURL(album.artworkPath), seed: album.uri)
                        .frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Spotify", systemImage: PluginID.spotify.icon).font(.caption.weight(.semibold)).foregroundStyle(PluginID.spotify.tint)
                        Text(album.name).font(.largeTitle.bold()).lineLimit(2)
                        Text(album.artist).font(.title2).foregroundStyle(.secondary)
                        let year = album.year > 0 ? album.year : s.year
                        Text([year > 0 ? "\(year)" : "", s.tracks.isEmpty ? "" : "\(s.tracks.count) songs",
                              s.tracks.isEmpty ? "" : totalDuration(s.tracks.map(\.lengthMs).reduce(0, +)),
                              lib != nil ? "in your library" : "no files yet"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if let lib {
                                Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(lib)) }.buttonStyle(.glassProminent)
                            } else {
                                if model.on(.soulseek) {
                                    Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(album.artist, album.name, songs: s.tracks.count) }
                                        .buttonStyle(.glassProminent)
                                }
                                if model.on(.youtube), spot.direct {
                                    Button("Get from YouTube", systemImage: "play.rectangle") { Task { await model.albumFromYouTube(album) } }.buttonStyle(.glass)
                                }
                            }
                            Button(model.on(.ownTone) ? "Play" : "Open in Spotify", systemImage: "play.fill") { Task { await model.playURIs([album.uri]) } }
                                .buttonStyle(.glass)
                        }
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                if s.loading { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
                else if let e = s.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                else {
                    VStack(spacing: 0) {
                        ForEach(Array(s.tracks.enumerated()), id: \.offset) { i, t in
                            let have = model.libraryTrack(for: t) != nil
                            HStack(spacing: 12) {
                                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).lineLimit(1)
                                    if t.artist != album.artist { Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: have ? "music.note" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(have ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                    .help(have ? "You have this song as a file" : "Only on Spotify")
                                Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                            .opacity(have ? 1 : 0.75)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
            }
            .padding(28).padding(.bottom, 60)
        }
        .navigationTitle(album.name)
        .task(id: album.uri) {
            defer { s.loading = false }
            guard spot.direct, spot.connected else { s.error = "Connect your Spotify account (Settings › Plugins) to see the songs"; return }
            do { let r = try await spot.album(album.uri); s.tracks = r.tracks; s.year = r.year }
            catch { s.error = error.localizedDescription }
        }
    }
}
