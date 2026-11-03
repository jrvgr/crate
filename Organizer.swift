import SwiftUI

// Tidies the files of albums into Artist/Year – Album/01 Title.ext inside the music folder they
// already live in (never across folders or shares). Shows every move first; covers and other
// files in an album folder move along, emptied folders are removed.

struct FileMove: Identifiable, Hashable {
    var id: String { from }
    var from, to: String
    var conflict = false
}

enum Organizer {
    static func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let t = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return t.isEmpty ? "Unknown" : String(t.prefix(120))
    }

    /// The music folder a file is in: the longest of the roots that contains it.
    static func root(of path: String, roots: [String]) -> String? {
        roots.filter { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }

    static func plan(_ albums: [Album], roots: [String], withYear: Bool) -> [FileMove] {
        var moves: [FileMove] = []
        for a in albums {
            let discs = Set(a.tracks.map(\.discNumber)).filter { $0 > 0 }.count > 1
            for t in a.tracks {
                guard let r = root(of: t.path, roots: roots) else { continue }
                let folder = clean(a.artist) + "/" + (withYear && a.year > 0 ? "\(a.year) – " : "") + clean(a.title)
                let num = t.trackNumber > 0 ? (discs ? "\(max(t.discNumber, 1))-" : "") + String(format: "%02d ", t.trackNumber) : ""
                let to = (r.hasSuffix("/") ? r : r + "/") + folder + "/" + num + clean(t.title) + "." + t.ext
                if to != t.path { moves.append(FileMove(from: t.path, to: to)) }
            }
        }
        // two files to one name, or a different file already there
        let targets = Dictionary(grouping: moves, by: \.to)
        for i in moves.indices {
            moves[i].conflict = (targets[moves[i].to]?.count ?? 0) > 1
                || (FileManager.default.fileExists(atPath: moves[i].to) && !moves.contains { $0.from == moves[i].to })
        }
        return moves
    }

    /// Moves the files, takes covers and other leftovers along, removes emptied folders.
    static func apply(_ moves: [FileMove]) -> (done: [FileMove], failed: [String]) {
        let fm = FileManager.default
        var done: [FileMove] = [], failed: [String] = []
        var folders: [String: String] = [:]        // old album folder -> new
        for m in moves where !m.conflict {
            do {
                try fm.createDirectory(atPath: (m.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: m.from, toPath: m.to)
                done.append(m)
                folders[(m.from as NSString).deletingLastPathComponent] = (m.to as NSString).deletingLastPathComponent
            } catch { failed.append("\((m.from as NSString).lastPathComponent): \(error.localizedDescription)") }
        }
        for (old, new) in folders where old != new {
            for n in (try? fm.contentsOfDirectory(atPath: old)) ?? [] where !LibraryLoader.audioExts.contains((n as NSString).pathExtension.lowercased()) {
                let dst = new + "/" + n
                if !fm.fileExists(atPath: dst) { try? fm.moveItem(atPath: old + "/" + n, toPath: dst) }
            }
            var dir = old      // remove the old folder and emptied parents (only if nothing but .DS_Store is left)
            for _ in 0..<2 {
                let left = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0 != ".DS_Store" }
                guard left.isEmpty else { break }
                try? fm.removeItem(atPath: dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return (done, failed)
    }
}

@MainActor
final class OrganizerState: ObservableObject {
    @Published var withYear = true
    @Published var moves: [FileMove] = []
    @Published var working = false
    @Published var result: String?
}

struct OrganizerSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var albums: [Album]
    @StateObject private var s = OrganizerState()

    var body: some View {
        let ok = s.moves.filter { !$0.conflict }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("Organise Files").font(.title2.bold())
            Text("Moves the files of \(albums.count == 1 ? "“\(albums[0].title)”" : "\(albums.count) albums") to Artist/\(s.withYear ? "Year – " : "")Album/01 Title, inside the music folder they're already in. Nothing moves until you press Move.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Put the year in front of the album folder", isOn: $s.withYear)
                .onChange(of: s.withYear) { replan() }
            if s.moves.isEmpty {
                ContentUnavailableView("Already tidy", systemImage: "checkmark.circle", description: Text("Every file is where it should be."))
                    .frame(maxHeight: .infinity)
            } else {
                List(s.moves) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(short(m.from)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        HStack(spacing: 4) {
                            Image(systemName: m.conflict ? "exclamationmark.triangle.fill" : "arrow.turn.down.right")
                                .foregroundStyle(m.conflict ? .orange : .secondary).font(.caption)
                            Text(short(m.to)).font(.callout).lineLimit(1).truncationMode(.head)
                        }
                        if m.conflict { Text("Another file would get this name; skipped").font(.caption).foregroundStyle(.orange) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                if let r = s.result { Label(r, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else if s.working { ProgressView().controlSize(.small); Text("Moving…").foregroundStyle(.secondary) }
                else { Text("\(ok) files to move" + (s.moves.count > ok ? ", \(s.moves.count - ok) skipped" : "")).foregroundStyle(.secondary) }
                Spacer()
                Button(s.result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction).disabled(s.working)
                Button("Move \(ok) Files") { Task { await run() } }
                    .buttonStyle(.glassProminent).disabled(ok == 0 || s.working || s.result != nil)
            }
        }
        .padding(22)
        .frame(width: 680, height: 560)
        .interactiveDismissDisabled(s.working)
        .onAppear { replan() }
    }

    var roots: [String] { model.folders + [model.importFolder, (model.importFolder as NSString).deletingLastPathComponent] }

    func replan() { s.moves = Organizer.plan(albums.filter { !model.isPodOnly($0) }, roots: roots, withYear: s.withYear) }

    func short(_ p: String) -> String {
        guard let r = Organizer.root(of: p, roots: roots) else { return p }
        return (r as NSString).lastPathComponent + "/" + p.dropFirst(r.count).drop { $0 == "/" }
    }

    func run() async {
        s.working = true
        let moves = s.moves
        let r = await Task.detached { Organizer.apply(moves) }.value
        await model.moved(r.done)
        s.working = false
        s.result = "Moved \(r.done.count) files" + (r.failed.isEmpty ? "" : ", \(r.failed.count) failed: \(r.failed[0])")
    }
}
