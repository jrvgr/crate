import SwiftUI
import QuickLook

// The window: a sidebar grouped into Library, the iPod, Playlists and Sources (one per plugin),
// a detail column, the search field at the top of the sidebar, and an activity bar at the bottom.

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @FocusState private var searchFocused: Bool
    @ObservedObject private var pageFilter = PageFilter.shared

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            NavigationStack(path: $model.path) {
                Group {
                    if !model.search.isEmpty { SearchView() }
                    else { PaneView(pane: model.pane ?? .albums) }
                }
                .modifier(BackForward())
                .modifier(FadeIn(when: model.path.isEmpty))
                .navigationDestination(for: Route.self) { r in
                    Group {
                    switch r {
                    case .album(let a): AlbumDetail(album: a)
                    case .artist(let name): ArtistDetail(name: name)
                    case .spotifyAlbum(let a): SpotifyAlbumView(album: a)
                    case .amAlbum(let a): AMAlbumView(album: a)
                    case .release(let g, let artist): SpotifyAlbumView(release: g, artist: artist)
                    }
                    }
                    .navigationBarBackButtonHidden(true)    // the window's own back button covers it
                    .modifier(BackForward())
                    .modifier(FadeIn())
                }
            }
            .onChange(of: model.path) { old, new in Hero.shared.navigated(from: old, to: new) }
            .onChange(of: model.pane) { old, new in
                Hero.shared.cancel()     // another page from the sidebar: nothing flies home
                if new == .ipod { Hero.shared.open(.ipod("page")) } else if old == .ipod { Hero.shared.close(.ipod("page")) }
            }
            .onChange(of: model.showSync) { _, on in on ? Hero.shared.open(.ipod("sync")) : Hero.shared.close(.ipod("sync")) }
            .overlay(alignment: .bottom) { ActivityBar() }
            .overlay { if model.dropTarget == .library { DropOverlay(text: "Add to Library", detail: "Copies into \((model.importRoot as NSString).lastPathComponent)", icon: "square.and.arrow.down") } }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importDropped(urls, toIPod: false) }
                return true
            } isTargeted: { on in model.dropTarget = on ? .library : (model.dropTarget == .library ? nil : model.dropTarget) }
            .overlay { if model.dropTarget == .unpin { DropOverlay(text: "Unpin", detail: "Takes it out of the sidebar", icon: "pin.slash") } }
            .onDrop(of: [Pane.pinnedType], isTargeted: Binding(get: { model.dropTarget == .unpin },
                                                              set: { on in model.dropTarget = on ? .unpin : (model.dropTarget == .unpin ? nil : model.dropTarget) })) { providers in
                for p in providers {
                    p.loadDataRepresentation(forTypeIdentifier: Pane.pinnedType.identifier) { d, _ in
                        guard let d, let k = String(data: d, encoding: .utf8) else { return }
                        Task { @MainActor in _ = model.unpinDropped(["crate-pinned:" + k]) }
                    }
                }
                return true
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Albums, artists, songs")
        .searchFocused($searchFocused)
        .onChange(of: model.focusSearch) { searchFocused = true }
        .quickLookPreview($model.quickLook)
        .onChange(of: model.place) { old, _ in model.visited(from: old) }
        .toolbar {
            if let prompt = pageFilter.prompt {
                // a capsule of its own at the toolbar's height: in the shared glass it merged into the iPod/bell/refresh
                // buttons' capsule (a ToolbarSpacer between them made no difference)
                ToolbarItem { PageFilterField(prompt: prompt).frame(height: 36).glassEffect(.regular, in: .capsule) }
                    .sharedBackgroundVisibility(.hidden)
            }
            if model.on(.musicAssistant) || model.on(.ownTone) {
                ToolbarItem { PlayOnMenu(player: model.player, ma: model.ma) }
            }
            if model.on(.soulseek) || model.on(.appleMusic) || model.on(.youtube) { ToolbarItem { DownloadIndicator() } }
            ToolbarItem { ActivityButton() }
            ToolbarItem {
                Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.syncing).help("Reload the library and the iPod")
            }
            ToolbarItem {
                Button { model.reviewSync() } label: {
                    Label(model.pendingCount > 0 ? "Sync \(model.pendingCount)" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.ipod == nil || (model.pendingCount == 0 && !model.syncing))
                .help(!model.connected ? "Review the queued changes; they sync when the iPod is connected" : "Review and sync the changes to the iPod")
            }
        }
        .task {
            let args = CommandLine.arguments    // for testing, see README
            func arg(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            for (flag, pane) in [("--open-recent", Pane.recent), ("--open-spotify", .spotify), ("--open-artists", .artists),
                                 ("--open-apple-music", .appleMusic), ("--open-ipod", .ipod), ("--open-songs", .songs),
                                 ("--open-soulseek", .soulseek), ("--open-downloads", .downloads), ("--open-health", .health), ("--open-youtube", .youtube), ("--open-review", .review), ("--open-albums", .albums)]
            where args.contains(flag) { model.pane = pane }
            if let q = arg("--search") { model.search = q }
            if let t = arg("--spotify-tab") { model.spotifyTab = t }
            model.spotifyArtist = arg("--spotify-artist")
            let m = model
            Snapshot.listen(m)
            Task { await slsk.poll { m.on(.soulseek) } }
            await model.reload()
            if let t = arg("--open-lookup") { model.lookupAlbum = model.albums.first { $0.title == t } }
            if let t = arg("--open-album"), let a = model.allAlbums.first(where: { $0.title == t }) { model.pane = .albums; model.path = [.album(a)] }
            if let n = arg("--open-playlist") {
                if let p = model.playlists.first(where: { $0.name == n }) { model.pane = .playlist(p.id) }
                else if let p = model.db?.playlists.first(where: { $0.name == n }) { model.pane = .podPlaylist(p.id) }
            }
            if let n = arg("--open-artist") { model.path = [.artist(n)] }
            if args.contains("--open-sync") { model.reviewSync() }
            if args.contains("--demo-sync") {     // screenshots: the sync sheet mid-sync, without syncing anything
                model.plan = model.makePlan(); model.syncing = true; model.syncPhase = "Adding songs"
                model.syncTotal = 40; model.syncDone = 17; model.syncCurrent = "Converting Aphex Twin – Xtal"; model.showSync = true
            }
        }
        // Find Metadata and Edit Tags happen on the album's own page
        .onChange(of: model.lookupAlbum) { _, a in if a != nil { model.editAlbum = nil }; model.showAlbumPage(a) }
        .onChange(of: model.editAlbum) { _, a in if a != nil { model.lookupAlbum = nil }; model.showAlbumPage(a) }
        .onChange(of: model.dedupeAlbum) { _, a in model.showAlbumPage(a) }
        .sheet(item: $model.editSmart) { SmartEditor(playlist: $0).environmentObject(model) }
        .modifier(PlaylistDialogs())
        .sheet(isPresented: $model.showMatch) { MatchSheet().environmentObject(model) }
        .sheet(item: $model.linking) { LinkSheet(track: $0).environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.merge != nil }, set: { if !$0 { model.merge = nil } })) {
            MergeSheet(albums: model.merge ?? []).environmentObject(model)
        }
        .confirmationDialog(model.albumOnAlbum.map { "“\($0.dragged.title)” on “\($0.target.title)”" } ?? "",
                            isPresented: Binding(get: { model.albumOnAlbum != nil }, set: { if !$0 { model.albumOnAlbum = nil } }),
                            presenting: model.albumOnAlbum) { pair in
            Button("Use “\(pair.dragged.title)”'s Cover for “\(pair.target.title)”") {
                Task { if let d = await model.coverData(pair.dragged) { await model.setCover(d, for: pair.target) } }
            }
            .disabled(model.artwork[pair.dragged.id] == nil)      // the shown cover: reading the files here ran on every redraw
            Button("Use “\(pair.target.title)”'s Cover for “\(pair.dragged.title)”") {
                Task { if let d = await model.coverData(pair.target) { await model.setCover(d, for: pair.dragged) } }
            }
            .disabled(model.artwork[pair.target.id] == nil)
            Button("Merge the Two Albums…") { model.merge = [pair.target, pair.dragged] }
            Button("Cancel", role: .cancel) {}
        } message: { pair in
            Text("Give one the other's cover, or merge them into one album (you pick the name and artist next).")
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { model.confirmTrash != nil }, set: { if !$0 { model.confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                let ts = model.confirmTrash ?? []
                model.confirmTrash = nil
                Task { await model.trash(ts) }
            }
        } message: {
            Text("The files go to the Trash (on a network share: a hidden .crate-trash folder there), so you can put them back. Copies on the iPod are removed at the next sync.")
        }
        .sheet(isPresented: Binding(get: { model.organize != nil }, set: { if !$0 { model.organize = nil } })) {
            OrganizerSheet(albums: model.organize ?? []).environmentObject(model)
        }
        .sheet(isPresented: $model.showMissing) {
            MissingAlbumsSheet().environmentObject(model).environmentObject(slsk).environmentObject(model.spotifyAPI)
        }
        .sheet(isPresented: Binding(get: { model.batchAlbums != nil }, set: { if !$0 { model.batchAlbums = nil } })) {
            BatchMetadataSheet(albums: model.batchAlbums ?? []).environmentObject(model)
        }
        // in the window rather than a sheet, so the sidebar's iPod can fly into it
        .overlay { SyncPanel() }
        .overlay { HeroOverlay() }
    }
}

