import SwiftUI

// Album lookups on MusicBrainz + Cover Art Archive. Picked matches are stored per album
// (Application Support/Crate/metadata.json) and fill year/genre when syncing.

struct MBRelease: Identifiable, Codable, Hashable {
    var id: String
    var title, artist: String
    var date = "", country = "", trackCount = 0, score = 0
    var genre = ""
    var source = "MusicBrainz", cover = ""
    var year: Int { Int(date.prefix(4)) ?? 0 }
}

enum MusicBrainz {
    static let agent = "Crate/0.1 (personal iPod library manager)"

    static func get(_ url: URL) async throws -> [String: Any] {
        var r = URLRequest(url: url); r.setValue(agent, forHTTPHeaderField: "User-Agent")
        for attempt in 0..<3 {   // MusicBrainz allows one request per second and answers 503 beyond that
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 503, attempt < 2 { try await Task.sleep(for: .seconds(2 * Double(attempt + 1))); continue }
            guard code == 200 else { throw URLError(.badServerResponse) }
            return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        throw URLError(.badServerResponse)
    }

    static func search(album: String, artist: String) async throws -> [MBRelease] {
        let q = "release:\"\(album)\"" + (artist.isEmpty || artist == "Various Artists" ? "" : " AND artist:\"\(artist)\"")
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        c.queryItems = [.init(name: "query", value: q), .init(name: "fmt", value: "json"), .init(name: "limit", value: "8")]
        let j = try await get(c.url!)
        return ((j["releases"] as? [[String: Any]]) ?? []).map { r in
            let credit = ((r["artist-credit"] as? [[String: Any]]) ?? []).map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
            return MBRelease(id: r["id"] as? String ?? "", title: r["title"] as? String ?? "", artist: credit,
                             date: r["date"] as? String ?? "", country: r["country"] as? String ?? "",
                             trackCount: r["track-count"] as? Int ?? 0, score: r["score"] as? Int ?? 0)
        }
    }

    /// Adds the most-voted genre of the release group.
    static func details(_ rel: MBRelease) async -> MBRelease {
        var r = rel
        if let j = try? await get(URL(string: "https://musicbrainz.org/ws/2/release/\(rel.id)?inc=release-groups+genres&fmt=json")!) {
            let rg = j["release-group"] as? [String: Any]
            let genres = ((j["genres"] as? [[String: Any]]) ?? []) + ((rg?["genres"] as? [[String: Any]]) ?? [])
            if let g = genres.max(by: { ($0["count"] as? Int ?? 0) < ($1["count"] as? Int ?? 0) })?["name"] as? String {
                r.genre = g.capitalized
            }
            if r.date.isEmpty, let d = rg?["first-release-date"] as? String { r.date = d }
        }
        return r
    }

    static func coverURL(_ r: MBRelease, size: Int = 500) -> URL {
        r.source == "Discogs" ? URL(string: r.cover)! : coverURL(r.id, size: size)
    }

    static func coverURL(_ id: String, size: Int = 500) -> URL { URL(string: "https://coverartarchive.org/release/\(id)/front-\(size)")! }

    static func cover(_ id: String) async -> Data? {
        guard let (d, resp) = try? await URLSession.shared.data(from: coverURL(id, size: 1200)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
}

enum Discogs {
    static var token: String { UserDefaults.standard.string(forKey: "discogsToken") ?? "" }

    static func search(album: String, artist: String) async throws -> [MBRelease] {
        guard !token.isEmpty else { return [] }
        var c = URLComponents(string: "https://api.discogs.com/database/search")!
        c.queryItems = [.init(name: "release_title", value: album), .init(name: "type", value: "release"),
                        .init(name: "per_page", value: "8")]
        if !artist.isEmpty, artist != "Various Artists" { c.queryItems!.append(.init(name: "artist", value: artist)) }
        var r = URLRequest(url: c.url!)
        r.setValue(MusicBrainz.agent, forHTTPHeaderField: "User-Agent")
        r.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        let (d, _) = try await URLSession.shared.data(for: r)
        let j = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return ((j["results"] as? [[String: Any]]) ?? []).map { x in
            let full = x["title"] as? String ?? ""       // "Artist - Album"
            let parts = full.components(separatedBy: " - ")
            let styles = (x["style"] as? [String]) ?? [], genres = (x["genre"] as? [String]) ?? []
            return MBRelease(id: "discogs-\(x["id"] as? Int ?? 0)", title: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : full,
                             artist: parts.count > 1 ? parts[0] : "", date: x["year"] as? String ?? "",
                             country: x["country"] as? String ?? "", trackCount: 0, score: 0,
                             genre: styles.first ?? genres.first ?? "", source: "Discogs", cover: x["cover_image"] as? String ?? "")
        }
    }
}

/// The iTunes Store (the same catalogue iTunes Match matches against): big covers, year, genre.
enum ITunesLookup {
    static func search(album: String, artist: String) async throws -> [MBRelease] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: (artist.isEmpty || artist == "Various Artists" ? "" : artist + " ") + album),
                        .init(name: "entity", value: "album"), .init(name: "limit", value: "8")]
        let (d, _) = try await URLSession.shared.data(from: c.url!)
        let j = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return ((j["results"] as? [[String: Any]]) ?? []).map { x in
            MBRelease(id: "itunes-\(x["collectionId"] as? Int ?? 0)", title: x["collectionName"] as? String ?? "",
                      artist: x["artistName"] as? String ?? "", date: String((x["releaseDate"] as? String ?? "").prefix(10)),
                      country: x["country"] as? String ?? "", trackCount: x["trackCount"] as? Int ?? 0, score: 0,
                      genre: x["primaryGenreName"] as? String ?? "", source: "iTunes",
                      cover: (x["artworkUrl100"] as? String ?? "").replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
        }
    }
}

enum MetadataStore {
    static var url: URL {
        let dir = Demo.dir("support") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata.json")
    }
    static func load() -> [String: MBRelease] {
        (try? JSONDecoder().decode([String: MBRelease].self, from: Data(contentsOf: url))) ?? [:]
    }
    static func save(_ m: [String: MBRelease]) { try? JSONEncoder().encode(m).write(to: url) }
}

/// Find Metadata, as a panel under the album page's header.
struct LookupPanel: View {
    @EnvironmentObject var model: Model
    var album: Album
    var close: () -> Void
    @StateObject private var state = LookupState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(state.applying == nil ? "Find Metadata" : state.summary == nil ? "Applying…" : "Metadata saved",
                      systemImage: "sparkle.magnifyingglass").font(.title3.bold())
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close")
                    .disabled(state.applying != nil && state.summary == nil)
            }
            if state.applying == nil {
                HStack(spacing: 8) {     // search by hand when the tags don't find it
                    TextField("Album", text: $state.title).textFieldStyle(.roundedBorder).onSubmit(research)
                    TextField("Artist", text: $state.artist).textFieldStyle(.roundedBorder).frame(width: 180).onSubmit(research)
                    Button("Search", action: research).buttonStyle(.glass)
                        .disabled(state.searching || (state.title + state.artist).trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Group {
                if let r = state.applying { progress(r) }
                else { results }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            HStack {
                if state.applying == nil {
                    Picker("", selection: $state.source) {
                        Text("All Sources").tag("")
                        ForEach(["MusicBrainz", "iTunes", "Discogs"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Toggle("Replace the current cover", isOn: $state.replaceCover).toggleStyle(.checkbox)
                }
                Spacer()
                if state.applying == nil {
                    Button("Cancel", action: close).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                } else {
                    Button("Done", action: close).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                        .disabled(state.summary == nil)
                }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.accentColor.opacity(0.08)), in: .rect(cornerRadius: 18))
        .task { state.title = album.title; state.artist = album.artist; await state.search(album) }
    }

    func research() { Task { await state.search(album) } }

    var results: some View {
        let shown = state.results.filter { state.source.isEmpty || $0.source == state.source }
        return Group {
            if state.searching { ProgressView("Searching MusicBrainz, iTunes\(Discogs.token.isEmpty ? "" : " and Discogs")…").frame(maxWidth: .infinity, minHeight: 120) }
            else if let e = state.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            else if shown.isEmpty { ContentUnavailableView("No matches", systemImage: "magnifyingglass") }
            else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(shown) { r in
                            HStack(spacing: 12) {
                                AsyncImage(url: MusicBrainz.coverURL(r, size: 250)) { $0.resizable().scaledToFill() }
                                    placeholder: { Color.secondary.opacity(0.15).overlay { Image(systemName: "photo").foregroundStyle(.tertiary) } }
                                    .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.headline).lineLimit(1)
                                    Text(r.artist).foregroundStyle(.secondary).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(r.source).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.quaternary, in: .capsule)
                                        Text([r.date, r.genre, r.country, r.trackCount > 0 ? "\(r.trackCount) tracks" : ""]
                                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if r.trackCount == album.tracks.count {
                                            Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).help("Same number of tracks")
                                        }
                                    }
                                }
                                Spacer()
                                VStack(spacing: 6) {
                                    Button("Use") { Task { await state.apply(r, to: album, model: model) } }
                                        .buttonStyle(.glassProminent).frame(width: 80)
                                        .help("Save year, genre and (if there's none yet) the cover")
                                    Button("Cover") { Task { await state.apply(r, to: album, model: model, coverOnly: true) } }
                                        .buttonStyle(.glass).frame(width: 80).controlSize(.small)
                                        .help("Only use this cover, replacing the current one")
                                }
                            }
                            .padding(10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
    }

    func progress(_ r: MBRelease) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                CachedImage(url: MusicBrainz.coverURL(r, size: 500), seed: "Metadata.swift:1")
                    .frame(width: 120, height: 120).clipShape(.rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(.title3.bold())
                    Text(r.artist).foregroundStyle(.secondary)
                    Text([r.source, r.date, r.genre].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(state.steps.enumerated()), id: \.offset) { i, s in
                    let current = i == state.steps.count - 1 && state.summary == nil
                    HStack(spacing: 10) {
                        if current { ProgressView().controlSize(.small).frame(width: 18) }
                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18) }
                        Text(s).foregroundStyle(current ? .primary : .secondary)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            if let s = state.summary {
                Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            }
        }
    }
}

@MainActor
final class LookupState: ObservableObject {
    @Published var results: [MBRelease] = []
    @Published var searching = true
    @Published var error: String?
    @Published var source = ""
    @Published var replaceCover = false
    @Published var applying: MBRelease?
    @Published var steps: [String] = []
    @Published var summary: String?
    @Published var title = ""         // what to search for: the album's tags, or typed
    @Published var artist = ""

    func search(_ a: Album) async {
        searching = true; error = nil
        defer { searching = false }
        let t = title.trimmingCharacters(in: .whitespaces), ar = artist.trimmingCharacters(in: .whitespaces)
        async let mb = (try? MusicBrainz.search(album: t, artist: ar)) ?? []
        async let it = (try? ITunesLookup.search(album: t, artist: ar)) ?? []
        async let dc = (try? Discogs.search(album: t, artist: ar)) ?? []
        let r = await mb + it + dc
        if r.isEmpty { error = "Nothing found (or the metadata services are unreachable)" }
        // same track count first, then MusicBrainz' score
        results = r.sorted { ($0.trackCount == a.tracks.count ? 1 : 0, $0.score) > ($1.trackCount == a.tracks.count ? 1 : 0, $1.score) }
    }

    func apply(_ r: MBRelease, to a: Album, model: Model, coverOnly: Bool = false) async {
        applying = r; steps = []; summary = nil
        summary = await model.apply(r, to: a, replaceCover: replaceCover, coverOnly: coverOnly) { [weak self] in self?.steps.append($0) }
    }
}
