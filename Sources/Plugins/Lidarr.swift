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

    private func call(_ method: String = "GET", _ path: String, _ query: [URLQueryItem] = [], body: Any? = nil) async throws -> Any {
        guard configured, var c = URLComponents(string: base + "/api/v1/" + path) else { throw LidarrError.notConfigured }
        if !query.isEmpty { c.queryItems = query }
        guard let u = c.url else { throw LidarrError.notConfigured }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = 30
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
    func get(artist: String, album: String) async throws -> String {
        let key = artist + "|" + album
        getting.insert(key); defer { getting.remove(key) }
        guard var a = try await lookup(artist: artist, album: album) else { throw LidarrError.notFound("“\(album)”") }
        let title = a["title"] as? String ?? album
        return try await add(&a, title: title)
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
        if let id = a["id"] as? Int, id > 0 {                       // already in Lidarr
            _ = try await call("PUT", "album/monitor", body: ["albumIds": [id], "monitored": true])
            _ = try await call("POST", "command", body: ["name": "AlbumSearch", "albumIds": [id]])
            Task { await refreshQueue() }
            return "Lidarr is searching for “\(title)”"
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
        a["addOptions"] = ["searchForNewAlbum": true]
        _ = try await call("POST", "album", body: a)
        Task { await refreshQueue() }
        return "Added “\(title)” to Lidarr; it's searching for it"
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
            return LidarrQueueItem(id: id, artist: artist?["artistName"] as? String ?? "", album: album?["title"] as? String ?? r["title"] as? String ?? "",
                                   status: (r["trackedDownloadState"] as? String ?? r["status"] as? String ?? "").capitalized,
                                   detail: warning ?? (r["timeleft"] as? String).map { "\($0) left" } ?? "",
                                   progress: size > 0 ? (size - left) / size : 0,
                                   cover: (cover?["remoteUrl"] as? String ?? cover?["url"] as? String).flatMap(URL.init(string:)))
        }
        let gone = !queue.isEmpty && items.count < queue.count
        if items != queue { queue = items; Model.shared?.objectWillChange.send() }
        // an album finished: Lidarr has filed it, so the servers and the library can pick it up
        if gone, let m = Model.shared { Task { await m.rescanServers(); try? await Task.sleep(for: .seconds(20)); await m.reload() } }
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
    func getWithLidarr(_ artist: String, _ album: String) {
        guard on(.lidarr) else { notify("Turn on the Lidarr plugin in Settings to get albums with it"); return }
        guard lidarr.configured else { notify("Set Lidarr's address and API key in Settings › Plugins › Lidarr"); return }
        Task {
            do { notify(try await lidarr.get(artist: artist, album: album)) }
            catch { notify("Lidarr: \(error.localizedDescription)") }
        }
    }

    func lidarrEntries() -> [DownloadEntry] {
        guard on(.lidarr) else { return [] }
        return lidarr.queue.map { q in
            DownloadEntry(id: "lidarr:\(q.id)", source: .lidarr, title: q.album, subtitle: [q.artist, q.detail].filter { !$0.isEmpty }.joined(separator: " · "),
                          state: q.status, progress: q.progress, artURL: q.cover)
        }
    }
}

/// "Get with Lidarr", next to "Find on Soulseek".
struct LidarrButton: View {
    @EnvironmentObject var model: Model
    var artist, album: String
    var label = "Get with Lidarr"
    var body: some View {
        if model.on(.lidarr) {
            Button(label, systemImage: PluginID.lidarr.icon) { model.getWithLidarr(artist, album) }
                .disabled(model.lidarr.getting.contains(artist + "|" + album))
                .help("Lidarr finds the album with its indexers and download client and files it in your music folder")
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
