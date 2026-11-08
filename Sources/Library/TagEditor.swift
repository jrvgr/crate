import SwiftUI
import UniformTypeIdentifiers

// Edits an album's tags in its files (FLAC, MP3, M4A): album-wide fields plus title, artist,
// track and disc per song, and the cover image. Only changed fields are written.

@MainActor
final class TagEditorState: ObservableObject {
    struct Row: Identifiable { var id: String { path }; var path: String; var title, artist: String; var track, disc: Int }
    @Published var album = ""
    @Published var albumArtist = ""
    @Published var genre = ""
    @Published var year = ""
    @Published var rows: [Row] = []
    @Published var cover: NSImage?
    @Published var coverData: Data?
    @Published var saving = false
    @Published var done = 0
    @Published var error: String?
    var original: (album: String, albumArtist: String, genre: String, year: String, rows: [Row]) = ("", "", "", "", [])

    func load(_ a: Album, artwork: NSImage?) {
        album = a.title; albumArtist = a.artist; genre = a.genre; year = a.year > 0 ? "\(a.year)" : ""
        rows = a.tracks.map { Row(path: $0.path, title: $0.title, artist: $0.trackArtist.isEmpty ? $0.artist : $0.trackArtist,
                                  track: $0.trackNumber, disc: $0.discNumber) }
        cover = artwork
        original = (album, albumArtist, genre, year, rows)
    }

    /// Numbers the songs 1, 2, 3… in their current order.
    func renumber() { for i in rows.indices { rows[i].track = i + 1 } }

    var changes: Int {
        var n = rows.indices.filter { i in
            let o = original.rows[i], r = rows[i]
            return o.title != r.title || o.artist != r.artist || o.track != r.track || o.disc != r.disc
        }.count
        if album != original.album || albumArtist != original.albumArtist || genre != original.genre || year != original.year { n = rows.count }
        return n + (coverData == nil ? 0 : 1)
    }

    func edits() -> [(String, TagEdit)] {
        rows.indices.compactMap { i in
            let o = original.rows[i], r = rows[i]
            var e = TagEdit()
            if r.title != o.title { e.title = r.title }
            if r.artist != o.artist { e.artist = r.artist }
            if r.track != o.track { e.track = r.track; e.trackCount = rows.count }
            if r.disc != o.disc { e.disc = r.disc }
            if album != original.album { e.album = album }
            if albumArtist != original.albumArtist { e.albumArtist = albumArtist }
            if genre != original.genre { e.genre = genre }
            if year != original.year { e.year = Int(year) }
            return e == TagEdit() ? nil : (r.path, e)
        }
    }
}

/// Edit Tags: the album page turned into a form.
struct TagEditor: View {
    @EnvironmentObject var model: Model
    var album: Album
    var close: () -> Void
    @StateObject private var s = TagEditorState()

    var body: some View {
        let unwritable = album.tracks.filter { !TagWriter.canWrite($0.path) }.count
        VStack(alignment: .leading, spacing: 16) {
            Label("Editing Tags", systemImage: "pencil").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 8) {
                    Cover(image: s.cover, seed: album.id).frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        .dropDestination(for: URL.self) { urls, _ in setCover(urls.first); return true }
                    Button("Choose Image…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.jpeg, .png]
                        if p.runModal() == .OK { setCover(p.url) }
                    }
                    .controlSize(.small)
                }
                Form {
                    TextField("Album", text: $s.album)
                    ArtistsField(label: "Album Artist", credit: $s.albumArtist, known: model.artists.map(\.name))
                    HStack {
                        TextField("Year", text: $s.year).frame(width: 140)
                        TextField("Genre", text: $s.genre)
                    }
                }
                .formStyle(.columns)
            }
            HStack {
                Text("Songs").font(.headline)
                Spacer()
                Button("Number 1, 2, 3…") { s.renumber() }.controlSize(.small)
            }
            VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Disc").frame(width: 34, alignment: .leading)
                        Text("Track").frame(width: 38, alignment: .leading)
                        Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Artists").frame(width: 260, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    ForEach($s.rows) { $r in
                        HStack(spacing: 8) {
                            TextField("1", value: $r.disc, format: .number).frame(width: 34).help("Disc number")
                            TextField("#", value: $r.track, format: .number).frame(width: 38).help("Track number")
                            TextField("Title", text: $r.title)
                            ArtistsField(label: "Artist", credit: $r.artist, known: model.artists.map(\.name)).frame(width: 260)
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.vertical, 3)
                    }
            }
            HStack {
                if s.saving {
                    ProgressView(value: Double(s.done), total: Double(max(s.edits().count, 1))).frame(width: 160)
                    Text("Writing \(s.done) of \(s.edits().count)…").font(.callout).foregroundStyle(.secondary)
                } else if let e = s.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                } else if unwritable > 0 {
                    Label("\(unwritable) files (WAV/AIFF) can't hold tags", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).buttonStyle(.glass).disabled(s.saving)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                    .disabled(s.saving || s.changes == 0)
            }
        }
        .onAppear { s.load(album, artwork: model.artwork[album.id]) }
    }

    func setCover(_ url: URL?) {
        guard let url else { return }
        Task {
            guard let d = await offMain({ try? Data(contentsOf: url) }), let img = NSImage(data: d) else { return }
            s.coverData = d; s.cover = img
        }
    }

    func save() async {
        s.saving = true; s.done = 0; s.error = nil
        let edits = s.edits()
        var failed: [String] = []
        for (path, e) in edits where TagWriter.canWrite(path) {
            let r = await Task.detached { () -> String? in
                do { try TagWriter.write(path, e); return nil } catch { return error.localizedDescription }
            }.value
            if let r { failed.append(r) }
            s.done += 1
        }
        if let d = s.coverData, !(await Model.writeCover(d, in: album.folder)) { failed.append("couldn't write cover.jpg") }
        await model.refreshFiles(album.tracks.map(\.path), cover: s.coverData, oldID: album.id)
        s.saving = false
        if failed.isEmpty { close() } else { s.error = "\(failed.count) failed: \(failed[0])" }
    }
}

