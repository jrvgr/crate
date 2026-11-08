import SwiftUI
import AppKit

/// What the detail column shows; the iPod's state is shown on every item as well.
enum Pane: Hashable {
    case recent, albums, artists, songs, playlists, health, review, ipod
    case smart(UUID)
    case spotify, appleMusic, soulseek, downloads, youtube
    case playlist(Int), podPlaylist(UInt64), cratePlaylist(UUID)
}

/// Pages pushed on top of a pane.
/// Where the window is: a page and what's open on it. Back and forward go through these.
/// A page in the back/forward history; the search it was opened from too, so going back returns to the results.
struct Place: Equatable { var pane: Pane?; var path: [Route]; var search = "" }

enum Route: Hashable { case album(Album), artist(String), spotifyAlbum(SpotifyAlbum), amAlbum(AMAlbum), release(ReleaseGroup, artist: String) }

/// An album artist with their albums (compilations under "Various Artists").
struct Artist: Identifiable, Hashable {
    var id: String { name.lowercased() }
    var name: String
    var albums: [Album]
    var trackCount: Int { albums.map(\.tracks.count).reduce(0, +) }
}

enum AlbumFilter: String, CaseIterable { case all = "All", onIPod = "On iPod", notOnIPod = "Not on iPod", podOnly = "Only on iPod" }
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
    @AppStorage("ownToneURL") var ownToneURL = ""
    @AppStorage("discogsToken") var discogsToken = ""
    @AppStorage("extraFolders") var foldersText = ""
    @AppStorage("pinnedPlaylists") var pinnedText = ""         // playlists pinned to the sidebar (Pane.pinKey)
    @AppStorage("importFolder") var importFolder = ""          // "": the music folder (importRoot)

    @Published var plugins: Set<PluginID> = PluginStore.load() { didSet { PluginStore.save(plugins) } }
    let slsk = Slskd()
    let spotifyAPI = SpotifyAPI()
    let player = Player()
    let yt = YouTube()
    let subsonic = Subsonic()
    let tagr = Tagr()
    let lidarr = Lidarr()
    let ma = MusicAssistant()

    // library
    @Published var libTracks: [LibTrack] = [] { didSet { genreCache = nil; libraryVersion += 1 } }
    /// Goes up whenever the songs change, and `syncVersion` whenever what's on (or queued for) the iPod does:
    /// views that filter the whole library keep their result until one of them moves.
    var libraryVersion = 0
    var syncVersion = 0
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
    @Published var cratePlaylists: [CratePlaylist] = Store.load("playlists.json", []) { didSet { Store.save("playlists.json", cratePlaylists); invalidateSyncCache() } }
    @Published var podEdits: [UInt64: PodPlaylistEdit] = Store.load("pod-playlist-edits.json", [:]) { didSet { Store.save("pod-playlist-edits.json", podEdits); invalidateSyncCache() } }
    @Published var renaming: PlaylistRef?
    @Published var renameText = ""
    @Published var confirmDeletePlaylist: PlaylistRef?
    @Published var smartPending = 0 { didSet { invalidateSyncCache() } }
    @Published var editSmart: SmartPlaylist?
    @Published var podSettings = PodSettings() { didSet { hiddenCache = nil; invalidateSyncCache(); if let i = ipod, podSettings != oldValue { PodSettings.save(podSettings, serial: i.key) } } }
    @Published var connected = false
    /// Set when the iPod's database is there but can't be read (a disk or filesystem error). Crate
    /// then shows the last copy it read and won't sync: writing would replace the real database.
    @Published var podReadError: String?
    @Published var lastSeen: Date?
    @Published var toAdd: Set<Album.ID> = [] { didSet { savePending() } }
    @Published var toRemove: Set<Album.ID> = [] { didSet { savePending() } }
    @Published var songsToAdd: Set<String> = [] { didSet { savePending() } }       // library file paths
    @Published var songsToRemove: Set<String> = [] { didSet { savePending() } }    // track keys on the iPod
    @Published var fileSizes: [String: Int64] = [:] { didSet { invalidateSyncCache() } }
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
    var diskWatch: DiskWatch?
    @Published var ratings: [String: Int] = Store.load("ratings.json", [:])        // library key → stars
    /// Frogger's extras (sticker, hiding songs, cover art for its Now Playing page, its iPod settings); off for a stock iPod.
    @Published var froggerFeatures = UserDefaults.standard.object(forKey: "froggerFeatures") as? Bool ?? true {
        didSet { UserDefaults.standard.set(froggerFeatures, forKey: "froggerFeatures") }
    }
    /// The iPod wears the frog sticker when it runs Frogger.
    var froggerSticker: Bool { froggerFeatures && podSettings.frogger == .installed }
    @Published var keptArtists: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "keptArtists") ?? [])
    @Published var brokenFiles: [String: String] = [:]
    @Published var checkingFiles = false
    @Published var showMatch = false
    @Published var links: [String: String] = Store.load("links.json", [:]) { didSet { Store.save("links.json", links) } }     // streamed song (uri and key) → library file path
    @Published var linking: OTTrack?           // the streamed song the Link to Local Song sheet is open for
    @Published var coverDrop: Album.ID?        // the cover an image is being dragged over
    @Published var albumOnAlbum: AlbumPair?    // an album dropped on another's cover: what to do with the two
    @Published var playlistsToAdd: Set<OTPlaylist.ID> = [] { didSet { savePending() } }
    @Published var playlistsToRemove: Set<PodPlaylist.ID> = [] { didSet { savePending() } }
    @Published var pendingName: String? { didSet { savePending() } }
    var restoring = false
    @Published var onTheGo: [OnTheGo] = [] { didSet { invalidateSyncCache() } }
    @Published var orphans: [URL]?
    @Published var podCheck: PodCheck?
    @Published var strayBytes: Int64 = 0            // the stray files' size, read with the check
    @Published var backupOnPod = false      // iTunesDB.crate-backup is there, read when the iPod loads
    @Published var history: [PodSample] = []

    // sync
    @Published var showSync = false
    /// The iPod is out on its own page or in the sync panel: the sidebar shows neither its iPod nor the remote.
    var ipodAway: Bool { (pane == .ipod && search.isEmpty && path.isEmpty) || showSync }
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
    /// A song or album (its id) the next page scrolls to and lights up a moment: the remote's Now Playing lines go there.
    @Published var highlight: String?
    @Published var search = ""
    @Published var back: [Place] = []         // the toolbar's back and forward, across pages
    @Published var forward: [Place] = []
    var travelling = false
    @Published var albumFilter = AlbumFilter.all
    @Published var albumSort = AlbumSort.artist
    @AppStorage("artistView") var artistView = "grid"        // "grid", "list" or "flow"
    @AppStorage("albumView") var albumView = "grid"          // "grid", "flow" or "list"
    @AppStorage("albumsByArtist") var albumsByArtist = false  // the library grid in a section per artist
    @Published var lookupAlbum: Album?
    @Published var dedupeAlbum: Album?           // its page shows the Duplicates panel
    @Published var editAlbum: Album?
    @Published var batchAlbums: [Album]?
    @Published var showMissing = false
    @Published var organize: [Album]?
    @Published var merge: [Album]?
    @Published var confirmTrash: [LibTrack]?
    @Published var artistInfo: [String: ArtistInfo] = ArtistLookup.load()
    @Published var artistLoading: Set<String> = []
    @Published var artistFailed: Set<String> = []        // MusicBrainz didn't answer (or doesn't know them), this run
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
    var amRunning = false

    // activity
    @Published var jobs: [Job] = []
    @Published var message = ""
    var messageTask: Task<Void, Never>?

    @Published var dropTarget: DropTarget?
    var unchecked: Set<Album.ID> = []               // covers shown from the cache before loadArtwork checked them
    enum DropTarget { case library, ipod, unpin }

    var observers: [NSObjectProtocol] = []
    var index: [String: (album: Album, track: LibTrack)] = [:]
    var pathIndex: [String: (album: Album, track: LibTrack)] = [:]

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
        player.stream = { [weak self] t in self.flatMap { $0.on(.subsonic) ? $0.subsonic.streamURL(forPath: t.path) : nil } }
        player.remote = { [weak self] in
            guard let self, self.on(.musicAssistant), self.player.output.hasPrefix("ma:") else { return nil }
            return (self.ma, String(self.player.output.dropFirst(3)))
        }
        player.remoteURI = { [weak self] t in MusicAssistant.uri(subsonicID: self?.subsonic.song(for: t)?.id, uri: t.uri) }
        player.onRemoteError = { [weak self] in self?.notify($0) }
        player.local = { [weak self] t in
            guard let self, let m = self.index[t.key] ?? self.index["~" + Self.loose(t.album) + "|" + Self.loose(t.title)] else { return nil }
            return (m.album.tracks, m.album.tracks.firstIndex { $0.id == m.track.id } ?? 0)
        }
        if on(.musicAssistant) { Task { try? await ma.loadPlayers() } }
        yt.onFiles = { [weak self] files, id in
            guard let self, let j = self.yt.jobs.first(where: { $0.id == id }) else { return }
            await self.importFiles(files, toIPod: false, title: "Importing \(j.title)")
        }
    }


    /// The iPod's songs as library keys (paired songs count as their library song).
    // Worked out once when the library or the iPod changes, not on every redraw (the album grid asks
    // for these per tile, which made every click slow).
    var podKeys: Set<String> = []
    var podAlbums: [Album] = []
    var podKeyByID: [UInt32: String] = [:]      // the database's track id → key
    var allAlbums: [Album] = []
    var artists: [Artist] = []
    var libraryIDs: Set<Album.ID> = []
    var albumByID: [Album.ID: Album] = [:]
    var syncCache: (pending: Int?, bytes: Int64?) = (nil, nil)
    var podLoads = 0

    /// Plugging the iPod in later in the session starts the queued sync, not the very first scan at launch.
    var lastSeenAtLaunch = false
    var saveTask: Task<Void, Never>?
    var hiddenCache: Set<String>? { didSet { if hiddenCache == nil { ruleCache = nil; invalidateSyncCache() } } }
    /// ruleHidden for the database Crate last read, cleared with hiddenCache.
    var ruleCache: Set<String>?
}


/// An album dragged onto another album's cover.
struct AlbumPair: Equatable { var dragged, target: Album }
