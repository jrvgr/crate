import SwiftUI

// The Soulseek plugin talks to slskd directly (REST API v0): searches, downloads, and imports
// finished album folders from slskd's download folder (as the Mac sees it) into the library.

struct SlskFile: Identifiable, Hashable {
    var id: String { filename }
    var filename: String          // remote path with backslashes: "@@music\Artist\Album\01 Song.flac"
    var size: Int
    var bitRate = 0, bitDepth = 0, sampleRate = 0, length = 0
    var name: String { filename.split(separator: "\\").last.map(String.init) ?? filename }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isAudio: Bool { LibraryLoader.audioExts.contains(ext) || ext == "ogg" || ext == "opus" }
}

/// One folder of one user's search response: the unit Crate downloads (an album, usually).
struct SlskFolder: Identifiable, Hashable {
    var id: String { username + "\u{1}" + directory }
    var username, directory: String
    var files: [SlskFile]
    var freeSlot: Bool
    var speed, queue: Int

    var name: String { directory.split(separator: "\\").last.map(String.init) ?? directory }
    var parent: String { directory.split(separator: "\\").dropLast().last.map(String.init) ?? "" }
    var audio: [SlskFile] { files.filter(\.isAudio) }
    var size: Int { audio.map(\.size).reduce(0, +) }
    var formats: String { Set(audio.map { $0.ext.uppercased() }).sorted().joined(separator: "/") }
    var lossless: Bool { audio.contains { ["flac", "wav", "aif", "aiff", "alac"].contains($0.ext) } }
    var quality: String {
        if lossless {
            let depth = audio.map(\.bitDepth).max() ?? 0, rate = audio.map(\.sampleRate).max() ?? 0
            return depth > 0 ? "\(depth)-bit / \(String(format: "%g", Double(rate) / 1000)) kHz" : "Lossless"
        }
        let br = audio.map(\.bitRate).max() ?? 0
        return br > 0 ? "\(br) kbps" : ""
    }
    /// Higher is better: free slot first, lossless, then speed.
    var rank: Double { (freeSlot ? 1e12 : 0) + (lossless ? 1e10 : 0) + Double(speed) - Double(queue) * 1e6 }
}

struct SlskTransfer: Identifiable, Hashable {
    var id: String
    var username, directory, filename, state: String
    var size, bytes: Int
    var percent, speed: Double
    var name: String { filename.split(separator: "\\").last.map(String.init) ?? filename }
    var done: Bool { state.hasPrefix("Completed") }
    var succeeded: Bool { state == "Completed, Succeeded" }
    var failed: Bool { done && !succeeded }
}

/// A downloading album: one remote folder of one user.
struct SlskJob: Identifiable, Hashable {
    var id: String { username + "\u{1}" + directory }
    var username, directory: String
    var files: [SlskTransfer]
    var name: String { directory.split(separator: "\\").last.map(String.init) ?? directory }
    var parent: String { directory.split(separator: "\\").dropLast().last.map(String.init) ?? "" }
    var finished: Bool { files.allSatisfy(\.done) }
    var succeeded: Int { files.filter(\.succeeded).count }
    var failed: Int { files.filter(\.failed).count }
    var progress: Double {
        let total = files.map(\.size).reduce(0, +)
        return total > 0 ? Double(files.map { $0.done ? $0.size : $0.bytes }.reduce(0, +)) / Double(total) : 0
    }
    var speed: Double { files.filter { !$0.done }.map(\.speed).reduce(0, +) }
    var stateText: String {
        if finished { return failed == 0 ? "Done" : "\(failed) of \(files.count) failed" }
        if files.contains(where: { $0.state.hasPrefix("InProgress") }) { return "Downloading" }
        if files.contains(where: { $0.state.contains("Remotely") }) { return "Queued by \(username)" }
        return "Waiting"
    }
}