/// A credit ("A, B & C", "A feat. B") as its artists, one chip each, plus a field to add one (suggesting the
/// library's artists). The files and the iPod keep one credit string, so the chips are joined back into one:
/// "A & B", "A, B & C", or "A feat. B & C" when the credit had a featured guest (Crate files those under A).
struct ArtistsField: View {
    var label: String
    @Binding var credit: String
    var known: [String]
    @StateObject private var ui = ArtistsFieldUI()
    @FocusState private var focused: Bool

    var body: some View {
        let names = ArtistsField.split(credit, known: known)
        let q = ui.new.trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = q.isEmpty ? [] : known.filter { $0.lowercased().contains(q) && !names.contains($0) }.prefix(6)
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                    HStack(spacing: 3) {
                        Text(n).lineLimit(1)
                        Button { set(names.enumerated().filter { $0.offset != i }.map(\.element)) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(n)")
                    }
                    .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: .capsule)
                    .contextMenu {
                        if i > 0 { Button("Make Main Artist") { var m = names; m.insert(m.remove(at: i), at: 0); set(m) } }
                        Button("Remove") { set(names.enumerated().filter { $0.offset != i }.map(\.element)) }
                    }
                }
                TextField(names.isEmpty ? label : "Add artist", text: $ui.new)
                    .textFieldStyle(.plain).frame(minWidth: 70)
                    .focused($focused)
                    .onSubmit { add(ui.new, to: names) }
                    .popover(isPresented: Binding(get: { !suggestions.isEmpty && focused }, set: { _ in }), arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(suggestions), id: \.self) { n in
                                Button { add(n, to: names) } label: { Text(n).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }
                                    .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 4)
                            }
                        }
                        .padding(.vertical, 6).frame(minWidth: 180)
                    }
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
        }
        .scrollIndicators(.never)
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15), lineWidth: 1) }
        .help("Each artist a chip: type a name and press Return to add one, right-click to make one the main artist")
    }

    func add(_ name: String, to names: [String]) {
        let n = name.trimmingCharacters(in: .whitespaces)
        ui.new = ""
        guard !n.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        set(names + [n])
    }

    func set(_ names: [String]) {
        credit = ArtistsField.join(names, featuring: ArtistsField.featuring(credit))
    }

    private static let seps = [" feat. ", " ft. ", " featuring ", " Feat. ", " Ft. ", ", ", " & ", " / ", " x ", " X ", " with "]

    static func featuring(_ credit: String) -> Bool {
        credit.range(of: #"\s\(?(feat\.?|ft\.?|featuring)\s"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The artists in a credit. Split at every joiner, then pieces put back together where the joined name is one of
    /// the library's artists ("Roni Size & Reprazent", "Tyler, The Creator").
    static func split(_ credit: String, known: [String]) -> [String] {
        let c = credit.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return [] }
        let lower = Set(known.map { $0.lowercased() })
        if lower.contains(c.lowercased()) { return [c] }
        // pieces and the joiner after each
        var parts: [(String, String)] = [], rest = Substring(c)
        while let r = seps.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            parts.append((String(rest[..<r.lowerBound]), String(rest[r])))
            rest = rest[r.upperBound...]
        }
        parts.append((String(rest), ""))
        var out: [String] = [], i = 0
        while i < parts.count {
            var name = parts[i].0, j = i
            // the longest run from here that is a known artist
            var k = i, joined = name
            while k + 1 < parts.count {
                joined += parts[k].1 + parts[k + 1].0
                k += 1
                if lower.contains(joined.lowercased()) { name = joined; j = k }
            }
            out.append(name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()"))))
            i = j + 1
        }
        return out.filter { !$0.isEmpty }
    }

    static func join(_ names: [String], featuring: Bool) -> String {
        func list(_ n: [String]) -> String { n.count <= 1 ? n.joined() : n.dropLast().joined(separator: ", ") + " & " + n.last! }
        guard let first = names.first else { return "" }
        if featuring && names.count > 1 { return first + " feat. " + list(Array(names.dropFirst())) }
        return list(names)
    }
}

@MainActor
final class ArtistsFieldUI: ObservableObject { @Published var new = "" }
