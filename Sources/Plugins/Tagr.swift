import SwiftUI

// Tagr (github.com/suitux/tagr) is a self-hosted web tag editor that runs next to the Subsonic server, on the same
// music folder. The Subsonic API can't change files, so for the server's songs that aren't on a share here, Crate
// sends tag and cover edits to Tagr instead: Tagr writes them into the files and the Subsonic server picks them up
// on its next scan. Set up under Settings › Plugins › Subsonic.
//
// This is the API Tagr's own web app uses (an Auth.js login with a session cookie, JSON in and out), not a
// published one, so a Tagr update may change it.

/// A song in Tagr's library.
struct TagrSong: Equatable {
    var id: Int
    var path, title: String
    var track, disc: Int
}

enum TagrError: LocalizedError {
    case notConfigured, login, http(Int, String), notFound(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Tagr isn't set up"
        case .login: return "Tagr didn't accept the username and password"
        case .http(let code, let msg): return msg.isEmpty ? "Tagr answered \(code)" : "Tagr: \(msg)"
        case .notFound(let what): return "Tagr doesn't have \(what) (is its music folder the same as the server's?)"
        }
    }
}

@MainActor
final class Tagr: ObservableObject {
    /// Picked in Settings: tag edits for the Subsonic server's songs that aren't on a share go through Tagr.
    @AppStorage("tagrOn") var enabled = false
    @AppStorage("tagrURL") var url = ""
    @AppStorage("tagrUser") var user = ""
    /// The Subsonic server's music folder as Tagr sees it (its container path), where the server's paths start.
    @AppStorage("tagrFolder") var folder = "/music"

    @Published var status = ""
    @Published var error: String?

    var testPassword: String?             // --tagr-check: used instead of the saved one, which stays as it is
    var password: String {
        get { testPassword ?? Keychain.get("tagr") }
        set {
            objectWillChange.send()
            loggedIn = false
            let status = Keychain.set("tagr", newValue)
            if status != errSecSuccess { error = "Couldn't save the password (\(status))" }
        }
    }

    var configured: Bool { !url.isEmpty && !user.isEmpty && !password.isEmpty }
    private var base: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
    private var root: String { folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder }

    /// An ephemeral session: its own in-memory cookie jar, for Tagr's session cookie.
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .always
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()
    private var loggedIn = false
    private var listings: [String: [TagrSong]] = [:]       // each folder's songs, read once per batch of edits

    // MARK: login

    /// Auth.js's credentials sign-in: a CSRF token, then the form, then the session tells whether it worked.
    func login() async throws {
        guard configured, let csrf = URL(string: base + "/api/auth/csrf") else { throw TagrError.notConfigured }
        let (d, _) = try await session.data(from: csrf)
        guard let token = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["csrfToken"] as? String,
              let callback = URL(string: base + "/api/auth/callback/credentials") else { throw TagrError.login }
        var r = URLRequest(url: callback)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.form(["csrfToken": token, "username": user, "password": password, "callbackUrl": base + "/"])
        _ = try await session.data(for: r)
        let (s, _) = try await session.data(from: URL(string: base + "/api/auth/session")!)
        let me = (try? JSONSerialization.jsonObject(with: s) as? [String: Any])?["user"] as? [String: Any]
        guard let me else { throw TagrError.login }
        loggedIn = true
        if let role = me["role"] as? String, role == "listener" { throw TagrError.http(403, "the user \(user) can only listen; it needs to be a tagger") }
    }

