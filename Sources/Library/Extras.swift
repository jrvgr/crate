import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// Matching fixes (songs whose tags differ between the iPod and the library), ratings set in Crate,
// artists kept on the iPod, checking files before they're synced, and settings to take to another Mac.

enum Store {
    static func load<T: Decodable>(_ name: String, _ empty: T) -> T {
        (try? Data(contentsOf: PodCache.dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? empty
    }
    static func save<T: Encodable>(_ name: String, _ value: T) {
        try? JSONEncoder().encode(value).write(to: PodCache.dir.appendingPathComponent(name))
    }
}

// MARK: matching

extension Model {
    /// The iPod key of a library song (its own key, or the one it was paired with).
    func podKey(_ libKey: String) -> String { podKeyByLib[libKey] ?? libKey }

    /// iPod songs with no library song of the same album and title, and library songs whose album is
    /// partly on the iPod, paired up where the title (ignoring punctuation) and artist look alike.
    func matchSuggestions() -> [(pod: PodTrack, lib: LibTrack)] {
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let libKeys = Set(libTracks.map(\.key))
        let unmatched = (db?.tracks ?? []).filter { !libKeys.contains($0.key) && aliases[$0.key] == nil }
        let used = Set(aliases.values)
        let candidates = libTracks.filter { !podKeys.contains($0.key) && !used.contains($0.key) }
        var byTitle: [String: [LibTrack]] = [:]
        for t in candidates { byTitle[loose(t.title), default: []].append(t) }
        var out: [(PodTrack, LibTrack)] = []
        for p in unmatched {
            guard let options = byTitle[loose(p.title)] else { continue }
            let pick = options.first { loose($0.album) == loose(p.album) }
                ?? options.first { loose($0.trackArtist.isEmpty ? $0.artist : $0.trackArtist) == loose(p.artist) && abs($0.lengthMs - p.lengthMs) < 3000 }
                ?? options.first { abs($0.lengthMs - p.lengthMs) < 1500 && p.lengthMs > 0 }
            if let pick { out.append((p, pick)) }
        }
        return out
    }

    func pair(_ pod: PodTrack, _ lib: LibTrack) {
        aliases[pod.key] = lib.key
        Store.save("matches.json", aliases)
    }
}

@MainActor
final class MatchState: ObservableObject {
    @Published var rows: [(pod: PodTrack, lib: LibTrack, on: Bool)] = []
}

struct MatchSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var s = MatchState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix Matching").font(.title2.bold())
            Text("These songs are on the iPod under slightly different tags than in your library, so Crate saw them as two different songs. Pair them and they count as the same song (nothing is copied or changed in the files).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if s.rows.isEmpty {
                ContentUnavailableView("Nothing to pair", systemImage: "link", description: Text("Every song on the iPod matches one in the library, or has no look-alike."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(s.rows.indices, id: \.self) { i in
                            let r = s.rows[i]
                            HStack(spacing: 12) {
                                Toggle("", isOn: $s.rows[i].on).labelsHidden()
                                VStack(alignment: .leading, spacing: 1) {
                                    Label(r.pod.title, pod: model.ipod?.glyph).lineLimit(1)
                                    Text("\(r.pod.artist) — \(r.pod.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "link").foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Label(r.lib.title, systemImage: "music.note").lineLimit(1)
                                    Text("\(r.lib.trackArtist.isEmpty ? r.lib.artist : r.lib.trackArtist) — \(r.lib.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8).glassEffect(.regular, in: .rect(cornerRadius: 10))
                        }
                    }
                }
            }
            HStack {
                if !model.aliases.isEmpty {
                    Button("Forget All Pairs") { model.aliases = [:]; Store.save("matches.json", model.aliases); s.rows = model.matchSuggestions().map { ($0.pod, $0.lib, true) } }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Pair \(s.rows.filter(\.on).count)") {
                    for r in s.rows where r.on { model.pair(r.pod, r.lib) }
                    model.notify("Paired \(s.rows.filter(\.on).count) songs")
                    dismiss()
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!s.rows.contains(where: \.on))
            }
        }
        .padding(22)
        .frame(width: 720, height: 560)
        .onAppear { s.rows = model.matchSuggestions().map { ($0.pod, $0.lib, true) } }
    }
}

// MARK: ratings

extension Model {
    /// Stars for a song: set in Crate, else what the iPod says.
    func rating(_ t: LibTrack) -> Int { ratings[t.key] ?? stat(t).rating }

    func rate(_ t: LibTrack, _ stars: Int) {
        ratings[t.key] = stars
        Store.save("ratings.json", ratings)
    }

    /// The same for a song on the iPod (its library song's key when it's matched to one).
    func rating(_ t: PodTrack) -> Int { ratings[aliases[t.key] ?? t.key] ?? t.stars }

    func rate(_ t: PodTrack, _ stars: Int) {
        ratings[aliases[t.key] ?? t.key] = stars
        Store.save("ratings.json", ratings)
    }
}

/// Five small stars; click one to rate, click the same again to clear. Unrated songs show them only on
/// hover, and hovering previews the rating a click gives.
struct StarPicker: View {
    var value: Int
    var set: (Int) -> Void
    @StateObject private var hover = StarHover()
    var body: some View {
        let shown = hover.star ?? value
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= shown ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(n <= shown ? (hover.star != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) : AnyShapeStyle(.quaternary))
                    .contentShape(.rect)
                    .onHover { h in if h { hover.star = n } else if hover.star == n { hover.star = nil } }
                    .onTapGesture { set(n == value ? 0 : n); hover.star = nil }
            }
        }
        .opacity(value == 0 && hover.star == nil && !hover.row ? 0 : 1)
        .onHover { hover.row = $0 }
        .help("Rating (written to the iPod on Sync)")
    }
}

final class StarHover: ObservableObject { @Published var star: Int?; @Published var row = false }

// MARK: artists kept on the iPod

extension Model {
    func toggleKeep(_ a: Artist) {
        if keptArtists.contains(a.id) { keptArtists.remove(a.id) } else { keptArtists.insert(a.id) }
        UserDefaults.standard.set(Array(keptArtists), forKey: "keptArtists")
        applyKeptArtists()
    }

