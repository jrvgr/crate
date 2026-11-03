import SwiftUI
import QuickLook

// The window: a sidebar grouped into Library, the iPod, Playlists and Sources (one per plugin),
// a detail column, the search field at the top of the sidebar, and an activity bar at the bottom.

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @FocusState private var searchFocused: Bool

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
                .navigationDestination(for: Route.self) { r in
                    switch r {
                    case .album(let a): AlbumDetail(album: a)
                    case .artist(let name): ArtistDetail(name: name)
                    }
                }
            }
            .overlay(alignment: .bottom) { ActivityBar() }
            .overlay { if model.dropTarget == .library { DropOverlay(text: "Add to Library", detail: "Copies into \((model.importFolder as NSString).lastPathComponent)", icon: "square.and.arrow.down") } }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importDropped(urls, toIPod: false) }
                return true
            } isTargeted: { on in model.dropTarget = on ? .library : (model.dropTarget == .library ? nil : model.dropTarget) }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Albums, artists, songs")
        .searchFocused($searchFocused)
        .onChange(of: model.focusSearch) { searchFocused = true }
        .quickLookPreview($model.quickLook)
        .toolbar {
            ToolbarItem(placement: .principal) { MiniPlayer() }
            if model.on(.soulseek) || model.on(.appleMusic) || model.on(.youtube) {
                ToolbarItem { DownloadsButton() }
            }
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
            let m = model
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
        .sheet(item: $model.lookupAlbum) { LookupSheet(album: $0).environmentObject(model) }
        .sheet(item: $model.editAlbum) { TagEditor(album: $0).environmentObject(model) }
        .sheet(item: $model.editSmart) { SmartEditor(playlist: $0).environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.organize != nil }, set: { if !$0 { model.organize = nil } })) {
            OrganizerSheet(albums: model.organize ?? []).environmentObject(model)
        }
        .sheet(isPresented: $model.showMissing) {
            MissingAlbumsSheet().environmentObject(model).environmentObject(slsk).environmentObject(model.spotifyAPI)
        }
        .sheet(isPresented: Binding(get: { model.batchAlbums != nil }, set: { if !$0 { model.batchAlbums = nil } })) {
            BatchMetadataSheet(albums: model.batchAlbums ?? []).environmentObject(model)
        }
        .sheet(isPresented: $model.showSync) { SyncSheet().environmentObject(model) }
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
        case .playlist(let id):
            if let p = model.playlists.first(where: { $0.id == id }) { PlaylistView(playlist: p) }
            else { ContentUnavailableView("Playlist not found", systemImage: "music.note.list") }
        case .podPlaylist(let id):
            if let p = model.db?.playlists.first(where: { $0.id == id }) { PodPlaylistView(playlist: p) }
            else { ContentUnavailableView("Playlist not on the iPod", systemImage: "music.note.list") }
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
        case .adding: return .accentColor
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
        if toAdd.contains(a.id) { return .adding }
        if toRemove.contains(a.id) { return .removing }
        switch state(a) { case .none: return .none; case .partial: return .partial; case .onIPod: return .onIPod }
    }

    func mark(_ p: OTPlaylist) -> SyncMark {
        if let pod = podPlaylist(for: p), playlistsToRemove.contains(pod.id) { return .removing }
        if playlistsToAdd.contains(p.id) { return .adding }
        return podPlaylist(for: p) == nil ? .none : .onIPod
    }

    func mark(_ p: PodPlaylist) -> SyncMark { playlistsToRemove.contains(p.id) ? .removing : .onIPod }

    /// Clicking a badge: queue, unqueue, or mark for removal.
    func cycle(_ a: Album) {
        switch mark(a) {
        case .adding: toAdd.remove(a.id)
        case .removing: toRemove.remove(a.id)
        case .onIPod: toRemove.insert(a.id)
        case .partial, .none: if !isPodOnly(a) { toAdd.insert(a.id) }
        }
    }
}

