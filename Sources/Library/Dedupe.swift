import SwiftUI

// Library deduping: the same song in more than one file (an album copied twice, an MP3 and a FLAC
// rip of it, a song that's also on a compilation). Each group keeps its best copy; the others go to
// the Trash after you check them. Copies on another album aren't ticked: that album would lose a song.

struct DupeGroup: Identifiable {
    var id: String { copies.map(\.path).sorted().joined(separator: "|") }
    var copies: [LibTrack]          // best first
    var keep: String                // path of the copy that stays
    var sizes: [String: Int64]
    /// Every copy is on the same album (a second rip), not a song repeated on another album.
    var sameAlbum: Bool { Set(copies.map { Dedupe.loose(Dedupe.plain($0.album)) }).count == 1 }
    var extra: [LibTrack] { copies.filter { $0.path != keep } }
}

enum Dedupe {
    static func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// "Song (2011 Remaster)", "Song - Remastered", "Album [Deluxe Edition]" → the plain name.
    static func plain(_ s: String) -> String {
        let words = ["remaster", "deluxe", "edition", "expanded", "anniversary", "bonus", "version", "mono", "stereo"]
        var t = s
        while let r = t.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression),
              words.contains(where: { t[r].lowercased().contains($0) }) { t.removeSubrange(r) }
        if let r = t.range(of: #"\s+-\s+[^-]*$"#, options: .regularExpression), words.contains(where: { t[r].lowercased().contains($0) }) {
            t.removeSubrange(r)
        }
        return t
    }

    static func size(_ path: String) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0)
    }

    /// Lossless before AAC before MP3, then the higher bit rate, then the one with a track number.
    static func rank(_ t: LibTrack, size: Int64) -> (Int, Int64, Int) {
        let kind = ["flac", "alac", "wav", "aif", "aiff"].contains(t.ext) ? 3 : t.ext == "m4a" ? 2 : 1
        return (kind, size * 8 / Int64(max(t.lengthMs, 1)), t.trackNumber > 0 ? 1 : 0)
    }

    /// Same artist and title and within 3 seconds of each other (a live or extended take differs more).
    static func find(_ tracks: [LibTrack]) -> [DupeGroup] {
        let byName = Dictionary(grouping: tracks) { t in
            loose(t.trackArtist.isEmpty ? t.artist : t.trackArtist) + "|" + loose(plain(t.title))
        }
        var out: [DupeGroup] = []
        for (_, ts) in byName where ts.count > 1 {
            // split into runs of similar length (unknown lengths join any run)
            var runs: [[LibTrack]] = []
            for t in ts.sorted(by: { $0.lengthMs < $1.lengthMs }) {
                if let last = runs.last?.last, t.lengthMs == 0 || last.lengthMs == 0 || t.lengthMs - last.lengthMs <= 3000 {
                    runs[runs.count - 1].append(t)
                } else { runs.append([t]) }
            }
            for run in runs where run.count > 1 {
                let sizes = Dictionary(run.map { ($0.path, size($0.path)) }, uniquingKeysWith: { a, _ in a })
                let best = run.sorted { rank($0, size: sizes[$0.path] ?? 0) > rank($1, size: sizes[$1.path] ?? 0) }
                out.append(DupeGroup(copies: best, keep: best[0].path, sizes: sizes))
            }
        }
        return out.sorted { ($0.sameAlbum ? 0 : 1, $0.copies[0].artist.lowercased(), $0.copies[0].album.lowercased(), $0.copies[0].trackNumber)
                          < ($1.sameAlbum ? 0 : 1, $1.copies[0].artist.lowercased(), $1.copies[0].album.lowercased(), $1.copies[0].trackNumber) }
    }
}

@MainActor
final class DedupeState: ObservableObject {
    @Published var groups: [DupeGroup] = []
    @Published var picked: Set<DupeGroup.ID> = []
    @Published var scanning = true
    @Published var working = false
    @Published var showAll = false        // also the songs repeated on other albums
}

struct DedupeSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var s = DedupeState()

    var body: some View {
        let shown = s.groups.filter { s.showAll || $0.sameAlbum }
        let chosen = s.groups.filter { s.picked.contains($0.id) }
        let freed = chosen.flatMap { g in g.extra.map { g.sizes[$0.path] ?? 0 } }.reduce(0, +)
        let others = s.groups.count(where: { !$0.sameAlbum })
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Songs").font(.title2.bold())
                Text(s.scanning ? "Looking through \(model.libTracks.count) songs…"
                     : s.groups.isEmpty ? "No song is in the library twice."
                     : "\(chosen.count) of \(s.groups.count) will keep only their best copy; \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) to the Trash")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown) { g in row(g) }
                }
            }
            HStack {
                if others > 0 {
                    Toggle("Show \(others) song\(others == 1 ? "" : "s") also on other albums", isOn: $s.showAll).toggleStyle(.checkbox)
                }
                if s.scanning || s.working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction).disabled(s.working)
                Button("Move \(chosen.map(\.extra.count).reduce(0, +)) to Trash") { Task { await trash(chosen) } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || s.working)
            }
        }
        .padding(22)
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(s.working)
        .task {
            let tracks = model.libTracks
            s.groups = await Task.detached { Dedupe.find(tracks) }.value
            s.picked = Set(s.groups.filter(\.sameAlbum).map(\.id))
            s.scanning = false
        }
    }

    func row(_ g: DupeGroup) -> some View {
        let first = g.copies[0]
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { s.picked.contains(g.id) },
                                     set: { if $0 { s.picked.insert(g.id) } else { s.picked.remove(g.id) } }))
                .labelsHidden().disabled(s.working)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(first.title).font(.headline).lineLimit(1)
                    Text(first.trackArtist.isEmpty ? first.artist : first.trackArtist).foregroundStyle(.secondary).lineLimit(1)
                    if !g.sameAlbum {
                        Text("Other albums").font(.caption).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.12), in: .capsule)
                    }
                }
                ForEach(g.copies) { t in
                    let keep = t.path == g.keep
                    HStack(spacing: 8) {
                        Button { set(g, keep: t.path) } label: {
                            Image(systemName: keep ? "checkmark.circle.fill" : "circle").foregroundStyle(keep ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain).help("Keep this copy").disabled(s.working)
                        Text(t.ext.uppercased()).font(.caption.monospaced().bold()).frame(width: 38, alignment: .leading)
                        Text(detail(t, g)).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(t.album).font(.caption).lineLimit(1)
                        Text((t.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                        Button { NSWorkspace.shared.selectFile(t.path, inFileViewerRootedAtPath: "") } label: { Image(systemName: "folder") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
                    }
                    .opacity(keep || s.picked.contains(g.id) ? 1 : 0.6)
                    .strikethrough(!keep && s.picked.contains(g.id), color: .secondary)
                }
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    func detail(_ t: LibTrack, _ g: DupeGroup) -> String {
        let size = g.sizes[t.path] ?? 0
        let kbps = t.lengthMs > 0 ? " · \(size * 8 / Int64(t.lengthMs)) kbps" : ""
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + kbps
    }

    func set(_ g: DupeGroup, keep path: String) {
        guard let i = s.groups.firstIndex(where: { $0.id == g.id }) else { return }
        s.groups[i].keep = path
    }

    func trash(_ groups: [DupeGroup]) async {
        s.working = true
        await model.trash(groups.flatMap(\.extra))
        s.working = false
        dismiss()
    }
}