/// The sync details over the window, like a sheet.
struct SyncPanel: View {
    @EnvironmentObject var model: Model

    var body: some View {
        ZStack {
            if model.showSync {
                Color.black.opacity(0.12).ignoresSafeArea().contentShape(.rect).onTapGesture {}     // the window behind waits
                    .transition(.opacity)
                // looks like a sheet: the window's own background, a hairline edge and a sheet's shadow
                SyncSheet()
                    .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 16))
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.showSync)
    }
}

/// Back and forward through pages and what's open on them; first in the toolbar on every page.
struct BackForward: ViewModifier {
    @EnvironmentObject var model: Model
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.back.isEmpty).keyboardShortcut("[", modifiers: .command).help("Back")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(model.forward.isEmpty).keyboardShortcut("]", modifiers: .command).help("Forward")
            }
            ToolbarItem(placement: .navigation) { PageTitleLabel() }.sharedBackgroundVisibility(.hidden)
        }
    }
}

extension ContentView {
    var trashTitle: String {
        let ts = model.confirmTrash ?? []
        let albums = Set(ts.map { $0.album.lowercased() })
        return ts.count == 1 ? "Delete “\(ts[0].title)”?" : albums.count == 1 ? "Delete “\(ts.first?.album ?? "")” (\(ts.count) songs)?"
            : "Delete \(albums.count) albums (\(ts.count) songs)?"
    }
}

struct PaneView: View {
    @EnvironmentObject var model: Model
    var pane: Pane
    var body: some View {
        switch pane {
        case .recent: RecentView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .songs: SongsView()
        case .health: HealthView()
        case .review: YearInReview()
        case .smart(let id): SmartPlaylistView(id: id)
        case .ipod: IPodView()
        case .spotify: SpotifyGrid()
        case .youtube: YouTubeView()
        case .appleMusic: AppleMusicView()
        case .soulseek: SoulseekView()
        case .downloads: DownloadsView()
        case .playlists: PlaylistsPage()
        case .playlist(let id):
            if let p = model.playlists.first(where: { $0.id == id }) { PlaylistView(playlist: p) }
            else { ContentUnavailableView("Playlist not found", systemImage: "music.note.list") }
        case .podPlaylist(let id):
            if let p = model.db?.playlists.first(where: { $0.id == id }) { PodPlaylistView(playlist: p) }
            else { ContentUnavailableView("Playlist not on the iPod", systemImage: "music.note.list") }
        case .cratePlaylist(let id): CratePlaylistView(id: id)
        }
    }
}

