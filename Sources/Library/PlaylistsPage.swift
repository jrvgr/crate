import SwiftUI
import UniformTypeIdentifiers

// Every playlist on one page: Crate's own, smart ones, the ones only on the iPod and each server's.
// The sidebar shows only the ones you pin, so a server with dozens doesn't fill it.

@MainActor
final class PlaylistsUI: ObservableObject {
    @AppStorage("playlistsTab") var tab = "All"
    @Published var query = ""
}

struct PlaylistsPage: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = PlaylistsUI()
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    /// One card: what it shows and where it goes.
    struct Card: Identifiable {
        enum Kind { case crate(CratePlaylist), smart(SmartPlaylist), pod(PodPlaylist), remote(OTPlaylist) }
        var kind: Kind
        var name, detail, icon: String
        var mark: SyncMark
        var pane: Pane
        var id: Pane { pane }
    }

    var groups: [(title: String, cards: [Card])] {
        var out: [(String, [Card])] = []
        out.append(("Crate", model.cratePlaylists.map { p in
            Card(kind: .crate(p), name: p.name, detail: "\(p.keys.count) songs", icon: "music.note.list",
                 mark: p.onIPod ? (model.crateNeedsSync(p) ? .adding : .onIPod) : .none, pane: .cratePlaylist(p.id))
        }))
        out.append(("Smart", model.smartPlaylists.map { p in
            Card(kind: .smart(p), name: p.name, detail: "Smart playlist", icon: "wand.and.stars",
                 mark: p.onIPod ? (model.smartNeedingSync.contains(p.id) ? .adding : .onIPod) : .none, pane: .smart(p.id))
        }))
        out.append(("On iPod", model.podOnlyPlaylists.map { p in
            Card(kind: .pod(p), name: model.podDisplayName(p), detail: "\(p.items.count) songs · only on the iPod", icon: model.origin(of: p).icon,
                 mark: model.playlistsToRemove.contains(p.id) ? .removing : model.podEdits[p.id] != nil ? .adding : .none, pane: .podPlaylist(p.id))
        }))
        for source in model.remoteSources {
            out.append((source, model.playlists.filter { model.source(of: $0) == source }.map { p in
                Card(kind: .remote(p), name: p.name, detail: "\(p.count) songs", icon: "music.note.list", mark: model.mark(p), pane: .playlist(p.id))
            }))
        }
        return out.filter { !$0.1.isEmpty }
    }

    /// The Show tabs as icons, like the Albums page's view switcher (the name is the tooltip).
    static func tabIcon(_ tab: String) -> Image {
        switch tab {
        case "All": Image(systemName: "square.grid.2x2")
        case "Crate": Image(systemName: "music.note.list")
        case "Smart": Image(systemName: "wand.and.stars")
        case "On iPod": Image(systemName: "ipod")
        case "Spotify": Image(nsImage: SpotifyMark.template)
        case "OwnTone": Image(systemName: "hifispeaker")
        case "Subsonic": Image(systemName: "server.rack")
        default: Image(systemName: "music.note.list")
        }
    }

    var body: some View {
        let all = groups
        let tabs = ["All"] + all.map(\.title)
        let tab = tabs.contains(ui.tab) ? ui.tab : "All"
        let q = ui.query.lowercased()
        let shown = all.filter { tab == "All" || $0.title == tab }
            .map { g in (title: g.title, cards: q.isEmpty ? g.cards : g.cards.filter { $0.name.lowercased().contains(q) }) }
            .filter { !$0.cards.isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if all.isEmpty {
                    ContentUnavailableView("No playlists yet", systemImage: "music.note.list",
                                           description: Text("Make one with New, or turn on a plugin that brings its own.")).padding(.top, 60)
                }
                ForEach(shown, id: \.title) { g in
                    VStack(alignment: .leading, spacing: 14) {
                        if tab == "All" {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(g.title).font(.title2.bold())
                                Text("\(g.cards.count)").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .glassEffect(.regular, in: .capsule)
                        }
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(g.cards) { c in
                                Button { model.search = ""; model.pane = c.pane; model.path = [] } label: { PlaylistCard(card: c) }
                                    .buttonStyle(.plain)
                                    .contextMenu { menu(c) }
                                    .pinDraggable(c.pane) { PlaylistCard(card: c).frame(width: 120) }
                            }
                        }
                    }
                }
            }
            .padding(24).padding(.bottom, 50)
        }
        .pageTitle("Playlists", subtitle: "\(model.playlistCount) playlists")
        .filtersInToolbar(search: "Filter \(model.playlistCount) playlists", text: $ui.query) {
            Picker("Show", selection: Binding(get: { tab }, set: { ui.tab = $0 })) {
                ForEach(tabs, id: \.self) { t in Self.tabIcon(t).help(t == "All" ? "All playlists" : t).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("New Playlist") { model.newPlaylist() }
                    Button("New Smart Playlist…") { model.editSmart = SmartPlaylist() }
                    Divider()
                    Section("Suggestions") {
                        ForEach(SmartPlaylist.suggestions(genres: model.topGenres).filter { s in !model.smartPlaylists.contains { $0.name == s.name } }) { p in
                            Button(p.name) { model.editSmart = p }
                        }
                    }
                } label: { Label("New", systemImage: "plus").labelStyle(.titleAndIcon) }
                .help("New playlist or smart playlist")
            }
        }
    }

    @ViewBuilder func menu(_ c: Card) -> some View {
        PinButton(pane: c.pane)
        switch c.kind {
        case .crate(let p):
            Button("Rename…", systemImage: "pencil") { model.startRename(.crate(p.id)) }
            Button(p.onIPod ? "Don't Keep on iPod" : "Keep on iPod", pod: model.ipod?.glyph) {
                if let i = model.cratePlaylist(p.id) { model.cratePlaylists[i].onIPod.toggle() }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { model.confirmDeletePlaylist = .crate(p.id) }
        case .smart(let p):
            Button("Edit Rules…", systemImage: "slider.horizontal.3") { model.editSmart = p }
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSmart(p) }
        case .pod(let p):
            Button("Rename…", systemImage: "pencil") { model.startRename(.pod(p.id)) }
            Button(model.playlistsToRemove.contains(p.id) ? "Keep on iPod" : "Remove from iPod", systemImage: "minus.circle") { model.toggleRemove(p) }
            HiddenPlaylistButton(name: p.name)
        case .remote(let p):
            PlaylistMenu(playlist: p)
        }
    }
}

