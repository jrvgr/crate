import SwiftUI
import AppKit

/// What the detail column shows; the iPod's state is shown on every item as well.
enum Pane: Hashable {
    case recent, albums, artists, songs, health, review, ipod
    case smart(UUID)
    case spotify, appleMusic, soulseek, downloads, youtube
    case playlist(Int), podPlaylist(UInt64), cratePlaylist(UUID)
}

/// Pages pushed on top of a pane.
enum Route: Hashable { case album(Album), artist(String), spotifyAlbum(SpotifyAlbum) }

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
    var playlistsEdit: [String] = []
    var onTheGo = 0
    var rename: String?
    var retag = 0
    var hide = 0, unhide = 0
    var markPlaylists: [String] = []
    var bytesIn: Int64 = 0, bytesOut: Int64 = 0
}

struct SyncReport {
    var added = 0, removed = 0, playlists = 0, replaced = 0
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
    @Published var libTracks: [LibTrack] = [] { didSet { genreCache = nil } }
    var genreCache: [String]?                                   // topGenres, until the songs change
    /// Library key → iPod key, the reverse of `aliases`, for podKey (smart playlist rules call it per song).
    var podKeyByLib: [String: String] = [:]
    /// Smart playlists bound for the iPod that need a sync (worked out in refreshSmartPending, not per render).
    @Published var smartNeedingSync: Set<UUID> = []
    @Published var albums: [Album] = [] { didSet { refreshDerived() } }
    @Published var artwork: [Album.ID: NSImage] = [:]
    @Published var artistArt: [Artist.ID: NSImage] = [:]
    @Published var metadata: [String: MBRelease] = MetadataStore.load()
    @Published var loading = false
    @Published var libraryError: String?