// MARK: sync marks

/// How an item relates to the iPod, shown as a small badge.
enum SyncMark {
    case none, onIPod, partial, adding, removing

    var icon: String? {
        switch self {
        case .none: return nil
        case .onIPod: return "checkmark"
        case .partial: return "circle.lefthalf.filled"
        case .adding: return "plus"
        case .removing: return "minus"
        }
    }
    var tint: Color {
        switch self {
        case .none: return .clear
        case .onIPod: return .green
        case .partial: return .orange
        case .adding: return .blue        // not the accent: it may be red, which reads as an error
        case .removing: return .red
        }
    }
    var help: String {
        switch self {
        case .none: return "Not on the iPod"
        case .onIPod: return "On the iPod"
        case .partial: return "Partly on the iPod"
        case .adding: return "Will be added on Sync"
        case .removing: return "Will be removed on Sync"
        }
    }
}

extension Model {
    func mark(_ a: Album) -> SyncMark {
        if toAdd.contains(a.id) || a.tracks.contains(where: { songsToAdd.contains($0.path) }) { return .adding }
        if toRemove.contains(a.id) || a.tracks.contains(where: { songsToRemove.contains($0.key) }) { return .removing }
        switch state(a) { case .none: return .none; case .partial: return .partial; case .onIPod: return .onIPod }
    }

    func mark(_ p: OTPlaylist) -> SyncMark {
        if let pod = podPlaylist(for: p), playlistsToRemove.contains(pod.id) { return .removing }
        if playlistsToAdd.contains(p.id) { return .adding }
        return podPlaylist(for: p) == nil ? .none : .onIPod
    }

    func mark(_ p: PodPlaylist) -> SyncMark { playlistsToRemove.contains(p.id) ? .removing : .onIPod }

    /// A badge's ✓ is easy to hit on the way to the cover: removing takes ⌥-click (or the context menu).
    static var removeClick: Bool { NSEvent.modifierFlags.contains(.option) }
    static let removeHint = "On the iPod · ⌥-click to remove"

    /// Clicking a badge: queue, unqueue, or mark for removal.
    func cycle(_ a: Album) {
        switch mark(a) {
        case .adding: toAdd.remove(a.id)
        case .removing: toRemove.remove(a.id)
        case .onIPod: if Self.removeClick { toRemove.insert(a.id) }
        case .partial, .none: if !isPodOnly(a) { toAdd.insert(a.id) }
        }
    }
}

struct MarkBadge: View {
    var mark: SyncMark
    var size: CGFloat = 26
    var help: String?
    var body: some View {
        if let icon = mark.icon {
            Image(systemName: icon).font(.system(size: size * 0.46, weight: .bold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(mark.tint), in: .circle)
                .help(help ?? mark.help)
        }
    }
}

struct SidebarMark: View {
    var mark: SyncMark
    var body: some View {
        if let icon = mark.icon {
            Image(systemName: icon == "checkmark" ? "checkmark.circle.fill" : icon + ".circle.fill")
                .foregroundStyle(mark.tint).help(mark.help)
        }
    }
}

// MARK: sidebar

/// Which sidebar groups are open (remembered).
@MainActor
final class SidebarUI: ObservableObject {
    @AppStorage("sidebarSmart") var smart = true
    @AppStorage("sidebarPlaylists") var playlists = true
    @AppStorage("sidebarIPod") var ipod = true
    @AppStorage("sidebarCollapsed") private var collapsedText = ""
    var collapsed: Set<String> {
        get { Set(collapsedText.split(separator: "\n").map(String.init)) }
        set { collapsedText = newValue.sorted().joined(separator: "\n"); objectWillChange.send() }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var player: Player
    @StateObject private var ui = SidebarUI()
    @Namespace private var pod

    var body: some View {
        // Clicking a row always goes to its top level, also when it's already selected with an album open.
        let selection = Binding<Pane?>(get: { model.search.isEmpty ? model.pane : nil },
                                       set: { model.search = ""; model.pane = $0 ?? model.pane; model.path = [] })
        VStack(spacing: 0) {
        List(selection: selection) {
            Section("Library") {
                Label("Recently Added", systemImage: "clock").tag(Pane.recent)
                SidebarRow(title: "Albums", icon: "square.stack", count: model.allAlbums.count).tag(Pane.albums)
                SidebarRow(title: "Artists", icon: "music.microphone", count: model.artists.count).tag(Pane.artists)
                SidebarRow(title: "Songs", icon: "music.note", count: model.libTracks.count).tag(Pane.songs)
                Label("Needs Attention", systemImage: "stethoscope").tag(Pane.health)
                Label("Year in Review", systemImage: "chart.bar.xaxis").tag(Pane.review)
            }

            // the Playlists page and the ones you pinned from it, together
            let pins = model.pinned.compactMap { p in model.pinLabel(p).map { (p, $0) } }
            Section("Playlists") {
                SidebarRow(title: "All Playlists", icon: "square.grid.2x2", count: model.playlistCount).tag(Pane.playlists)
                ForEach(pins, id: \.0) { pane, l in
                    HStack {
                        Label(l.name, systemImage: l.icon).lineLimit(1)
                        Spacer()
                        if l.mark != .onIPod { SidebarMark(mark: l.mark) }     // on the iPod is the usual case
                    }
                    .tag(pane)
                    .contextMenu { PinButton(pane: pane) }
                    // drag out: onto the window to unpin, onto the iPod card to queue
                    .itemProvider { pane.pinKey.map(Pane.pinnedProvider) }
                }
                // reorder by dragging (pins counts only the playlists still there)
                .onMove { var p = pins.map(\.0); p.move(fromOffsets: $0, toOffset: $1); model.pinned = p }
            }

            let sources = [PluginID.spotify, .appleMusic, .soulseek, .youtube].filter { model.on($0) }
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources) { p in
                        Group {
                            if p == .spotify { Label { Text(p.name) } icon: { Image(nsImage: SpotifyMark.template) } }
                            else { Label(p.name, systemImage: p.icon) }
                        }
                        .tag(p == .spotify ? Pane.spotify : p == .appleMusic ? .appleMusic : p == .youtube ? .youtube : .soulseek)
                    }
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in model.pinDropped(items) }
        ShareNotice().padding(.horizontal, 10).padding(.top, 6)
        // when music starts the remote lifts out of the card's iPod, which leaves an icon behind
        VStack(spacing: 0) {
            if player.showsRemote && !model.ipodAway { PlayerCard(ns: pod).padding(.top, 10).zIndex(1) }
            IPodCard(ns: pod).padding(10)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: player.showsRemote && !model.ipodAway)
        .zIndex(1)      // a dragged remote passes over the list, not under it
        }
    }
}

/// A sidebar group's header: the chevron always shows (List only shows its own on hover) and the whole title toggles.
struct SidebarHeader<Trailing: View>: View {
    var title: String
    @Binding var open: Bool
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            trailing
        }
    }
}