/// A playlist as a tile: its own picture for a server's playlist, else a mosaic of its albums' covers.
struct PlaylistCard: View {
    @EnvironmentObject var model: Model
    @StateObject private var hover = HoverState()
    var card: PlaylistsPage.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { art }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay(alignment: .topTrailing) {
                    // like an album's badge: click to queue for the iPod, unqueue or mark for removal
                    Button { model.cycle(card) } label: {
                        if card.mark == .none {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                                .glassEffect(.clear, in: .circle).help("Add to the iPod")
                        } else { MarkBadge(mark: card.mark, size: 24, help: card.mark == .onIPod ? Model.removeHint : nil) }
                    }
                    .buttonStyle(.plain).padding(7)
                    // as on album tiles: on the iPod or not only on hover; queued and removing always show
                    .opacity((card.mark == .none && model.ipod == nil) || ((card.mark == .none || card.mark == .onIPod) && !hover.on) ? 0 : 1)
                }
                .overlay(alignment: .bottomLeading) {
                    if model.pinned.contains(card.pane) {
                        Image(systemName: "pin.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).glassEffect(.regular.tint(.black.opacity(0.3)), in: .circle)
                            .padding(7).help("Pinned to the sidebar")
                    }
                }
            Text(card.name).font(.headline).lineLimit(1)
            Text(card.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { hover.on = $0 }
    }

    @ViewBuilder var art: some View {
        if case .remote(let p) = card.kind, !p.artwork.isEmpty {
            CachedImage(url: model.artURL(p.artwork), seed: p.uri)
        } else {
            let covers = Array(albumIDs.compactMap { model.artwork[$0] }.prefix(4))
            if covers.count == 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { tile(covers[0]); tile(covers[1]) }
                    GridRow { tile(covers[2]); tile(covers[3]) }
                }
            } else if let c = covers.first {
                Image(nsImage: c).resizable().scaledToFill()
            } else {
                ZStack {
                    Cover(image: nil, seed: card.name)
                    // a rating playlist shows its stars, so "3 stars" and "2 stars" don't look the same
                    if case .smart(let p) = card.kind, p.rules.count == 1, let r = p.rules.first, r.field == .rating, let n = Int(r.value), (1...5).contains(n) {
                        HStack(spacing: 3) {
                            ForEach(1...5, id: \.self) { i in Image(systemName: i <= n ? "star.fill" : "star").opacity(i <= n ? 0.9 : 0.4) }
                        }
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    } else {
                        Image(systemName: card.icon).font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
    }

    func tile(_ img: NSImage) -> some View {
        Color.clear.aspectRatio(1, contentMode: .fit).overlay { Image(nsImage: img).resizable().scaledToFill() }.clipped()
    }

    /// The first few different albums in the playlist.
    var albumIDs: [String] {
        let tracks: [LibTrack]
        switch card.kind {
        case .crate(let p): tracks = model.songs(p)
        case .smart(let p): tracks = model.evaluate(p)
        default: tracks = []
        }
        var seen = Set<String>(), out: [String] = []
        for t in tracks where seen.insert(t.album.lowercased()).inserted { out.append(t.album.lowercased()); if out.count == 4 { break } }
        return out
    }
}

/// Pin or unpin a playlist in the sidebar.
struct PinButton: View {
    @EnvironmentObject var model: Model
    var pane: Pane
    var body: some View {
        let on = model.pinned.contains(pane)
        Button(on ? "Unpin from Sidebar" : "Pin to Sidebar", systemImage: on ? "pin.slash" : "pin") { model.togglePin(pane) }
        Divider()
    }
}

extension View {
    /// Drag a playlist onto the sidebar to pin it.
    @ViewBuilder func pinDraggable<Preview: View>(_ pane: Pane, @ViewBuilder preview: () -> Preview) -> some View {
        if let k = pane.pinKey { draggable("crate-pin:" + k, preview: preview) } else { self }
    }
}

/// What can be dropped on the iPod card: files and albums (URLs) or playlists (pinDraggable's strings).
enum PodDrop: Transferable {
    case url(URL), text(String)
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (u: URL) in PodDrop.url(u) })
        ProxyRepresentation(importing: { (s: String) in PodDrop.text(s) })
    }
}