enum SlskdError: Error, LocalizedError {
    case notConfigured, login(Int), http(Int)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter the slskd address and your login in Settings › Plugins › Soulseek"
        case .login(let c): return c == 401 ? "slskd didn't accept the username or password" : "slskd login failed (HTTP \(c))"
        case .http(let c): return c == 401 ? "slskd refused the login (401)" : "slskd answered HTTP \(c)"
        }
    }
}

@MainActor
final class Slskd: ObservableObject {
    @AppStorage("slskdURL") var url = ""
    @AppStorage("slskdUser") var user = ""
    @AppStorage("slskdAPIKey") var apiKey = ""
    @AppStorage("slskdDownloads") var downloadsFolder = ""
    @AppStorage("slskdAutoImport") var autoImport = true

    @Published var connected = false
    @Published var serverState = ""
    @Published var error: String?
    @Published var query = ""
    @Published var searching = false
    @Published var searchState = ""
    @Published var results: [SlskFolder] = []
    // browsing one user's shares, instead of the search results
    @Published var browsing: String?
    @Published var browseFolders: [SlskFolder] = []
    @Published var browseState = ""
    @Published var browseFilter = ""
    private var browseTask: Task<Void, Never>?
    @Published var jobs: [SlskJob] = []
    // quality rules: what counts as a usable folder, and which one is picked automatically
    @AppStorage("slskdPrefer") var prefer = "any"           // "any", "lossless", "mp3"
    @AppStorage("slskdMinBitrate") var minBitrate = 0       // for lossy files, kbps
    @AppStorage("slskdFreeSlot") var freeSlotOnly = false
    @AppStorage("slskdMaxQueue") var maxQueue = 0           // 0 = any
    @Published var expanded: Set<String> = []
    @Published var wantSongs = 0          // set by "Complete Album": folders with at least this many songs go first
    @Published var busy: Set<String> = []
    @Published var requested: Set<SlskFolder.ID> = []
    @Published var imported: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "slskdImported") ?? [])

    var password: String {
        get { Keychain.get("slskd") }
        set {
            objectWillChange.send()
            let status = Keychain.set("slskd", newValue)
            token = ""
            if status != errSecSuccess { error = "Couldn't save the password in the Keychain (\(status))" }
        }
    }

    /// Called with a finished album folder (local path) when auto-import is on.
    var onFinished: ((SlskJob, String) -> Void)?
    private var token = ""
    private var searchTask: Task<Void, Never>?
    private var polling = false

    var base: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
    var configured: Bool { !url.isEmpty && (!apiKey.isEmpty || (!user.isEmpty && !password.isEmpty)) }

    // MARK: HTTP

    private func login() async throws {
        guard !user.isEmpty, !password.isEmpty else { throw SlskdError.notConfigured }
        var r = URLRequest(url: URL(string: base + "/api/v0/session")!)
        r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let t = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["token"] as? String else {
            throw SlskdError.login(code)
        }
        token = t
    }

    func call(_ path: String, method: String = "GET", body: Any? = nil, timeout: Double = 15, retry: Bool = true) async throws -> Any? {
        guard configured, let u = URL(string: base + "/api/v0" + path) else { throw SlskdError.notConfigured }
        if apiKey.isEmpty, token.isEmpty { try await login() }
        var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = timeout
        if !apiKey.isEmpty { r.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        else { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry, apiKey.isEmpty { token = ""; return try await call(path, method: method, body: body, timeout: timeout, retry: false) }
        guard (200..<300).contains(code) else { throw SlskdError.http(code) }
        return d.isEmpty ? nil : try? JSONSerialization.jsonObject(with: d)
    }

    /// Logs in (again) and reads whether slskd is connected to the Soulseek network.
    func check() async {
        token = ""
        do {
            let s = try await call("/server") as? [String: Any]
            connected = true
            let online = (s?["isLoggedIn"] as? Bool) ?? (s?["isConnected"] as? Bool) ?? false
            serverState = online ? "Connected to Soulseek" : "slskd is up, not connected to Soulseek (\(s?["state"] as? String ?? "?"))"
            error = nil
        } catch {
            connected = false; serverState = ""
            self.error = error.localizedDescription
        }
    }

    // MARK: search

    func search(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        query = q
        closeBrowse()
        searchTask?.cancel()
        searchTask = Task { await runSearch(q) }
    }

    private func runSearch(_ q: String) async {
        searching = true; results = []; searchState = "Searching…"
        defer { searching = false }
        do {
            results = try await find(q) { [weak self] folders, users, complete in
                self?.results = folders
                self?.searchState = complete ? "" : "Searching… \(users) users answered"
            }
            error = nil
            searchState = results.isEmpty ? "Nothing found for “\(q)”" : ""
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription; searchState = "" }
    }

    /// What Soulseek can match: peers match whole words of the file path, so punctuation glues words
    /// together ("tomorrow's", "a.k.a"), a leading "-" excludes a word, and "(Deluxe Edition)" or
    /// "[Remastered]" rarely is in anyone's folder name.
    static func terms(_ q: String) -> String {
        var s = q.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "&", with: " ")
        s = String(s.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = s.split(separator: " ").map(String.init).filter { $0.count > 1 || $0.first?.isNumber == true }
        return words.isEmpty ? q : words.joined(separator: " ")
    }

    /// One Soulseek search, start to finish (about 15 s); `update` gets the folders as they come in.
    func find(_ q: String, update: (([SlskFolder], Int, Bool) -> Void)? = nil) async throws -> [SlskFolder] {
        let id = UUID().uuidString.lowercased()
        _ = try await call("/searches", method: "POST", body: ["id": id, "searchText": Self.terms(q), "searchTimeout": 15000,
                                                               "responseLimit": 300, "fileLimit": 20000])
        defer { Task { _ = try? await self.call("/searches/\(id)", method: "DELETE") } }
        var complete = false, folders: [SlskFolder] = []
        for _ in 0..<40 where !complete {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1.5))
            let s = try await call("/searches/\(id)") as? [String: Any]
            complete = (s?["isComplete"] as? Bool) ?? ((s?["state"] as? String)?.contains("Completed") ?? false)
            let n = s?["responseCount"] as? Int ?? 0
            if n > 0 || complete { folders = parse(try await call("/searches/\(id)/responses")) }
            update?(folders, n, complete)
        }
        return folders
    }

    /// Whether a folder passes the quality rules.
    func passes(_ f: SlskFolder) -> Bool {
        if prefer == "lossless", !f.lossless { return false }
        if prefer == "mp3", f.lossless { return false }
        if !f.lossless, minBitrate > 0, let br = f.audio.map(\.bitRate).filter({ $0 > 0 }).min(), br < minBitrate { return false }
        if freeSlotOnly, !f.freeSlot { return false }
        if maxQueue > 0, f.queue > maxQueue { return false }
        return true
    }

    /// The folder to download for an album: passes the rules, about as many songs as the album,
    /// a name that looks like it, then the best source.
    func best(_ folders: [SlskFolder], album: String, songs: Int) -> SlskFolder? {
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = loose(album)
        return folders.filter { f in
            passes(f) && (songs == 0 || (f.audio.count >= songs - 1 && f.audio.count <= songs + 3))
                && (want.isEmpty || loose(f.name + f.parent).contains(want) || want.contains(loose(f.name)))
        }
        .max { $0.rank < $1.rank }
    }

    /// The file to download for one song: in a folder that passes the rules, named like the song,
    /// from a folder that looks like its album when there is one, then the best source.
    func bestSong(_ folders: [SlskFolder], title: String, album: String) -> (SlskFolder, SlskFile)? {
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = loose(title), albumWant = loose(album)
        guard !want.isEmpty else { return nil }
        let hits = folders.filter(passes).compactMap { f in
            f.audio.first { loose(($0.name as NSString).deletingPathExtension).contains(want) }.map { (f, $0) }
        }
        let fromAlbum = hits.filter { !albumWant.isEmpty && loose($0.0.name + $0.0.parent).contains(albumWant) }
        return (fromAlbum.isEmpty ? hits : fromAlbum).max { $0.0.rank < $1.0.rank }
    }

    private func parse(_ j: Any?) -> [SlskFolder] {
        var out: [SlskFolder] = []
        for r in (j as? [[String: Any]]) ?? [] {
            let user = r["username"] as? String ?? ""
            let files = ((r["files"] as? [[String: Any]]) ?? []).map { Self.file($0, in: nil) }
            let byDir = Dictionary(grouping: files) { $0.filename.split(separator: "\\").dropLast().joined(separator: "\\") }
            for (dir, fs) in byDir where fs.contains(where: \.isAudio) {
                out.append(SlskFolder(username: user, directory: dir, files: fs.sorted { $0.filename < $1.filename },
                                      freeSlot: r["hasFreeUploadSlot"] as? Bool ?? false,
                                      speed: r["uploadSpeed"] as? Int ?? 0, queue: r["queueLength"] as? Int ?? 0))
            }
        }
        return out.sorted { $0.rank > $1.rank }
    }

    /// A file from slskd JSON; browse and folder answers name it relative to its folder.
    private static func file(_ f: [String: Any], in dir: String?) -> SlskFile {
        var name = f["filename"] as? String ?? ""
        if let dir, !name.contains("\\") { name = dir + "\\" + name }
        return SlskFile(filename: name, size: f["size"] as? Int ?? 0, bitRate: f["bitRate"] as? Int ?? 0,
                        bitDepth: f["bitDepth"] as? Int ?? 0, sampleRate: f["sampleRate"] as? Int ?? 0, length: f["length"] as? Int ?? 0)
    }

    private static func folders(_ j: Any?) -> [(String, [SlskFile])] {
        let dirs = (j as? [[String: Any]]) ?? ((j as? [String: Any]).map { [$0] } ?? [])
        return dirs.compactMap { d in
            guard let name = (d["name"] ?? d["directory"]) as? String else { return nil }
            return (name, ((d["files"] as? [[String: Any]]) ?? []).map { file($0, in: name) }.sorted { $0.filename < $1.filename })
        }
    }

    private func path(_ user: String) -> String { user.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? user }

    // MARK: browsing a user

    /// Shows everything `user` shares, folder per folder (large shares take a minute to come in).
    func browse(_ user: String) {
        browseTask?.cancel()
        browsing = user; browseFolders = []; browseFilter = ""; browseState = "Asking \(user) for their shares…"
        browseTask = Task {
            do {
                let info = try? await call("/users/\(path(user))/info") as? [String: Any]
                let j = try await call("/users/\(path(user))/browse", timeout: 180) as? [String: Any]
                guard browsing == user else { return }
                let free = info?["hasFreeUploadSlot"] as? Bool ?? false, queue = info?["queueLength"] as? Int ?? 0
                let speed = info?["uploadSpeed"] as? Int ?? 0
                browseFolders = Self.folders(j?["directories"]).filter { $0.1.contains(where: \.isAudio) }.map {
                    SlskFolder(username: user, directory: $0.0, files: $0.1, freeSlot: free, speed: speed, queue: queue)
                }.sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
                browseState = browseFolders.isEmpty ? "\(user) shares no music (or is offline)" : ""
            } catch is CancellationError {
            } catch {
                if browsing == user { browseState = "Couldn't browse \(user): \(error.localizedDescription)" }
            }
        }
    }

    func closeBrowse() { browseTask?.cancel(); browsing = nil; browseFolders = []; browseState = "" }

    /// The whole remote folder: a search answer only lists the files that matched.
    func complete(_ f: SlskFolder) async -> SlskFolder {
        guard let j = try? await call("/users/\(path(f.username))/directory", method: "POST", body: ["directory": f.directory], timeout: 60),
              let files = Self.folders(j).first(where: { $0.0 == f.directory })?.1 ?? Self.folders(j).first?.1,
              files.filter(\.isAudio).count >= f.audio.count else { return f }
        var full = f; full.files = files
        return full
    }

    // MARK: downloads

    /// Queues the folder's audio files (or only `song`), and its cover images, on slskd.
    func download(_ f: SlskFolder, only song: SlskFile? = nil) async throws {
        let f = song == nil ? await complete(f) : f
        let images: Set<String> = ["jpg", "jpeg", "png"]
        let files = f.files.filter { file in song.map { file == $0 } ?? file.isAudio || images.contains(file.ext) }.map { ["filename": $0.filename, "size": $0.size] as [String: Any] }
        let user = f.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.username
        _ = try await call("/transfers/downloads/\(user)", method: "POST", body: files)
        requested.insert(f.id)
        await refreshDownloads()
    }

    func refreshDownloads() async {
        guard configured else { return }
        do {
            let j = try await call("/transfers/downloads") as? [[String: Any]] ?? []
            var out: [SlskJob] = []
            for u in j {
                let user = u["username"] as? String ?? ""
                for d in (u["directories"] as? [[String: Any]]) ?? [] {
                    let dir = d["directory"] as? String ?? ""
                    let files: [SlskTransfer] = ((d["files"] as? [[String: Any]]) ?? []).map { f in
                        SlskTransfer(id: f["id"] as? String ?? UUID().uuidString, username: user, directory: dir,
                                     filename: f["filename"] as? String ?? "", state: f["state"] as? String ?? "",
                                     size: f["size"] as? Int ?? 0, bytes: f["bytesTransferred"] as? Int ?? 0,
                                     percent: f["percentComplete"] as? Double ?? 0, speed: f["averageSpeed"] as? Double ?? 0)
                    }
                    out.append(SlskJob(username: user, directory: dir, files: files))
                }
            }
            jobs = out.sorted { ($0.finished ? 1 : 0, $0.name) < ($1.finished ? 1 : 0, $1.name) }
            connected = true; error = nil
            for job in jobs where job.finished && job.succeeded > 0 && !imported.contains(job.id) && autoImport {
                markImported(job)
                onFinished?(job, localFolder(job))
            }
        } catch { self.error = error.localizedDescription; connected = false }
    }

    /// slskd saves a remote folder as <download dir>/<folder name>/.
    func localFolder(_ j: SlskJob) -> String { downloadsFolder + "/" + j.name }

    func markImported(_ j: SlskJob) {
        imported.insert(j.id)
        UserDefaults.standard.set(Array(imported), forKey: "slskdImported")
    }

    func cancel(_ j: SlskJob, remove: Bool) async {
        let user = j.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? j.username
        for f in j.files where remove || !f.done {
            _ = try? await call("/transfers/downloads/\(user)/\(f.id)?remove=\(remove)", method: "DELETE")
        }
        await refreshDownloads()
    }

    func clearFinished() async {
        _ = try? await call("/transfers/downloads/all/completed", method: "DELETE")
        await refreshDownloads()
    }

    var active: [SlskJob] { jobs.filter { !$0.finished } }

    func toggleExpanded(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }

    /// Follows the downloads while the plugin is on (faster while something is downloading).
    func poll(while on: @escaping () -> Bool) async {
        guard !polling else { return }
        polling = true; defer { polling = false }
        while !Task.isCancelled {
            if on() && configured { await refreshDownloads() }
            try? await Task.sleep(for: .seconds(active.isEmpty ? 15 : 3))
        }
    }
}

