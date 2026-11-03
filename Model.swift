import SwiftUI
import AppKit

/// What the detail column shows; the iPod's state is shown on every item as well.
enum Pane: Hashable {
    case recent, albums, artists, songs, health, review, ipod
    case smart(UUID)
    case spotify, appleMusic, soulseek, downloads, youtube
    case playlist(Int), podPlaylist(UInt64)
}

/// Pages pushed on top of a pane.
enum Route: Hashable { case album(Album), artist(String) }

/// An album artist with their albums (compilations under "Various Artists").
struct Artist: Identifiable, Hashable {
    var id: String { name.lowercased() }
    var name: String
    var albums: [Album]
    var trackCount: Int { albums.map(\.tracks.count).reduce(0, +) }
}

enum AlbumFilter: String, CaseIterable { case all = "All", onIPod = "On iPod", notOnIPod = "Not on iPod" }
enum AlbumSort: String, CaseIterable { case artist = "Artist", title = "Title", year = "Year", added = "Recently Added" }

/// Something Crate is busy with, shown in the activity bar and the Activity popover.
struct Job: Identifiable, Hashable {
    enum State: Hashable { case queued, running, done, failed(String) }
    var id = UUID()
    var title: String
    var detail = ""
    var icon = "gearshape"
    var progress: Double?
    var state = State.queued
    var finished: Date?
    var started = Date()
    var source: PluginID?             // set for downloads, which the Downloads pane lists
    var subtitle = ""
    var art: URL?
    var active: Bool { state == .queued || state == .running }
}

/// What the next Sync will do, shown before it starts.
struct SyncPlan {
    var addAlbums: [Album] = []
    var addSongs = 0, convertSongs = 0
    var removeAlbums: [Album] = []
    var removeSongs = 0
    var playlistsAdd: [String] = [], playlistsRemove: [String] = []
    var onTheGo = 0
    var rename: String?
    var bytesIn: Int64 = 0, bytesOut: Int64 = 0
}

struct SyncReport {
    var added = 0, removed = 0, playlists = 0
    var changedElsewhere = 0, playCounts = 0
    var calendars = ""
    var failures: [String] = []
    var error: String?
    var seconds = 0.0
}

@MainActor
final class Model: ObservableObject {
    // core settings
    @AppStorage("ownToneURL") var ownToneURL = "http://host:3689"
    @AppStorage("discogsToken") var discogsToken = ""
    @AppStorage("extraFolders") var foldersText = "/path/to/music"
    @AppStorage("importFolder") var importFolder = "/path/to/music/Added"

    @Published var plugins: Set<PluginID> = PluginStore.load() { didSet { PluginStore.save(plugins) } }
    let slsk = Slskd()
    let spotifyAPI = SpotifyAPI()
    let player = Player()
    let yt = YouTube()

    // library
    @Published var libTracks: [LibTrack] = []
    @Published var albums: [Album] = []
    @Published var artwork: [Album.ID: NSImage] = [:]
    @Published var artistArt: [Artist.ID: NSImage] = [:]
    @Published var metadata: [String: MBRelease] = MetadataStore.load()
    @Published var loading = false
    @Published var libraryError: String?

    // iPod
    @Published var ipod: IPodInfo?
    @Published var db: ITunesDB? {
        didSet { podStats = Dictionary((db?.tracks ?? []).map { ($0.key, $0.stat) }, uniquingKeysWith: { a, b in a.plays >= b.plays ? a : b }) }
    }
    @Published var podStats: [String: PodStat] = [:]
    @Published var smartPlaylists: [SmartPlaylist] = SmartStore.load()
    @Published var smartPending = 0
    @Published var editSmart: SmartPlaylist?
    @Published var podSettings = PodSettings() { didSet { if let i = ipod, podSettings != oldValue { PodSettings.save(podSettings, serial: i.key) } } }
    @Published var connected = false
    @Published var lastSeen: Date?
    @Published var toAdd: Set<Album.ID> = [] { didSet { savePending() } }
    @Published var toRemove: Set<Album.ID> = [] { didSet { savePending() } }
    @Published var playlistsToAdd: Set<OTPlaylist.ID> = [] { didSet { savePending() } }
    @Published var playlistsToRemove: Set<PodPlaylist.ID> = [] { didSet { savePending() } }
    @Published var pendingName: String? { didSet { savePending() } }
    private var restoring = false
    @Published var onTheGo: [OnTheGo] = []
    @Published var orphans: [URL]?
    @Published var podCheck: PodCheck?
    @Published var history: [PodSample] = []

    // sync
    @Published var showSync = false
    @Published var plan: SyncPlan?
    @Published var syncing = false
    @Published var syncPhase = ""
    @Published var syncDone = 0
    @Published var syncTotal = 0
    @Published var syncCurrent = ""
    @Published var report: SyncReport?

    // navigation
    @Published var pane: Pane? = .albums { didSet { if pane != oldValue { path = [] } } }
    @Published var path: [Route] = []
    @Published var search = ""
    @Published var albumFilter = AlbumFilter.all
    @Published var albumSort = AlbumSort.artist
    @AppStorage("albumView") var albumView = "grid"          // "grid", "flow" or "list"
    @Published var lookupAlbum: Album?
    @Published var editAlbum: Album?
    @Published var batchAlbums: [Album]?
    @Published var showMissing = false
    @Published var organize: [Album]?
    @Published var artistInfo: [String: ArtistInfo] = ArtistLookup.load()
    @Published var artistLoading: Set<String> = []
    @Published var quickLook: URL?
    @Published var flowAlbum: Album?          // the album in the middle of Cover Flow
    @Published var focusSearch = 0