    /// Queues the albums of kept artists that aren't on the iPod yet (new downloads included).
    func applyKeptArtists() {
        guard ipod != nil, !keptArtists.isEmpty else { return }
        for a in albums where keptArtists.contains(a.artist.lowercased()) && state(a) != .onIPod && !toRemove.contains(a.id) {
            toAdd.insert(a.id)
        }
    }
}

// MARK: checking files

enum FileCheck {
    /// nil when the file decodes to the end; otherwise what's wrong (cut off downloads, broken files).
    static func problem(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return "file not found" }
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return "can't be read as audio" }
        guard f.length > 0 else { return "no audio in it" }
        let tail = AVAudioFrameCount(min(Int64(f.processingFormat.sampleRate * 2), f.length))
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: tail) else { return nil }
        f.framePosition = f.length - Int64(tail)
        do { try f.read(into: buf) } catch { return "cut off or damaged near the end" }
        return buf.frameLength < tail / 2 ? "cut off or damaged near the end" : nil
    }
}

extension Model {
    /// Checks the songs the next sync would copy; the broken ones are skipped by Sync.
    func checkQueuedFiles() async {
        let paths = syncWork().map(\.1.path)
        checkingFiles = true; defer { checkingFiles = false }
        let found = await Task.detached { () -> [String: String] in
            var bad: [String: String] = [:]
            for p in paths { if let why = FileCheck.problem(p) { bad[p] = why } }
            return bad
        }.value
        brokenFiles = found
    }
}

// MARK: settings for another Mac

/// Everything Crate needs to manage the same library and iPod from another Mac.
struct CrateSettingsFile: Codable {
    var defaults: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var files: [String: Data] = [:]
}

enum SettingsTransfer {
    static let keys = ["ownToneURL", "extraFolders", "importFolder", "slskdURL", "slskdUser", "slskdDownloads", "spotifyMode",
                       "spotifyClientID", "playOn", "slskdPrefer", "albumView"]
    static let listKeys = ["enabledPlugins", "keptArtists"]
    static let files = ["smart-playlists.json", "metadata.json", "matches.json", "ratings.json", "ipod.json"]

    static func export() -> Data? {
        var f = CrateSettingsFile()
        let d = UserDefaults.standard
        for k in keys { if let v = d.object(forKey: k) { f.defaults[k] = "\(v)" } }
        for k in listKeys { if let v = d.stringArray(forKey: k) { f.lists[k] = v } }
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("pod.") { if let v = d.data(forKey: k) { f.files["defaults:" + k] = v } }
        for n in files { if let data = try? Data(contentsOf: PodCache.dir.appendingPathComponent(n)) { f.files[n] = data } }
        if let m = try? Data(contentsOf: MetadataStore.url) { f.files["metadata.json"] = m }
        return try? JSONEncoder().encode(f)
    }

    static func importFile(_ data: Data) -> Bool {
        guard let f = try? JSONDecoder().decode(CrateSettingsFile.self, from: data) else { return false }
        let d = UserDefaults.standard
        for (k, v) in f.defaults { d.set(v, forKey: k) }
        for (k, v) in f.lists { d.set(v, forKey: k) }
        for (n, data) in f.files {
            if n.hasPrefix("defaults:") { d.set(data, forKey: String(n.dropFirst("defaults:".count))) }
            else if n == "metadata.json" { try? data.write(to: MetadataStore.url) }
            else { try? data.write(to: PodCache.dir.appendingPathComponent(n)) }
        }
        return true
    }
}

struct SettingsTransferRow: View {
    @EnvironmentObject var model: Model
    var body: some View {
        LabeledContent("Another Mac") {
            HStack {
                Button("Export Settings…") {
                    let p = NSSavePanel(); p.nameFieldStringValue = "Crate Settings.json"; p.allowedContentTypes = [.json]
                    if p.runModal() == .OK, let u = p.url, let d = SettingsTransfer.export() { try? d.write(to: u); model.notify("Settings exported") }
                }
                Button("Import…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.json]
                    if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) {
                        model.notify(SettingsTransfer.importFile(d) ? "Settings imported – restart Crate to use them" : "That isn't a Crate settings file")
                    }
                }
            }
        }
        .help("Library folders, plugins (no passwords), smart playlists, metadata choices, ratings, iPod settings and the queue")
    }
}
