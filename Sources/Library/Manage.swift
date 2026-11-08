import SwiftUI

// Deleting (to the Trash) and merging albums in the library.

extension Model {
    /// Moves the files to the Trash and takes them out of the library and the iPod queue.
    var trashRoots: [String] { libraryRoots }

    /// To the Trash; on network shares (which have none) into a hidden .crate-trash folder in the
    /// same music folder, kept by date, so it can still be put back.
    nonisolated static func discard(_ path: String, roots: [String]) -> Bool {
        let url = URL(fileURLWithPath: path)
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return true }
        let root = Organizer.root(of: path, roots: roots) ?? (path as NSString).deletingLastPathComponent
        let day = Date().formatted(.iso8601.year().month().day())
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        let dst = root + "/.crate-trash/" + day + "/" + rel
        try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dst)
        return (try? FileManager.default.moveItem(atPath: path, toPath: dst)) != nil
    }

    func trash(_ tracks: [LibTrack]) async {
        // songs only on the Subsonic server can't be deleted from here (its API can't delete files)
        let tracks = tracks.filter { !Subsonic.serverOnly($0.path) }
        guard !tracks.isEmpty else { notify(Model.serverOnlyHelp); return }
        let paths = tracks.map(\.path)
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent }), roots = trashRoots
        let (failed, gone) = await offMain { () -> (Int, Set<String>) in
            var failed = 0
            for p in paths where !Model.discard(p, roots: roots) { failed += 1 }
            // album folders left with only covers or nothing go too
            for f in folders {
                let left = ((try? FileManager.default.contentsOfDirectory(atPath: f)) ?? []).filter { $0 != ".DS_Store" }
                if !left.contains(where: { LibraryLoader.audioExts.contains(($0 as NSString).pathExtension.lowercased()) }) {
                    _ = Model.discard(f, roots: roots)
                }
            }
            return (failed, Set(paths.filter { !FileManager.default.fileExists(atPath: $0) }))
        }
        // their copies on the iPod go at the next sync too
        let fromPod = tracks.filter { gone.contains($0.path) && podKeys.contains($0.key) }
        songsToRemove.formUnion(fromPod.map { podKey($0.key) })
        songsToAdd.subtract(gone)
        libTracks.removeAll { gone.contains($0.path) }
        let ids = Set(albums.map(\.id))
        rebuild()
        toAdd = toAdd.filter { id in albums.contains { $0.id == id } || !ids.contains(id) }
        await rescanServers()
        notify("Deleted \(paths.count - failed) file\(paths.count - failed == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) couldn't be moved" : "")
               + (fromPod.isEmpty ? "" : "; \(fromPod.count) leave the iPod on the next sync"))
    }

    /// The .crate-trash folders on the shares: their size, and emptying them for good.
    /// All on the shares, so all off the main thread.
    nonisolated static func crateTrash(_ roots: [String]) -> [String] {
        Set(roots).map { $0 + "/.crate-trash" }.filter { FileManager.default.fileExists(atPath: $0) }
    }
    func crateTrashSize() async -> Int64 {
        let roots = trashRoots
        return await offMain {
            Model.crateTrash(roots).reduce(Int64(0)) { sum, dir in
                var n = Int64(0)
                for case let rel as String in FileManager.default.enumerator(atPath: dir) ?? .init() {
                    n += Int64((try? FileManager.default.attributesOfItem(atPath: dir + "/" + rel))?[.size] as? Int ?? 0)
                }
                return sum + n
            }
        }
    }
    func emptyCrateTrash() async {
        let roots = trashRoots
        await offMain { Model.crateTrash(roots).forEach { try? FileManager.default.removeItem(atPath: $0) } }
    }
    func showCrateTrash() async {
        let roots = trashRoots
        if let dir = await offMain({ Model.crateTrash(roots).first }) { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
    }
}

@MainActor
final class MergeState: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var oneFolder = true
    @Published var working = false
    @Published var error: String?
    @Published var phase = ""                  // what merging is doing now
    @Published var done = 0                    // files through this phase
    @Published var total = 0                   // 0: no count for this phase
}

