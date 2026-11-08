import SwiftUI
import AppKit

// Playlists you can change: Crate's own (kept here and copied to the iPod like smart playlists), the
// playlists on the iPod (changes wait for Sync, like everything else there) and OwnTone's .m3u files
// (changed in place on the share, then OwnTone rescans). Spotify's stay read-only.

/// A playlist Crate keeps: library songs in your order.
struct CratePlaylist: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "Untitled Playlist"
    var keys: [String] = []           // each song's TrackKey
    var onIPod = false
    var podID: UInt64? = nil          // its playlist on the iPod, so a rename follows it there
}

/// Changes to a playlist on the iPod, made on the next sync.
struct PodPlaylistEdit: Codable, Hashable {
    var name: String? = nil
    var trackIDs: [UInt32]? = nil
}

/// A playlist Crate can rename or delete.
enum PlaylistRef: Hashable {
    case crate(UUID), pod(UInt64), ownTone(Int)
}

extension Array {
    mutating func moveItem(_ from: Int, to: Int) {
        guard indices.contains(from), indices.contains(to), from != to else { return }
        insert(remove(at: from), at: to)
    }
}

// MARK: OwnTone's .m3u files

enum OwnToneM3U {
    enum Failure: LocalizedError {
        case notEditable, exists(String)
        var errorDescription: String? {
            switch self {
            case .notEditable: return "Crate can't reach its .m3u file (is the share mounted?)"
            case .exists(let n): return "There's already a playlist called “\(n)”"
            }
        }
    }

    /// The playlist's file on this Mac, when Crate can change it.
    static func file(_ p: OTPlaylist) -> String? {
        guard p.spotifyID == nil, ["m3u", "m3u8"].contains((p.path as NSString).pathExtension.lowercased()) else { return nil }
        let local = LibraryLoader.localPath(p.path)
        return FileManager.default.isWritableFile(atPath: local) ? local : nil
    }

    /// A path on this Mac as OwnTone sees it (the reverse of LibraryLoader.localPath).
    static func serverPath(_ p: String) -> String {
        ServerPaths.convert(p, ServerPaths.mappings, from: \.mac, to: \.server)
    }

    /// An entry's path or URL the way OwnTone resolves it: relative to the playlist's folder.
    static func resolve(_ line: String, dir: String) -> String {
        if line.contains("://") { return line }
        let p = line.replacingOccurrences(of: "\\", with: "/")
        return ((p.hasPrefix("/") ? p : dir + "/" + p) as NSString).standardizingPath
    }