    // iPod
    @Published var ipod: IPodInfo?
    @Published var db: ITunesDB? {
        didSet {
            // plays and ratings made on the iPod since the last sync sit in its Play Counts file until
            // Sync adds them to the database; they count right away (Most Played etc.) without
            // touching `db`, so Sync doesn't add them twice
            var merged = db
            if let e = unmergedPlays, merged?.mergePlayCounts(e) != nil { podStats = Self.stats(merged) }
            else { podStats = Self.stats(db) }
            refreshPod()
        }
    }
    @Published var podStats: [String: PodStat] = [:]
    /// The iPod's Play Counts file, read when it connects; cleared once a sync merged it.
    var unmergedPlays: [PlayCounts.Entry]?
    static func stats(_ db: ITunesDB?) -> [String: PodStat] {
        Dictionary((db?.tracks ?? []).map { ($0.key, $0.stat) }, uniquingKeysWith: { a, b in a.plays >= b.plays ? a : b })
    }
    @Published var smartPlaylists: [SmartPlaylist] = SmartStore.load()
    @Published var cratePlaylists: [CratePlaylist] = Store.load("playlists.json", []) { didSet { Store.save("playlists.json", cratePlaylists) } }
    @Published var podEdits: [UInt64: PodPlaylistEdit] = Store.load("pod-playlist-edits.json", [:]) { didSet { Store.save("pod-playlist-edits.json", podEdits) } }
    @Published var renaming: PlaylistRef?
    @Published var renameText = ""
    @Published var confirmDeletePlaylist: PlaylistRef?
    @Published var smartPending = 0
    @Published var editSmart: SmartPlaylist?
    @Published var podSettings = PodSettings() { didSet { hiddenCache = nil; if let i = ipod, podSettings != oldValue { PodSettings.save(podSettings, serial: i.key) } } }
    @Published var connected = false
    /// Set when the iPod's database is there but can't be read (a disk or filesystem error). Crate
    /// then shows the last copy it read and won't sync: writing would replace the real database.
    @Published var podReadError: String?
    @Published var lastSeen: Date?
    @Published var toAdd: Set<Album.ID> = [] { didSet { savePending() } }
    @Published var toRemove: Set<Album.ID> = [] { didSet { savePending() } }
    @Published var songsToAdd: Set<String> = [] { didSet { savePending() } }       // library file paths
    @Published var songsToRemove: Set<String> = [] { didSet { savePending() } }    // track keys on the iPod
    @Published var fileSizes: [String: Int64] = [:]
    @Published var aliases: [String: String] = Store.load("matches.json", [:]) { didSet { refreshPod() } }     // iPod key → library key
    @Published var retags: [String: PodRetag] = Store.load("retags.json", [:]) { didSet { Store.save("retags.json", retags); refreshPod() } }     // iPod key → new tags
    @Published var hides: [String: Bool] = Store.load("hides.json", [:]) { didSet { Store.save("hides.json", hides); hiddenCache = nil } }     // iPod key → your hide/show choice, over the hidden-playlist rule
    @Published var skips: [String: PodSkip] = Store.load("skips.json", [:]) { didSet { Store.save("skips.json", skips) } }      // iPod key → skips on the iPod (FroggerSkips, added on Sync)
    @Published var froggerBusy = false
    @Published var froggerMessage: String?
    @Published var froggerFailed = false
    @Published var froggerRestart: Frogger.Action?     // what just changed the firmware, until the restart hint is dismissed
    @Published var froggerConfirm: Frogger.Action?
    @Published var brokenPod: DiskRepair.Broken?           // an iPod whose disk macOS won't mount writable (DiskRepair.swift)
    @Published var podRepairBusy = false
    @Published var podRepairMessage: String?
    @Published var podRepairConfirm = false
    @Published var podRepairProgress: DiskRepair.Progress?
    @Published var podRepairLog: [String] = []
    var diskCheck: Task<Void, Never>?
    private var diskWatch: DiskWatch?
    @Published var ratings: [String: Int] = Store.load("ratings.json", [:])        // library key → stars
    @Published var keptArtists: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "keptArtists") ?? [])
    @Published var brokenFiles: [String: String] = [:]
    @Published var checkingFiles = false
    @Published var showMatch = false
    @Published var coverDrop: Album.ID?        // the cover an image is being dragged over
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
    @AppStorage("albumsByArtist") var albumsByArtist = false  // the library grid in a section per artist
    @Published var lookupAlbum: Album?
    @Published var editAlbum: Album?
    @Published var batchAlbums: [Album]?
    @Published var showMissing = false
    @Published var organize: [Album]?
    @Published var merge: [Album]?
    @Published var confirmTrash: [LibTrack]?
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
    @Published var spotifyTab = "albums"
    @Published var spotifyArtist: String?

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
        // also the disks that never mount, like an iPod whose volume has errors
        diskWatch = DiskWatch { [weak self] in Task { @MainActor in self?.diskChanged() } }
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

    /// The iPod's songs as library keys (paired songs count as their library song).
    // Worked out once when the library or the iPod changes, not on every redraw (the album grid asks
    // for these per tile, which made every click slow).
    private(set) var podKeys: Set<String> = []
    private(set) var podAlbums: [Album] = []
    private(set) var allAlbums: [Album] = []
    private(set) var artists: [Artist] = []
    private var libraryIDs: Set<Album.ID> = []

    private func refreshPod() {
        hiddenCache = nil
        let tracks = (db?.tracks ?? []).map { t in     // renames waiting for the next sync already count
            var t = t
            if let r = retags[t.key] { t.title = r.title; t.album = r.album; t.artist = r.artist }
            return t
        }
        podKeys = Set(tracks.map { aliases[$0.key] ?? $0.key })
        podKeyByLib = Dictionary(aliases.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        podAlbums = LibraryLoader.albums(tracks.map {
            LibTrack(title: $0.title, artist: $0.artist, album: $0.album, genre: $0.genre, trackNumber: $0.trackNumber,
                     discNumber: 0, year: 0, lengthMs: $0.lengthMs, path: $0.relativePath)
        })
        refreshDerived()
    }

    private func refreshDerived() {
        hiddenCache = nil
        libraryIDs = Set(albums.map(\.id))
        /// Library albums plus albums that are only on the iPod (so they can be opened and removed).
        allAlbums = (albums + podAlbums.filter { !libraryIDs.contains($0.id) })
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
        artists = Dictionary(grouping: allAlbums) { $0.artist.lowercased() }.values
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

    func isPodOnly(_ a: Album) -> Bool { !libraryIDs.contains(a.id) }

    private static func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    func rebuild() {
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
    func libraryTrack(key k: String) -> (album: Album, track: LibTrack)? { index[k] }

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

    func podPlaylist(for p: OTPlaylist) -> PodPlaylist? { db?.playlists.first { samePlaylist($0.name, p.name) } }

    /// iPod playlists that don't come from an OwnTone playlist (On-The-Go, made elsewhere).
    var podOnlyPlaylists: [PodPlaylist] {
        let names = Set((playlists.map(\.name) + smartPlaylists.map(\.name) + cratePlaylists.map(\.name)).map(baseName))
        return (db?.playlists ?? []).filter { !names.contains(baseName($0.name)) }
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
                        var own = try await spotifyAPI.playlists()
                        if let liked = try? await spotifyAPI.likedPlaylist() { own.insert(liked, at: 0) }
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
        applyKeptArtists()
        refreshSmartPending()
        Task { await loadSizes() }
        await loadArtwork()
    }

    private func loadArtwork() async {
        // all file reading and image decoding happens off the main thread (the files live on shares)
        for ar in artists where artistArt[ar.id] == nil {
            if let img = await Task.detached(operation: { LibraryLoader.artistImage(ar).flatMap { NSImage(data: $0) } }).value { artistArt[ar.id] = img }
        }
        // cached copies first (quick), then whatever is still missing from the files themselves
        let cached = await Task.detached { [albums] in
            albums.compactMap { a in ArtCache.image("album:" + a.folder).map { (a.id, $0) } }
        }.value
        for (id, img) in cached where artwork[id] == nil { artwork[id] = img }
        for a in albums where artwork[a.id] == nil {
            if let d = await LibraryLoader.artwork(for: a),
               let img = await Task.detached(operation: { ArtCache.store(d, for: "album:" + a.folder) ?? NSImage(data: d) }).value { artwork[a.id] = img }
        }
        await loadPodArtwork()
    }

    /// Covers for albums that only exist on the iPod: the art in its own files, else the iTunes catalogue.
    func loadPodArtwork() async {
        for a in podAlbums where isPodOnly(a) && artwork[a.id] == nil {
            let key = "pod:" + a.id
            if let img = await Task.detached(operation: { ArtCache.image(key) }).value { artwork[a.id] = img; continue }
            var data: Data?
            if let ipod, connected, let first = a.tracks.first {
                var onPod = a; onPod.tracks = [first]
                onPod.tracks[0].path = ipod.mount.appendingPathComponent(first.path).path
                data = await LibraryLoader.artwork(for: onPod)
            }
            if data == nil {
                let am = AMAlbum(title: a.title, artist: a.artist, tracks: [])
                if let u = await AppleMusic.artworkURL(am), let (d, _) = try? await URLSession.shared.data(from: u) { data = d }
            }
            if let d = data, let img = await Task.detached(operation: { ArtCache.store(d, for: key) }).value { artwork[a.id] = img }
        }
    }

    /// Apple Lossless songs on the iPod (too big for its memory buffer, hard on the battery) become AAC: the
    /// library file is converted and goes over the iPod's copy at the same place, and the record gets the new
    /// size, bit rate and file type, so play counts, ratings and playlists stay. Songs only on the iPod keep theirs.
    private func replaceLossless(_ db: inout ITunesDB, ipod: IPodInfo, report rep: inout SyncReport) async {
        let source = { (t: PodTrack) in self.index[self.aliases[t.key] ?? t.key]?.1.path }
        // AAC copies in a layout the iPod can't read (MP4Layout.swift): rearranged where they are, audio untouched
        syncPhase = "Fixing song files"; syncTotal = 0; syncDone = 0
        let file = { (t: PodTrack) in ipod.mount.appendingPathComponent(t.relativePath) }
        let unreadable = db.tracks.indices.filter {
            !db.tracks[$0].isLossless && db.tracks[$0].relativePath.lowercased().hasSuffix(".m4a") && !MP4Layout.iPodReady(file(db.tracks[$0]).path)
        }
        if !unreadable.isEmpty { syncTotal = unreadable.count }
        for i in unreadable {
            let t = db.tracks[i], dst = file(t)
            syncCurrent = "Rearranging \(t.artist) – \(t.title)"
            let staged = dst.deletingLastPathComponent().appendingPathComponent(".crate-new-" + dst.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: staged)
                try await Task.detached { try MP4Layout.remux(dst.path, to: staged) }.value
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: staged)
                let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
                let info = await Syncer.audioInfo(dst)
                db.replaceFile(i, size: size, kbps: info.kbps, ms: info.ms)
                rep.replaced += 1
            } catch { try? FileManager.default.removeItem(at: staged); rep.failures.append("\(t.title): \(error.localizedDescription)") }
            syncDone += 1
        }
        let todo = db.tracks.indices.filter { db.tracks[$0].isLossless && source(db.tracks[$0]) != nil }
        guard !todo.isEmpty else { return }
        syncTotal = todo.count; syncDone = 0
        // as in Adding songs: conversions run ahead, several at once; the iPod gets one copy at a time, in order
        let kbps = podSettings.aacKbps
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crate-lossless-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let slots = Slots(max(2, cores - 2)), ahead = max(4, cores * 2)
        var converted: [Int: Task<URL, Error>] = [:]
        func schedule(_ n: Int) {
            guard n < todo.count, converted[n] == nil else { return }
            let src = source(db.tracks[todo[n]])!, out = tmp.appendingPathComponent("\(n).m4a")
            converted[n] = Task.detached {
                await slots.take()
                defer { Task { await slots.give() } }
                guard FileManager.default.fileExists(atPath: src) else { throw SyncError.missingSource(src) }
                try Syncer.convert(src, to: out, kbps: kbps)
                return out
            }
        }
        for (n, i) in todo.enumerated() {
            for k in n...min(n + ahead, todo.count - 1) { schedule(k) }
            let t = db.tracks[i]
            syncCurrent = "Converting \(t.artist) – \(t.title)"
            let dst = ipod.mount.appendingPathComponent(t.relativePath)
            do {
                let aac = try await converted[n]!.value
                converted[n] = nil
                let info = await Syncer.audioInfo(aac)
                let staged = dst.deletingLastPathComponent().appendingPathComponent(".crate-new-" + dst.lastPathComponent)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: aac, to: staged)
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: staged)
                try? FileManager.default.removeItem(at: aac)
                let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
                db.replaceFile(i, size: size, kbps: info.kbps, ms: info.ms)
                rep.replaced += 1
                if rep.replaced % 10 == 0 { try? Syncer.write(db, to: ipod) }    // the records follow the replaced files
            } catch { converted[n] = nil; rep.failures.append("\(t.title): still lossless, \(error.localizedDescription)") }
            syncDone = n + 1
        }
        syncCurrent = ""
    }

    /// Reads these files' tags again after they were edited (the album may have a new name now).
    func refreshFiles(_ paths: [String], cover: Data? = nil, oldID: Album.ID? = nil) async {
        var fresh: [String: LibTrack] = [:]
        for p in paths {
            let parts = p.split(separator: "/").suffix(3).joined(separator: "/")
            var t = await LibraryLoader.track(p, relative: parts)
            if let old = libTracks.first(where: { $0.path == p }) {
                t.uri = old.uri; t.added = old.added
                if old.key != t.key || old.artist != t.artist { followOnIPod(old, t) }
            }
            fresh[p] = t
        }
        libTracks = libTracks.map { fresh[$0.path] ?? $0 }
        let oldArt = oldID.flatMap { artwork[$0] }
        rebuild()
        if let newID = fresh.values.first?.album.lowercased() {
            let folder = albums.first { $0.id == newID }?.folder ?? ""
            if let d = cover, let img = ArtCache.store(d, for: "album:" + folder) ?? NSImage(data: d) { artwork[newID] = img }
            else if artwork[newID] == nil { artwork[newID] = oldArt }
        }
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
    }

    /// A song whose tags changed: its copy on the iPod gets the same title/album/artist at the next sync,
    /// so it stays one song instead of turning into an "only on iPod" leftover plus a new copy.
    private func followOnIPod(_ old: LibTrack, _ new: LibTrack) {
        guard let db else { return }
        let podKey = retags.first { $0.value.key == old.key }?.key     // renamed before, not synced yet
            ?? aliases.first { $0.value == old.key }?.key
            ?? old.key
        guard db.tracks.contains(where: { $0.key == podKey }) else { return }
        let r = PodRetag(title: new.title, album: new.album, artist: new.artist)
        if aliases[podKey] != nil { aliases[podKey] = r.key; Store.save("matches.json", aliases) }
        retags[podKey] = r
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
        toAdd.count + toRemove.count + songsToAdd.count + songsToRemove.count + playlistsToAdd.count + playlistsToRemove.count
            + podSavedLists.count + (pendingName == nil ? 0 : 1) + smartPending + retags.count + hidePending
            + cratePlaylists.filter(crateNeedsSync).count + podEditsPending
    }

    var usedFraction: Double {
        guard let i = ipod, i.capacity > 0 else { return 0 }
        return Double(i.used) / Double(i.capacity)
    }

    var musicBytes: Int64 { Int64((db?.tracks ?? []).map(\.size).reduce(0, +)) }

    enum DBRead { case ok(ITunesDB), missing, failed(String) }

    /// Reads the iPod's database, telling "not there" (a new iPod) apart from "can't be read".
    static func readDB(_ url: URL) -> DBRead {
        do {
            let d = try Data(contentsOf: url)
            do { return .ok(try ITunesDB.read(d)) } catch { return .failed("the database is damaged") }
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            return .missing
        } catch {
            let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
            return .failed("the disk reported: \(posix ?? error.localizedDescription)")
        }
    }

    /// Finds the iPod; when it's unplugged, the last one seen is shown from the cache (read only).
    func loadIPod() {
        let wasConnected = connected, had = ipod?.key
        if let i = IPodInfo.find() {
            ipod = i; connected = true; lastSeen = nil
            podReadError = nil
            DiskRepair.keepSpotlightOff(i.mount)
            switch Self.readDB(i.dbURL) {
            case .ok(let parsed):
                unmergedPlays = (try? Data(contentsOf: PlayCounts.url(i))).flatMap(PlayCounts.parse)
                db = parsed; PodCache.saveDB(from: i)
            case .missing: db = .empty(name: i.mount.lastPathComponent)      // a fresh iPod: start a database
            case .failed(let why):
                podReadError = why
                db = PodCache.loadDB() ?? .empty(name: i.mount.lastPathComponent)
            }
            onTheGo = OnTheGo.load(i, db: db!)
            if !loading { Task { await loadPodArtwork() } }
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
        if connected, !wasConnected, had != nil || lastSeenAtLaunch, podSettings.syncOnConnect, pendingCount > 0, !syncing, podReadError == nil {
            notify("\(podName) connected – syncing \(pendingCount) queued changes")
            reviewSync()
            Task { await sync() }
        }
        lastSeenAtLaunch = true
    }

    /// Plugging the iPod in later in the session starts the queued sync, not the very first scan at launch.
    private var lastSeenAtLaunch = false

    /// Saves the queue a moment after the last change (clicking through albums shouldn't wait on disk writes).
    private func savePending() {
        guard !restoring, ipod != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard let self, !Task.isCancelled, let i = self.ipod else { return }
            let seen = self.connected ? Date() : (self.lastSeen ?? Date())
            let c = PodCache(info: i, seen: seen, toAdd: self.toAdd.sorted(), toRemove: self.toRemove.sorted(),
                             playlistsToAdd: self.playlistsToAdd.sorted(), playlistsToRemove: self.playlistsToRemove.sorted(),
                             pendingName: self.pendingName, songsToAdd: self.songsToAdd.sorted(), songsToRemove: self.songsToRemove.sorted())
            Task.detached { c.save() }
        }
    }
    private var saveTask: Task<Void, Never>?

    private func restorePending() {
        guard let c = PodCache.load(), c.info.key == ipod?.key else { return }
        restoring = true; defer { restoring = false }
        toAdd = Set(c.toAdd); toRemove = Set(c.toRemove)
        songsToAdd = Set(c.songsToAdd ?? []); songsToRemove = Set(c.songsToRemove ?? [])
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

    /// Goes to an album's page, unless it's already showing.
    func showAlbumPage(_ a: Album?) {
        guard let a else { return }
        if case .album(let shown)? = path.last, shown.id == a.id { return }
        search = ""
        path.append(.album(a))
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
        toAdd = []; toRemove = []; songsToAdd = []; songsToRemove = []; playlistsToAdd = []; playlistsToRemove = []; pendingName = nil
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
        brokenFiles = [:]
        Task { await estimateSizes() }
        Task { await checkQueuedFiles() }
    }

    /// Per album, the songs the next sync adds and removes (for the sync sheet's preview).
    func syncPreview() -> [(album: String, artist: String, add: [String], remove: [String])] {
        var out: [String: (album: String, artist: String, add: [String], remove: [String])] = [:]
        for (a, t) in addWork(have: podKeys) { out[a.id, default: (a.title, a.artist, [], [])].add.append(t.title) }
        let keys = removalKeys
        for t in (db?.tracks ?? []) where keys.contains(t.key) {
            out[t.album.lowercased(), default: (t.album, t.artist, [], [])].remove.append(t.title)
        }
        return out.values.sorted { ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased()) }
    }

    func syncWork() -> [(Album, LibTrack)] { addWork(have: podKeys) }

    private func addWork(have: Set<String>) -> [(Album, LibTrack)] {
        var work = albums.filter { toAdd.contains($0.id) }.flatMap { a in a.tracks.filter { !have.contains($0.key) }.map { (a, $0) } }
        let queued = Set(work.map(\.1.path))
        for a in albums { for t in a.tracks where songsToAdd.contains(t.path) && !queued.contains(t.path) && !have.contains(t.key) { work.append((a, t)) } }
        return work
    }

    /// Keys of the iPod songs that go on the next sync (whole albums and single songs).
    var removalKeys: Set<String> { Set(podAlbums.filter { toRemove.contains($0.id) }.flatMap { $0.tracks.map(\.key) }).union(songsToRemove) }

    // MARK: single songs

    // MARK: Hidden songs (Frogger's hide flag)
    //
    // A song is hidden from the iPod's Artists/Albums when you hid it yourself, or when it's only
    // in playlists you marked as hidden ("~Name" or "Name ~" on the iPod). Showing a song yourself wins
    // over the playlists. Your choices are kept in `hides`; the flags are written on Sync.

    static let hideMark = "~"

    func baseName(_ name: String) -> String {
        var n = name
        if n.hasPrefix(Self.hideMark) { n = String(n.dropFirst(Self.hideMark.count)).trimmingCharacters(in: .whitespaces) }
        else if n.hasSuffix(Self.hideMark) { n = String(n.dropLast(Self.hideMark.count)).trimmingCharacters(in: .whitespaces) }
        return n
    }

    func samePlaylist(_ a: String, _ b: String) -> Bool { baseName(a) == baseName(b) }

    /// A playlist you marked, or one already named with the mark (in Spotify, say) that you didn't unmark.
    func isHiddenPlaylist(_ name: String) -> Bool { podSettings.hiddenPlaylists[baseName(name)] ?? (baseName(name) != name) }

    /// The name a playlist gets on the iPod: Crate adds or removes the mark only on playlists you chose.
    func podName(forPlaylist name: String) -> String {
        let base = baseName(name)
        switch podSettings.hiddenPlaylists[base] {
        case true?: return podSettings.hideMarkAtEnd ? base + " " + Self.hideMark : Self.hideMark + base
        case false?: return base
        case nil: return name
        }
    }

    func toggleHiddenPlaylist(_ name: String) {
        podSettings.hiddenPlaylists[baseName(name)] = !isHiddenPlaylist(name)
    }

    /// Keys of songs that are in a hidden playlist and in no other playlist, unless their whole album is on
    /// the iPod for another reason: an album you loaded keeps all its songs in Artists/Albums. An album
    /// that is only there because hidden playlists hold every song of it (a single, say) still hides.
    /// `tracks`: the iPod's tracks as they are at that moment (during a sync, already retagged: their keys are the
    /// new ones), by default the database Crate last read.
    func ruleHidden(_ lists: [PodPlaylist], tracks: [PodTrack]? = nil) -> Set<String> {
        let keyByID = Dictionary((tracks ?? db?.tracks ?? []).map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        var marked = Set<String>(), other = Set<String>()
        for p in lists {
            let keys = p.items.compactMap { keyByID[$0.trackID] }
            if isHiddenPlaylist(p.name) { marked.formUnion(keys) } else { other.formUnion(keys) }
        }
        var hidden = marked.subtracting(other)
        for a in albums where state(a) == .onIPod {
            let keys = a.tracks.map { podKey($0.key) }
            if !keys.allSatisfy(hidden.contains) { hidden.subtract(keys) }
        }
        return hidden
    }

    func wantsHidden(_ podKey: String, _ rule: Set<String>) -> Bool { hides[podKey] ?? rule.contains(podKey) }

    /// Whether a song on the iPod is (or will be, after the next sync) hidden from Artists/Albums.
    func isHidden(_ t: LibTrack) -> Bool { hiddenOnIPod.contains(podKey(t.key)) }

    /// The iPod keys of the songs Frogger hides from Artists/Albums after the next sync (a song renamed at that
    /// sync under both names). Kept until the database, the library or a hide choice changes: albums ask per tile.
    var hiddenOnIPod: Set<String> {
        if let c = hiddenCache { return c }
        let rule = ruleHidden(db?.playlists ?? [])
        var s = Set<String>()
        for t in db?.tracks ?? [] where wantsHidden(t.key, rule) {
            s.insert(t.key)
            if let r = retags[t.key] { s.insert(r.key) }
        }
        hiddenCache = s
        return s
    }
    private var hiddenCache: Set<String>?

    /// How many of an album's songs on the iPod are hidden there, of how many on the iPod.
    func hiddenCount(_ a: Album) -> (hidden: Int, onIPod: Int) {
        let keys = a.tracks.map { podKey($0.key) }.filter(podKeys.contains), hidden = hiddenOnIPod
        return (keys.filter(hidden.contains).count, keys.count)
    }

    /// Hides or shows these songs' copies on the iPod at the next sync; songs not on the iPod are left alone.
    func setHidden(_ tracks: [LibTrack], _ on: Bool) {
        let rule = ruleHidden(db?.playlists ?? [])
        var h = hides
        for t in tracks {
            let k = podKey(t.key)
            guard podKeys.contains(t.key) || podKeys.contains(k) else { continue }
            h[k] = rule.contains(k) == on ? nil : on
        }
        hides = h
        objectWillChange.send()
    }

    /// Hide flags and playlist marks the next sync would change.
    var hidePending: Int {
        guard let db else { return 0 }
        let rule = ruleHidden(db.playlists)
        return db.tracks.filter { $0.hidden != wantsHidden($0.key, rule) }.count
            + db.playlists.filter { $0.name != podName(forPlaylist: $0.name) }.count
    }

    func songMark(_ t: LibTrack) -> SyncMark {
        if songsToAdd.contains(t.path) { return .adding }
        if songsToRemove.contains(podKey(t.key)) { return .removing }
        let a = albums.first { $0.id == t.album.lowercased() }
        if podKeys.contains(t.key) { return a.map { toRemove.contains($0.id) } == true ? .removing : .onIPod }
        return a.map { toAdd.contains($0.id) } == true ? .adding : .none
    }

    /// Queues one song for the iPod, or for removal from it (or takes it out of the queue again).
    func toggleSong(_ t: LibTrack) {
        if songsToAdd.contains(t.path) { songsToAdd.remove(t.path) }
        else if songsToRemove.contains(podKey(t.key)) { songsToRemove.remove(podKey(t.key)) }
        else if podKeys.contains(t.key) { songsToRemove.insert(podKey(t.key)) }
        else { songsToAdd.insert(t.path) }
    }

    // MARK: sizes

    /// What a song takes on the iPod: converted ones by length and bit rate, the rest by file size.
    func podSize(_ t: LibTrack) -> Int64 {
        if t.needsConversion { return Int64(t.lengthMs) * Int64(podSettings.aacKbps) / 8 }
        return fileSizes[t.path] ?? Int64(t.lengthMs) * 256 / 8
    }
    func podSize(_ a: Album) -> Int64 { a.tracks.reduce(0) { $0 + podSize($1) } }

    /// Roughly what the queued changes add (positive) or free up on the iPod.
    var queuedBytes: Int64 {
        let add = addWork(have: podKeys).reduce(Int64(0)) { $0 + podSize($1.1) }
        let keys = removalKeys
        let out = Int64((db?.tracks ?? []).filter { keys.contains($0.key) }.map(\.size).reduce(0, +))
        return add - out
    }

    func loadSizes() async {
        let paths = libTracks.map(\.path).filter { fileSizes[$0] == nil }
        guard !paths.isEmpty else { return }
        let found = await Task.detached { () -> [String: Int64] in
            var out: [String: Int64] = [:]
            for p in paths { if let n = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int { out[p] = Int64(n) } }
            return out
        }.value
        fileSizes.merge(found) { a, _ in a }
    }

    func makePlan() -> SyncPlan {
        var p = SyncPlan()
        let have = podKeys
        p.addAlbums = albums.filter { toAdd.contains($0.id) }
        let work = addWork(have: have)
        p.addSongs = work.count
        p.convertSongs = work.filter { podSettings.needsConversion($0.1) }.count
        p.removeAlbums = podAlbums.filter { toRemove.contains($0.id) }
        let removeKeys = removalKeys
        p.removeSongs = (db?.tracks ?? []).filter { removeKeys.contains($0.key) }.count
        p.bytesOut = Int64((db?.tracks ?? []).filter { removeKeys.contains($0.key) }.map(\.size).reduce(0, +))
        p.playlistsAdd = playlists.filter { playlistsToAdd.contains($0.id) }.map(\.name) + smartPlaylists.filter(smartNeedsSync).map(\.name)
        let smartWork = smartPlaylists.filter(\.onIPod).flatMap(evaluate).filter { !have.contains($0.key) }
        p.addSongs += Set(smartWork.map(\.path)).subtracting(work.map(\.1.path)).count
        p.playlistsAdd += cratePlaylists.filter(crateNeedsSync).map(\.name)
        let crateWork = cratePlaylists.filter(\.onIPod).flatMap(songs).filter { !have.contains($0.key) }
        p.addSongs += Set(crateWork.map(\.path)).subtracting(work.map(\.1.path)).subtracting(smartWork.map(\.path)).count
        p.playlistsRemove = (db?.playlists ?? []).filter { playlistsToRemove.contains($0.id) }.map(\.name)
        p.playlistsEdit = (db?.playlists ?? []).compactMap { pl in
            podEdits[pl.id].map { e in e.name.map { "\(pl.name) → \($0)" } ?? pl.name }
        }
        p.onTheGo = podSavedLists.count
        p.rename = pendingName
        p.retag = (db?.tracks ?? []).filter { retags[$0.key] != nil }.count
        let rule = ruleHidden(db?.playlists ?? [])
        p.hide = (db?.tracks ?? []).filter { !$0.hidden && wantsHidden($0.key, rule) }.count
        p.unhide = (db?.tracks ?? []).filter { $0.hidden && !wantsHidden($0.key, rule) }.count
        p.markPlaylists = (db?.playlists ?? []).filter { $0.name != podName(forPlaylist: $0.name) }.map { podName(forPlaylist: $0.name) }
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
        // Only a database that truly isn't there yet starts from what Crate knows; one that can't be
        // read (I/O error) stops the sync, or an empty database would be written over the real one.
        let current: ITunesDB?
        switch Self.readDB(ipod.dbURL) {
        case .ok(let d): current = d
        case .missing: current = known.tracks.isEmpty ? known : nil
        case .failed(let why): current = nil; podReadError = why
        }
        guard var db = current else {
            report = SyncReport(error: "Couldn't read the iPod's database (\(podReadError ?? "it's missing")); nothing was changed")
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
        // what the iPod saved, read again against this database (its playlists still as the iPod knows them)
        let otg = OnTheGo.load(ipod, db: db).filter { $0.kind != .onTheGo || podSettings.importOnTheGo }
        keepFromPod(otg, in: &db)
        rep.playlists += otg.count
        let podHides = PodHides.load(ipod, db: db)      // songs hidden or shown on the iPod become your hide choice
        for (k, v) in PodHides.choices(podHides, db: db) { hides[k] = v }
        let podSkips = PodSkips.load(ipod, db: db).map { (db.tracks[$0.index].key, $0) }     // added once the database is written
        db.playlists.removeAll { playlistsToRemove.contains($0.id) }
        rep.playlists += applyPodEdits(&db)

        syncPhase = "Removing songs"
        let removeKeys = removalKeys
        let removing = db.tracks.filter { removeKeys.contains($0.key) }
        syncTotal = removing.count; syncDone = 0
        for t in removing {
            syncCurrent = "\(t.artist) – \(t.title)"
            Syncer.remove(t, from: ipod); rep.removed += 1; syncDone += 1
        }
        syncCurrent = ""
        db.tracks.removeAll { removeKeys.contains($0.key) }
        let left = Set(db.tracks.map(\.id))     // new tracks may reuse the ids of removed ones
        for i in db.playlists.indices { db.playlists[i].items.removeAll { !left.contains($0.trackID) } }
        // write now (before the track order changes again), so On-The-Go lists and play counts can't be imported twice
        if !otg.isEmpty || rep.removed > 0 || pendingName != nil || playCountsMerged || !podHides.isEmpty || !podSkips.isEmpty {
            do {
                try Syncer.write(db, to: ipod)
                otg.forEach { try? FileManager.default.removeItem(at: $0.url) }
                if !podHides.isEmpty { try? FileManager.default.removeItem(at: PodHides.url(ipod)) }
                if !podSkips.isEmpty {      // (a file left behind is stale now: the database's stamp moved on)
                    try? FileManager.default.removeItem(at: PodSkips.url(ipod))
                    skips = PodSkips.add(podSkips, to: skips)
                }
                if playCountsMerged { try? FileManager.default.removeItem(at: PlayCounts.url(ipod)); unmergedPlays = nil }
            } catch { rep.error = "Writing the database failed: \(error.localizedDescription)"; return }
        }
        pendingName = nil; toRemove = []; songsToRemove = []; playlistsToRemove = []
        let renames = retags
        for (old, r) in renames where hides[old] != nil { hides[r.key] = hides.removeValue(forKey: old) }     // choices follow renamed songs
        for (old, r) in renames where skips[old] != nil { skips[r.key] = skips.removeValue(forKey: old) }
        for i in db.tracks.indices { if let r = renames[db.tracks[i].key] { db.retag(i, r) } }
        await replaceLossless(&db, ipod: ipod, report: &rep)

        let have = Set(db.tracks.map { aliases[$0.key] ?? $0.key })
        var work = addWork(have: have).filter { brokenFiles[$0.1.path] == nil }
        for (_, t) in addWork(have: have) where brokenFiles[t.path] != nil { rep.failures.append("\(t.title): skipped, \(brokenFiles[t.path]!)") }
        var queued = Set(work.map(\.1.path))
        var lists: [(OTPlaylist, [OTTrack])] = []
        for p in playlists where playlistsToAdd.contains(p.id) {      // playlists bring the tracks there are files for
            syncPhase = "Reading playlist \(p.name)"; syncTotal = 0
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
        var mine: [(CratePlaylist, [LibTrack])] = []
        for cp in cratePlaylists where cp.onIPod {      // and Crate's playlists
            let ts = songs(cp)
            mine.append((cp, ts))
            for t in ts where !have.contains(t.key) && queued.insert(t.path).inserted {
                if let a = libraryTrack(key: t.key)?.album { work.append((a, t)) }
            }
        }
        syncPhase = "Adding songs"; syncTotal = work.count; syncDone = 0
        // Conversions run ahead, several at once on this Mac; the iPod gets one copy at a time, in order.
        let settings = podSettings
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crate-convert-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let slots = Slots(max(2, cores - 2))
        let ahead = max(4, cores * 2)       // how far conversions may run ahead of the copying
        var prepared: [Int: Task<URL?, Error>] = [:]
        func schedule(_ i: Int) {
            guard i < work.count, prepared[i] == nil else { return }
            let t = work[i].1
            prepared[i] = Task.detached {
                guard settings.needsConversion(t) else { return nil }
                await slots.take()
                defer { Task { await slots.give() } }
                return try await Syncer.prepare(t, settings: settings, in: tmp)
            }
        }
        for (n, (album, var t)) in work.enumerated() {
            for i in n...min(n + ahead, work.count - 1) { schedule(i) }
            syncCurrent = (settings.needsConversion(t) ? "Converting " : "Copying ") + "\(t.trackArtist.isEmpty ? t.artist : t.trackArtist) – \(t.title)"
            let ready: URL?
            do { ready = try await prepared[n]?.value } catch { rep.failures.append("\(t.title): \(error.localizedDescription)"); syncDone = n + 1; continue }
            prepared[n] = nil
            if podSettings.fillTagsFromMetadata, let mb = metadata[album.id] {
                if t.year == 0 { t.year = mb.year }
                if t.genre.isEmpty { t.genre = mb.genre }
            }
            do {
                db.tracks.append(try await Syncer.add(t, to: ipod, albumCount: album.tracks.count, id: db.nextID, settings: podSettings, prepared: ready))
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
        syncPhase = "Writing playlists"; syncCurrent = ""; syncTotal = 0
        let idByKey = Dictionary(db.tracks.flatMap { t in [(t.key, t.id)] + (aliases[t.key].map { [($0, t.id)] } ?? []) }, uniquingKeysWith: { a, _ in a })
        for (p, ts) in lists {
            let items = ts.compactMap { t in libraryTrack(for: t).flatMap { idByKey[$0.track.key] } ?? idByKey[t.key] }
                .map { PodPlaylist.Item(trackID: $0) }
            if let i = db.playlists.firstIndex(where: { samePlaylist($0.name, p.name) }) { db.playlists[i].items = items }
            else { db.playlists.append(PodPlaylist(name: p.name, items: items)) }
            rep.playlists += 1
        }
        for (sp, ts) in smart {
            let items = ts.compactMap { idByKey[$0.key] }.map { PodPlaylist.Item(trackID: $0) }
            if let i = db.playlists.firstIndex(where: { samePlaylist($0.name, sp.name) }) { db.playlists[i].items = items }
            else { db.playlists.append(PodPlaylist(name: sp.name, items: items)) }
            rep.playlists += 1
        }
        for (cp, _) in mine {      // by key, so songs that are only on the iPod (added there) stay
            let items = cp.keys.compactMap { idByKey[$0] }.map { PodPlaylist.Item(trackID: $0) }
            let id: UInt64
            if let i = db.playlists.firstIndex(where: { $0.id == cp.podID }) ?? db.playlists.firstIndex(where: { samePlaylist($0.name, cp.name) }) {
                db.playlists[i].items = items
                if !samePlaylist(db.playlists[i].name, cp.name) { db.playlists[i].rename(cp.name) }
                id = db.playlists[i].id
            } else {
                let new = PodPlaylist(name: cp.name, items: items)
                db.playlists.append(new); id = new.id
            }
            if let i = cratePlaylist(cp.id) { cratePlaylists[i].podID = id }
            rep.playlists += 1
        }
        for i in db.playlists.indices {       // the hidden-playlist mark, then the hide flags it implies
            let want = podName(forPlaylist: db.playlists[i].name)
            if db.playlists[i].name != want { db.playlists[i].rename(want) }
        }
        let rule = ruleHidden(db.playlists, tracks: db.tracks)
        for i in db.tracks.indices {
            let want = wantsHidden(db.tracks[i].key, rule)
            if db.tracks[i].hidden != want { db.setHidden(i, want) }
        }
        for i in db.tracks.indices {        // ratings set in Crate
            if let r = ratings[aliases[db.tracks[i].key] ?? db.tracks[i].key] { db.setRating(i, r) }
        }
        let solo = Set(db.tracks.map { $0.artist.lowercased() } + artists.map { $0.name.lowercased() })
        for i in db.tracks.indices {        // collaborations under their main artist, or back to the full credit
            let t = db.tracks[i]
            let found = index[aliases[t.key] ?? t.key]
            let lib = found?.1.artist
            let full = lib.map { ArtistCredit.main($0, solo: solo) == t.artist } == true ? lib! : t.artist
            let want = podSettings.mainArtistOnly ? ArtistCredit.main(full, solo: solo) : full
            // the library album's artist, which Frogger lists the track under (one name per album);
            // songs that are only on the iPod keep theirs
            let album = found.map { $0.0.artist }.flatMap { $0.isEmpty ? nil : $0 }
            if want != t.artist || (album != nil && album != t.albumArtist) {
                db.retag(i, PodRetag(title: t.title, album: t.album, artist: want, albumArtist: album))
            }
        }
        if podSettings.calendars || podSettings.reminders {
            syncPhase = "Calendars and To Do"; syncCurrent = ""; syncTotal = 0
            rep.calendars = await CalendarSync.write(to: ipod, settings: podSettings)
        }
        syncPhase = "Writing the database"; syncCurrent = ""; syncTotal = 0
        do {
            try Syncer.write(db, to: ipod)
            retags = retags.filter { renames[$0.key] == nil }
            syncPhase = "Cover art"; syncCurrent = ""; syncTotal = 0
            await FroggerArt.write(db, to: ipod, albums: albums) { done, total, album in     // for Frogger's Now Playing page
                self.syncDone = done; self.syncTotal = total; self.syncCurrent = album
            }
            syncCurrent = ""
        }
        catch { rep.error = "Writing the database failed: \(error.localizedDescription)" }
        toAdd = []; songsToAdd = []; playlistsToAdd = []
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

    /// Uses an image you dropped on an album's cover as its cover.jpg.
    func setCover(_ data: Data, for album: Album) async {
        guard NSImage(data: data) != nil, !isPodOnly(album) else { notify("That isn't an image"); return }
        let fm = FileManager.default
        for n in ["folder.jpg", "cover.png", "folder.png", "front.jpg"] where fm.fileExists(atPath: album.folder + "/" + n) {
            try? fm.moveItem(atPath: album.folder + "/" + n, toPath: album.folder + "/" + n + ".old")
        }
        try? fm.removeItem(atPath: album.folder + "/cover.jpg")
        guard fm.createFile(atPath: album.folder + "/cover.jpg", contents: data) else { notify("Couldn't write cover.jpg in \(album.folder)"); return }
        artwork[album.id] = ArtCache.store(data, for: "album:" + album.folder) ?? NSImage(data: data)
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
        notify("New cover for \(album.title)")
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
        artwork[album.id] = ArtCache.store(d, for: "album:" + album.folder) ?? img
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

    /// Copies albums from the iPod into the library (for music that only lives on the iPod).
    func copyFromIPod(_ albums: [Album]) async {
        guard let ipod, connected, let db else { notify("Connect the iPod to copy from it"); return }
        let keys = Set(albums.flatMap { $0.tracks.map(\.key) })
        let urls = db.tracks.filter { keys.contains($0.key) }.map { ipod.mount.appendingPathComponent($0.relativePath) }
        guard !urls.isEmpty else { return }
        let job = startJob(albums.count == 1 ? "Copying \(albums[0].title) from the iPod" : "Copying \(albums.count) albums from the iPod", icon: "ipod")
        do {
            let r = try await Importer.run(urls, into: importFolder, rename: true)
            await addToLibrary(r.tracks)
            finishJob(job, "\(r.tracks.count) songs copied to the library" + (r.skipped > 0 ? ", \(r.skipped) already there" : ""))
        } catch { finishJob(job, "Copying failed: \(error.localizedDescription)", failed: true) }
    }

    var podOnlyAlbums: [Album] { podAlbums.filter(isPodOnly) }

    /// Where a remote playlist comes from (a sidebar group of its own).
    func source(of p: OTPlaylist) -> String { p.spotifyID != nil ? "Spotify" : "OwnTone" }
    var remoteSources: [String] { ["Spotify", "OwnTone"].filter { s in playlists.contains { source(of: $0) == s } } }

    /// Where a playlist on the iPod came from.
    enum PodOrigin { case spotify, ownTone, smart, crate, onTheGo, ipod
        var icon: String {
            switch self {
            case .spotify: return "dot.radiowaves.left.and.right"
            case .ownTone: return "hifispeaker"
            case .smart: return "gearshape.2"
            case .crate: return "music.note.list"
            case .onTheGo: return "hand.tap"
            case .ipod: return "ipod"
            }
        }
        var help: String {
            switch self {
            case .spotify: return "Copied from a Spotify playlist"
            case .ownTone: return "Copied from an OwnTone playlist"
            case .smart: return "Kept up to date from a smart playlist"
            case .crate: return "Kept up to date from a playlist in Crate"
            case .onTheGo: return "Made on the iPod (On-The-Go)"
            case .ipod: return "Only on the iPod"
            }
        }
    }
    func origin(of p: PodPlaylist) -> PodOrigin {
        if smartPlaylists.contains(where: { $0.name == p.name }) { return .smart }
        if cratePlaylists.contains(where: { $0.podID == p.id || $0.name == p.name }) { return .crate }
        if let r = playlists.first(where: { $0.name == p.name }) { return r.spotifyID != nil ? .spotify : .ownTone }
        return p.name.hasPrefix("On-The-Go") ? .onTheGo : .ipod
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
            artwork[lib.id] = ArtCache.store(d, for: "album:" + lib.folder) ?? img
            if on(.ownTone) { await ownToneRescan(ownToneURL) }
        }
    }

    // MARK: Spotify

    /// Spotify albums you have files for (matched on album title).
    func hasFiles(_ s: SpotifyAlbum) -> Bool { libraryIDs.contains(s.name.lowercased()) }

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