extension Pane {
    /// The playlists in a pinDraggable drag.
    static func dragged(_ items: [String]) -> [Pane] {
        items.compactMap { i in
            ["crate-pin:", "crate-pinned:"].first(where: i.hasPrefix).flatMap { Pane(pinKey: String(i.dropFirst($0.count))) }
        }
    }
    /// A pinned playlist dragged out of the sidebar: as text for the iPod card, and as its own type, which only the
    /// window's unpin drop takes (so playlists dragged from the Playlists page don't light it up).
    static let pinnedType = UTType(exportedAs: "nl.jrvgr.crate.pinned-playlist")
    static func pinnedProvider(_ key: String) -> NSItemProvider {
        let p = NSItemProvider(object: ("crate-pinned:" + key) as NSString)
        p.registerDataRepresentation(forTypeIdentifier: pinnedType.identifier, visibility: .ownProcess) { done in
            done(Data(key.utf8), nil); return nil
        }
        return p
    }
    /// Pinned playlists dragged out of the sidebar ("crate-pinned:"), as opposed to ones dragged from the Playlists page.
    static func unpinned(_ items: [String]) -> [Pane] {
        items.compactMap { $0.hasPrefix("crate-pinned:") ? Pane(pinKey: String($0.dropFirst(13))) : nil }
    }

    /// How a pinned playlist is remembered.
    var pinKey: String? {
        switch self {
        case .playlist(let i): "remote:\(i)"
        case .podPlaylist(let i): "pod:\(i)"
        case .cratePlaylist(let u): "crate:" + u.uuidString
        case .smart(let u): "smart:" + u.uuidString
        default: nil
        }
    }

    init?(pinKey k: String) {
        let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "remote": guard let i = Int(parts[1]) else { return nil }; self = .playlist(i)
        case "pod": guard let i = UInt64(parts[1]) else { return nil }; self = .podPlaylist(i)
        case "crate": guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .cratePlaylist(u)
        case "smart": guard let u = UUID(uuidString: parts[1]) else { return nil }; self = .smart(u)
        default: return nil
        }
    }
}