struct SidebarRow: View {
    var title, icon: String
    var count: Int
    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

struct PlaylistMenu: View {
    @EnvironmentObject var model: Model
    var playlist: OTPlaylist
    var body: some View {
        let pod = model.podPlaylist(for: playlist)
        Button(model.playlistsToAdd.contains(playlist.id) ? "Don't Sync" : pod == nil ? "Add to iPod" : "Update on iPod",
               pod: model.ipod?.glyph) { model.toggleAdd(playlist) }
        if let pod {
            Button(model.playlistsToRemove.contains(pod.id) ? "Keep on iPod" : "Remove from iPod", systemImage: "minus.circle") {
                model.toggleRemove(pod)
            }
        }
        HiddenPlaylistButton(name: playlist.name)
        if playlist.subsonicID != nil {
            Button("Play", systemImage: "play.fill") { Task { await model.playSongs(of: playlist) } }
        } else if let uri = model.playURI(playlist) {
            Button(model.playURILabel, systemImage: "play.fill") { Task { await model.playURIs([uri]) } }
        }
        if model.ownToneEditable(playlist) {
            Divider()
            Button("Rename…", systemImage: "pencil") { model.startRename(.ownTone(playlist.id)) }
            Button("Delete…", systemImage: "trash", role: .destructive) { model.confirmDeletePlaylist = .ownTone(playlist.id) }
        }
    }
}

/// Marks a playlist as hidden: its songs (unless another playlist has them) stay out of the iPod's
/// Artists/Albums (Frogger's hide flag, written on Sync).
struct HiddenPlaylistButton: View {
    @EnvironmentObject var model: Model
    var name: String
    var body: some View {
        let on = model.isHiddenPlaylist(name)
        if model.froggerFeatures {
            Button(on ? "Show Its Songs in iPod Library" : "Hide Its Songs from iPod Library", systemImage: on ? "eye" : "eye.slash") {
                model.toggleHiddenPlaylist(name)
            }
        }
    }
}

struct IPodCard: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var player: Player
    @StateObject private var hover = HoverState()
    var ns: Namespace.ID