struct MarkBadge: View {
    var mark: SyncMark
    var size: CGFloat = 26
    var body: some View {
        if let icon = mark.icon {
            Image(systemName: icon).font(.system(size: size * 0.46, weight: .bold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(mark.tint), in: .circle)
                .help(mark.help)
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

struct Sidebar: View {
    @EnvironmentObject var model: Model

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

            let ownLists = model.playlists
            Section {
                    ForEach(model.smartPlaylists) { p in
                        HStack {
                            Label(p.name, systemImage: "gearshape.2").lineLimit(1)
                            Spacer()
                            if p.onIPod { SidebarMark(mark: model.smartNeedsSync(p) ? .adding : .onIPod) }
                        }
                        .tag(Pane.smart(p.id))
                        .contextMenu {
                            Button("Edit Rules…", systemImage: "slider.horizontal.3") { model.editSmart = p }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSmart(p) }
                        }
                    }
                    ForEach(ownLists) { p in
                        HStack {
                            Label(p.name, systemImage: p.spotifyID != nil ? "dot.radiowaves.left.and.right" : "music.note.list").lineLimit(1)
                            Spacer()
                            SidebarMark(mark: model.mark(p))
                        }
                        .tag(Pane.playlist(p.id))
                        .contextMenu { PlaylistMenu(playlist: p) }
                    }
                    ForEach(model.podOnlyPlaylists) { p in
                        HStack {
                            Label(p.name, systemImage: "ipod").lineLimit(1)
                            Spacer()
                            SidebarMark(mark: model.mark(p))
                        }
                        .tag(Pane.podPlaylist(p.id))
                        .help("Only on the iPod")
                        .contextMenu {
                            Button(model.playlistsToRemove.contains(p.id) ? "Keep on iPod" : "Remove from iPod", systemImage: "minus.circle") {
                                model.toggleRemove(p)
                            }
                        }
                    }
                    ForEach(model.onTheGo, id: \.self) { l in
                        HStack {
                            Label("On-The-Go", systemImage: "ipod")
                            Spacer()
                            SidebarMark(mark: model.podSettings.importOnTheGo ? .adding : .none)
                        }
                        .help("\(l.trackIDs.count) songs made on the iPod; saved as a playlist on Sync")
                    }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button { model.editSmart = SmartPlaylist() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New Smart Playlist")
                }
            }

            let sources = [PluginID.spotify, .appleMusic, .soulseek, .youtube].filter { model.on($0) }
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources) { p in
                        Label(p.name, systemImage: p.icon).tag(p == .spotify ? Pane.spotify : p == .appleMusic ? .appleMusic : p == .youtube ? .youtube : .soulseek)
                    }
                }
            }
        }
        IPodCard().padding(10)
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
               systemImage: "ipod") { model.toggleAdd(playlist) }
        if let pod {
            Button(model.playlistsToRemove.contains(pod.id) ? "Keep on iPod" : "Remove from iPod", systemImage: "minus.circle") {
                model.toggleRemove(pod)
            }
        }
        Button(model.on(.ownTone) ? "Play on OwnTone" : "Open in Spotify", systemImage: "play.fill") { Task { await model.playURIs([playlist.uri]) } }
    }
}

