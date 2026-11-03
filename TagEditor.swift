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
                    Cover(image: s.cover, seed: album.id).frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16))
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
                    TextField("Album Artist", text: $s.albumArtist)
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
                        Text("Artist").frame(width: 170, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    ForEach($s.rows) { $r in
                        HStack(spacing: 8) {
                            TextField("1", value: $r.disc, format: .number).frame(width: 34).help("Disc number")
                            TextField("#", value: $r.track, format: .number).frame(width: 38).help("Track number")
                            TextField("Title", text: $r.title)
                            TextField("Artist", text: $r.artist).frame(width: 170)
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
        guard let url, let d = try? Data(contentsOf: url), let img = NSImage(data: d) else { return }
        s.coverData = d; s.cover = img
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
        if let d = s.coverData {
            let dst = album.folder + "/cover.jpg"
            let fm = FileManager.default
            for n in ["folder.jpg", "cover.png", "folder.png", "front.jpg"] where fm.fileExists(atPath: album.folder + "/" + n) {
                try? fm.moveItem(atPath: album.folder + "/" + n, toPath: album.folder + "/" + n + ".old")
            }
            try? fm.removeItem(atPath: dst)
            if !fm.createFile(atPath: dst, contents: d) { failed.append("couldn't write cover.jpg") }
        }
        await model.refreshFiles(album.tracks.map(\.path), cover: s.coverData, oldID: album.id)
        s.saving = false
        if failed.isEmpty { close() } else { s.error = "\(failed.count) failed: \(failed[0])" }
    }
}