    /// Form encoding that keeps "+" and "&" in a password intact.
    nonisolated static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")" }.joined(separator: "&").utf8)
    }

    /// One request; logs in first, and once more when the session ran out.
    private func send(_ r: URLRequest, again: Bool = true) async throws -> [String: Any] {
        if !loggedIn { try await login() }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, again { loggedIn = false; return try await send(r, again: false) }
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code), json["success"] as? Bool != false else { throw TagrError.http(code, json["error"] as? String ?? "") }
        return json
    }

    func check() async {
        guard configured else { status = ""; error = nil; return }
        do {
            loggedIn = false
            try await login()
            // a folder's listing has only the songs right in it: look for any song under the music folder
            let any = try await songs(in: "", limit: 1)
            status = any.isEmpty ? "Connected, but Tagr has no songs yet (has it scanned?)"
                : any[0].path.hasPrefix(root + "/") ? "Connected as \(user)"
                : "Connected, but Tagr's songs aren't under \(root) (\((any[0].path as NSString).deletingLastPathComponent))"
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    // MARK: songs

    /// The songs in a folder (Tagr's paths); "" for all of them.
    func songs(in folder: String, search: String? = nil, limit: Int = 1000) async throws -> [TagrSong] {
        var c = URLComponents(string: base + "/api/songs")!
        c.queryItems = [.init(name: "folderPath", value: folder), .init(name: "limit", value: "\(limit)")]
            + (search.map { [URLQueryItem(name: "search", value: $0)] } ?? [])
        guard let u = c.url else { throw TagrError.notConfigured }
        let j = try await send(URLRequest(url: u))
        return ((j["files"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let id = s["id"] as? Int else { return nil }
            return TagrSong(id: id, path: s["filePath"] as? String ?? "", title: s["title"] as? String ?? "",
                            track: s["trackNumber"] as? Int ?? 0, disc: s["discNumber"] as? Int ?? 0)
        }
    }

    /// Starts a batch of edits: folders are read again.
    func forget() { listings = [:] }

    /// Tagr's copy of a library song, from the path the Subsonic server reports for it (relative to its music
    /// folder): in that folder by disc, track and title, else by title, else by file name; else a search by title.
    /// Servers that don't report real paths make up the file names, but the folder is the album's.
    func find(_ t: LibTrack, serverPath rel: String) async throws -> TagrSong {
        let bare = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let title = bare(t.title), name = (rel as NSString).lastPathComponent
        let dir = root + "/" + (rel as NSString).deletingLastPathComponent
        if listings[dir] == nil { listings[dir] = try await songs(in: dir) }
        let here = listings[dir] ?? []
        if let s = here.first(where: { t.trackNumber > 0 && $0.track == t.trackNumber && max($0.disc, 1) == max(t.discNumber, 1) && bare($0.title) == title })
            ?? here.first(where: { bare($0.title) == title })
            ?? here.first(where: { ($0.path as NSString).lastPathComponent == name }) { return s }
        let found = try await songs(in: "", search: t.title, limit: 50).filter { bare($0.title) == title }
        if found.count == 1 { return found[0] }
        throw TagrError.notFound("“\(t.title)”")
    }

    /// Writes the edit into the song's file (and its cover, when the edit has one).
    func update(_ id: Int, _ e: TagEdit) async throws {
        var f: [String: Any] = [:]
        if let v = e.title { f["title"] = v }
        if let v = e.artist { f["artist"] = v }
        if let v = e.albumArtist { f["albumArtist"] = v }
        if let v = e.album { f["album"] = v }
        if let v = e.genre { f["genre"] = v }
        if let v = e.year { f["year"] = v > 0 ? v : NSNull() }
        if let v = e.track { f["trackNumber"] = v > 0 ? v : NSNull() }
        if let v = e.trackCount { f["trackTotal"] = v > 0 ? v : NSNull() }
        if let v = e.disc { f["discNumber"] = v > 0 ? v : NSNull() }
        if !f.isEmpty {
            var r = URLRequest(url: URL(string: base + "/api/songs/\(id)")!)
            r.httpMethod = "PATCH"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: f)
            _ = try await send(r)
        }
        if let c = e.cover { try await setCover(id, c) }
    }

    /// Embeds the image as the song's cover.
    func setCover(_ id: Int, _ image: Data) async throws {
        let png = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let boundary = "crate-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"cover.\(png ? "png" : "jpg")\"\r\n".utf8)
        body += Data("Content-Type: \(png ? "image/png" : "image/jpeg")\r\n\r\n".utf8) + image + Data("\r\n--\(boundary)--\r\n".utf8)
        var r = URLRequest(url: URL(string: base + "/api/songs/\(id)/picture")!)
        r.httpMethod = "PUT"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        _ = try await send(r)
    }
}

/// Tagr's settings, under the Subsonic plugin's.
struct TagrSettings: View {
    @ObservedObject var tagr: Tagr
    @State private var password = ""
    @State private var testing = false

    var body: some View {
        Picker("Edit tags", selection: tagr.$enabled) {
            Text("Only of files on a share").tag(false)
            Text("Also on the server, with Tagr").tag(true)
        }
        .help("The Subsonic API can't change files. Tagr, a tag editor running next to the server on the same music folder, can")
        if tagr.enabled { fields }
    }

    @ViewBuilder var fields: some View {
        TextField("Tagr", text: tagr.$url, prompt: Text("http://host:3000"))
        TextField("Tagr username", text: tagr.$user, prompt: Text("A tagger or the admin"))
        LabeledContent("Tagr password") {
            HStack {
                SecureField("", text: $password, prompt: Text(tagr.password.isEmpty ? "Your password in Tagr" : "Saved – type to change"))
                    .onSubmit(save)
                Button("Save", action: save).disabled(password.isEmpty)
            }
        }
        TextField("Music folder in Tagr", text: tagr.$folder, prompt: Text("/music"))
            .help("Where Tagr sees the Subsonic server's music folder; the server's paths are looked up under it")
        if tagr.configured {
            LabeledContent("Tagr status") {
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    Text(tagr.error ?? (tagr.status.isEmpty ? "Not checked" : tagr.status))
                        .foregroundStyle(tagr.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(2)
                    Button("Test") { testing = true; Task { await tagr.check(); testing = false } }
                }
            }
        }
    }

    func save() {
        tagr.password = password
        password = ""
        testing = true
        Task { await tagr.check(); testing = false }
    }
}