struct IPodCard: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let i = model.ipod, let db = model.db {
                SidebarIPod()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.podName).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                        Text(model.connected ? "\(db.tracks.count) songs · \(ByteCountFormatter.string(fromByteCount: i.free, countStyle: .file)) free"
                             : "Not connected · \(db.tracks.count) songs")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.connected {
                        Button { model.eject() } label: { Image(systemName: "eject.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .disabled(model.syncing).help("Eject")
                    } else {
                        Image(systemName: "powerplug").foregroundStyle(.tertiary).help("Not connected")
                    }
                }
                CapacityBar(height: 6)
                if model.syncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Syncing \(model.syncDone) of \(model.syncTotal)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show") { model.showSync = true }.font(.caption).buttonStyle(.link)
                    }
                } else if model.pendingCount > 0 && !model.connected {
                    Label("\(model.pendingCount) change\(model.pendingCount == 1 ? "" : "s") \(model.podSettings.syncOnConnect ? "sync when connected" : "waiting")",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.pendingCount > 0 {
                    Button { model.reviewSync() } label: {
                        Label("Sync \(model.pendingCount) change\(model.pendingCount == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "ipod").font(.system(size: 24, weight: .light)).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No iPod").font(.headline)
                        Text("Connect it over USB").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .glassEffect(model.dropTarget == .ipod ? .regular.tint(.accentColor) : .regular, in: .rect(cornerRadius: 16))
        .overlay { if model.dropTarget == .ipod { RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2) } }
        .contentShape(.rect)
        .onTapGesture { if model.ipod != nil { model.search = ""; model.pane = .ipod } }
        .help("Drop music here to add it to the library and the iPod")
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importDropped(urls, toIPod: true) }
            return true
        } isTargeted: { on in model.dropTarget = on ? .ipod : (model.dropTarget == .ipod ? nil : model.dropTarget) }
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
                    ProgressView(value: Double(model.syncDone), total: Double(max(model.syncTotal, 1)))
                }
                Button("Details") { model.showSync = true }.buttonStyle(.glass).controlSize(.small)
            } else if let j = current {
                Image(systemName: j.icon).foregroundStyle(.tint).frame(width: 18)
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

/// Opens Downloads; shows how many are running.
struct DownloadsButton: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    var body: some View {
        let n = slsk.active.count + model.jobs.filter { $0.source != nil && $0.active }.count + model.yt.jobs.filter { !$0.finished }.count
        Button { model.search = ""; model.pane = .downloads } label: {
            Label("Downloads", systemImage: n > 0 ? "arrow.down.circle.dotted" : "arrow.down.circle")
        }
        .badge(n)
        .help(n > 0 ? "\(n) downloading" : "Downloads")
    }
}

/// Toolbar button with a list of everything Crate did or is doing.
struct ActivityButton: View {
    @EnvironmentObject var model: Model
    @StateObject private var shown = Toggle()
    final class Toggle: ObservableObject { @Published var on = false }

    var body: some View {
        let n = model.activeJobs.count
        Button { shown.on.toggle() } label: {
            Label("Activity", systemImage: n > 0 ? "clock.badge" : "clock")
        }
        .help("Activity")
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
                                    Image(systemName: j.icon).foregroundStyle(j.active ? Color.accentColor : .secondary).frame(width: 18)
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
            }
            .frame(width: 360)
        }
    }
}

// MARK: sync sheet

/// Review → progress → result, in one sheet that keeps its size.
struct SyncSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
        // the iPod itself, big enough to watch: its screen shows the sync, the wheel spins
        IPodArt(mode: model.podArtMode, name: model.podName, height: model.syncing ? 260 : 230)
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
        .frame(width: 760, height: 480)
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
                if p.onTheGo > 0 {
                    PlanRow(icon: "music.note.list", tint: .green, title: "Save \(p.onTheGo) On-The-Go list\(p.onTheGo == 1 ? "" : "s")",
                            detail: "Made on the iPod; kept as “On-The-Go N” playlists")
                }
                if let n = p.rename {
                    PlanRow(icon: "pencil.circle.fill", tint: .purple, title: "Rename to “\(n)”", detail: "Was “\(model.db?.name ?? "")”")
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
                ProgressView(value: Double(model.syncDone), total: Double(max(model.syncTotal, 1)))
                Text(model.syncCurrent.isEmpty ? " " : model.syncCurrent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                for_phase("Removing songs", after: ["Adding songs", "Measuring loudness", "Writing playlists", "Writing the database", "Done"])
                for_phase("Adding songs", after: ["Measuring loudness", "Writing playlists", "Writing the database", "Done"])
                if model.podSettings.soundCheck { for_phase("Measuring loudness", after: ["Writing playlists", "Writing the database", "Done"]) }
                for_phase("Writing playlists", after: ["Writing the database", "Done"])
                for_phase("Writing the database", after: ["Done"])
            }
            .padding(.horizontal, 4)
            Text("Keep the iPod connected until the sync is done.").font(.caption).foregroundStyle(.secondary)
        }
    }

    func for_phase(_ name: String, after: [String]) -> some View {
        let done = after.contains(model.syncPhase), now = model.syncPhase == name
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

struct Stat: View {
    var value, label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