// MARK: views

struct SoulseekView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @FocusState private var focused: Bool

    var body: some View {
        let shown = slsk.results.filter(slsk.passes).sorted { a, b in
            slsk.wantSongs == 0 ? false : (a.audio.count >= slsk.wantSongs ? 1 : 0) > (b.audio.count >= slsk.wantSongs ? 1 : 0)
        }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Artist, album or song", text: $slsk.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { slsk.wantSongs = 0; slsk.search(slsk.query) }
                if slsk.searching { ProgressView().controlSize(.small) }
                Button("Search") { slsk.search(slsk.query) }
                    .buttonStyle(.glassProminent).disabled(slsk.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24).padding(.top, 18)

            HStack {
                QualityMenu()
                if slsk.results.count > shown.count {
                    Text("\(slsk.results.count - shown.count) hidden by the quality rules").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(slsk.searchState.isEmpty ? (shown.isEmpty ? "" : "\(shown.count) folders, best sources first") : slsk.searchState)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30).padding(.vertical, 10)

            if let user = slsk.browsing {
                SlskBrowseView(user: user)
            } else if !slsk.configured {
                PluginSetupNotice(plugin: .soulseek, text: "Add your slskd address and login to search Soulseek.")
            } else if let e = slsk.error, slsk.results.isEmpty {
                ContentUnavailableView("slskd unreachable", systemImage: "wifi.exclamationmark", description: Text(e))
            } else if shown.isEmpty && slsk.searching {
                // a search takes about 15 s and folders come in as users answer: say so instead of an empty page
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching Soulseek for “\(slsk.query)”").font(.headline)
                    Text(slsk.results.isEmpty ? "Folders show up here as users answer" : "\(slsk.results.count) folders so far, none pass the quality rules yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else if shown.isEmpty {
                ContentUnavailableView("Search Soulseek", systemImage: "arrow.down.circle",
                                       description: Text("Results are grouped per folder; download one and it's imported into the library when it's done."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown.prefix(200)) { SlskFolderRow(folder: $0) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 60)
                }
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("Soulseek")
        .navigationSubtitle(slsk.serverState)
        .task { if !slsk.connected { await slsk.check() }; if slsk.results.isEmpty { focused = true } }
    }
}

struct SlskFolderRow: View {
    @EnvironmentObject var slsk: Slskd
    @EnvironmentObject var model: Model
    var folder: SlskFolder
    var open: Bool { slsk.expanded.contains(folder.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { withAnimation(.snappy) { slsk.toggleExpanded(folder.id) } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                Image(systemName: folder.lossless ? "waveform" : "music.note")
                    .font(.title3).foregroundStyle(folder.lossless ? .orange : .secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(folder.name).font(.headline).lineLimit(1)
                        if slsk.wantSongs > 0 {
                            let full = folder.audio.count >= slsk.wantSongs
                            Text(full ? "complete" : "\(folder.audio.count)/\(slsk.wantSongs)").font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background((full ? Color.green : Color.orange).opacity(0.2), in: .capsule)
                                .foregroundStyle(full ? .green : .orange)
                        }
                    }
                    Text([folder.parent, "\(folder.audio.count) tracks", folder.formats, folder.quality,
                          ByteCountFormatter.string(fromByteCount: Int64(folder.size), countStyle: .file)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Button { slsk.browse(folder.username) } label: {
                        Label(folder.username, systemImage: "person.fill").font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.plain).help("Browse everything \(folder.username) shares")
                    .disabled(slsk.browsing == folder.username)
                    HStack(spacing: 4) {
                        Circle().fill(folder.freeSlot ? .green : .orange).frame(width: 7, height: 7)
                        Text(folder.freeSlot ? "Free slot" : "Queue \(folder.queue)")
                        Text("· " + ByteCountFormatter.string(fromByteCount: Int64(folder.speed), countStyle: .file) + "/s")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 170, alignment: .trailing)
                if slsk.requested.contains(folder.id) {
                    Label("Queued", systemImage: "checkmark").font(.callout).foregroundStyle(.green).frame(width: 110)
                } else {
                    Button {
                        slsk.busy.insert(folder.id)
                        Task {
                            do { try await slsk.download(folder); model.notify("Downloading \(folder.name) from \(folder.username)") }
                            catch { model.notify("Download failed: \(error.localizedDescription)") }
                            slsk.busy.remove(folder.id)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down").frame(width: 92)
                    }
                    .buttonStyle(.glassProminent).disabled(slsk.busy.contains(folder.id))
                }
            }
            .padding(12)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folder.files) { f in
                        HStack {
                            Text(f.name).lineLimit(1).foregroundStyle(f.isAudio ? .primary : .secondary)
                            Spacer()
                            if f.length > 0 { Text(duration(f.length * 1000)).monospacedDigit().foregroundStyle(.secondary) }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .font(.callout).padding(.horizontal, 16).padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 10).padding(.leading, 56)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// Everything one user shares, as folders with music, filtered by folder name.
struct SlskBrowseView: View {
    @EnvironmentObject var slsk: Slskd
    var user: String

    var body: some View {
        let words = slsk.browseFilter.lowercased().split(separator: " ")
        let shown = slsk.browseFolders.filter { f in words.allSatisfy { f.directory.lowercased().contains($0) } }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { slsk.closeBrowse() } label: { Label("Search Results", systemImage: "chevron.left") }
                    .buttonStyle(.glass)
                Label(user, systemImage: "person.fill").font(.headline)
                Spacer()
                TextField("Filter folders", text: $slsk.browseFilter).textFieldStyle(.roundedBorder).frame(width: 220)
                Text(slsk.browseFolders.isEmpty ? "" : "\(shown.count) of \(slsk.browseFolders.count) folders")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 30).padding(.bottom, 10)
            if slsk.browseFolders.isEmpty {
                VStack(spacing: 10) {
                    if slsk.browseState.hasPrefix("Asking") { ProgressView() }
                    Text(slsk.browseState).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown.prefix(500)) { SlskFolderRow(folder: $0) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 60)
                }
            }
        }
    }
}

/// The quality rules, as a menu on the Soulseek page (also in Settings).
struct QualityMenu: View {
    @EnvironmentObject var slsk: Slskd
    var body: some View {
        Menu {
            Picker("Format", selection: slsk.$prefer) {
                Text("Any format").tag("any"); Text("Lossless only (FLAC…)").tag("lossless"); Text("MP3/AAC only").tag("mp3")
            }
            .pickerStyle(.inline)
            Picker("Lossy at least", selection: slsk.$minBitrate) {
                Text("Any bit rate").tag(0); Text("192 kbps").tag(192); Text("256 kbps").tag(256); Text("320 kbps").tag(320)
            }
            .pickerStyle(.inline)
            Toggle("Only users with a free slot", isOn: slsk.$freeSlotOnly)
            Picker("Queue", selection: slsk.$maxQueue) {
                Text("Any queue").tag(0); Text("Queue of 5 or less").tag(5); Text("Queue of 20 or less").tag(20)
            }
            .pickerStyle(.inline)
        } label: {
            Label(summary, systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .help("Which folders count, and which one Crate picks by itself")
    }
    var summary: String {
        var p: [String] = [slsk.prefer == "lossless" ? "Lossless" : slsk.prefer == "mp3" ? "MP3/AAC" : "Any format"]
        if slsk.minBitrate > 0 { p.append("≥ \(slsk.minBitrate) kbps") }
        if slsk.freeSlotOnly { p.append("free slot") }
        if slsk.maxQueue > 0 { p.append("queue ≤ \(slsk.maxQueue)") }
        return p.joined(separator: ", ")
    }
}

/// Shown in a plugin's pane when it still needs settings.
struct PluginSetupNotice: View {
    var plugin: PluginID
    var text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: plugin.icon).font(.system(size: 40, weight: .light)).foregroundStyle(plugin.tint)
            Text("Set up \(plugin.name)").font(.title2.bold())
            Text(text).foregroundStyle(.secondary)
            SettingsLink { Text("Open Settings…") }.buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}