extension Model {
    /// A playlist card's badge: queue it for the iPod, unqueue it, or mark it for removal (and back).
    func cycle(_ c: PlaylistsPage.Card) {
        if c.mark == .onIPod, !Self.removeClick { return }
        switch c.kind {
        case .crate(let p): if let i = cratePlaylist(p.id) { cratePlaylists[i].onIPod.toggle() }
        case .smart(let p): if let i = smartPlaylists.firstIndex(where: { $0.id == p.id }) { smartPlaylists[i].onIPod.toggle(); saveSmart() }
        case .pod(let p): toggleRemove(p)
        case .remote(let p):
            if c.mark == .onIPod || c.mark == .removing, let pod = podPlaylist(for: p) { toggleRemove(pod) } else { toggleAdd(p) }
        }
    }

    var playlistCount: Int { cratePlaylists.count + smartPlaylists.count + podOnlyPlaylists.count + playlists.count }

    var pinned: [Pane] {
        get { pinnedText.split(separator: "\n").compactMap { Pane(pinKey: String($0)) } }
        set { pinnedText = newValue.compactMap(\.pinKey).joined(separator: "\n"); objectWillChange.send() }
    }

    func togglePin(_ p: Pane) { if pinned.contains(p) { pinned.removeAll { $0 == p } } else { pinned.append(p) } }

    /// Pin playlists dragged onto the sidebar (see pinDraggable); false when the drag wasn't one.
    func pinDropped(_ items: [String]) -> Bool {
        let panes = Pane.dragged(items)
        for p in panes where !pinned.contains(p) { pinned.append(p) }
        return !panes.isEmpty
    }

    /// Pinned playlists dragged out of the sidebar onto the window: unpinned, like apps off the Dock.
    func unpinDropped(_ items: [String]) -> Bool {
        let panes = Pane.unpinned(items)
        pinned.removeAll { panes.contains($0) }
        return !panes.isEmpty
    }

    /// Queue playlists dragged onto the iPod card (or keep ones marked for removal).
    func queueDropped(_ items: [String]) -> Bool {
        let panes = Pane.dragged(items)
        for pane in panes {
            switch pane {
            case .cratePlaylist(let id): if let i = cratePlaylist(id) { cratePlaylists[i].onIPod = true }
            case .smart(let id): if let i = smartPlaylists.firstIndex(where: { $0.id == id }) { smartPlaylists[i].onIPod = true; saveSmart() }
            case .podPlaylist(let id): playlistsToRemove.remove(id)
            case .playlist(let id):
                guard let p = playlists.first(where: { $0.id == id }) else { break }
                if let pod = podPlaylist(for: p) { playlistsToRemove.remove(pod.id) } else { playlistsToAdd.insert(p.id) }
            default: break
            }
        }
        if !panes.isEmpty { notify("Queued \(panes.count) playlist\(panes.count == 1 ? "" : "s") for the iPod") }
        return !panes.isEmpty
    }

    /// A pinned playlist's name, icon and iPod mark; nil once it's gone.
    func pinLabel(_ p: Pane) -> (name: String, icon: String, mark: SyncMark)? {
        switch p {
        case .cratePlaylist(let id):
            guard let i = cratePlaylist(id) else { return nil }
            let c = cratePlaylists[i]
            return (c.name, "music.note.list", c.onIPod ? (crateNeedsSync(c) ? .adding : .onIPod) : .none)
        case .smart(let id):
            guard let s = smartPlaylists.first(where: { $0.id == id }) else { return nil }
            return (s.name, "wand.and.stars", s.onIPod ? (smartNeedingSync.contains(id) ? .adding : .onIPod) : .none)
        case .podPlaylist(let id):
            guard let pl = db?.playlists.first(where: { $0.id == id }) else { return nil }
            return (podDisplayName(pl), origin(of: pl).icon, playlistsToRemove.contains(id) ? .removing : .none)
        case .playlist(let id):
            guard let pl = playlists.first(where: { $0.id == id }) else { return nil }
            return (pl.name, "music.note.list", mark(pl))
        default: return nil
        }
    }
}