    // OwnTone / Spotify
    @Published var playlists: [OTPlaylist] = []
    @Published var playlistTracks: [Int: [OTTrack]] = [:]
    @Published var spotify: [SpotifyAlbum] = []
    @Published var onlyMissing = true

    // Apple Music
    @Published var amAlbums: [AMAlbum] = []
    @Published var amLoading = false
    @Published var amError: String?
    @Published var amArt: [AMAlbum.ID: URL] = [:]
    @Published var amHideImported = true
    @Published var amHidden: Set<AMAlbum.ID> = []     // snapshot, so imported tiles don't vanish mid-queue
    @Published var amQueue: [(album: AMAlbum, toIPod: Bool, job: UUID)] = []
    private var amRunning = false

    // activity
    @Published var jobs: [Job] = []
    @Published var message = ""
    private var messageTask: Task<Void, Never>?

    @Published var dropTarget: DropTarget?
    enum DropTarget { case library, ipod }

    private var observers: [NSObjectProtocol] = []
    private var index: [String: (album: Album, track: LibTrack)] = [:]

    static weak var shared: Model?

    init() {
        Model.shared = self
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.loadIPod() }
            })
        }
        slsk.onFinished = { [weak self] job, folder in Task { await self?.importDownloaded(job, folder: folder) } }
        yt.onFiles = { [weak self] files, id in
            guard let self, let j = self.yt.jobs.first(where: { $0.id == id }) else { return }
            await self.importFiles(files, toIPod: false, title: "Importing \(j.title)")
        }
    }

    // MARK: plugins

    func on(_ p: PluginID) -> Bool { plugins.contains(p) && (p.requires.map { on($0) } ?? true) }

    func setPlugin(_ p: PluginID, _ enabled: Bool) {
        if enabled { plugins.insert(p); if let r = p.requires { plugins.insert(r) } }
        else { plugins.remove(p) }

        if case .playlist = pane, !on(.ownTone) { pane = .albums }
        Task { await reload() }
    }

    var folders: [String] {
        get { foldersText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { foldersText = newValue.joined(separator: "\n"); objectWillChange.send() }
    }

    // MARK: activity

    func notify(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { message = "" } }
    }

    @discardableResult
    func startJob(_ title: String, icon: String, detail: String = "", queued: Bool = false) -> UUID {
        let j = Job(title: title, detail: detail, icon: icon, state: queued ? .queued : .running)
        jobs.insert(j, at: 0)
        return j.id
    }

    func updateJob(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        if !jobs[i].active, jobs[i].finished == nil { jobs[i].finished = Date() }
    }

    func finishJob(_ id: UUID, _ detail: String, failed: Bool = false) {
        updateJob(id) { $0.detail = detail; $0.progress = nil; $0.state = failed ? .failed(detail) : .done }
        jobs = Array(jobs.prefix(40))
    }

    var activeJobs: [Job] { jobs.filter(\.active) }

    // MARK: library

    var podKeys: Set<String> { Set(db?.tracks.map(\.key) ?? []) }

    var podAlbums: [Album] {
        let ts = (db?.tracks ?? []).map {
            LibTrack(title: $0.title, artist: $0.artist, album: $0.album, genre: $0.genre, trackNumber: $0.trackNumber,
                     discNumber: 0, year: 0, lengthMs: $0.lengthMs, path: $0.relativePath)
        }
        return LibraryLoader.albums(ts)
    }

    /// Library albums plus albums that are only on the iPod (so they can be opened and removed).
    var allAlbums: [Album] {
        let lib = Set(albums.map(\.id))
        return (albums + podAlbums.filter { !lib.contains($0.id) })
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    var artists: [Artist] {
        Dictionary(grouping: allAlbums) { $0.artist.lowercased() }.values
            .map { Artist(name: $0[0].artist, albums: $0.sorted { ($0.year, $0.title) < ($1.year, $1.title) }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var recentlyAdded: [Album] {
        albums.filter { $0.added != nil }.sorted { $0.added! > $1.added! }
    }

    func artistMark(_ a: Artist) -> SyncMark {
        let marks = a.albums.map { mark($0) }
        if marks.allSatisfy({ $0 == .onIPod }) { return .onIPod }
        if marks.contains(.adding) { return .adding }
        if marks.contains(.removing) { return .removing }
        return marks.contains { $0 == .onIPod || $0 == .partial } ? .partial : .none
    }

    func isPodOnly(_ a: Album) -> Bool { !albums.contains { $0.id == a.id } }

    private static func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    private func rebuild() {
        var seen = Set<String>()
        libTracks = libTracks.filter { seen.insert($0.path).inserted }
        albums = LibraryLoader.albums(libTracks)
        index = [:]
        for a in albums { for t in a.tracks {
            index[t.key] = (a, t)
            let k = "~" + Self.loose(t.album) + "|" + Self.loose(t.title)
            if index[k] == nil { index[k] = (a, t) }
        } }
    }

    /// The file for a playlist track: same album and title, or the same once punctuation is ignored.
    func libraryTrack(for t: OTTrack) -> (album: Album, track: LibTrack)? {
        index[t.key] ?? index["~" + Self.loose(t.album) + "|" + Self.loose(t.title)]
    }

    enum Availability { case onIPod, file, streamOnly }
    func availability(_ t: OTTrack) -> Availability {
        let keys = podKeys
        if keys.contains(t.key) { return .onIPod }
        guard let lt = libraryTrack(for: t) else { return .streamOnly }
        return keys.contains(lt.track.key) ? .onIPod : .file
    }

    func podPlaylist(for p: OTPlaylist) -> PodPlaylist? { db?.playlists.first { $0.name == p.name } }

    /// iPod playlists that don't come from an OwnTone playlist (On-The-Go, made elsewhere).
    var podOnlyPlaylists: [PodPlaylist] {
        let names = Set(playlists.map(\.name) + smartPlaylists.map(\.name))
        return (db?.playlists ?? []).filter { !names.contains($0.name) }
    }

    func tracks(for p: OTPlaylist) async -> [OTTrack] {
        if let t = playlistTracks[p.id] { return t }
        let t = p.spotifyID != nil ? ((try? await spotifyAPI.tracks(p.spotifyID!)) ?? [])
            : ((try? await OwnTonePlaylists.tracks(p.id, base: ownToneURL)) ?? [])
        playlistTracks[p.id] = t
        return t
    }

    func reload() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let job = startJob("Loading library", icon: "square.stack")
        loadIPod()
        var tracks: [LibTrack] = []
        libraryError = nil
        if on(.ownTone) {
            updateJob(job) { $0.detail = "Reading OwnTone" }
            do { tracks = try await LibraryLoader.fromOwnTone(ownToneURL) }
            catch { libraryError = "OwnTone unreachable: \(error.localizedDescription)" }
        }
        // the import folder is scanned directly too, so new files show up before OwnTone has indexed them
        for f in folders + [importFolder] where !f.isEmpty {
            updateJob(job) { $0.detail = "Scanning \((f as NSString).lastPathComponent)" }
            tracks += await LibraryLoader.scan(f, skipping: Set(tracks.map(\.path)))
        }
        libTracks = tracks
        rebuild()
        playlistTracks = [:]
        var lists: [OTPlaylist] = on(.ownTone) ? ((try? await OwnTonePlaylists.all(ownToneURL)) ?? []) : []
        spotify = []
        if on(.spotify) {
            if spotifyAPI.direct {
                if spotifyAPI.connected {
                    updateJob(job) { $0.detail = "Reading Spotify" }
                    do {
                        spotify = try await spotifyAPI.savedAlbums()
                        let own = try await spotifyAPI.playlists()
                        let names = Set(own.map { $0.name.lowercased() })
                        lists = lists.filter { !names.contains($0.name.lowercased()) } + own    // OwnTone mirrors the same playlists
                        spotifyAPI.error = nil
                    } catch { spotifyAPI.error = error.localizedDescription }
                }
            } else if on(.ownTone) {
                spotify = (try? await SpotifyLibrary.albums(ownToneURL)) ?? []
            }
        }
        playlists = lists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        finishJob(job, "\(libTracks.count) songs in \(albums.count) albums")
        refreshSmartPending()
        await loadArtwork()
    }

    private func loadArtwork() async {
        for ar in artists where artistArt[ar.id] == nil {
            if let d = LibraryLoader.artistImage(ar), let img = NSImage(data: d) { artistArt[ar.id] = img }
        }
        for a in albums where artwork[a.id] == nil {
            if let d = await LibraryLoader.artwork(for: a), let img = NSImage(data: d) { artwork[a.id] = img }
        }
    }

    /// Reads these files' tags again after they were edited (the album may have a new name now).
    func refreshFiles(_ paths: [String], cover: Data? = nil, oldID: Album.ID? = nil) async {
        var fresh: [String: LibTrack] = [:]
        for p in paths {
            let parts = p.split(separator: "/").suffix(3).joined(separator: "/")
            var t = await LibraryLoader.track(p, relative: parts)
            if let old = libTracks.first(where: { $0.path == p }) { t.uri = old.uri; t.added = old.added }
            fresh[p] = t
        }
        libTracks = libTracks.map { fresh[$0.path] ?? $0 }
        let oldArt = oldID.flatMap { artwork[$0] }
        rebuild()
        if let newID = fresh.values.first?.album.lowercased() {
            if let d = cover, let img = NSImage(data: d) { artwork[newID] = img } else if artwork[newID] == nil { artwork[newID] = oldArt }
        }
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
    }

    /// Files the organiser moved: same songs, new paths (the iPod's copies are matched on tags, not paths).
    func moved(_ moves: [FileMove]) async {
        let to = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        libTracks = libTracks.map { t in var n = t; if let p = to[t.path] { n.path = p }; return n }
        let art = artwork
        rebuild()
        artwork = art
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
    }

    /// Adds freshly imported files without rescanning everything.
    func addToLibrary(_ tracks: [LibTrack]) async {
        libTracks += tracks
        rebuild()
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
        await loadArtwork()
    }

    /// Artwork paths are relative to OwnTone, Spotify's are full URLs.
    func artURL(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        guard !path.isEmpty else { return nil }
        return URL(string: ownToneURL + (path.hasPrefix("/") ? "" : "/") + path.replacingOccurrences(of: "./", with: ""))
    }

    /// Plays on OwnTone when it's on (it can play Spotify too), otherwise opens the Spotify app.
    func playURIs(_ uris: [String]) async {
        if on(.ownTone) { await OwnTonePlaylists.play(uris, base: ownToneURL) }
        else if let first = uris.first, first.hasPrefix("spotify:") { SpotifyAPI.open(first) }
    }

    /// Plays on the chosen output: this Mac, or OwnTone's speakers.
    func play(_ a: Album, from start: Int = 0) async {
        if player.output == "owntone", on(.ownTone) {
            let uris = a.tracks.dropFirst(start).map(\.uri).filter { !$0.isEmpty }
            if uris.isEmpty { notify("\(a.title) isn't in OwnTone's library yet"); return }
            await OwnTonePlaylists.play(uris, base: ownToneURL)
        } else if isPodOnly(a) {
            notify("\(a.title) is only on the iPod")
        } else {
            player.play(a.tracks, from: start)
        }
    }

    // MARK: iPod

    enum State { case none, partial, onIPod }
    func state(_ a: Album) -> State {
        let keys = podKeys
        let n = a.tracks.filter { keys.contains($0.key) }.count
        return n == 0 ? .none : n == a.tracks.count ? .onIPod : .partial
    }

    var podName: String { pendingName ?? db?.name ?? "iPod" }

    var pendingCount: Int {
        toAdd.count + toRemove.count + playlistsToAdd.count + playlistsToRemove.count
            + (podSettings.importOnTheGo ? onTheGo.count : 0) + (pendingName == nil ? 0 : 1) + smartPending
    }

    var usedFraction: Double {
        guard let i = ipod, i.capacity > 0 else { return 0 }
        return Double(i.used) / Double(i.capacity)
    }

    var musicBytes: Int64 { Int64((db?.tracks ?? []).map(\.size).reduce(0, +)) }

    /// Finds the iPod; when it's unplugged, the last one seen is shown from the cache (read only).
    func loadIPod() {
        let wasConnected = connected, had = ipod?.key
        if let i = IPodInfo.find() {
            ipod = i; connected = true; lastSeen = nil
            if let d = try? Data(contentsOf: i.dbURL), let parsed = try? ITunesDB.read(d) { db = parsed; PodCache.saveDB(from: i) }
            else { db = .empty(name: i.mount.lastPathComponent) }
            onTheGo = OnTheGo.load(i, db: db!)
            PodHistory.record(i, db: db!)
            history = PodHistory.load(i.key)
            refreshSmartPending()
        } else if let c = PodCache.load() {
            ipod = c.info; connected = false; lastSeen = c.seen
            history = PodHistory.load(c.info.key)
            db = PodCache.loadDB() ?? db; onTheGo = []; orphans = nil
        } else {
            ipod = nil; db = nil; connected = false; onTheGo = []; orphans = nil
            return
        }
        guard let i = ipod else { return }
        if had != i.key {
            podSettings = PodSettings.load(i.key); orphans = nil
            restorePending()
        }
        savePending()
        if connected, !wasConnected, had != nil || lastSeenAtLaunch, podSettings.syncOnConnect, pendingCount > 0, !syncing {
            notify("\(podName) connected – syncing \(pendingCount) queued changes")
            reviewSync()
            Task { await sync() }
        }
        lastSeenAtLaunch = true
    }

    /// Plugging the iPod in later in the session starts the queued sync, not the very first scan at launch.
    private var lastSeenAtLaunch = false

    private func savePending() {
        guard !restoring, let i = ipod else { return }
        let old = PodCache.load()
        PodCache(info: i, seen: connected ? Date() : (old?.seen ?? Date()), toAdd: toAdd.sorted(), toRemove: toRemove.sorted(),
                 playlistsToAdd: playlistsToAdd.sorted(), playlistsToRemove: playlistsToRemove.sorted(), pendingName: pendingName).save()
    }

    private func restorePending() {
        guard let c = PodCache.load(), c.info.key == ipod?.key else { return }
        restoring = true; defer { restoring = false }
        toAdd = Set(c.toAdd); toRemove = Set(c.toRemove)
        playlistsToAdd = Set(c.playlistsToAdd); playlistsToRemove = Set(c.playlistsToRemove)
        pendingName = c.pendingName
    }

    func addAll(_ a: Artist) { for al in a.albums where !isPodOnly(al) && state(al) != .onIPod { toAdd.insert(al.id) } }
    func removeAll(_ a: Artist) { for al in a.albums where state(al) != .none { toRemove.insert(al.id) } }

    func toggleAdd(_ p: OTPlaylist) {
        if playlistsToAdd.contains(p.id) { playlistsToAdd.remove(p.id) } else { playlistsToAdd.insert(p.id) }
    }
    func toggleRemove(_ p: PodPlaylist) {
        if playlistsToRemove.contains(p.id) { playlistsToRemove.remove(p.id) } else { playlistsToRemove.insert(p.id) }
    }
    func toggleAdd(_ a: Album) {
        if toAdd.contains(a.id) { toAdd.remove(a.id) } else if state(a) != .onIPod { toAdd.insert(a.id) }
    }
    func toggleRemove(_ a: Album) {
        if toRemove.contains(a.id) { toRemove.remove(a.id) } else { toRemove.insert(a.id) }
    }

    /// The album that ⌘I, ⌘Y and friends act on: the open album page, else Cover Flow's middle one.
    var focusAlbum: Album? {
        if case .album(let a)? = path.last { return albums.first { $0.id == a.id } ?? a }
        return pane == .albums && search.isEmpty ? flowAlbum : nil
    }

    /// Shows an album's cover in Quick Look (the cover file, or the embedded art saved to a temp file).
    func quickLookCover(_ a: Album) {
        let fm = FileManager.default
        if let n = ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "front.jpg"].first(where: { fm.fileExists(atPath: a.folder + "/" + $0) }) {
            quickLook = URL(fileURLWithPath: a.folder + "/" + n); return
        }
        guard let img = artwork[a.id], let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = fm.temporaryDirectory.appendingPathComponent(Organizer.clean(a.title) + ".png")
        try? png.write(to: url)
        quickLook = url
    }

    func deleteSmart(_ p: SmartPlaylist) {
        smartPlaylists.removeAll { $0.id == p.id }
        saveSmart()
        if pane == .smart(p.id) { pane = .albums }
    }

    func discardChanges() {
        toAdd = []; toRemove = []; playlistsToAdd = []; playlistsToRemove = []; pendingName = nil
    }

    func scanOrphans() async {
        guard let ipod, let db, connected else { return }
        let c = await Task.detached { Syncer.check(ipod, db: db) }.value
        podCheck = c; orphans = c.stray
    }

    /// Takes songs whose file is gone out of the iPod's database (read fresh, written right away).
    func removeMissing() {
        guard let ipod, connected, let gone = podCheck?.missing, !gone.isEmpty,
              var fresh = (try? Data(contentsOf: ipod.dbURL)).flatMap({ try? ITunesDB.read($0) }) else { return }
        let ids = Set(gone.map(\.id))
        fresh.tracks.removeAll { ids.contains($0.id) }
        do { try Syncer.write(fresh, to: ipod); notify("Removed \(gone.count) songs without a file from the iPod's list") }
        catch { notify("Writing the database failed: \(error.localizedDescription)") }
        podCheck?.missing = []
        loadIPod()
    }

    func deleteOrphans() {
        let n = orphans?.count ?? 0
        orphans?.forEach { try? FileManager.default.removeItem(at: $0) }
        orphans = []
        loadIPod()
        notify("Removed \(n) stray files from the iPod")
    }

    var hasBackup: Bool { connected && (ipod.map { FileManager.default.fileExists(atPath: $0.backupURL.path) } ?? false) }

    /// Puts iTunesDB.crate-backup back (the database from before the last Crate write).
    func restoreBackup() {
        guard let i = ipod, connected else { return }
        do {
            _ = try ITunesDB.read(Data(contentsOf: i.backupURL))
            let tmp = i.dbURL.appendingPathExtension("restore")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: i.backupURL, to: tmp)
            _ = try FileManager.default.replaceItemAt(i.dbURL, withItemAt: tmp)
            loadIPod()
            notify("Restored the previous iPod database")
        } catch { notify("Restore failed: \(error.localizedDescription)") }
    }

    // MARK: sync

    /// Opens the sync sheet with what will happen.
    func reviewSync() {
        report = nil
        plan = makePlan()
        showSync = true
        Task { await estimateSizes() }
    }

    private func addWork(have: Set<String>) -> [(Album, LibTrack)] {
        albums.filter { toAdd.contains($0.id) }.flatMap { a in a.tracks.filter { !have.contains($0.key) }.map { (a, $0) } }
    }

    func makePlan() -> SyncPlan {
        var p = SyncPlan()
        let have = podKeys
        p.addAlbums = albums.filter { toAdd.contains($0.id) }
        let work = addWork(have: have)
        p.addSongs = work.count
        p.convertSongs = work.filter { podSettings.needsConversion($0.1) }.count
        p.removeAlbums = podAlbums.filter { toRemove.contains($0.id) }
        let removeKeys = Set(p.removeAlbums.flatMap { $0.tracks.map(\.key) })
        p.removeSongs = (db?.tracks ?? []).filter { removeKeys.contains($0.key) }.count
        p.bytesOut = Int64((db?.tracks ?? []).filter { removeKeys.contains($0.key) }.map(\.size).reduce(0, +))
        p.playlistsAdd = playlists.filter { playlistsToAdd.contains($0.id) }.map(\.name) + smartPlaylists.filter(smartNeedsSync).map(\.name)
        let smartWork = smartPlaylists.filter(\.onIPod).flatMap(evaluate).filter { !have.contains($0.key) }
        p.addSongs += Set(smartWork.map(\.path)).subtracting(work.map(\.1.path)).count
        p.playlistsRemove = (db?.playlists ?? []).filter { playlistsToRemove.contains($0.id) }.map(\.name)
        p.onTheGo = podSettings.importOnTheGo ? onTheGo.count : 0
        p.rename = pendingName
        return p
    }

    private func estimateSizes() async {
        let work = addWork(have: podKeys).map(\.1), s = podSettings
        let bytes = await Task.detached { () -> Int64 in
            work.reduce(Int64(0)) { sum, t in
                if s.needsConversion(t) { return sum + Int64(t.lengthMs) * Int64(s.aacKbps) / 8 }
                return sum + Int64((try? FileManager.default.attributesOfItem(atPath: t.path))?[.size] as? Int ?? 0)
            }
        }.value
        plan?.bytesIn = bytes
    }

    func sync() async {
        guard let ipod, let known = db, connected, !syncing else { return }
        syncing = true; report = nil
        // Start from what's on the iPod right now, not what Crate read earlier: anything another app
        // (or the iPod itself) changed in the meantime is kept, and only the queued changes are applied.
        guard var db = (try? Data(contentsOf: ipod.dbURL)).flatMap({ try? ITunesDB.read($0) }) ?? (FileManager.default.fileExists(atPath: ipod.dbURL.path) ? nil : known) else {
            report = SyncReport(error: "Couldn't read the iPod's database; nothing was changed")
            syncing = false
            return
        }
        let before = Set(known.tracks.map(\.key)), now = Set(db.tracks.map(\.key))
        let elsewhere = before.symmetricDifference(now).count
            + Set(known.playlists.map(\.name)).symmetricDifference(Set(db.playlists.map(\.name))).count
        var playCountsMerged = false
        let start = Date()
        var rep = SyncReport()
        defer {
            rep.seconds = Date().timeIntervalSince(start)
            report = rep; syncing = false; syncCurrent = ""
            loadIPod()
            if rep.error == nil, podSettings.ejectAfterSync, connected { eject() }
        }
        syncPhase = "Preparing"; syncDone = 0; syncTotal = 0
        rep.changedElsewhere = elsewhere
        if let entries = (try? Data(contentsOf: PlayCounts.url(ipod))).flatMap(PlayCounts.parse), let n = db.mergePlayCounts(entries) {
            rep.playCounts = n; playCountsMerged = true
        }
        if let n = pendingName, !n.isEmpty { db.name = n }
        let otg = podSettings.importOnTheGo ? onTheGo : []
        db.importOnTheGo(otg)
        rep.playlists += otg.count
        db.playlists.removeAll { playlistsToRemove.contains($0.id) }

        syncPhase = "Removing songs"
        let removeKeys = Set(podAlbums.filter { toRemove.contains($0.id) }.flatMap { $0.tracks.map(\.key) })
        for t in db.tracks where removeKeys.contains(t.key) { Syncer.remove(t, from: ipod); rep.removed += 1 }
        db.tracks.removeAll { removeKeys.contains($0.key) }
        let left = Set(db.tracks.map(\.id))     // new tracks may reuse the ids of removed ones
        for i in db.playlists.indices { db.playlists[i].items.removeAll { !left.contains($0.trackID) } }
        // write now (before the track order changes again), so On-The-Go lists and play counts can't be imported twice
        if !otg.isEmpty || rep.removed > 0 || pendingName != nil || playCountsMerged {
            do {
                try Syncer.write(db, to: ipod)
                otg.forEach { try? FileManager.default.removeItem(at: $0.url) }
                if playCountsMerged { try? FileManager.default.removeItem(at: PlayCounts.url(ipod)) }
            } catch { rep.error = "Writing the database failed: \(error.localizedDescription)"; return }
        }
        pendingName = nil; toRemove = []; playlistsToRemove = []

        let have = Set(db.tracks.map(\.key))
        var work = addWork(have: have)
        var queued = Set(work.map(\.1.path))
        var lists: [(OTPlaylist, [OTTrack])] = []
        for p in playlists where playlistsToAdd.contains(p.id) {      // playlists bring the tracks there are files for
            syncPhase = "Reading playlist \(p.name)"
            let ts = await tracks(for: p)
            lists.append((p, ts))
            for t in ts {
                if let m = libraryTrack(for: t), !have.contains(m.track.key), queued.insert(m.track.path).inserted { work.append(m) }
            }
        }
        var smart: [(SmartPlaylist, [LibTrack])] = []
        for sp in smartPlaylists where sp.onIPod {     // smart playlists bring their songs too
            let ts = evaluate(sp)
            smart.append((sp, ts))
            for t in ts where !have.contains(t.key) && queued.insert(t.path).inserted {
                if let a = albums.first(where: { $0.id == t.album.lowercased() }) { work.append((a, t)) }
            }
        }
        syncPhase = "Adding songs"; syncTotal = work.count
        for (n, (album, var t)) in work.enumerated() {
            if podSettings.fillTagsFromMetadata, let mb = metadata[album.id] {
                if t.year == 0 { t.year = mb.year }
                if t.genre.isEmpty { t.genre = mb.genre }
            }
            syncCurrent = "\(podSettings.needsConversion(t) ? "Converting" : "Copying") \(t.trackArtist.isEmpty ? t.artist : t.trackArtist) – \(t.title)"
            do {
                db.tracks.append(try await Syncer.add(t, to: ipod, albumCount: album.tracks.count, id: db.nextID, settings: podSettings))
                rep.added += 1
                if n % 10 == 9 { try Syncer.write(db, to: ipod) }    // keep the database current during long syncs
            } catch { rep.failures.append("\(t.title): \(error.localizedDescription)") }
            syncDone = n + 1
        }
        if podSettings.soundCheck {       // measured on the iPod's own copies (local and already AAC/MP3)
            let todo = db.tracks.indices.filter { db.soundCheck($0) == 0 }
            if !todo.isEmpty {
                syncPhase = "Measuring loudness"; syncTotal = todo.count; syncDone = 0
                var cache = Loudness.load()
                for (n, i) in todo.enumerated() {
                    let t = db.tracks[i], path = ipod.mount.appendingPathComponent(t.relativePath).path
                    syncCurrent = "\(t.artist) – \(t.title)"
                    let key = "\(path)|\(t.size)"
                    var lufs = cache[key]?.first
                    if lufs == nil { lufs = await Task.detached { Loudness.measure(path) }.value; if let l = lufs { cache[key] = [l] } }
                    if let l = lufs { db.setSoundCheck(i, Loudness.soundCheck(l)) }
                    syncDone = n + 1
                }
                Loudness.save(cache)
            }
        }
        syncPhase = "Writing playlists"; syncCurrent = ""
        let idByKey = Dictionary(db.tracks.map { ($0.key, $0.id) }, uniquingKeysWith: { a, _ in a })
        for (p, ts) in lists {
            let items = ts.compactMap { t in libraryTrack(for: t).flatMap { idByKey[$0.track.key] } ?? idByKey[t.key] }
                .map { PodPlaylist.Item(trackID: $0) }
            if let i = db.playlists.firstIndex(where: { $0.name == p.name }) { db.playlists[i].items = items }
            else { db.playlists.append(PodPlaylist(name: p.name, items: items)) }
            rep.playlists += 1
        }
        for (sp, ts) in smart {
            let items = ts.compactMap { idByKey[$0.key] }.map { PodPlaylist.Item(trackID: $0) }
            if let i = db.playlists.firstIndex(where: { $0.name == sp.name }) { db.playlists[i].items = items }
            else { db.playlists.append(PodPlaylist(name: sp.name, items: items)) }
            rep.playlists += 1
        }
        if podSettings.calendars || podSettings.reminders {
            syncPhase = "Calendars and To Do"; syncCurrent = ""
            rep.calendars = await CalendarSync.write(to: ipod, settings: podSettings)
        }
        syncPhase = "Writing the database"
        do { try Syncer.write(db, to: ipod) }
        catch { rep.error = "Writing the database failed: \(error.localizedDescription)" }
        toAdd = []; playlistsToAdd = []
        syncPhase = "Done"
    }

    /// Calendars and To Do onto the iPod (the files only, no database change).
    func writeCalendars() async -> String {
        guard let ipod, connected, podSettings.calendars || podSettings.reminders else { return "" }
        return await CalendarSync.write(to: ipod, settings: podSettings)
    }

    func eject() {
        guard let ipod, connected else { return }
        do { try Syncer.eject(ipod); notify("Ejected – safe to unplug") }
        catch { notify("Eject failed: \(error.localizedDescription)") }
        loadIPod()
    }

    // MARK: metadata

    /// Stores a metadata match: year/genre into the files' tags, the cover next to the files.
    /// `step` reports each stage to the lookup dialog; returns a one-line summary.
    func apply(_ release: MBRelease, to album: Album, replaceCover: Bool, coverOnly: Bool = false, step: (String) -> Void) async -> String {
        if coverOnly { return await saveCover(release, to: album, replace: true, step: step) ?? "No cover found" }
        step("Fetching details from \(release.source)")
        let r = release.source == "MusicBrainz" ? await MusicBrainz.details(release) : release
        metadata[album.id] = r
        MetadataStore.save(metadata)
        var parts = ["Saved " + [r.year > 0 ? "\(r.year)" : "", r.genre].filter { !$0.isEmpty }.joined(separator: ", ")]
        step("Writing year and genre into \(album.tracks.count) files")
        let written = await writeTags(album, year: r.year, genre: r.genre)
        if written.files > 0 { parts.append("tags written to \(written.files) files") }
        if let e = written.error { parts.append(e) }
        if let c = await saveCover(r, to: album, replace: replaceCover, step: step) { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// Saves the release's cover as cover.jpg (replacing folder.jpg/cover.png too, so it wins).
    func saveCover(_ r: MBRelease, to album: Album, replace: Bool, step: (String) -> Void) async -> String? {
        let fm = FileManager.default
        let names = ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "front.jpg"]
        let existing = names.filter { fm.fileExists(atPath: album.folder + "/" + $0) }
        guard existing.isEmpty || replace else { return nil }
        step("Downloading the cover")
        let coverData = r.source == "MusicBrainz" ? await MusicBrainz.cover(r.id)
            : (try? await URLSession.shared.data(from: URL(string: r.cover) ?? MusicBrainz.coverURL(r.id)))?.0
        guard let d = coverData, let img = NSImage(data: d) else { return "no cover found" }
        guard !isPodOnly(album) else { artwork[album.id] = img; return nil }
        for n in existing where n != "cover.jpg" {       // the old image would otherwise still be picked first by some readers
            try? fm.moveItem(atPath: album.folder + "/" + n, toPath: album.folder + "/" + n + ".old")
        }
        try? fm.removeItem(atPath: album.folder + "/cover.jpg")
        guard fm.createFile(atPath: album.folder + "/cover.jpg", contents: d) else { return "couldn't write cover.jpg" }
        artwork[album.id] = img
        if on(.ownTone) { step("Asking OwnTone to rescan"); await ownToneRescan(ownToneURL) }
        return existing.isEmpty ? "cover saved" : "cover replaced"
    }

    /// Writes year/genre into the album's FLAC and MP3 files (off the main thread).
    func writeTags(_ album: Album, year: Int, genre: String) async -> (files: Int, error: String?) {
        let paths = album.tracks.map(\.path).filter { TagWriter.canWrite($0) && FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty, year > 0 || !genre.isEmpty else { return (0, nil) }
        let result = await Task.detached { () -> (Int, String?) in
            var n = 0, err: String?
            for p in paths {
                do { if try TagWriter.write(p, year: year, genre: genre) { n += 1 } }
                catch { err = err ?? error.localizedDescription }
            }
            return (n, err)
        }.value
        if result.0 > 0, on(.ownTone) { await ownToneRescan(ownToneURL) }
        return result
    }

    // MARK: imports

    /// Copies audio files into the import folder and adds them to the library; optionally queues them.
    @discardableResult
    func importFiles(_ urls: [URL], toIPod: Bool, job: UUID? = nil, title: String = "Importing") async -> Set<Album.ID> {
        let job = job ?? startJob(title, icon: "square.and.arrow.down")
        updateJob(job) { $0.state = .running; $0.detail = "Copying into \((self.importFolder as NSString).lastPathComponent)" }
        do {
            let r = try await Importer.run(urls, into: importFolder)
            guard !r.tracks.isEmpty else {
                finishJob(job, r.skipped > 0 ? "Already in the library (\(r.skipped) files)" : "No audio files found")
                return []
            }
            await addToLibrary(r.tracks)
            let ids = Set(r.tracks.map { $0.album.lowercased() })
            if toIPod { for a in albums where ids.contains(a.id) && state(a) != .onIPod { toAdd.insert(a.id) } }
            finishJob(job, "\(r.tracks.count) files in \(ids.count) album\(ids.count == 1 ? "" : "s")"
                + (r.skipped > 0 ? ", \(r.skipped) already there" : "") + (toIPod ? ", queued for the iPod" : ""))
            return ids
        } catch {
            finishJob(job, "Import failed: \(error.localizedDescription)", failed: true)
            return []
        }
    }

    /// Drag and drop onto the window (library) or the iPod card (library + queue).
    func importDropped(_ urls: [URL], toIPod: Bool) async {
        let roots = folders + [importFolder, (importFolder as NSString).deletingLastPathComponent]
        let known = urls.filter { u in Organizer.root(of: u.path, roots: roots) != nil }
        if !known.isEmpty, known.count == urls.count {
            if toIPod {      // already in the library: just queue those albums
                let ids = Set(libTracks.filter { t in known.contains { t.path.hasPrefix($0.path) } }.map { $0.album.lowercased() })
                for a in albums where ids.contains(a.id) && state(a) != .onIPod { toAdd.insert(a.id) }
                notify("Queued \(ids.count) album\(ids.count == 1 ? "" : "s") for the iPod")
            }
            return
        }
        let ids = await importFiles(urls, toIPod: toIPod, title: "Importing dropped files")
        if let a = albums.first(where: { ids.contains($0.id) }) {
            notify("Added \(ids.count == 1 ? a.title : "\(ids.count) albums") to the library" + (toIPod ? " and the iPod queue" : ""))
        }
    }

    /// A finished Soulseek download: copy its folder into the library.
    func importDownloaded(_ job: SlskJob, folder: String) async {
        guard FileManager.default.fileExists(atPath: folder) else {
            notify("Can't find \(folder) – is the share with slskd's downloads mounted?")
            return
        }
        await importFiles([URL(fileURLWithPath: folder)], toIPod: false, title: "Importing \(job.name)")
    }

    // MARK: Apple Music

    func loadAppleMusic() async {
        guard !amLoading else { return }       // Music answers one long query at a time; a second one times out
        amLoading = true; defer { amLoading = false }
        do {
            amAlbums = try await AppleMusic.albums(); amError = nil
            amHidden = Set(amAlbums.filter(inLibrary).map(\.id))
        } catch { amError = error.localizedDescription }
    }

    func inLibrary(_ a: AMAlbum) -> Bool { albums.contains { $0.id == a.id } }

    func amJob(_ a: AMAlbum) -> Job? {
        guard let id = amQueue.first(where: { $0.album.id == a.id })?.job else { return nil }
        return jobs.first { $0.id == id }
    }

    /// Queues an iTunes Match album; the queue is worked through one album at a time.
    func importAppleMusic(_ a: AMAlbum, toIPod: Bool) {
        guard !amQueue.contains(where: { $0.album.id == a.id }) else { return }
        let job = startJob(a.title, icon: "icloud.and.arrow.down", detail: "Waiting", queued: true)
        updateJob(job) { $0.source = .appleMusic; $0.subtitle = "\(a.artist) · \(a.tracks.count) songs"; $0.art = self.amArt[a.id] }
        amQueue.append((a, toIPod, job))
        guard !amRunning else { return }
        amRunning = true
        Task {
            while let next = amQueue.first {
                await runAppleMusicImport(next.album, toIPod: next.toIPod, job: next.job)
                amQueue.removeFirst()
            }
            amRunning = false
        }
    }

    private func runAppleMusicImport(_ a: AMAlbum, toIPod: Bool, job: UUID) async {
        updateJob(job) { $0.state = .running; $0.detail = "Downloading in Music"; $0.progress = 0 }
        do {
            let paths = try await AppleMusic.download(a) { [weak self] done, total in
                self?.updateJob(job) { $0.detail = "Downloading \(done) of \(total)"; $0.progress = Double(done) / Double(max(total, 1)) }
            }
            let ids = await importFiles(paths.map { URL(fileURLWithPath: $0) }, toIPod: toIPod, job: job)
            if let lib = albums.first(where: { ids.contains($0.id) }) { await saveAppleMusicCover(a, into: lib) }
            if let i = amAlbums.firstIndex(where: { $0.id == a.id }), let fresh = try? await AppleMusic.albums().first(where: { $0.id == a.id }) {
                amAlbums[i] = fresh
            }
        } catch { finishJob(job, error.localizedDescription, failed: true) }
    }

    /// Puts the iTunes Store cover (1200 px) next to an imported album when it has no cover file.
    func saveAppleMusicCover(_ a: AMAlbum, into lib: Album) async {
        let fm = FileManager.default
        guard !["cover.jpg", "folder.jpg", "cover.png", "folder.png"].contains(where: { fm.fileExists(atPath: lib.folder + "/" + $0) }) else { return }
        var url = amArt[a.id]
        if url == nil { url = await AppleMusic.artworkURL(a) }
        guard let u = url.flatMap({ URL(string: $0.absoluteString.replacingOccurrences(of: "600x600bb", with: "1200x1200bb")) }),
              let (d, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: d) else { return }
        if fm.createFile(atPath: lib.folder + "/cover.jpg", contents: d) {
            artwork[lib.id] = img
            if on(.ownTone) { await ownToneRescan(ownToneURL) }
        }
    }

    // MARK: Spotify

    /// Spotify albums you have files for (matched on album title).
    func hasFiles(_ s: SpotifyAlbum) -> Bool { albums.contains { $0.id == s.name.lowercased() } }

    /// Fetches a Spotify album from YouTube, song by song.
    func albumFromYouTube(_ a: SpotifyAlbum) async {
        guard on(.youtube) else { return }
        guard spotifyAPI.direct, spotifyAPI.connected else { notify("Connect your Spotify account to fetch whole albums from YouTube"); return }
        do {
            let r = try await spotifyAPI.album(a.uri)
            yt.fetch(r.tracks, album: a.name, art: r.art, year: r.year)
            notify("Fetching “\(a.name)” from YouTube (\(r.tracks.count) songs)")
        } catch { notify(error.localizedDescription) }
    }

    /// Looks the album up on Soulseek (the Soulseek pane, search started).
    func findOnSoulseek(_ artist: String, _ album: String, songs: Int = 0) {
        guard on(.soulseek) else { notify("Turn on the Soulseek plugin in Settings to download albums"); return }
        search = ""
        pane = .soulseek
        slsk.wantSongs = songs
        slsk.search((artist == "Various Artists" ? "" : artist + " ") + album)
    }

    /// How many songs the full album has, when the library copy has fewer: gaps in the track
    /// numbers, or more songs on the release picked with Find Metadata.
    func expectedSongs(_ a: Album) -> Int? {
        let have = a.tracks.count
        let byNumbers = Set(a.tracks.map(\.discNumber)).count <= 1 ? (a.tracks.map(\.trackNumber).max() ?? 0) : 0
        let full = max(byNumbers, metadata[a.id]?.trackCount ?? 0)
        return full > have ? full : nil
    }
}