    var body: some View {
        // big while syncing and for a drop, unless the player card already shows a big iPod
        // the iPod is out on its page or in the sync panel: an icon holds its place here
        let away = model.ipodAway
        let big = (model.syncing || model.dropTarget == .ipod) && !player.showsRemote && !away
        VStack(alignment: .leading, spacing: 8) {
            if big {
                // as wide as the card
                Color.clear.aspectRatio(IPodArt.aspect, contentMode: .fit)
                    .overlay { GeometryReader { g in PodPicture(height: g.size.height) } }
                    .heroSource(.ipod("page")).heroSource(.ipod("sync"))
                    .matchedGeometryEffect(id: "ipod", in: ns)
                    .frame(maxWidth: .infinity)
            }
            if let i = model.ipod, let db = model.db {
                HStack(spacing: 10) {
                    if player.showsRemote || away {
                        // the player card, the iPod page or the sync panel already draws the iPod: two read oddly
                        Image.pod(i.glyph, height: 30).frame(width: 34, height: 34)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Hero.shared.dock = $0 }
                            // gone at once when the iPod comes back, so it doesn't fade under the one landing there
                            .foregroundStyle(.secondary).transition(.asymmetric(insertion: .opacity, removal: .identity))
                    } else if !big {
                        PodPicture(height: 46)
                            .heroSource(.ipod("page")).heroSource(.ipod("sync"))
                            .matchedGeometryEffect(id: "ipod", in: ns)
                            .modifier(PullOut())
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.podName).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                        if let e = model.podReadError {
                            Label("Can't read the iPod", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red).lineLimit(1)
                                .help("Its song database won't open: \(e). Crate shows the last copy it read and won't sync until this is fixed.")
                        } else {
                        Text(model.connected ? "\(db.tracks.count) songs · \(ByteCountFormatter.string(fromByteCount: i.free, countStyle: .file)) free"
                             : "Not connected")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    // one icon: the card opens the iPod page (its settings live there); Eject is in its context menu
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.pane == .ipod || hover.on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                CapacityBar(height: 6, incoming: max(0, model.pendingCount > 0 ? model.queuedBytes : 0))
                if model.pendingCount > 0, !model.syncing, model.queuedBytes != 0 {
                    let q = model.queuedBytes
                    Text((q >= 0 ? "≈ \(ByteCountFormatter.string(fromByteCount: q, countStyle: .file)) to add" : "≈ \(ByteCountFormatter.string(fromByteCount: -q, countStyle: .file)) freed")
                         + (q > i.free ? " · doesn't fit" : ""))
                        .font(.caption).foregroundStyle(q > i.free ? .red : .secondary)
                }
                if model.syncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.syncTotal > 0 ? "\(model.syncPhase) \(model.syncDone) of \(model.syncTotal)" : model.syncPhase).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show") { model.showSync = true }.font(.caption).buttonStyle(.link)
                    }
                } else if model.pendingCount > 0 && !model.connected {
                    Label("\(model.pendingCount) change\(model.pendingCount == 1 ? "" : "s") waiting", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(model.podSettings.syncOnConnect ? "They sync by themselves when the iPod is plugged in" : "They sync when you press Sync")
                } else if model.pendingCount > 0 {
                    Button { model.reviewSync() } label: {
                        Label("Sync \(model.pendingCount) change\(model.pendingCount == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    Image.pod(height: 30).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No iPod").font(.headline)
                        Text("Connect it over USB").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: big)
        // a drop only lifts the glass a little: the accent (red here) read as an error
        .glassEffect(model.dropTarget == .ipod ? .regular.tint(.primary.opacity(0.08)) : .regular, in: .rect(cornerRadius: 16))
        .overlay { if model.dropTarget == .ipod { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.2), lineWidth: 1) } }
        .contentShape(.rect)
        .onHover { hover.on = $0 }
        .onTapGesture { if model.ipod != nil { model.search = ""; model.pane = .ipod } }
        .contextMenu {
            if model.ipod != nil {
                Button("Show iPod", pod: model.ipod?.glyph) { model.search = ""; model.pane = .ipod }
                Button("Sync…", systemImage: "arrow.triangle.2.circlepath") { model.reviewSync() }.disabled(model.pendingCount == 0 || model.syncing)
                Button("Eject", systemImage: "eject") { model.eject() }.disabled(!model.connected || model.syncing)
            }
        }
        .help("Open the iPod's page and settings; drop music or playlists here to add them to the iPod")
        .dropDestination(for: PodDrop.self) { items, _ in
            let urls = items.compactMap { if case .url(let u) = $0 { u } else { nil } }
            let texts = items.compactMap { if case .text(let t) = $0 { t } else { nil } }
            if !urls.isEmpty { Task { await model.importDropped(urls, toIPod: true) } }
            return model.queueDropped(texts) || !urls.isEmpty
        } isTargeted: { on in model.dropTarget = on ? .ipod : (model.dropTarget == .ipod ? nil : model.dropTarget) }
    }
}

/// The player while something plays: a drawn iPod whose buttons and wheel drive whatever speaker
/// is playing. Kept apart from the real iPod's card so it doesn't read as the iPod playing.
/// Done with it: drag the remote back down into the iPod card. The music plays on and the remote waits
/// in there until it's pulled out again; without an iPod card to wait in, the music stops.
struct PlayerCard: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var player: Player
    @StateObject private var drag = PlayerDrag()
    var ns: Namespace.ID
    static let dropDistance: CGFloat = 80

    var body: some View {
        let home = drag.offset.height > Self.dropDistance
        let hero = Hero.shared
        // no card of its own: just the remote, with where it plays under it
        VStack(spacing: 6) {
            Color.clear.aspectRatio(IPodArt.aspect, contentMode: .fit)
                .overlay { GeometryReader { g in LiveIPod(height: g.size.height) } }
                .heroSource(.ipod("page")).heroSource(.ipod("sync"))
                .matchedGeometryEffect(id: "ipod", in: ns)
                // while it's dragged the window's overlay draws it (the sidebar column would clip it); this one
                // stays put, nearly invisible, so the drag goes on
                .opacity(drag.offset == .zero && !drag.landing ? 1 : 0.001)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.base = $0 }
                // the wheel and the scrub bar keep their own drags: this one starts on the rest of the iPod
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        drag.offset = g.translation
                        let r = drag.base.offsetBy(dx: g.translation.width, dy: g.translation.height)
                        hero.dragged = g.translation.height > Self.dropDistance ? r.insetBy(dx: r.width * 0.05, dy: r.height * 0.05) : r
                    }
                    .onEnded { g in
                        drag.landing = true; drag.offset = .zero
                        if g.translation.height > Self.dropDistance, model.db != nil, let at = hero.dragged {
                            // into the card: the sidebar closes up while the iPod flies to where the card's will be
                            hero.dragged = nil
                            hero.dock(from: at)
                            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { player.docked = true }
                            return
                        }
                        if g.translation.height > Self.dropDistance {     // no iPod card to go into: the music stops
                            hero.dragged = nil; drag.landing = false
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { player.stop() }
                            return
                        }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8), completionCriteria: .removed) { hero.dragged = drag.base } completion: {
                            hero.dragged = nil; drag.landing = false
                        }
                    })
                .pointerStyle(drag.offset == .zero ? .grabIdle : .grabActive)
            Text(home ? "Let go to stop" : "on \(model.outputName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .zIndex(1)      // dragged over the iPod card, not under it
        .help("Crate's remote for \(model.outputName), not the iPod itself. Drag it back onto the iPod to stop.")
    }
}

@MainActor
final class PlayerDrag: ObservableObject {
    @Published var offset: CGSize = .zero
    @Published var landing = false              // let go: the overlay's copy is on its way home or into the card
    var base: CGRect = .zero                    // where the remote sits, in the window
}