    /// The playlist with `paths` (OwnTone's) in that order. Each kept entry keeps its own lines (#EXTINF);
    /// new ones are bare paths. Entries OwnTone didn't list (`listed`: missing files, say) stay, at the end.
    static func rewrite(_ text: String, dir: String, paths: [String], listed: [String]) -> String {
        var header: [String] = [], entries: [(lines: [String], target: String)] = [], pending: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if entries.isEmpty && pending.isEmpty && !line.hasPrefix("#EXTINF") { header.append(raw) } else { pending.append(raw) }
            } else {
                entries.append((pending + [raw], resolve(line, dir: dir))); pending = []
            }
        }
        var queue: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() { queue[e.target, default: []].append(i) }
        var out = header, taken = Set<Int>()
        for p in paths {
            if let i = queue[p]?.first {
                queue[p]!.removeFirst(); taken.insert(i); out += entries[i].lines
            } else {
                out.append(p)
            }
        }
        let known = Set(listed)
        for (i, e) in entries.enumerated() where !taken.contains(i) && !known.contains(e.target) { out += e.lines }
        return (out + pending).joined(separator: "\n") + "\n"
    }

    /// A copy in Crate's Application Support before every change, since these are your files.
    static func backup(_ file: String) {
        let dir = PodCache.dir.appendingPathComponent("Playlist Backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        try? FileManager.default.copyItem(atPath: file, toPath: dir.appendingPathComponent("\(name) \(stamp).m3u").path)
    }

    static func read(_ file: String) throws -> String {
        let d = try Data(contentsOf: URL(fileURLWithPath: file))
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    static func write(_ p: OTPlaylist, paths: [String], listed: [String]) throws {
        guard let file = file(p) else { throw Failure.notEditable }
        let text = try read(file)
        backup(file)
        try rewrite(text, dir: (p.path as NSString).deletingLastPathComponent, paths: paths, listed: listed)
            .write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Renames the file (OwnTone names a playlist after it) and any #PLAYLIST line. Returns the new OwnTone path.
    static func rename(_ p: OTPlaylist, to name: String) throws -> String {
        guard let file = file(p) else { throw Failure.notEditable }
        let ext = (file as NSString).pathExtension
        let new = ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(Importer.safe(name) + "." + ext)
        guard !FileManager.default.fileExists(atPath: new) else { throw Failure.exists(name) }
        backup(file)
        let text = try read(file)
        if text.contains("#PLAYLIST:") {
            let fixed = text.components(separatedBy: "\n").map { $0.hasPrefix("#PLAYLIST:") ? "#PLAYLIST:" + name : $0 }.joined(separator: "\n")
            try fixed.write(toFile: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.moveItem(atPath: file, toPath: new)
        return serverPath(new)
    }

    static func delete(_ p: OTPlaylist) throws {
        guard let file = file(p) else { throw Failure.notEditable }
        backup(file)
        try FileManager.default.removeItem(atPath: file)
    }

    /// Asks OwnTone to rescan, so it sees the changed files.
    static func rescan(_ base: String) async {
        var r = URLRequest(url: URL(string: base + "/api/update")!); r.httpMethod = "PUT"
        _ = try? await URLSession.shared.data(for: r)
    }
}

// MARK: model

extension Model {
    func cratePlaylist(_ id: UUID) -> Int? { cratePlaylists.firstIndex { $0.id == id } }

    /// A Crate playlist's songs that are in the library, in order.
    func songs(_ p: CratePlaylist) -> [LibTrack] { p.keys.compactMap { libraryTrack(key: $0)?.track } }

    /// The iPod's copy of a Crate playlist.
    func podCopy(of p: CratePlaylist) -> PodPlaylist? {
        db?.playlists.first { $0.id == p.podID } ?? db?.playlists.first { samePlaylist($0.name, p.name) }
    }

    func crateNeedsSync(_ p: CratePlaylist) -> Bool {
        guard p.onIPod, db != nil else { return false }
        let ts = songs(p)
        guard let pod = podCopy(of: p) else { return !ts.isEmpty }
        let keys = podKeys
        let byID = podKeyByID
        return !samePlaylist(pod.name, p.name) || ts.contains { !keys.contains($0.key) } || pod.items.compactMap { byID[$0.trackID] } != ts.map(\.key)
    }

    /// Edits to iPod playlists that are still on it.
    var podEditsPending: Int { podEdits.keys.filter { id in db?.playlists.contains { $0.id == id } == true }.count }

    func newPlaylist(_ tracks: [LibTrack] = []) {
        var p = CratePlaylist()
        let taken = Set(cratePlaylists.map { $0.name.lowercased() })
        var n = 2
        while taken.contains(p.name.lowercased()) { p.name = "Untitled Playlist \(n)"; n += 1 }
        var seen = Set<String>()
        p.keys = tracks.map(\.key).filter { seen.insert($0).inserted }
        cratePlaylists.append(p)
        pane = .cratePlaylist(p.id)
        startRename(.crate(p.id))
    }

    func add(_ tracks: [LibTrack], to id: UUID) {
        guard let i = cratePlaylist(id) else { return }
        var seen = Set(cratePlaylists[i].keys)
        let new = tracks.map(\.key).filter { seen.insert($0).inserted }
        cratePlaylists[i].keys += new
        notify(added(new.count, to: cratePlaylists[i].name))
    }

    private func added(_ n: Int, to name: String) -> String {
        n == 0 ? "Already in “\(name)”" : "Added \(n) song\(n == 1 ? "" : "s") to “\(name)”"
    }

    /// Changes the songs of a Crate playlist as shown (songs missing from the library stay, at the end).
    func editCrate(_ id: UUID, _ change: (inout [String]) -> Void) {
        guard let i = cratePlaylist(id) else { return }
        var keys = songs(cratePlaylists[i]).map(\.key)
        let missing = cratePlaylists[i].keys.filter { libraryTrack(key: $0) == nil }
        change(&keys)
        cratePlaylists[i].keys = keys + missing
    }

    // iPod playlists: what they'll be after the next sync

    func podItems(_ p: PodPlaylist) -> [UInt32] { podEdits[p.id]?.trackIDs ?? p.items.map(\.trackID) }
    func podDisplayName(_ p: PodPlaylist) -> String { podEdits[p.id]?.name ?? p.name }

    func editPod(_ p: PodPlaylist, name: String? = nil, _ change: ((inout [UInt32]) -> Void)? = nil) {
        var e = podEdits[p.id] ?? PodPlaylistEdit()
        if let name { e.name = name == p.name ? nil : name }
        if let change {
            var ids = podItems(p); change(&ids)
            e.trackIDs = ids == p.items.map(\.trackID) ? nil : ids
        }
        podEdits[p.id] = e.name == nil && e.trackIDs == nil ? nil : e
    }

    /// The iPod's copies of these library songs.
    func podIDs(for tracks: [LibTrack]) -> [UInt32] {
        let byKey = Dictionary((db?.tracks ?? []).map { ($0.key, $0.id) }, uniquingKeysWith: { a, _ in a })
        return tracks.compactMap { byKey[podKey($0.key)] }
    }

    func add(_ tracks: [LibTrack], toPod p: PodPlaylist) {
        let have = Set(podItems(p))
        let new = podIDs(for: tracks).filter { !have.contains($0) }
        editPod(p) { $0 += new }
        notify(added(new.count, to: podDisplayName(p)) + (new.isEmpty ? "" : " on the next Sync"))
    }

    /// What the iPod saved that the next sync keeps (On-The-Go only with its setting on).
    var podSavedLists: [OnTheGo] { onTheGo.filter { $0.kind != .onTheGo || podSettings.importOnTheGo } }

    /// Playlist edits made on the iPod, applied to the database being synced: a playlist saved there becomes a
    /// Crate playlist (copied back to the iPod), and a Crate playlist edited there takes those songs, so this
    /// sync doesn't put the old ones back.
    func keepFromPod(_ lists: [OnTheGo], in db: inout ITunesDB) {
        let (saved, synced) = db.applyFromPod(lists)
        let key = Dictionary(db.tracks.map { ($0.id, aliases[$0.key] ?? $0.key) }, uniquingKeysWith: { a, _ in a })
        let onPod = Set(key.values)
        for (n, ids) in saved {
            var k = n
            while (cratePlaylists.map(\.name) + db.playlists.map(\.name)).contains(where: { samePlaylist($0, "New Playlist \(k)") }) { k += 1 }
            cratePlaylists.append(CratePlaylist(name: "New Playlist \(k)", keys: ids.compactMap { key[$0] }, onIPod: true))
        }
        for id in synced {
            guard let p = db.playlists.first(where: { $0.id == id }),
                  let c = cratePlaylists.firstIndex(where: { $0.podID == id || samePlaylist($0.name, p.name) }) else { continue }
            // songs that aren't on the iPod (yet) stay, at the end
            cratePlaylists[c].keys = p.items.compactMap { key[$0.trackID] } + cratePlaylists[c].keys.filter { !onPod.contains($0) }
        }
    }

    /// Applies the queued iPod playlist edits to the database being synced.
    func applyPodEdits(_ db: inout ITunesDB) -> Int {
        var n = 0
        let have = Set(db.tracks.map(\.id))
        for i in db.playlists.indices {
            guard let e = podEdits[db.playlists[i].id] else { continue }
            if let name = e.name { db.playlists[i].rename(name) }
            // new items, so their positions are written afresh
            if let ids = e.trackIDs { db.playlists[i].items = ids.filter(have.contains).map { PodPlaylist.Item(trackID: $0) } }
            n += 1
        }
        podEdits = [:]
        return n
    }

    // a server's playlists: OwnTone's (its .m3u files on the share) and the Subsonic server's (through its API)

    func serverEditable(_ p: OTPlaylist) -> Bool {
        if p.subsonicID != nil { return on(.subsonic) }
        return p.spotifyID == nil && on(.ownTone) && OwnToneM3U.file(p) != nil
    }

    func editServerPlaylist(_ p: OTPlaylist, _ change: (inout [OTTrack]) -> Void) async {
        let before = await tracks(for: p)
        var after = before
        change(&after)
        do {
            if let id = p.subsonicID {
                let ids = after.map { subsonic.id(forPath: $0.path) }
                guard !ids.contains(nil) else { notify("Couldn't change “\(p.name)”: some of its songs aren't on the Subsonic server"); return }
                try await subsonic.setSongs(ids.compactMap { $0 }, ofPlaylist: id)
            } else {
                let paths = after.map(\.path), listed = before.map(\.path)
                try await offMain { try OwnToneM3U.write(p, paths: paths, listed: listed) }     // the .m3u is on the share
            }
            playlistTracks[p.id] = after
            if let i = playlists.firstIndex(where: { $0.id == p.id }) { playlists[i].count = after.count }
            if p.subsonicID == nil { Task { await refreshOwnTonePlaylists() } }
        } catch { notify("Couldn't change “\(p.name)”: \(error.localizedDescription)") }
    }

    func add(_ tracks: [LibTrack], toServer p: OTPlaylist) async {
        let subsonicList = p.subsonicID != nil
        // the playlist's own path for a song: the library's for Subsonic (only songs the server has), the server's for OwnTone
        let path = { (t: LibTrack) -> String? in subsonicList ? (self.subsonic.id(forPath: t.path) != nil ? t.path : nil) : OwnToneM3U.serverPath(t.path) }
        let have = Set(await self.tracks(for: p).map(\.path))
        let usable = tracks.compactMap { t in path(t).map { (t, $0) } }
        let new = usable.filter { !have.contains($0.1) }.map { t, path in
            OTTrack(id: 0, title: t.title, artist: t.trackArtist.isEmpty ? t.artist : t.trackArtist, album: t.album, albumArtist: t.artist,
                    dataKind: "file", uri: t.uri, artworkPath: "", lengthMs: t.lengthMs, path: path)
        }
        await editServerPlaylist(p) { $0 += new }
        let skipped = tracks.count - usable.count
        notify(added(new.count, to: p.name) + (skipped > 0 ? " (\(skipped) aren't on the Subsonic server)" : ""))
    }

    /// Rescans, then reads OwnTone's playlists again (a renamed file is a new playlist there).
    func refreshOwnTonePlaylists(select name: String? = nil) async {
        await OwnToneM3U.rescan(ownToneURL)
        try? await Task.sleep(for: .seconds(3))
        guard let fresh = try? await OwnTonePlaylists.all(ownToneURL) else { return }
        let spotify = playlists.filter { $0.spotifyID != nil }, names = Set(spotify.map { $0.name.lowercased() })
        playlists = (spotify + playlists.filter { $0.subsonicID != nil } + fresh.filter { !names.contains($0.name.lowercased()) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for p in fresh { playlistTracks[p.id] = nil }
        if let name, case .playlist = pane, let p = fresh.first(where: { $0.name == name }) { pane = .playlist(p.id) }
    }

    // renaming and deleting, for every kind

    func name(of r: PlaylistRef) -> String {
        switch r {
        case .crate(let id): return cratePlaylist(id).map { cratePlaylists[$0].name } ?? ""
        case .pod(let id): return db?.playlists.first { $0.id == id }.map(podDisplayName) ?? ""
        case .ownTone(let id): return playlists.first { $0.id == id }?.name ?? ""
        }
    }

    func startRename(_ r: PlaylistRef) { renameText = name(of: r); renaming = r }

    func rename(_ r: PlaylistRef, to new: String) async {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != name(of: r) else { return }
        switch r {
        case .crate(let id):
            if let i = cratePlaylist(id) { cratePlaylists[i].name = n }
        case .pod(let id):
            if let p = db?.playlists.first(where: { $0.id == id }) { editPod(p, name: n) }
        case .ownTone(let id):
            guard let p = playlists.first(where: { $0.id == id }) else { return }
            if let sid = p.subsonicID {
                do {
                    try await subsonic.renamePlaylist(sid, to: n)
                    if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].name = n }
                } catch { notify("Couldn't rename “\(p.name)”: \(error.localizedDescription)") }
                return
            }
            do {
                let path = try await offMain { try OwnToneM3U.rename(p, to: n) }
                if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].path = path; playlists[i].name = n }
                await refreshOwnTonePlaylists(select: n)
            } catch { notify("Couldn't rename “\(p.name)”: \(error.localizedDescription)") }
        }
    }

    func deletePlaylist(_ r: PlaylistRef) async {
        switch r {
        case .crate(let id):
            guard let i = cratePlaylist(id) else { return }
            if cratePlaylists[i].onIPod, let pod = podCopy(of: cratePlaylists[i]) { playlistsToRemove.insert(pod.id) }
            cratePlaylists.remove(at: i)
            if pane == .cratePlaylist(id) { pane = .albums }
        case .pod(let id):
            podEdits[id] = nil
            playlistsToRemove.insert(id)
        case .ownTone(let id):
            guard let p = playlists.first(where: { $0.id == id }) else { return }
            do {
                if let sid = p.subsonicID { try await subsonic.deletePlaylist(sid) }
                else { try await offMain { try OwnToneM3U.delete(p) } }
                playlists.removeAll { $0.id == id }
                if pane == .playlist(id) { pane = .albums }
                if p.subsonicID == nil { Task { await refreshOwnTonePlaylists() } }
            } catch { notify("Couldn't delete “\(p.name)”: \(error.localizedDescription)") }
        }
    }
}

// MARK: views

/// The rename and delete questions, for the whole window.
struct PlaylistDialogs: ViewModifier {
    @EnvironmentObject var model: Model

    func body(content: Content) -> some View {
        let deleting = model.confirmDeletePlaylist
        content
            .alert("Rename Playlist", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
                   presenting: model.renaming) { r in
                TextField("Name", text: $model.renameText)
                Button("Rename") { Task { await model.rename(r, to: model.renameText) } }
                Button("Cancel", role: .cancel) {}
            } message: { r in
                switch r {
                case .crate: Text("")
                case .pod: Text("The iPod's playlist is renamed on the next Sync.")
                case .ownTone(let id):
                    Text(model.playlists.first { $0.id == id }?.subsonicID != nil ? "Renames it on the Subsonic server." : "Renames its .m3u file on the share.")
                }
            }
            .confirmationDialog("Delete “\(deleting.map(model.name) ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { model.confirmDeletePlaylist = nil } }),
                                presenting: deleting) { r in
                Button("Delete", role: .destructive) { Task { await model.deletePlaylist(r) } }
            } message: { r in
                switch r {
                case .crate(let id):
                    let onIPod = model.cratePlaylist(id).map { model.cratePlaylists[$0].onIPod } ?? false
                    Text("The songs stay in your library." + (onIPod ? " Its copy on the iPod goes on the next Sync." : ""))
                case .pod: Text("It's removed from the iPod on the next Sync.")
                case .ownTone(let id):
                    Text(model.playlists.first { $0.id == id }?.subsonicID != nil ? "Deletes it from the Subsonic server. The songs stay."
                                                                                  : "Deletes its .m3u file from the share. A copy is kept in Crate's Playlist Backups folder.")
                }
            }
    }
}

/// "Add to Playlist" for library songs: a new playlist, Crate's, OwnTone's and (for songs on it) the iPod's.
struct AddToPlaylistMenu: View {
    @EnvironmentObject var model: Model
    var tracks: [LibTrack]

    var body: some View {
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist", systemImage: "plus") { model.newPlaylist(tracks) }
            if !model.cratePlaylists.isEmpty {
                Divider()
                ForEach(model.cratePlaylists) { p in Button(p.name) { model.add(tracks, to: p.id) } }
            }
            ForEach(["Subsonic", "OwnTone"], id: \.self) { source in
                let lists = model.playlists.filter { model.serverEditable($0) && model.source(of: $0) == source }
                if !lists.isEmpty {
                    Section(source) {
                        ForEach(lists) { p in Button(p.name) { Task { await model.add(tracks, toServer: p) } } }
                    }
                }
            }
            if let db = model.db, !db.playlists.isEmpty, !model.podIDs(for: tracks).isEmpty {
                Section("On \(model.podName)") {
                    ForEach(db.playlists) { p in Button(model.podDisplayName(p)) { model.add(tracks, toPod: p) } }
                }
            }
        }
    }
}

extension View {
    /// Drag a playlist row onto another to move it there.
    func reorderable(_ index: Int, move: @escaping (Int, Int) -> Void) -> some View {
        draggable("crate-row:\(index)")
            .dropDestination(for: String.self) { items, _ in
                guard let s = items.first, s.hasPrefix("crate-row:"), let from = Int(s.dropFirst(10)) else { return false }
                move(from, index)
                return true
            }
    }
}

/// Move and remove, in a playlist row's menu.
struct PlaylistRowActions: View {
    var index, count: Int
    var move: (Int, Int) -> Void
    var remove: (Int) -> Void

    var body: some View {
        Button("Move to Top", systemImage: "arrow.up.to.line") { move(index, 0) }.disabled(index == 0)
        Button("Move to Bottom", systemImage: "arrow.down.to.line") { move(index, count - 1) }.disabled(index == count - 1)
        Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { remove(index) }
    }
}

/// A playlist page's song row.
struct PlaylistSongRow: View {
    var number: Int
    var title, detail: String
    var lengthMs: Int
    var onIPod = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if onIPod { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("On the iPod") }
            Text(lengthMs > 0 ? duration(lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(number % 2 == 0 ? Color.primary.opacity(0.04) : .clear)
        .contentShape(.rect)
    }
}

/// Up to four album covers in a 2×2 square.
struct AlbumMosaic: View {
    @EnvironmentObject var model: Model
    var albums: [Album]
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 2
            if albums.count < 4 {
                Cover(image: albums.first.flatMap { model.artwork[$0.id] }, seed: albums.first?.id ?? "playlist")
            } else {
                VStack(spacing: 0) {
                    ForEach(0..<2) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<2) { c in
                                Cover(image: model.artwork[albums[r * 2 + c].id], seed: albums[r * 2 + c].id).frame(width: s, height: s).clipped()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CratePlaylistView: View {
    @EnvironmentObject var model: Model
    var id: UUID

    var body: some View {
        if let i = model.cratePlaylist(id) {
            let p = model.cratePlaylists[i]
            let ts = model.songs(p), keys = model.podKeys
            var seen = Set<String>()
            let covers = ts.compactMap { model.libraryTrack(key: $0.key)?.album }.filter { seen.insert($0.id).inserted }.prefix(4)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .bottom, spacing: 24) {
                        AlbumMosaic(albums: Array(covers))
                            .frame(width: 200, height: 200).clipShape(.rect(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Playlist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(p.name).font(.largeTitle.bold()).lineLimit(2)
                                .onTapGesture(count: 2) { model.startRename(.crate(id)) }
                                .help("Double-click to rename")
                            Text("\(ts.count) songs · \(totalDuration(ts.map(\.lengthMs).reduce(0, +))) · \(ts.filter { keys.contains($0.key) }.count) on the iPod")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Toggle("Keep on the iPod", isOn: Binding(get: { p.onIPod }, set: { v in
                                    if let i = model.cratePlaylist(id) { model.cratePlaylists[i].onIPod = v }
                                }))
                                .toggleStyle(.switch)
                                Button("Play", systemImage: "play.fill") { model.player.play(ts) }.buttonStyle(.glass).disabled(ts.isEmpty)
                                Button { model.startRename(.crate(id)) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.glass).help("Rename…")
                                Button { model.confirmDeletePlaylist = .crate(id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.glass).help("Delete Playlist…")
                            }
                            .padding(.top, 8)
                        }
                        Spacer(minLength: 0)
                    }
                    if ts.isEmpty {
                        ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                               description: Text("Right-click an album or songs and choose Add to Playlist."))
                    } else {
                        let move = { (a: Int, b: Int) in model.editCrate(id) { $0.moveItem(a, to: b) } }
                        let remove = { (n: Int) in model.editCrate(id) { $0.remove(at: n) } }
                        VStack(spacing: 0) {
                            ForEach(Array(ts.enumerated()), id: \.offset) { n, t in
                                PlaylistSongRow(number: n + 1, title: t.title, detail: "\(t.trackArtist.isEmpty ? t.artist : t.trackArtist) — \(t.album)",
                                                lengthMs: t.lengthMs, onIPod: keys.contains(t.key))
                                    .onTapGesture(count: 2) { model.player.play(ts, from: n) }
                                    .reorderable(n, move: move)
                                    .contextMenu {
                                        Button("Play", systemImage: "play.fill") { model.player.play(ts, from: n) }
                                        if let a = model.libraryTrack(key: t.key)?.album {
                                            Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(a)) }
                                        }
                                        Divider()
                                        PlaylistRowActions(index: n, count: ts.count, move: move, remove: remove)
                                    }
                            }
                        }
                        .clipShape(.rect(cornerRadius: 14))
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        Text("Drag songs to change the order.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(28).padding(.bottom, 60)
            }
            .pageTitle(p.name)
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
        }
    }
}