/// Merges albums into one: the same album title and album artist in every file, optionally one folder.
struct MergeSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var albums: [Album]
    @StateObject private var s = MergeState()

    var body: some View {
        let tracks = albums.flatMap(\.tracks)
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \(albums.count) Albums").font(.title2.bold())
            Text("All \(tracks.count) songs get the same album and album artist in their files, so they show up as one album (and go to the iPod as one).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(albums.prefix(6)) { a in
                    VStack(spacing: 4) {
                        Cover(image: model.artwork[a.id], seed: a.id).frame(width: 74, height: 74).clipShape(.rect(cornerRadius: 8, style: .continuous))
                        Text(a.title).font(.caption).lineLimit(1).frame(width: 80)
                    }
                    .onTapGesture { s.title = a.title; s.artist = a.artist }
                    .help("Use this album's name")
                }
            }
            Form {
                Picker("Album", selection: $s.title) {
                    ForEach(Array(Set(albums.map(\.title))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("Album title", text: $s.title)
                Picker("Album artist", selection: $s.artist) {
                    ForEach(Array(Set(albums.map(\.artist))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("Album artist", text: $s.artist)
                Toggle("Move the files into one folder", isOn: $s.oneFolder)
            }
            .formStyle(.grouped)
            if let e = s.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack {
                if s.working {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.phase + (s.total > 0 ? " (\(s.done) of \(s.total))" : "…")).foregroundStyle(.secondary).monospacedDigit()
                        if s.total > 0 { ProgressView(value: Double(s.done), total: Double(s.total)) }
                        else { ProgressView().progressViewStyle(.linear) }
                    }
                    .frame(maxWidth: 300)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction).disabled(s.working)
                Button("Merge") { Task { await merge() } }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(s.working || s.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(s.working)
        .onAppear {
            let biggest = albums.max { $0.tracks.count < $1.tracks.count }
            s.title = biggest?.title ?? ""; s.artist = biggest?.artist ?? ""
        }
    }

    func merge() async {
        s.working = true; s.error = nil
        // a server song that isn't on this Mac (not on the share, not downloaded) has no file to write;
        // the server keeps its own tags for it
        let tracks = await Task.detached { [all = albums.flatMap(\.tracks)] in
            all.filter { TagWriter.canWrite($0.path) && FileManager.default.fileExists(atPath: $0.path) }
        }.value
        let e = TagEdit(albumArtist: s.artist, album: s.title)
        var failed: [String] = []
        s.phase = "Writing album tags"; s.done = 0; s.total = tracks.count
        for t in tracks {
            defer { s.done += 1 }
            let p = t.path
            if let err = await Task.detached(operation: { () -> String? in
                do { try TagWriter.write(p, e); return nil } catch { return error.localizedDescription }
            }).value { failed.append(err) }
        }
        let wasAdding = albums.contains { model.toAdd.contains($0.id) }
        s.phase = "Reading the songs back in"; s.total = 0
        await model.refreshFiles(tracks.map(\.path), oldID: albums.first?.id, rescan: false)
        if wasAdding { model.toAdd.insert(s.title.lowercased()) }
        if s.oneFolder, let merged = model.albums.first(where: { $0.id == s.title.lowercased() }) {
            let roots = model.libraryRoots
            let moves = Organizer.plan([merged], roots: roots, withYear: false)
            s.phase = "Moving \(moves.count) files into one folder"
            let r = await Task.detached { Organizer.apply(moves) }.value
            await model.moved(r.done, rescan: false)
            failed += r.failed
        }
        s.working = false
        // the servers pick the changes up in the background; no need to hold the dialog for it
        Task { await model.rescanServers() }
        if failed.isEmpty { model.notify("Merged into “\(s.title)”"); dismiss() } else { s.error = "\(failed.count) failed: \(failed[0])" }
    }
}

/// Drop an image (from Finder or a browser) on an album's cover to make it the cover, or another album (its folder,
/// dragged from a grid) to choose between taking its cover and merging the two (Model.albumOnAlbum).
struct CoverDrop: ViewModifier {
    @EnvironmentObject var model: Model
    var album: Album
    var corner: CGFloat
    static let images: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif", "tif", "tiff"]

    func body(content: Content) -> some View {
        if model.isPodOnly(album) { content } else {
            content
                .overlay {
                    if model.coverDrop == album.id {
                        RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.tint, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: corner, style: .continuous))
                            .overlay { Label("Drop on This Album", systemImage: "square.and.arrow.down").font(.callout.bold()).padding(8).glassEffect(.regular, in: .capsule) }
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    // another album, dragged from a grid: its folder
                    let folders = Set(urls.filter(\.isFileURL).map { $0.standardizedFileURL.path })
                    if let other = model.allAlbums.first(where: { !$0.folder.isEmpty && folders.contains(URL(fileURLWithPath: $0.folder).standardizedFileURL.path) }) {
                        guard other.id != album.id else { return false }
                        model.albumOnAlbum = AlbumPair(dragged: other, target: album)
                        return true
                    }
                    guard let u = urls.first(where: { !$0.isFileURL || Self.images.contains($0.pathExtension.lowercased()) }) else { return false }
                    Task {
                        let data = u.isFileURL ? await offMain({ try? Data(contentsOf: u) }) : (try? await URLSession.shared.data(from: u))?.0
                        if let data { await model.setCover(data, for: album) }
                    }
                    return true
                } isTargeted: { on in
                    if on { model.coverDrop = album.id } else if model.coverDrop == album.id { model.coverDrop = nil }
                }
        }
    }
}

extension View {
    func coverDrop(_ album: Album, corner: CGFloat = 14) -> some View { modifier(CoverDrop(album: album, corner: corner)) }
}