/// The card's iPod while the remote is docked in it: drag it up (or double-click it) to get the remote back.
struct PullOut: ViewModifier {
    @EnvironmentObject var player: Player
    @StateObject private var drag = PlayerDrag()

    func body(content: Content) -> some View {
        if player.docked, player.current != nil {
            content
                .offset(y: min(0, drag.offset.height))
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { drag.offset = $0.translation }
                    .onEnded { g in
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            if g.translation.height < -30 { player.docked = false }
                            drag.offset = .zero
                        }
                    })
                .onTapGesture(count: 2) { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { player.docked = false } }
                .pointerStyle(drag.offset == .zero ? .grabIdle : .grabActive)
                .help("Drag up for the remote (playing \(player.current?.title ?? ""))")
        } else { content }
    }
}

/// The iPod's disk: music, other files, what the queued changes will add, free space.
struct CapacityBar: View {
    @EnvironmentObject var model: Model
    var height: CGFloat = 10
    var incoming: Int64 = 0

    var body: some View {
        GeometryReader { g in
            let cap = Double(max(model.ipod?.capacity ?? 1, 1))
            let music = Double(model.musicBytes), used = Double(model.ipod?.used ?? 0)
            let other = max(0, used - music), add = Double(incoming)
            let w = { (b: Double) in max(0, g.size.width * b / cap) }
            HStack(spacing: 1) {
                Rectangle().fill(.tint).frame(width: w(music))
                Rectangle().fill(.orange).frame(width: w(other))
                if add > 0 { Rectangle().fill(.tint.opacity(0.45)).frame(width: min(w(add), max(0, g.size.width - w(music) - w(other)))) }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(.capsule)
        }
        .frame(height: height)
        .help("Music \(ByteCountFormatter.string(fromByteCount: model.musicBytes, countStyle: .file)), other \(ByteCountFormatter.string(fromByteCount: max(0, (model.ipod?.used ?? 0) - model.musicBytes), countStyle: .file)), free \(ByteCountFormatter.string(fromByteCount: model.ipod?.free ?? 0, countStyle: .file))")
    }
}

struct DropOverlay: View {
    var text, detail, icon: String
    var body: some View {
        RoundedRectangle(cornerRadius: 22).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 22))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
                    Text(text).font(.title2.bold())
                    Text(detail).foregroundStyle(.secondary)
                }
                .padding(28).glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .padding(16)
            .allowsHitTesting(false)
    }
}

// MARK: activity

/// A fixed-size bar at the bottom of the window: what's running right now, or the last message.
struct ActivityBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let running = model.activeJobs
        let current = running.first { $0.state == .running } ?? running.first
        let visible = model.syncing || current != nil || !model.message.isEmpty
        HStack(spacing: 12) {
            if model.syncing {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
                    .symbolEffect(.rotate, isActive: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Syncing \(model.podName)").font(.callout.weight(.semibold)).lineLimit(1)
                    SyncBar()
                }
                Button("Details") { model.showSync = true }.buttonStyle(.glass).controlSize(.small)
            } else if let j = current {
                Image(symbol: j.icon).foregroundStyle(.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(j.title + (running.count > 1 ? "  +\(running.count - 1) more" : "")).font(.callout.weight(.semibold)).lineLimit(1)
                    if let p = j.progress { ProgressView(value: p) }
                    else { Text(j.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 18)
                Text(model.message).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 440, height: 52)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.bottom, 14)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 30)
        .animation(.snappy, value: visible)
        .allowsHitTesting(visible)
    }
}

/// Toolbar button with a list of everything Crate did or is doing.
/// Downloads live here too (they're things running): a row at the bottom opens their page.
/// While something downloads (Soulseek, Apple Music, YouTube): a ring with how far along it all is; opens Downloads.
/// Gone again when nothing is coming in.
struct DownloadIndicator: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    var body: some View {
        let busy = model.downloadEntries(slsk).filter { !$0.finished }
        if !busy.isEmpty {
            let p = busy.map { min(max($0.progress, 0), 1) }.reduce(0, +) / Double(busy.count)
            Button { model.search = ""; model.path = []; model.pane = .downloads } label: {
                ZStack {
                    Circle().stroke(.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(p, 0.03)).stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: p)
                    Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                }
                .frame(width: 16, height: 16)
            }
            .help("\(busy.count) downloading · \(Int(p * 100))% – show Downloads")
        }
    }
}

