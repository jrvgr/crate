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

    func tracks(_ playlistID: String) async throws -> [OTTrack] {
        try await all("/playlists/\(playlistID)/tracks?limit=100&additional_types=track", limit: 5000).enumerated().compactMap { n, i in
            guard let t = i["track"] as? [String: Any], t["type"] as? String == "track" else { return nil }
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