struct ActivityButton: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @StateObject private var shown = Toggle()
    final class Toggle: ObservableObject { @Published var on = false }

    var body: some View {
        let n = model.activeJobs.count
        let downloads = slsk.active.count + model.jobs.filter { $0.source != nil && $0.active }.count + model.yt.jobs.filter { !$0.finished }.count
        let downloading = model.on(.soulseek) || model.on(.appleMusic) || model.on(.youtube)
        Button { shown.on.toggle() } label: {
            // not a clock: next to Refresh's arrow, two circles read as the same thing
            Label("Activity", systemImage: n + downloads > 0 ? "bell.badge" : "bell")
        }
        .help(downloads > 0 ? "Activity · \(downloads) downloading" : "Activity")
        .popover(isPresented: $shown.on, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Activity").font(.headline)
                    Spacer()
                    Button("Clear") { model.jobs.removeAll { !$0.active } }.buttonStyle(.link)
                        .disabled(!model.jobs.contains { !$0.active })
                }
                .padding(14)
                Divider()
                if model.jobs.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.jobs) { j in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(symbol: j.icon).foregroundStyle(j.active ? Color.accentColor : .secondary).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(j.title).font(.callout.weight(.medium)).lineLimit(1)
                                        if j.state == .running, let p = j.progress { ProgressView(value: p) }
                                        Text(j.state == .queued ? "Waiting" : j.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    switch j.state {
                                    case .running: ProgressView().controlSize(.small)
                                    case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
                                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
                if downloading {
                    Divider()
                    Button { shown.on = false; model.search = ""; model.pane = .downloads } label: {
                        HStack {
                            Label("Downloads", systemImage: "arrow.down.circle")
                            Spacer()
                            if downloads > 0 { Text("\(downloads) downloading").foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain).padding(14)
                }
            }
            .frame(width: 360)
        }
    }
}

// MARK: sync sheet

/// Review → progress → result, in one sheet that keeps its size.
struct SyncSheet: View {
    @EnvironmentObject var model: Model
    func dismiss() { model.showSync = false }

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
        // the iPod itself, big enough to watch: its screen shows the sync, the wheel spins
        IPodArt(mode: model.podArtMode, name: model.podName, height: model.syncing ? 260 : 230, frogger: model.froggerSticker)
            .heroTarget(.ipod("sync"))
            .animation(.spring(response: 0.55, dampingFraction: 0.55), value: model.syncing)
            .frame(width: 160, height: 260)
            .padding(.top, 6)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.syncing ? "Syncing \(model.podName)" : model.report != nil ? "Sync finished" : "Sync \(model.podName)")
                        .font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Group {
                if model.syncing { progress }
                else if let r = model.report { result(r) }
                else if let p = model.plan { review(p) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if !model.syncing && model.report == nil {
                    Button("Discard Changes", role: .destructive) { model.discardChanges(); dismiss() }
                        .buttonStyle(.glass)
                }
                Spacer()
                if model.syncing {
                    Text("You can close this; the sync keeps going.").font(.caption).foregroundStyle(.secondary)
                    Button("Hide") { dismiss() }.buttonStyle(.glass)
                } else if model.report != nil {
                    if model.connected { Button("Eject", systemImage: "eject") { model.eject(); dismiss() }.buttonStyle(.glass) }
                    Button("Done") { model.report = nil; dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                } else {
                    if !model.connected {
                        Text(model.podSettings.syncOnConnect ? "Syncs by itself when you connect the iPod" : "Connect the iPod to sync")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(model.connected ? "Cancel" : "Close") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    Button("Start Sync") { Task { await model.sync() } }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                        .disabled(!model.connected || model.pendingCount == 0 || !(fits))
                }
            }
        }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .interactiveDismissDisabled(model.syncing)
    }

    var fits: Bool {
        guard let p = model.plan, let i = model.ipod else { return false }
        return p.bytesIn - p.bytesOut < i.free - 50_000_000
    }

    var subtitle: String {
        guard let i = model.ipod else { return "Not connected" }
        if !model.connected { return "Not connected · last seen \((model.lastSeen ?? Date()).formatted(.relative(presentation: .named)))" }
        return "\(i.modelName) · \(ByteCountFormatter.string(fromByteCount: i.free, countStyle: .file)) free"
    }

    func review(_ p: SyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                if p.addSongs > 0 || !p.addAlbums.isEmpty {
                    PlanRow(icon: "plus.circle.fill", tint: .accentColor, title: "Add \(p.addSongs) songs",
                            detail: p.addAlbums.prefix(3).map(\.title).joined(separator: ", ") + (p.addAlbums.count > 3 ? " and \(p.addAlbums.count - 3) more" : "")
                                + (p.convertSongs > 0 ? " · \(p.convertSongs) converted to \(model.podSettings.aacKbps) kbps AAC" : ""))
                }
                if p.removeSongs > 0 {
                    PlanRow(icon: "minus.circle.fill", tint: .red, title: "Remove \(p.removeSongs) songs",
                            detail: p.removeAlbums.prefix(3).map(\.title).joined(separator: ", ") + (p.removeAlbums.count > 3 ? " and \(p.removeAlbums.count - 3) more" : ""))
                }
                if !p.playlistsAdd.isEmpty {
                    PlanRow(icon: "music.note.list", tint: .accentColor, title: "Copy \(p.playlistsAdd.count) playlist\(p.playlistsAdd.count == 1 ? "" : "s")",
                            detail: p.playlistsAdd.joined(separator: ", ") + " (songs there are files for)")
                }
                if !p.playlistsRemove.isEmpty {
                    PlanRow(icon: "music.note.list", tint: .red, title: "Remove \(p.playlistsRemove.count) playlist\(p.playlistsRemove.count == 1 ? "" : "s")",
                            detail: p.playlistsRemove.joined(separator: ", "))
                }
                if !p.playlistsEdit.isEmpty {
                    PlanRow(icon: "music.note.list", tint: .purple, title: "Change \(p.playlistsEdit.count) playlist\(p.playlistsEdit.count == 1 ? "" : "s")",
                            detail: p.playlistsEdit.joined(separator: ", ") + " (edited in Crate)")
                }
                if p.onTheGo > 0 {
                    PlanRow(icon: "music.note.list", tint: .green, title: "Save \(p.onTheGo) playlist\(p.onTheGo == 1 ? "" : "s") from the iPod",
                            detail: "Made or changed on the iPod; saved ones become Crate playlists")
                }
                if let n = p.rename {
                    PlanRow(icon: "pencil.circle.fill", tint: .purple, title: "Rename to “\(n)”", detail: "Was “\(model.db?.name ?? "")”")
                }
                if p.retag > 0 {
                    PlanRow(icon: "pencil.circle.fill", tint: .purple, title: "Update the tags of \(p.retag) song\(p.retag == 1 ? "" : "s")",
                            detail: "Merged or edited in Crate; the iPod's copies get the new album and title")
                }
                if !p.markPlaylists.isEmpty {
                    PlanRow(icon: "pencil.circle.fill", tint: .purple, title: "Rename \(p.markPlaylists.count) playlist\(p.markPlaylists.count == 1 ? "" : "s")",
                            detail: p.markPlaylists.joined(separator: ", "))
                }
                if p.hide + p.unhide > 0 {
                    PlanRow(icon: "eye.slash", tint: .secondary, title: hideTitle(p),
                            detail: "Hidden songs stay out of Artists and Albums but still play from playlists (needs Frogger)")
                }
                if model.checkingFiles {
                    PlanRow(icon: "checkmark.shield", tint: .secondary, title: "Checking the files…", detail: "Broken or cut-off files are skipped")
                } else if !model.brokenFiles.isEmpty {
                    PlanRow(icon: "exclamationmark.triangle.fill", tint: .orange, title: "\(model.brokenFiles.count) broken file\(model.brokenFiles.count == 1 ? "" : "s") will be skipped",
                            detail: model.brokenFiles.prefix(3).map { "\(($0.key as NSString).lastPathComponent): \($0.value)" }.joined(separator: "; "))
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            let preview = model.syncPreview()
            if !preview.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, a in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(a.album).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    if !a.add.isEmpty { Text("+\(a.add.count)").font(.caption.bold()).foregroundStyle(.tint) }
                                    if !a.remove.isEmpty { Text("−\(a.remove.count)").font(.caption.bold()).foregroundStyle(.red) }
                                }
                                ForEach(a.add, id: \.self) { Label($0, systemImage: "plus").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                ForEach(a.remove, id: \.self) { Label($0, systemImage: "minus").font(.caption).foregroundStyle(.red.opacity(0.8)).lineLimit(1) }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 6) {
                CapacityBar(height: 12, incoming: max(0, p.bytesIn - p.bytesOut))
                HStack {
                    Text(p.bytesIn > 0 ? "About \(ByteCountFormatter.string(fromByteCount: p.bytesIn, countStyle: .file)) to copy"
                         : p.addSongs > 0 ? "Working out the size…" : "Nothing to copy")
                    if p.bytesOut > 0 { Text("· \(ByteCountFormatter.string(fromByteCount: p.bytesOut, countStyle: .file)) freed") }
                    Spacer()
                    if !fits && p.bytesIn > 0 { Label("Doesn't fit", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.syncPhase).font(.headline)
                    Spacer()
                    if model.syncTotal > 0 { Text("\(model.syncDone) of \(model.syncTotal)").monospacedDigit().foregroundStyle(.secondary) }
                }
                SyncBar()
                Text(model.syncCurrent.isEmpty ? " " : model.syncCurrent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(phases, id: \.self) { for_phase($0) }
            }
            .padding(.horizontal, 4)
            Text("Keep the iPod connected until the sync is done.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The sync's phases in order (Model.sync).
    var phases: [String] {
        ["Removing songs", "Fixing song files", "Adding songs"] + (model.podSettings.soundCheck ? ["Measuring loudness"] : []) + ["Writing playlists"]
            + (model.podSettings.calendars || model.podSettings.reminders ? ["Calendars and To Do"] : [])
            + ["Writing the database", "Cover art"]
    }

    /// Where the sync is in `phases`: reading playlists happens while songs are gathered for adding.
    var phaseIndex: Int {
        let p = model.syncPhase
        if p == "Done" { return phases.count }
        if p.hasPrefix("Reading playlist") { return phases.firstIndex(of: "Adding songs") ?? 0 }
        return phases.firstIndex(of: p) ?? -1
    }

    func for_phase(_ name: String) -> some View {
        let i = phases.firstIndex(of: name) ?? 0, done = i < phaseIndex, now = i == phaseIndex
        return HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : now ? "circle.dotted" : "circle")
                .foregroundStyle(done ? .green : now ? Color.accentColor : .secondary)
                .symbolEffect(.pulse, isActive: now)
            Text(name).foregroundStyle(done || now ? .primary : .secondary)
        }
    }

    func result(_ r: SyncReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = r.error {
                Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Label(r.failures.isEmpty ? "Everything was synced" : "Synced, with \(r.failures.count) problem\(r.failures.count == 1 ? "" : "s")",
                      systemImage: r.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(r.failures.isEmpty ? .green : .orange)
            }
            HStack(spacing: 12) {
                Stat(value: "\(r.added)", label: "added")
                Stat(value: "\(r.removed)", label: "removed")
                if r.replaced > 0 { Stat(value: "\(r.replaced)", label: "fixed") }
                Stat(value: "\(r.playlists)", label: "playlists")
                Stat(value: r.seconds >= 60 ? "\(Int(r.seconds) / 60)m \(Int(r.seconds) % 60)s" : "\(Int(r.seconds))s", label: "took")
            }
            if !r.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(10).glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
            if r.changedElsewhere > 0 {
                Label("\(r.changedElsewhere) change\(r.changedElsewhere == 1 ? " was" : "s were") made on the iPod by something else since Crate read it; they were kept.",
                      systemImage: "arrow.triangle.merge").font(.callout).foregroundStyle(.secondary)
            }
            if !r.calendars.isEmpty {
                Label(r.calendars.prefix(1).uppercased() + r.calendars.dropFirst(), systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
            }
            if r.playCounts > 0 {
                Label("Plays and ratings of \(r.playCounts) songs from the iPod were saved.", systemImage: "play.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let db = model.db { Text("\(db.tracks.count) songs on \(db.name) now.").foregroundStyle(.secondary) }
        }
    }
}

struct PlanRow: View {
    var icon: String, tint: Color, title, detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// The sync's progress: the current phase's count, or a moving bar for a phase without one.
struct SyncBar: View {
    @EnvironmentObject var model: Model
    var body: some View {
        if model.syncTotal > 0 {
            ProgressView(value: Double(min(model.syncDone, model.syncTotal)), total: Double(model.syncTotal))
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }
}
