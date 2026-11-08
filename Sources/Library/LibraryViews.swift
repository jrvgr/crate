import SwiftUI

// MARK: albums

struct AlbumsView: View {
    @EnvironmentObject var model: Model
    @StateObject private var sel = AlbumSelection()
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    func artistHeader(_ group: [Album]) -> some View {
        NavigationLink(value: Route.artist(group[0].artist)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group[0].artist).font(.title2.bold())
                Text("\(group.count)").foregroundStyle(.secondary)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Open \(group[0].artist)")
    }

    var shown: [Album] {
        model.allAlbums.filter { a in
            let m = model.mark(a)
            switch model.albumFilter {
            case .all: break
            case .onIPod: if m == .none || m == .adding { return false }
            case .notOnIPod: if m == .onIPod || m == .removing { return false }
            case .podOnly: if !model.isPodOnly(a) { return false }
            }
            return true
        }
        .sorted(by: { a, b in
            switch model.albumSort {
            case .artist: return false
            case .title: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .year: return (a.year, a.title) > (b.year, b.title)
            case .added: return (a.added ?? .distantPast) > (b.added ?? .distantPast)
            }
        })
    }

    /// One section per artist, in artist order; each keeps the chosen sort.
    func byArtist(_ list: [Album]) -> [(String, [Album])] {
        Dictionary(grouping: list) { $0.artist.lowercased() }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Where each letter of the index starts: an artist's section, or the first album under that letter
    /// (none when the grid isn't in letter order).
    func anchors(_ list: [Album]) -> [(letter: String, id: String)] {
        let keyed: [(String, String)]
        if model.albumsByArtist { keyed = byArtist(list).map { ($0.1[0].artist, "artist-" + $0.0) } }
        else if model.albumSort == .artist { keyed = list.map { ($0.artist, $0.id) } }
        else if model.albumSort == .title { keyed = list.map { ($0.title, $0.id) } }
        else { return [] }
        var seen = Set<String>()
        return keyed.compactMap { s, id in
            let l = LetterIndex.letter(s)
            return seen.insert(l).inserted ? (l, id) : nil
        }
    }

    func tiles(_ albums: [Album]) -> some View {
        LazyVGrid(columns: columns, spacing: 26) {
            ForEach(albums) { a in
                AlbumTile(album: a)
                    .background {
                        if sel.ids.contains(a.id) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.primary.opacity(0.12))
                                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.45), lineWidth: 2) }
                                .padding(-7)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AlbumSelection.space)) } action: { sel.frames[a.id] = $0 }
                    .albumLink(a, select: sel.click)
                    .contextMenu {
                        if sel.ids.count > 1 && sel.ids.contains(a.id) {
                            AlbumsMenu(albums: shown.filter { sel.ids.contains($0.id) }) { sel.ids = [] }
                        } else { AlbumMenu(album: a) }
                    }
            }
        }
    }

    /// Drag from the gaps or margins to draw a selection rectangle over the tiles (⌘ or ⇧ adds to the selection);
    /// a click there clears it.
    func marquee(_ list: [Album]) -> some View {
        let ids = Set(list.map(\.id))
        return Color.clear.contentShape(.rect)
            .onTapGesture { sel.ids = [] }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(AlbumSelection.space))
                .onChanged { sel.drag(from: $0.startLocation, to: $0.location, among: ids) }
                .onEnded { _ in sel.end() })
    }

    @ViewBuilder var marqueeRect: some View {
        if let r = sel.rect {
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08))
                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.35), lineWidth: 1) }
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        let list = shown
        Group {
            if model.albumView == "flow" && !list.isEmpty {
                CoverFlowAlbums(albums: list)
            } else if model.albumView == "list" && !list.isEmpty {
                AlbumList(albums: list)
            } else {
                let marks = anchors(list)
                ScrollViewReader { proxy in
                ScrollView {
                    if model.albums.isEmpty && model.db == nil {
                        ContentUnavailableView(model.loading ? "Loading library…" : "No music found", systemImage: "music.note",
                                               description: Text("Drop music on this window (it goes into ~/Music/Crate unless you pick another folder), add your music folders in Settings › Library, or turn on the Subsonic plugin."))
                            .padding(.top, 120)
                    }
                    if model.albumsByArtist {
                        LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                            ForEach(byArtist(list), id: \.0) { key, group in
                                Section {
                                    tiles(group)
                                } header: {
                                    artistHeader(group)
                                        .padding(.top, 10)      // pinned, it keeps some air under the toolbar
                                        // pushed off by the next artist's header, it fades and shrinks as it goes: worked out
                                        // from where it is on every frame, so it follows the scroll both ways (a header that
                                        // moved by itself raced the scroll). Pinned, it sits at the scroll view's top (0 here;
                                        // measured from the toolbar's height instead, a pinned one counted as pushed and vanished)
                                        .visualEffect { content, proxy in
                                            let pushed = min(max(-proxy.frame(in: .scrollView).minY / max(proxy.size.height, 1), 0), 1)
                                            return content.opacity(1 - pushed).scaleEffect(1 - 0.15 * pushed, anchor: .leading)
                                        }
                                }
                                .id("artist-" + key)
                            }
                        }
                        .padding(24).padding(.trailing, marks.count > 3 ? 30 : 0)
                        .padding(.bottom, 50)
                        .background { marquee(list) }
                        .overlay(alignment: .topLeading) { marqueeRect }
                        .coordinateSpace(.named(AlbumSelection.space))
                    } else {
                        tiles(list)
                            .padding(24).padding(.trailing, marks.count > 3 ? 30 : 0)
                            .padding(.bottom, 50)
                            .background { marquee(list) }
                            .overlay(alignment: .topLeading) { marqueeRect }
                            .coordinateSpace(.named(AlbumSelection.space))
                    }
                }
                .overlay(alignment: .trailing) {
                    if marks.count > 3 {
                        LetterIndex(letters: LetterIndex.all) { l in
                            // a letter with no albums goes to the next one that has some, as on the iPod touch
                            let i = LetterIndex.all.firstIndex(of: l) ?? 0
                            if let m = marks.first(where: { (LetterIndex.all.firstIndex(of: $0.letter) ?? LetterIndex.all.count) >= i }) ?? marks.last {
                                proxy.scrollTo(m.id, anchor: .top)
                            }
                        }
                    }
                }
                }
            }
        }
        .pageTitle("Albums", subtitle: sel.ids.isEmpty ? "\(list.count) albums" : "\(sel.ids.count) of \(list.count) albums selected", show: model.albumView != "list")
        .onChange(of: model.albumFilter) { sel.ids = [] }
        .onChange(of: model.albumView) { sel.ids = [] }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: model.$albumView) {
                    Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                    Image(systemName: "list.bullet").tag("list").help("List")
                    Image(systemName: "rectangle.stack").tag("flow").help("Cover Flow")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Show", selection: $model.albumFilter) {
                        ForEach(AlbumFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Sort By", selection: $model.albumSort) {
                        ForEach(AlbumSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Group by Artist", isOn: model.$albumsByArtist)
                        .disabled(model.albumView != "grid")
                } label: {
                    Label(model.albumFilter == .all ? model.albumSort.rawValue : "\(model.albumFilter.rawValue) · \(model.albumSort.rawValue)",
                          systemImage: model.albumFilter == .all ? "arrow.up.arrow.down" : "line.3.horizontal.decrease.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .help("Show all albums or only those on / not on the iPod, and sort them")
            }
        }
    }
}

@MainActor
final class AlbumListUI: ObservableObject {
    @Published var selection: Set<Album.ID> = []
    @Published var sort = [KeyPathComparator(\AlbumRow.artist), KeyPathComparator(\AlbumRow.yearSort), KeyPathComparator(\AlbumRow.title)]
    @Published var query = ""
    @Published var genre = ""                  // "" = every genre
    @Published var decade = 0                  // 0 = any, -1 = no year
    @Published var lossless = false

    var filtering: Bool { !query.isEmpty || !genre.isEmpty || decade != 0 || lossless }
    func clear() { query = ""; genre = ""; decade = 0; lossless = false }
}

/// One row of the album list (sortable fields).
struct AlbumRow: Identifiable {
    var album: Album
    var id: Album.ID { album.id }
    var title: String { album.title }
    var artist: String { album.artist }
    var year: Int { album.year }
    var yearSort: Int { album.year == 0 ? 9999 : album.year }
    var genre: String { album.genre }
    var songs: Int { album.tracks.count }
    var length: Int { album.lengthMs }
    var added: Date { album.added ?? .distantPast }
}

/// Albums as a table: sortable columns, iPod state, double-click opens, right-click for the album menu.
struct AlbumList: View {
    @EnvironmentObject var model: Model
    var albums: [Album]
    @StateObject private var ui = AlbumListUI()

    var filtered: [Album] {
        albums.filter { a in
            if !ui.genre.isEmpty && !a.tracks.contains(where: { SongsUI.genres($0.genre).contains(ui.genre) }) { return false }
            if ui.decade == -1 && a.year > 0 { return false }
            if ui.decade > 0 && a.year / 10 * 10 != ui.decade { return false }
            if ui.lossless && !a.tracks.contains(where: \.needsConversion) { return false }
            return matchesQuery(ui.query, [a.title, a.artist, a.genre, a.year > 0 ? String(a.year) : ""] + a.tracks.map(\.title))
        }
    }

    @ViewBuilder var filterBar: some View {
        let genres = Set(albums.flatMap { $0.tracks.flatMap { SongsUI.genres($0.genre) } }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let decades = Set(albums.map(\.year).filter { $0 > 0 }.map { $0 / 10 * 10 }).sorted(by: >)
            Menu {
                Picker("Genre", selection: $ui.genre) {
                    Text("All Genres").tag("")
                    Divider()
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text(ui.genre.isEmpty ? "All Genres" : ui.genre) }
            .fixedSize()
            Menu {
                Picker("Decade", selection: $ui.decade) {
                    Text("Any Year").tag(0)
                    Divider()
                    ForEach(decades, id: \.self) { Text("\(String($0))s").tag($0) }
                    Text("No Year").tag(-1)
                }
                .pickerStyle(.inline)
            } label: { Text(ui.decade == 0 ? "Any Year" : ui.decade < 0 ? "No Year" : "\(String(ui.decade))s") }
            .fixedSize()
            Toggle("Lossless", isOn: $ui.lossless).toggleStyle(.button)
                .help("Albums with FLAC, WAV or AIFF files (converted to AAC on the iPod)")
            if ui.filtering { Button("Clear") { ui.clear() } }
    }

    var body: some View {
        let rows = filtered.map(AlbumRow.init).sorted(using: ui.sort)
        Table(rows, selection: $ui.selection, sortOrder: $ui.sort) {
            TableColumn("") { (r: AlbumRow) in
                let m = model.mark(r.album)
                Button { model.cycle(r.album) } label: {
                    Image(systemName: m.icon.map { $0 == "checkmark" ? "checkmark.circle.fill" : $0 + ".circle.fill" } ?? "plus.circle")
                        .foregroundStyle(m == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(m.tint))
                }
                .buttonStyle(.plain).help(m == .none ? "Add to the iPod" : m == .onIPod ? Model.removeHint : m.help)
                .disabled(model.isPodOnly(r.album) && m == .none)
            }
            .width(22)
            TableColumn("Album", value: \.title) { (r: AlbumRow) in
                HStack(spacing: 8) {
                    Cover(image: model.artwork[r.id], seed: r.id).frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 4, style: .continuous))
                    Text(r.title).lineLimit(1)
                    HiddenMark(album: r.album, compact: true).environmentObject(model)   // Table cells can lose the environment while scrolling
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Artist", value: \.artist)
            TableColumn("Year", value: \.yearSort) { (r: AlbumRow) in Text(r.year > 0 ? String(r.year) : "").monospacedDigit() }.width(46)
            TableColumn("Genre", value: \.genre).width(min: 70, ideal: 110)
            TableColumn("Songs", value: \.songs) { (r: AlbumRow) in Text("\(r.songs)").monospacedDigit() }.width(46)
            TableColumn("Time", value: \.length) { (r: AlbumRow) in Text(totalDuration(r.length)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("Size") { (r: AlbumRow) in
                Text(ByteCountFormatter.string(fromByteCount: model.podSize(r.album), countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                    .help("About this much on the iPod (lossless files are converted)")
            }
            .width(66)
            TableColumn("Added", value: \.added) { (r: AlbumRow) in
                Text(r.album.added?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: Album.ID.self) { ids in
            if ids.count == 1, let a = albums.first(where: { ids.contains($0.id) }) { AlbumMenu(album: a) }
            else if ids.count > 1 { AlbumsMenu(albums: albums.filter { ids.contains($0.id) }) }
        } primaryAction: { ids in
            if let a = albums.first(where: { ids.contains($0.id) }) { model.path.append(.album(a)) }
        }
        .pageTitle("Albums", subtitle: ui.filtering ? "\(rows.count) of \(albums.count) albums" : "\(albums.count) albums")
        .filtersInToolbar(search: "Filter \(albums.count) albums", text: $ui.query) { filterBar }
        .overlay { if rows.isEmpty && ui.filtering { ContentUnavailableView("No Albums Match", systemImage: "line.3.horizontal.decrease.circle") } }
    }
}

struct AlbumMenu: View {
    @EnvironmentObject var model: Model
    var album: Album
    var body: some View {
        let m = model.mark(album)
        if model.isPodOnly(album) {
            Button("Copy to Library", systemImage: "square.and.arrow.down") { Task { await model.copyFromIPod([album]) } }
                .disabled(!model.connected)
            if m != .removing {
                Button("Delete from iPod", systemImage: "trash", role: .destructive) { model.toRemove.insert(album.id) }
                    .help("It's only on the iPod: it goes at the next sync")
            }
        }
        if !model.isPodOnly(album), m != .onIPod, m != .removing {
            Button(m == .adding ? "Don't Add to iPod" : m == .partial ? "Add Missing Songs" : "Add to iPod", systemImage: "plus.circle") {
                model.toggleAdd(album)
            }
        }
        if m == .onIPod || m == .partial || m == .removing {
            Button(m == .removing ? "Keep on iPod" : "Remove from iPod", systemImage: "minus.circle") { model.toggleRemove(album) }
            if model.froggerFeatures {
                let hidden = album.tracks.allSatisfy(model.isHidden)
                Button(hidden ? "Show in iPod Library" : "Hide from iPod Library", systemImage: hidden ? "eye" : "eye.slash") {
                    model.setHidden(album.tracks, !hidden)
                }
            }
        }
        if !model.isPodOnly(album) {
            Divider()
            Button("Play", systemImage: "play.fill") { Task { await model.play(album) } }
            AddToPlaylistMenu(tracks: album.tracks)
            Button("Find Metadata…", systemImage: "sparkle.magnifyingglass") { model.lookupAlbum = album }
            Button("Edit Tags…", systemImage: "pencil") { model.editAlbum = album }.disabled(!model.tagsEditable(album)).help(model.tagsEditable(album) ? "" : Model.serverOnlyHelp)
            Button("Organise Files…", systemImage: "folder.badge.gearshape") { model.organize = [album] }.disabled(!model.filesHere(album)).help(model.filesHere(album) ? "" : Model.serverOnlyHelp)
            Button("Find Duplicates…", systemImage: "square.on.square") { model.dedupeAlbum = album }
            Divider()
            Button("Delete from Library…", systemImage: "trash", role: .destructive) { model.confirmTrash = album.tracks }.disabled(!model.filesHere(album)).help(model.filesHere(album) ? "" : Model.serverOnlyHelp)
            Button("Quick Look Cover", systemImage: "eye") { Task { await model.quickLookCover(album) } }
            Menu("Merge With", systemImage: "arrow.triangle.merge") {
                let same = model.albums.filter { $0.id != album.id && ($0.artist == album.artist || Model.looseMatch($0.title, album.title)) }
                ForEach(same.prefix(20)) { other in Button(other.title + " – " + other.artist) { model.merge = [album, other] } }
                    .disabled(!model.tagsEditable(album))
                if same.isEmpty { Text("Select albums in the list view to merge any") }
            }
            LidarrButton(artist: album.artist, album: album.title, label: model.expectedSongs(album) != nil ? "Complete Album with Lidarr" : "Get with Lidarr")
            if model.on(.soulseek) {
                Button(model.expectedSongs(album) != nil ? "Complete Album on Soulseek" : "Find on Soulseek", systemImage: "arrow.down.circle") {
                    model.findOnSoulseek(album.artist, album.title, songs: model.expectedSongs(album) ?? album.tracks.count)
                }
            }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: album.folder) }
        }
    }
}

struct AlbumTile: View {
    @EnvironmentObject var model: Model
    @StateObject private var hover = HoverState()
    var album: Album

    var body: some View {
        let m = model.mark(album)
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { Cover(image: model.artwork[album.id], seed: album.id) }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .coverDrop(album)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .heroSource(.album(album))
                .overlay {
                    if m == .adding || m == .removing { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(m.tint, lineWidth: 3) }
                }
                .opacity(m == .removing ? 0.55 : 1)
                .overlay(alignment: .bottomLeading) { HiddenMark(album: album).padding(8) }
                .overlay(alignment: .topTrailing) {
                    Button { model.cycle(album) } label: {
                        if m == .none { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                                            .glassEffect(.clear, in: .circle).help("Add to the iPod") }
                        else { MarkBadge(mark: m, help: m == .onIPod ? Model.removeHint : nil) }
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    // on the iPod or not is the usual state: only on hover; partly, queued and removing always show
                    .opacity((m == .none && model.ipod == nil) || ((m == .none || m == .onIPod) && !hover.on) ? 0 : 1)
                }
            Text(album.title).font(.headline).lineLimit(1)
            let year = album.year > 0 ? album.year : (model.metadata[album.id]?.year ?? 0)
            Text(album.artist + (year > 0 ? " · \(year)" : "") + (model.isPodOnly(album) ? " · only on iPod" : ""))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { hover.on = $0 }
    }
}

/// An album tile in a grid: a click opens the album, a drag carries its folder (onto the iPod card, a playlist,
/// Finder…). Not a NavigationLink: on the Mac its button keeps the mouse and a drag never starts.
struct AlbumLink: ViewModifier {
    @EnvironmentObject var model: Model
    var album: Album
    /// Takes a click that selects rather than opens (true when it did).
    var select: ((String) -> Bool)?
    func body(content: Content) -> some View {
        let tile = content.contentShape(.rect).onTapGesture {
            if select?(album.id) != true { model.path.append(.album(album)) }
        }
        if album.folder.isEmpty { tile } else {
            tile.draggable(URL(fileURLWithPath: album.folder)) {
                Cover(image: model.artwork[album.id], seed: album.id).frame(width: 90, height: 90).clipShape(.rect(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

extension View {
    func albumLink(_ album: Album, select: ((String) -> Bool)? = nil) -> some View { modifier(AlbumLink(album: album, select: select)) }
}

/// The Albums grid's selection: a rectangle dragged over the tiles, or ⌘/⇧-clicks.
@MainActor
final class AlbumSelection: ObservableObject {
    static let space = "albumGrid"
    @Published var ids: Set<String> = []
    @Published var rect: CGRect?
    /// Where each tile is in the grid (the ones laid out so far).
    var frames: [String: CGRect] = [:]
    private var base: Set<String>?

    func drag(from s: CGPoint, to e: CGPoint, among shown: Set<String>) {
        if base == nil {
            let f = NSEvent.modifierFlags
            base = f.contains(.command) || f.contains(.shift) ? ids : []
        }
        let r = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
        rect = r
        let hit = base!.union(frames.filter { shown.contains($0.key) && $0.value.intersects(r) }.map(\.key))
        if hit != ids { ids = hit }
    }
    func end() { rect = nil; base = nil }

    /// ⌘-click toggles a tile, ⇧-click adds it; a plain click clears the selection and opens the album.
    func click(_ id: String) -> Bool {
        let f = NSEvent.modifierFlags
        guard f.contains(.command) || f.contains(.shift) else { ids = []; return false }
        if f.contains(.command), ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        return true
    }
}

/// The menu for several selected albums, in the list and the grid.
struct AlbumsMenu: View {
    @EnvironmentObject var model: Model
    var albums: [Album]
    var deselect: (() -> Void)?
    var body: some View {
        let lib = albums.filter { !model.isPodOnly($0) }, podOnly = albums.filter(model.isPodOnly)
        if !lib.isEmpty {
            Button("Add \(lib.count) Albums to iPod", systemImage: "plus.circle") { lib.forEach { if model.state($0) != .onIPod { model.toAdd.insert($0.id) } } }
        }
        Button("Remove \(albums.count) Albums from iPod", systemImage: "minus.circle") { albums.forEach { if model.state($0) != .none { model.toRemove.insert($0.id) } } }
        if !podOnly.isEmpty {
            Button("Copy \(podOnly.count) Albums to Library", systemImage: "square.and.arrow.down") { Task { await model.copyFromIPod(podOnly) } }
                .disabled(!model.connected)
        }
        let editable = lib.filter(model.filesHere)          // not the ones only on the Subsonic server
        let taggable = lib.filter(model.tagsEditable)       // those too, when Tagr writes their tags
        if !lib.isEmpty {
            AddToPlaylistMenu(tracks: lib.flatMap(\.tracks))
            Button("Find Metadata for \(lib.count) Albums…", systemImage: "sparkle.magnifyingglass") { model.batchAlbums = lib }
            Button("Organise Files…", systemImage: "folder.badge.gearshape") { model.organize = editable }.disabled(editable.isEmpty)
            if taggable.count > 1 { Button("Merge \(taggable.count) Albums…", systemImage: "arrow.triangle.merge") { model.merge = taggable } }
        }
        Divider()
        // albums only on the iPod have no files here: deleting them takes them off the iPod at the next sync
        if !podOnly.isEmpty {
            Button("Delete \(podOnly.count) Albums from iPod", systemImage: "trash", role: .destructive) { podOnly.forEach { model.toRemove.insert($0.id) } }
        }
        if !editable.isEmpty {
            Button("Delete \(editable.count) Albums from Library…", systemImage: "trash", role: .destructive) { model.confirmTrash = editable.flatMap(\.tracks) }
        }
        if let deselect { Divider(); Button("Deselect All", action: deselect) }
    }
}

func duration(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60000, ms / 1000 % 60) }

func totalDuration(_ ms: Int) -> String {
    let m = (ms + 30000) / 60000
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

/// The song or album a page lights up a moment (Model.highlight).
@MainActor
final class Flash: ObservableObject { @Published var id: String? }

/// Scrolls to Model.highlight when it's one of `ids` and lights it up a moment, then lets it go.
@MainActor
func showHighlight(_ model: Model, ids: [String], proxy: ScrollViewProxy, flash: Flash) async {
    guard let h = model.highlight, ids.contains(h) else { return }
    model.highlight = nil
    try? await Task.sleep(for: .milliseconds(350))           // the page is still coming in
    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(h, anchor: .center) }
    withAnimation(.easeOut(duration: 0.2)) { flash.id = h }
    try? await Task.sleep(for: .seconds(1.6))
    withAnimation(.easeOut(duration: 0.8)) { flash.id = nil }
}

struct AlbumDetail: View {
    @EnvironmentObject var model: Model
    var album: Album
    @StateObject private var studio = CoverStudioUI()
    @StateObject private var flash = Flash()
    @StateObject private var hovered = Flash()       // the song row under the pointer

    var body: some View {
        let m = model.mark(album), keys = model.podKeys, podOnly = model.isPodOnly(album)
        let mb = model.metadata[album.id]
        let year = album.year > 0 ? album.year : (mb?.year ?? 0)
        let genre = album.tracks.first { !$0.genre.isEmpty }?.genre ?? mb?.genre ?? ""
        let formats = Set(album.tracks.map { $0.ext.uppercased() }).sorted().joined(separator: "/")
        let editing = model.editAlbum?.id == album.id, finding = model.lookupAlbum?.id == album.id
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if editing {
                    TagEditor(album: album) { model.editAlbum = nil }
                } else {
                HStack(alignment: .bottom, spacing: 24) {
                    IPodCover(image: model.artwork[album.id], seed: album.id)
                        .frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                        .heroTarget(.album(album))
                        .onTapGesture { Task { await model.quickLookCover(album) } }
                        .coverDrop(album, corner: 16)
                        .help(model.artwork[album.id] == nil ? "Drop an image here to use it as the cover" : "Quick Look (⌘Y); drop an image to replace the cover")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                        Button { model.path.append(.artist(album.artist)) } label: {
                            Text(album.artist).font(.title2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Go to artist")
                        if let full = model.expectedSongs(album), !podOnly {
                            HStack(spacing: 8) {
                                Label("\(album.tracks.count) of \(full) songs", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                if model.on(.soulseek) {
                                    Button("Complete Album") { model.findOnSoulseek(album.artist, album.title, songs: full) }
                                        .buttonStyle(.glass).controlSize(.small)
                                        .help("Search Soulseek for a copy with all \(full) songs")
                                }
                            }
                            .font(.callout)
                        }
                        Text([year > 0 ? "\(year)" : "", genre, "\(album.tracks.count) songs",
                              totalDuration(album.tracks.map(\.lengthMs).reduce(0, +)), podOnly ? "" : formats,
                              podOnly ? "" : "≈ " + ByteCountFormatter.string(fromByteCount: model.podSize(album), countStyle: .file) + " on the iPod"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        let hidden = model.hiddenCount(album)
                        if model.froggerFeatures, hidden.hidden > 0 {
                            Label(hidden.hidden == hidden.onIPod ? "Hidden from Artists and Albums on the iPod (still in its playlists)"
                                  : "\(hidden.hidden) of \(hidden.onIPod) songs hidden from Artists and Albums on the iPod", systemImage: "eye.slash")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        // like the artist page: Play, the iPod, and everything else named in the ⋯ menu
                        HStack(spacing: 10) {
                            if podOnly {
                                Button("Copy to Library", systemImage: "square.and.arrow.down") { Task { await model.copyFromIPod([album]) } }
                                    .buttonStyle(.glassProminent).disabled(!model.connected).help("Copy these songs from the iPod into your library")
                            } else {
                                Button("Play", systemImage: "play.fill") { Task { await model.play(album) } }.buttonStyle(.glassProminent)
                            }
                            if podOnly {
                                if m == .onIPod || m == .partial || m == .removing {
                                    Button(m == .removing ? "Keep on iPod" : "Remove from iPod",
                                           systemImage: m == .removing ? "arrow.uturn.backward" : "minus") { model.toggleRemove(album) }
                                }
                            } else {
                                // where the album stands on the iPod. Partly there it has two ways to go, so a menu; otherwise
                                // one, so the button toggles it (a menu with a single item was a click for nothing)
                                let label = HStack(spacing: 7) { PodStateIcon(mark: m); Text(ipodTitle(m)) }
                                if m == .partial {
                                    GlassMenu {
                                        Button("Add Missing Songs", systemImage: "plus") { model.toggleAdd(album) }.disabled(model.ipod == nil)
                                        Button("Remove from iPod", systemImage: "minus") { model.toggleRemove(album) }
                                    } label: { label }
                                    .help(m.help)
                                } else {
                                    Button { m == .none || m == .adding ? model.toggleAdd(album) : model.toggleRemove(album) } label: { label }
                                        .disabled(m == .none && model.ipod == nil)
                                        .help(m == .none ? "Put this album on the iPod at the next sync"
                                              : m == .adding ? "Queued for the next sync – click to not add it after all"
                                              : m == .removing ? "Goes at the next sync – click to keep it on the iPod"
                                              : "On the iPod – click to remove it at the next sync")
                                }
                            }
                            if !podOnly {
                                GlassMenu {
                                    Button("Find Metadata…", systemImage: "sparkle.magnifyingglass") { model.lookupAlbum = album }
                                    Button("Edit Tags…", systemImage: "pencil") { model.editAlbum = album }.disabled(!model.tagsEditable(album)).help(model.tagsEditable(album) ? "" : Model.serverOnlyHelp)
                                    Button("Find Duplicates…", systemImage: "square.on.square") { model.dedupeAlbum = album }
                                    if model.froggerFeatures {
                                        Button("Cover Studio…", systemImage: "camera.filters") { Task { studio.open = true; await studio.select(album, model: model) } }
                                    }
                                    Divider()
                                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: album.folder) }
                                } label: { MoreLabel() }
                                    .help("More")
                            }
                        }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).menuStyle(.button).fixedSize()
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                if finding { LookupPanel(album: album) { model.lookupAlbum = nil } }
                if model.dedupeAlbum?.id == album.id { DedupePanel(album: album) { model.dedupeAlbum = nil } }
                VStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                        HStack(spacing: 12) {
                            Text(t.trackNumber > 0 ? "\(t.trackNumber)" : "").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).lineLimit(1)
                                if !t.trackArtist.isEmpty, t.trackArtist != album.artist {
                                    Text(t.trackArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            let sm = podOnly ? (keys.contains(t.key) ? (m == .removing ? SyncMark.removing : .onIPod) : .none) : model.songMark(t)
                            Button { if !podOnly { model.toggleSong(t) } } label: {
                                Image(systemName: sm.icon.map { $0 == "checkmark" ? "checkmark.circle.fill" : $0 + ".circle.fill" } ?? "plus.circle")
                                    .foregroundStyle(sm == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(sm.tint))
                            }
                            .buttonStyle(.plain).help(sm == .none ? "Add this song to the iPod" : sm.help)
                            // a song like the rest of the album says nothing the header doesn't: only on hover
                            .opacity(m != .partial && sm == m && hovered.id != t.id ? 0 : 1)
                            if !podOnly { StarPicker(value: model.rating(t)) { model.rate(t, $0) } }
                            Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(flash.id == t.id ? Color.primary.opacity(0.2)
                                    : model.player.current?.id == t.id ? Color.accentColor.opacity(0.15) : i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                        .id(t.id)
                        .contentShape(.rect)
                        .onHover { on in if on { hovered.id = t.id } else if hovered.id == t.id { hovered.id = nil } }
                        .onTapGesture(count: 2) { Task { await model.play(album, from: i) } }
                        .contextMenu {
                            Button("Play", systemImage: "play.fill") { Task { await model.play(album, from: i) } }
                            if !podOnly {
                                let sm = model.songMark(t)
                                Button(sm == .none ? "Add Song to iPod" : sm == .onIPod ? "Remove Song from iPod" : "Don't Sync This Song",
                                       systemImage: sm == .none ? "plus.circle" : "minus.circle") { model.toggleSong(t) }
                                AddToPlaylistMenu(tracks: [t])
                                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.path)]) }
                                Divider()
                                Button("Delete Song…", systemImage: "trash", role: .destructive) { model.confirmTrash = [t] }
                                    .disabled(Subsonic.serverOnly(t.path)).help(Subsonic.serverOnly(t.path) ? Model.serverOnlyHelp : "")
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                if !podOnly { MissingSongs(album: album) }
                }
            }
            .padding(28)
            .padding(.bottom, 50)
        }
        .task(id: model.highlight) { await showHighlight(model, ids: album.tracks.map(\.id), proxy: proxy, flash: flash) }
        }
        .onDisappear {
            if model.editAlbum?.id == album.id { model.editAlbum = nil }
            if model.lookupAlbum?.id == album.id { model.lookupAlbum = nil }
            if model.dedupeAlbum?.id == album.id { model.dedupeAlbum = nil }
        }
        .background { Backdrop(image: model.artwork[album.id]) }
        .pageTitle(album.title)
        .sheet(isPresented: $studio.open) { CoverStudio(ui: studio).environmentObject(model) }
    }

    func ipodTitle(_ m: SyncMark) -> String {
        switch m {
        case .none: "Add to iPod"
        case .onIPod: "On iPod"
        case .partial: "Partly on iPod"
        case .adding: "Adding to iPod"
        case .removing: "Removing from iPod"
        }
    }
}

// MARK: playlists

struct PlaylistView: View {
    @EnvironmentObject var model: Model
    var playlist: OTPlaylist

    var body: some View {
        let tracks = model.playlistTracks[playlist.id]
        let all = tracks ?? []
        let avail = all.map { model.availability($0) }
        let onPod = avail.filter { $0 == .onIPod }.count, files = avail.filter { $0 == .file }.count
        let m = model.mark(playlist), pod = model.podPlaylist(for: playlist)
        let shown = Array(all.enumerated())
        // the iPod copies of this playlist's songs, and which of them are hidden (the rule worked out once)
        let rule = model.ruleHidden(model.db?.playlists ?? [])
        let lib = zip(all, avail).map { t, a in a == .onIPod ? model.libraryTrack(for: t)?.track : nil }
        let hidden = lib.map { l in l.map { model.wantsHidden(model.podKey($0.key), rule) } ?? false }
        let onPodLib = lib.compactMap { $0 }
        let allHidden = !onPodLib.isEmpty && hidden.filter { $0 }.count == onPodLib.count
        let editable = model.serverEditable(playlist)
        let move = { (a: Int, b: Int) in Task { await model.editServerPlaylist(playlist) { $0.moveItem(a, to: b) } } }
        let remove = { (n: Int) in Task { await model.editServerPlaylist(playlist) { $0.remove(at: n) } } }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    Mosaic(paths: playlist.artwork.isEmpty ? Array(NSOrderedSet(array: all.map(\.artworkPath)).array.compactMap { $0 as? String }.prefix(4))
                                                           : [playlist.artwork])
                        .frame(width: 200, height: 200).clipShape(.rect(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.spotifyID != nil ? "Spotify Playlist" : playlist.subsonicID != nil ? "Subsonic Playlist" : "Playlist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(playlist.name).font(.largeTitle.bold()).lineLimit(2)
                        Text(tracks == nil ? "\(playlist.count) songs" :
                             "\(all.count) songs · \(totalDuration(all.map(\.lengthMs).reduce(0, +))) · \(onPod + files) with files · \(onPod) on iPod")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button(m == .adding ? "Don't Sync" : pod == nil ? "Add to iPod" : "Update on iPod",
                                   systemImage: m == .adding ? "xmark" : "plus") { model.toggleAdd(playlist) }
                                .buttonStyle(.glassProminent).disabled(model.ipod == nil || (tracks != nil && onPod + files == 0))
                            if let pod {
                                Button(m == .removing ? "Keep on iPod" : "Remove from iPod",
                                       systemImage: m == .removing ? "arrow.uturn.backward" : "minus") { model.toggleRemove(pod) }
                                    .buttonStyle(.glass)
                            }
                            if !onPodLib.isEmpty, model.froggerFeatures {
                                Button(allHidden ? "Show in iPod Library" : "Hide from iPod Library", systemImage: allHidden ? "eye" : "eye.slash") {
                                    model.setHidden(onPodLib, !allHidden)
                                }
                                .buttonStyle(.glass)
                                .help("Keeps this playlist's songs out of the iPod's Artists and Albums (with Frogger). They still play from playlists")
                            }
                            if playlist.subsonicID != nil {
                                Button("Play", systemImage: "play.fill") { Task { await model.playSongs(of: playlist) } }.buttonStyle(.glass)
                            } else if let uri = model.playURI(playlist) {
                                Button(model.remoteName == nil ? "Open in Spotify" : "Play", systemImage: "play.fill") {
                                    Task { await model.playURIs([uri]) }
                                }.buttonStyle(.glass)
                            }
                            if editable {
                                Button { model.startRename(.ownTone(playlist.id)) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.glass).help("Rename… (renames its .m3u file)")
                                Button { model.confirmDeletePlaylist = .ownTone(playlist.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.glass).help("Delete Playlist…")
                            }
                        }
                        .padding(.top, 8)
                        if tracks != nil, files + onPod < all.count {
                            HStack {
                                Text("\(all.count - files - onPod) songs are only on Spotify." + (model.on(.soulseek) ? " Right-click one to find its album on Soulseek." : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                if model.on(.youtube) {
                                    Button("Get Them from YouTube") {
                                        let missing = all.filter { model.availability($0) == .streamOnly }
                                        model.yt.fetch(missing, album: nil, art: missing.first?.artworkPath ?? "")
                                        model.notify("Fetching \(missing.count) songs from YouTube")
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if tracks == nil { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.offset) { i, t in
                        if editable {
                            TrackRow(track: t, index: i, availability: avail[i], podTrack: lib[i], hidden: hidden[i],
                                     edit: PlaylistRowActions(index: i, count: all.count, move: { _ = move($0, $1) }, remove: { _ = remove($0) }))
                                .reorderable(i) { _ = move($0, $1) }
                        } else {
                            TrackRow(track: t, index: i, availability: avail[i], podTrack: lib[i], hidden: hidden[i])
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(28)
            .padding(.bottom, 50)
        }
        .pageTitle(playlist.name)
        .task(id: playlist.id) { _ = await model.tracks(for: playlist) }
    }
}

struct TrackRow: View {
    @EnvironmentObject var model: Model
    var track: OTTrack
    var index: Int
    var availability: Model.Availability
    var podTrack: LibTrack? = nil        // the library song whose copy is on the iPod
    var hidden = false                   // that copy is hidden from the iPod's Artists/Albums
    var edit: PlaylistRowActions? = nil  // move and remove, in a playlist Crate can change

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: model.artURL(track.artworkPath), seed: "LibraryViews.swift:5")
                .frame(width: 34, height: 34).clipShape(.rect(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                Text("\(track.artist) — \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(availability == .streamOnly ? 0.6 : 1)
            Spacer()
            if hidden, let podTrack {
                Button { model.setHidden([podTrack], false) } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Hidden from the iPod's Artists and Albums. Click to show it again")
            }
            switch availability {
            case .onIPod: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("On the iPod")
            case .file: Image(systemName: "music.note").foregroundStyle(.tint).help("You have the file; goes to the iPod with the playlist")
            // monotone, like the other marks in the row: the green logo shouted on every streamed song
            case .streamOnly: Image(nsImage: SpotifyMark.template).resizable().scaledToFit().frame(width: 14, height: 14)
                .foregroundStyle(.secondary).help("Only on Spotify")
            }
            Text(track.lengthMs > 0 ? duration(track.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(index % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if let m = model.libraryTrack(for: track) { model.path.append(.album(m.album)) }
        }
        .contextMenu {
            if let m = model.libraryTrack(for: track) {
                Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(m.album)) }
                if let podTrack, model.froggerFeatures {
                    Button(hidden ? "Show in iPod Library" : "Hide from iPod Library", systemImage: hidden ? "eye" : "eye.slash") {
                        model.setHidden([podTrack], !hidden)
                    }
                }
            } else {
                if model.on(.soulseek) {
                    Button("Find “\(track.album)” on Soulseek", systemImage: "arrow.down.circle") {
                        model.findOnSoulseek(track.albumArtist.isEmpty ? track.artist : track.albumArtist, track.album)
                    }
                }
            }
            if !track.uri.hasPrefix("library:") { LinkMenu(track: track) }
            if (model.on(.ownTone) && !track.uri.isEmpty) || track.uri.hasPrefix("spotify:") {
                Button(model.playURILabel, systemImage: "play.fill") { Task { await model.playURIs([track.uri]) } }
            }
            if let edit { Divider(); edit }
        }
    }
}

/// Up to four covers in a 2×2 grid (one fills the square).
struct Mosaic: View {
    @EnvironmentObject var model: Model
    var paths: [String]
    var body: some View {
        GeometryReader { g in
            let one = paths.count < 4
            let s = one ? g.size.width : g.size.width / 2
            let grid = [GridItem(.fixed(s), spacing: 0), GridItem(.fixed(s), spacing: 0)]
            if paths.isEmpty { Cover(image: nil, seed: "playlist") }
            else if one { cover(paths[0]).frame(width: s, height: s) }
            else {
                LazyVGrid(columns: grid, spacing: 0) {
                    ForEach(paths, id: \.self) { cover($0).frame(width: s, height: s).clipped() }
                }
            }
        }
    }
    func cover(_ p: String) -> some View {
        CachedImage(url: model.artURL(p), seed: "LibraryViews.swift:6")
    }
}

struct PodPlaylistView: View {
    @EnvironmentObject var model: Model
    var playlist: PodPlaylist

    var body: some View {
        let byID = Dictionary((model.db?.tracks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = model.podItems(playlist).compactMap { byID[$0] }
        let removing = model.playlistsToRemove.contains(playlist.id)
        let edited = model.podEdits[playlist.id] != nil
        // edits work on the songs shown (ids of songs no longer on the iPod drop out)
        let move = { (a: Int, b: Int) in model.editPod(playlist) { list in
            var shown = list.filter { byID[$0] != nil }; shown.moveItem(a, to: b); list = shown } }
        let remove = { (n: Int) in model.editPod(playlist) { list in
            var shown = list.filter { byID[$0] != nil }; shown.remove(at: n); list = shown } }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    Image(systemName: "music.note.list").font(.system(size: 70, weight: .light))
                        .frame(width: 200, height: 200).glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On the iPod").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(model.podDisplayName(playlist)).font(.largeTitle.bold())
                            .onTapGesture(count: 2) { model.startRename(.pod(playlist.id)) }
                            .help("Double-click to rename")
                        Text("\(tracks.count) songs · \(totalDuration(tracks.map(\.lengthMs).reduce(0, +)))").foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button(removing ? "Keep on iPod" : "Remove from iPod", systemImage: removing ? "arrow.uturn.backward" : "minus") {
                                model.toggleRemove(playlist)
                            }
                            .buttonStyle(.glass)
                            Button { model.startRename(.pod(playlist.id)) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.glass).help("Rename…")
                        }
                        .padding(.top, 8)
                        if edited {
                            HStack(spacing: 8) {
                                Label("Changed in Crate; the iPod gets it on the next Sync", systemImage: "clock.arrow.circlepath")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Revert") { model.podEdits[playlist.id] = nil }.buttonStyle(.link)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        PlaylistSongRow(number: i + 1, title: t.title, detail: "\(t.artist) — \(t.album)", lengthMs: t.lengthMs)
                            .reorderable(i, move: move)
                            .contextMenu { PlaylistRowActions(index: i, count: tracks.count, move: move, remove: remove) }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                if !tracks.isEmpty { Text("Drag songs to change the order.").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(28)
            .opacity(removing ? 0.6 : 1)
        }
        .pageTitle(model.podDisplayName(playlist))
    }
}

struct Cover: View {
    var image: NSImage?
    var seed: String
    var body: some View {
        // a cover that arrives later (a download, an artist's discography) fades in over its placeholder
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                placeholder.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: image != nil)
    }

    /// A muted colour of its own per album (the same every launch) with a faint record.
    private var placeholder: some View {
        let h = Double(seed.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 360) / 360
        return GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                LinearGradient(colors: [Color(hue: h, saturation: 0.22, brightness: 0.36), Color(hue: h, saturation: 0.28, brightness: 0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<4) { i in
                    Circle().strokeBorder(.white.opacity(0.07), lineWidth: max(0.5, d * 0.006))
                        .frame(width: d * (0.72 - CGFloat(i) * 0.12), height: d * (0.72 - CGFloat(i) * 0.12))
                }
                Circle().fill(Color(hue: h, saturation: 0.35, brightness: 0.55).opacity(0.5)).frame(width: d * 0.22, height: d * 0.22)
                Circle().fill(.black.opacity(0.35)).frame(width: d * 0.03, height: d * 0.03)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

struct SpotifyGrid: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var spot: SpotifyAPI
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    var shown: [SpotifyAlbum] {
        model.spotify.filter { a in
            !model.onlyMissing || !model.hasFiles(a)
        }
    }

    var body: some View {
        let list = shown
        let albums = model.spotifyTab == "artists" ? list.filter { $0.artist.lowercased() == model.spotifyArtist?.lowercased() } : list
        let lists = model.playlists.filter { model.source(of: $0) == "Spotify" || (!spot.direct && $0.spotifyID == nil && $0.subsonicID == nil) }
        // albums (all, or one artist's) can be a grid, a list or Cover Flow, like the library
        let showsAlbums = model.spotifyTab == "albums" || (model.spotifyTab == "artists" && model.spotifyArtist != nil)
        let altView = showsAlbums && model.albumView != "grid" && !albums.isEmpty && !(spot.direct && !spot.connected)
        Group {
        if altView {
            VStack(spacing: 0) {
                header
                if model.spotifyTab == "artists", let name = model.spotifyArtist {
                    SourceArtistHeader(name: name, albums: albums.count) { model.spotifyArtist = nil }
                }
                if model.albumView == "flow" { SpotifyCoverFlow(albums: Array(albums.prefix(600))) }
                else { SpotifyAlbumList(albums: albums).padding(.top, 10) }
            }
        } else {
        ScrollViewReader { proxy in
        ScrollView {
            header
            if model.spotifyTab == "playlists" {
                if lists.isEmpty {
                    ContentUnavailableView("No playlists", systemImage: "music.note.list").padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(lists) { p in
                        Button { model.search = ""; model.pane = .playlist(p.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay { CachedImage(url: model.artURL(p.artwork), seed: p.uri) }
                                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                                    .overlay(alignment: .topTrailing) { MarkBadge(mark: model.mark(p), size: 24).padding(7) }
                                Text(p.name).font(.headline).lineLimit(1)
                                Text("\(p.count) songs").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { PlaylistMenu(playlist: p) }
                    }
                }
                .padding(24).padding(.bottom, 50)
            } else if model.spotifyTab == "artists" && model.spotifyArtist == nil && !list.isEmpty {
                SourceArtistGrid(entries: SourceArtistGrid.entries(list, artist: \.artist, art: { model.artURL($0.artworkPath) }, seed: \.uri)) {
                    model.path.append(.artist($0))
                }
            } else {
            if model.spotifyTab == "artists", let name = model.spotifyArtist {
                SourceArtistHeader(name: name, albums: albums.count) { model.spotifyArtist = nil }
            }
            if spot.direct && !spot.connected {
                PluginSetupNotice(plugin: .spotify, text: "Connect your Spotify account to see your saved albums and playlists.")
            } else if let e = spot.error, spot.direct {
                ContentUnavailableView("Spotify", systemImage: "exclamationmark.triangle", description: Text(e)).padding(.top, 60)
            } else if list.isEmpty && !model.loading {
                ContentUnavailableView(model.onlyMissing ? "You have files for every saved album" : "No saved albums",
                                       systemImage: PluginID.spotify.icon).padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(albums.prefix(600)) { a in
                    NavigationLink(value: Route.spotifyAlbum(a)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay {
                                CachedImage(url: model.artURL(a.artworkPath), seed: a.uri)
                            }
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                // streaming is the norm on this page; only the albums you also have files for are marked
                                if model.hasFiles(a) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .glassEffect(.regular.tint(.green), in: .circle)
                                        .help("In the library")
                                        .padding(7)
                                }
                            }
                        Text(a.name).font(.headline).lineLimit(1)
                        Text("\(a.artist) · \(a.trackCount) saved").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.on(.soulseek) {
                            Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(a.artist, a.name) }
                        }
                        LidarrButton(artist: a.artist, album: a.name)
                        if model.on(.youtube) {
                            Button("Get from YouTube", systemImage: "play.rectangle") { Task { await model.albumFromYouTube(a) } }
                        }
                        Button(model.playURILabel, systemImage: "play.fill") { Task { await model.playURIs([a.uri]) } }
                        Button("Copy “Artist – Album”", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(a.artist) – \(a.name)", forType: .string)
                        }
                    }
                }
            }
            .padding(24).padding(.bottom, 50)
            }
        }
        .overlay(alignment: .trailing) {
            if model.spotifyTab == "artists" && model.spotifyArtist == nil {
                ArtistLetters.index(ArtistLetters.of(SourceArtistGrid.entries(list, artist: \.artist, art: { _ in nil }, seed: \.uri).map(\.name)).letters, proxy: proxy)
            }
        }
        }
        }
        }
        .pageTitle("Spotify", subtitle: model.spotifyTab == "artists" && model.spotifyArtist == nil ? "\(Set(list.map { $0.artist.lowercased() }).count) artists"
                            : "\(albums.count) album\(albums.count == 1 ? "" : "s")" + (albums.count > 600 ? " (first 600 shown, search finds the rest)" : ""))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $model.spotifyTab) {
                    Image(systemName: "opticaldisc").help("Albums").tag("albums")
                    Image(systemName: "music.microphone").help("Artists").tag("artists")
                    Image(systemName: "music.note.list").help("Playlists").tag("playlists")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if showsAlbums {
                ToolbarItem(placement: .navigation) {
                    Picker("View", selection: model.$albumView) {
                        Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                        Image(systemName: "list.bullet").tag("list").help("List")
                        Image(systemName: "rectangle.stack").tag("flow").help("Cover Flow")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            if model.on(.soulseek) {
                ToolbarItem(placement: .navigation) {
                    Button { model.showMissing = true } label: { Label("Get Missing Albums…", systemImage: "arrow.down.circle") }
                        .help("Find the saved albums you have no files for on Soulseek")
                        .disabled(model.spotify.isEmpty)
                }
            }
        }
    }
}

extension SpotifyGrid {
    var header: some View {
        HStack(spacing: 14) {
            if model.spotifyTab != "playlists" {
                Toggle("Only albums without files", isOn: $model.onlyMissing).toggleStyle(.switch)
            }
            Spacer()
            Text("Spotify streams can't be copied to the iPod").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 16)
    }
}

@MainActor
final class SpotifyListUI: ObservableObject {
    @Published var selection: Set<SpotifyAlbum.ID> = []
    @Published var sort = [KeyPathComparator(\SpotifyAlbum.artist), KeyPathComparator(\SpotifyAlbum.year), KeyPathComparator(\SpotifyAlbum.name)]
}

/// Saved Spotify albums as a table, like the library's album list; double-click opens one.
struct SpotifyAlbumList: View {
    @EnvironmentObject var model: Model
    var albums: [SpotifyAlbum]
    @StateObject private var ui = SpotifyListUI()

    var body: some View {
        Table(albums.sorted(using: ui.sort), selection: $ui.selection, sortOrder: $ui.sort) {
            TableColumn("") { (a: SpotifyAlbum) in
                Image(systemName: model.hasFiles(a) ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(model.hasFiles(a) ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .help(model.hasFiles(a) ? "You have files for this album" : "Spotify only")
            }
            .width(22)
            TableColumn("Album", value: \.name) { (a: SpotifyAlbum) in
                HStack(spacing: 8) {
                    CachedImage(url: model.artURL(a.artworkPath), seed: a.uri).frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 4, style: .continuous))
                    Text(a.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.artist)
            TableColumn("Year", value: \.year) { (a: SpotifyAlbum) in Text(a.year > 0 ? String(a.year) : "").monospacedDigit() }.width(46)
            TableColumn("Saved", value: \.trackCount) { (a: SpotifyAlbum) in Text("\(a.trackCount)").monospacedDigit() }.width(50)
        }
        .contextMenu(forSelectionType: SpotifyAlbum.ID.self) { ids in
            if ids.count == 1, let a = albums.first(where: { ids.contains($0.id) }) {
                Button("Open", systemImage: "chevron.right") { model.path.append(.spotifyAlbum(a)) }
                Button(model.playURILabel, systemImage: "play.fill") { Task { await model.playURIs([a.uri]) } }
                if model.on(.soulseek) {
                    Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(a.artist, a.name) }
                }
                LidarrButton(artist: a.artist, album: a.name)
            }
        } primaryAction: { ids in
            if let a = albums.first(where: { ids.contains($0.id) }) { model.path.append(.spotifyAlbum(a)) }
        }
    }
}

// MARK: artists

struct ArtistImage: View {
    @EnvironmentObject var model: Model
    var artist: Artist
    var body: some View {
        if let img = model.artistArt[artist.id] { Image(nsImage: img).resizable().scaledToFill() }
        else if let p = model.artistInfo[artist.id]?.photo, let u = URL(string: p), !p.isEmpty {
            CachedImage(url: u, seed: artist.id)
        }
        else { Cover(image: artist.albums.lazy.compactMap { model.artwork[$0.id] }.first, seed: artist.id) }
    }
}

struct ArtistsView: View {
    @EnvironmentObject var model: Model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 26)]

    var body: some View {
        Group {
            if model.artistView == "list" { ArtistList() }
            else if model.artistView == "flow" && !model.artists.isEmpty { CoverFlowArtists(artists: model.artists) }
            else { grid }
        }
        .pageTitle("Artists", subtitle: "\(model.artists.count) artists", show: model.artistView != "list")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: model.$artistView) {
                    Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                    Image(systemName: "list.bullet").tag("list").help("List")
                    Image(systemName: "rectangle.stack").tag("flow").help("Cover Flow")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }

    var grid: some View {
        let list = model.artists
        let marks = ArtistLetters.of(list.map(\.name), letter: LetterIndex.letter)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(Array(list.enumerated()), id: \.element.id) { n, a in
                    NavigationLink(value: Route.artist(a.name)) {
                        VStack(spacing: 8) {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { ArtistImage(artist: a) }
                                .clipShape(.circle)
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                                .heroSource(.artist(a.name))
                                .overlay(alignment: .bottomTrailing) { MarkBadge(mark: model.artistMark(a)).padding(4) }
                            Text(a.name).font(.headline).lineLimit(1)
                            Text("\(a.albums.count) album\(a.albums.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .id(marks.first.contains(n) ? ArtistLetters.id(marks.letterOf[n]) : "artist-" + a.id)
                    .contextMenu {
                        let tracks = a.albums.flatMap(\.tracks)
                        Button("Play", systemImage: "play.fill") { Task { await model.play(tracks) } }
                        Button("Shuffle", systemImage: "shuffle") { Task { await model.play(tracks.shuffled()) } }
                        AddToPlaylistMenu(tracks: tracks)
                        Divider()
                        Button("Add All to iPod", systemImage: "plus.circle") { model.addAll(a) }
                        Button("Remove All from iPod", systemImage: "minus.circle") { model.removeAll(a) }
                    }
                }
            }
            .padding(24).padding(.trailing, marks.letters.count > 3 ? 18 : 0).padding(.bottom, 50)
        }
        .overlay(alignment: .trailing) { ArtistLetters.index(marks.letters, proxy: proxy) }
        }
    }
}

/// One row of the artist list (sortable fields).
struct ArtistRow: Identifiable {
    var artist: Artist
    var id: Artist.ID { artist.id }
    var name: String
    var albums: Int { artist.albums.count }
    var songs: Int { artist.trackCount }
    var genre: String
    var length: Int { artist.albums.map(\.lengthMs).reduce(0, +) }
    var plays: Int
    var added: Date { artist.albums.compactMap(\.added).max() ?? .distantPast }
    var first: Int { artist.albums.map(\.year).filter { $0 > 0 }.min() ?? 9999 }
}

@MainActor
final class ArtistListUI: ObservableObject {
    @Published var selection: Set<Artist.ID> = []
    @Published var sort = [KeyPathComparator(\ArtistRow.name)]
    @Published var query = ""
    @Published var genre = ""
    @Published var show = AlbumFilter.all
    var filtering: Bool { !query.isEmpty || !genre.isEmpty || show != .all }
    func clear() { query = ""; genre = ""; show = .all }
}

/// Artists as a table: albums, songs, genre, plays; double-click opens the artist.
struct ArtistList: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = ArtistListUI()

    /// The genre most of an artist's songs have.
    func genre(_ a: Artist) -> String {
        var n: [String: Int] = [:]
        for t in a.albums.flatMap(\.tracks) { for g in SongsUI.genres(t.genre) { n[g, default: 0] += 1 } }
        return n.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? ""
    }

    var body: some View {
        let all = model.artists
        let rows = all.compactMap { a -> ArtistRow? in
            let m = model.artistMark(a)
            switch ui.show {
            case .all: break
            case .onIPod: if m == .none || m == .adding { return nil }
            case .notOnIPod: if m == .onIPod || m == .partial || m == .removing { return nil }
            case .podOnly: if !a.albums.contains(where: model.isPodOnly) { return nil }
            }
            if !ui.genre.isEmpty && !a.albums.contains(where: { $0.tracks.contains { SongsUI.genres($0.genre).contains(ui.genre) } }) { return nil }
            guard matchesQuery(ui.query, [a.name] + a.albums.map(\.title)) else { return nil }
            let plays = a.albums.flatMap(\.tracks).map { model.stat($0).plays }.reduce(0, +)
            return ArtistRow(artist: a, name: a.name, genre: genre(a), plays: plays)
        }
        .sorted(using: ui.sort)
        let genres = Set(model.libTracks.flatMap { SongsUI.genres($0.genre) }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        Table(rows, selection: $ui.selection, sortOrder: $ui.sort) {
            TableColumn("") { (r: ArtistRow) in MarkBadge(mark: model.artistMark(r.artist), size: 16) }.width(22)
            TableColumn("Artist", value: \.name) { (r: ArtistRow) in
                HStack(spacing: 8) {
                    Color.clear.frame(width: 26, height: 26).overlay { ArtistImage(artist: r.artist).environmentObject(model) }.clipShape(.circle)
                    Text(r.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Albums", value: \.albums) { (r: ArtistRow) in Text("\(r.albums)").monospacedDigit() }.width(50)
            TableColumn("Songs", value: \.songs) { (r: ArtistRow) in Text("\(r.songs)").monospacedDigit() }.width(50)
            TableColumn("Genre", value: \.genre).width(min: 70, ideal: 120)
            TableColumn("Since", value: \.first) { (r: ArtistRow) in Text(r.first < 9999 ? String(r.first) : "").monospacedDigit() }.width(46)
            TableColumn("Time", value: \.length) { (r: ArtistRow) in Text(totalDuration(r.length)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("Plays", value: \.plays) { (r: ArtistRow) in Text(r.plays > 0 ? "\(r.plays)" : "").monospacedDigit().foregroundStyle(.secondary) }.width(46)
            TableColumn("Added", value: \.added) { (r: ArtistRow) in
                Text(r.added == .distantPast ? "" : r.added.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: Artist.ID.self) { ids in
            let picked = all.filter { ids.contains($0.id) }
            if !picked.isEmpty {
                let tracks = picked.flatMap { $0.albums.flatMap(\.tracks) }
                Button("Play", systemImage: "play.fill") { Task { await model.play(tracks) } }
                Button("Shuffle", systemImage: "shuffle") { Task { await model.play(tracks.shuffled()) } }
                AddToPlaylistMenu(tracks: tracks)
                Divider()
                Button("Add All to iPod", systemImage: "plus.circle") { picked.forEach(model.addAll) }
                Button("Remove All from iPod", systemImage: "minus.circle") { picked.forEach(model.removeAll) }
            }
        } primaryAction: { ids in
            if let a = all.first(where: { ids.contains($0.id) }) { model.path.append(.artist(a.name)) }
        }
        .pageTitle("Artists", subtitle: ui.filtering ? "\(rows.count) of \(all.count) artists" : "\(all.count) artists")
        .filtersInToolbar(search: "Filter \(all.count) artists", text: $ui.query) {
                Menu {
                    Picker("Show", selection: $ui.show) { ForEach(AlbumFilter.allCases, id: \.self) { Text($0 == .all ? "All Artists" : $0.rawValue).tag($0) } }
                        .pickerStyle(.inline)
                } label: { Text(ui.show == .all ? "All Artists" : ui.show.rawValue) }
                .fixedSize()
                Menu {
                    Picker("Genre", selection: $ui.genre) {
                        Text("All Genres").tag("")
                        Divider()
                        ForEach(genres, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Text(ui.genre.isEmpty ? "All Genres" : ui.genre) }
                .fixedSize()
                if ui.filtering { Button("Clear") { ui.clear() } }
        }
        .overlay { if rows.isEmpty && ui.filtering { ContentUnavailableView("No Artists Match", systemImage: "line.3.horizontal.decrease.circle") } }
    }
}

/// A blurred, dimmed copy of the artwork behind a detail page.
struct Backdrop: View {
    var image: NSImage?
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(height: 420).frame(maxWidth: .infinity).clipped()
                .blur(radius: 70).opacity(0.45)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
    }
}

// MARK: Apple Music

@MainActor
final class AMUI: ObservableObject {
    enum Sort: String, CaseIterable { case artist = "Artist", title = "Title", year = "Year", songs = "Most Songs" }
    enum Group: String, CaseIterable { case letter = "A–Z", artist = "Artist", year = "Decade", genre = "Genre", none = "None" }
    enum Where: String, CaseIterable {
        case all = "All", mac = "On This Mac", cloud = "In iCloud"
        var icon: String { switch self { case .all: "square.grid.2x2"; case .mac: "laptopcomputer"; case .cloud: "icloud" } }
    }
    @Published var query = ""
    @Published var sort = Sort.artist
    @Published var group = Group.letter
    @Published var place = Where.all
    @Published var byArtist = CommandLine.arguments.contains("--am-artists")    // for testing
    @Published var artist: String?
}

struct AppleMusicView: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = AMUI()
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    static func letter(_ s: String) -> String {
        LetterIndex.letter(s.hasPrefix("The ") ? String(s.dropFirst(4)) : s)
    }

    var shown: [AMAlbum] {
        let words = ui.query.split(separator: " ")
        return model.amAlbums.filter { a in
            (!model.amHideImported || !model.amHidden.contains(a.id))
                && (ui.place == .all || (ui.place == .mac ? a.downloaded == a.tracks.count : a.downloaded < a.tracks.count))
                && words.allSatisfy { (a.title + " " + a.artist + " " + (a.tracks.first?.genre ?? "")).localizedStandardContains($0) }
                && (!ui.byArtist || ui.artist == nil || a.artist.lowercased() == ui.artist?.lowercased())
        }
        .sorted { x, y in
            switch ui.sort {
            case .artist: return (x.artist.lowercased(), x.year, x.title.lowercased()) < (y.artist.lowercased(), y.year, y.title.lowercased())
            case .title: return x.title.localizedCaseInsensitiveCompare(y.title) == .orderedAscending
            case .year: return (x.year, x.artist) > (y.year, y.artist)
            case .songs: return x.tracks.count > y.tracks.count
            }
        }
    }

    func key(_ a: AMAlbum) -> String {
        switch ui.group {
        case .letter: return Self.letter(ui.sort == .title ? a.title : a.artist)
        case .artist: return a.artist
        case .year: return a.year > 0 ? "\(a.year / 10 * 10)s" : "Unknown"
        case .genre: return a.tracks.first { !$0.genre.isEmpty }?.genre ?? "Unknown"
        case .none: return ""
        }
    }

    var body: some View {
        let list = shown
        var order: [String] = [], groups: [String: [AMAlbum]] = [:]
        for a in list { let k = key(a); if groups[k] == nil { order.append(k) }; groups[k, default: []].append(a) }
        if ui.group == .letter || ui.group == .artist || ui.group == .genre { order.sort { ($0 == "#" || $0 == "Unknown" ? 1 : 0, $0) < ($1 == "#" || $1 == "Unknown" ? 1 : 0, $1) } }
        if ui.group == .year { order.sort(by: >) }
        let artistGrid = ui.byArtist && ui.artist == nil
        let letters = ui.group == .letter && !artistGrid ? order : []
        let artistLetters = artistGrid ? ArtistLetters.of(SourceArtistGrid.entries(list, artist: \.artist, art: { _ in nil }, seed: \.id).map(\.name)).letters : []
        return Group {
            if !artistGrid && model.albumView != "grid" && !list.isEmpty {
                VStack(spacing: 0) {
                    filterRow.padding(.bottom, 10)
                    if ui.byArtist, let name = ui.artist { SourceArtistHeader(name: name, albums: list.count) { ui.artist = nil } }
                    if model.albumView == "flow" { AMCoverFlow(albums: list) } else { AMAlbumList(albums: list) }
                }
            } else { grid(list, order: order, groups: groups, artistGrid: artistGrid, letters: letters, artistLetters: artistLetters) }
        }
        .pageTitle("Apple Music", subtitle: model.amLoading && model.amAlbums.isEmpty ? "Reading the Music library…"
                            : ui.byArtist && ui.artist == nil ? "\(Set(list.map { $0.artist.lowercased() }).count) artists" : "\(list.count) albums")
        .task { if model.amAlbums.isEmpty { await model.loadAppleMusic() } }
        .onChange(of: model.amHideImported) { model.amHidden = Set(model.amAlbums.filter(model.inLibrary).map(\.id)) }
        .onDisappear { model.amHidden = Set(model.amAlbums.filter(model.inLibrary).map(\.id)) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $ui.byArtist) { Image(systemName: "opticaldisc").help("Albums").tag(false); Image(systemName: "music.microphone").help("Artists").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if !artistGrid {
                ToolbarItem(placement: .navigation) {
                    Picker("View", selection: model.$albumView) {
                        Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                        Image(systemName: "list.bullet").tag("list").help("List")
                        Image(systemName: "rectangle.stack").tag("flow").help("Cover Flow")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Sort By", selection: $ui.sort) { ForEach(AMUI.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline)
                    Picker("Group By", selection: $ui.group) { ForEach(AMUI.Group.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline)
                } label: { Label(ui.sort.rawValue, systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon) }
                .help("Sort and group")
            }
            ToolbarItem(placement: .navigation) {
                Button { Task { await model.loadAppleMusic() } } label: { Label("Reload Apple Music", systemImage: "arrow.clockwise.icloud") }
                    .disabled(model.amLoading).help("Read the Music library again")
            }
        }
    }

    var filterRow: some View {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter albums", text: $ui.query).textFieldStyle(.plain)
                        if !ui.query.isEmpty { Button { ui.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: 280)
                    Picker("", selection: $ui.place) { ForEach(AMUI.Where.allCases, id: \.self) { Image(systemName: $0.icon).help($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Toggle("Hide imported", isOn: $model.amHideImported).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 24).padding(.top, 16)
    }

    func grid(_ list: [AMAlbum], order: [String], groups: [String: [AMAlbum]], artistGrid: Bool, letters: [String], artistLetters: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                filterRow
                if let e = model.amError {
                    ContentUnavailableView("Can't read Apple Music", systemImage: "exclamationmark.triangle",
                                           description: Text(e + "\nAllow Crate to control Music in System Settings › Privacy & Security › Automation."))
                        .padding(.top, 80)
                } else if model.amLoading && model.amAlbums.isEmpty {
                    ProgressView("Reading your Apple Music library…").padding(.top, 120)
                } else if list.isEmpty {
                    ContentUnavailableView(ui.query.isEmpty ? "No albums" : "No albums match “\(ui.query)”", systemImage: "icloud").padding(.top, 80)
                }
                if artistGrid {
                    SourceArtistGrid(entries: SourceArtistGrid.entries(list, artist: \.artist, art: { model.amArt[$0.id] }, seed: \.id),
                                     load: { name in
                                         guard let a = list.first(where: { $0.artist.lowercased() == name.lowercased() }), model.amArt[a.id] == nil,
                                               let u = await AppleMusic.artworkURL(a) else { return }
                                         model.amArt[a.id] = u
                                     }) { model.path.append(.artist($0)) }
                } else {
                if ui.byArtist, let name = ui.artist {
                    SourceArtistHeader(name: name, albums: list.count) { ui.artist = nil }
                }
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: ui.group == .none ? [] : [.sectionHeaders]) {
                    ForEach(order, id: \.self) { k in
                        Section {
                            LazyVGrid(columns: columns, spacing: 26) {
                                ForEach(groups[k] ?? []) { a in AMTile(album: a) }
                            }
                        } header: {
                            if ui.group != .none {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(k).font(.title2.bold())
                                    Text("\(groups[k]?.count ?? 0)").foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 6).padding(.horizontal, 10)
                                .glassEffect(.regular, in: .capsule)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .id("am-" + k)
                    }
                }
                .padding(24).padding(.trailing, letters.isEmpty ? 0 : 18).padding(.bottom, 80)
                }
            }
            .overlay(alignment: .trailing) {
                if letters.count > 3 {
                    LetterIndex(letters: letters) { proxy.scrollTo("am-" + $0, anchor: .top) }
                }
                ArtistLetters.index(artistLetters, proxy: proxy)
            }
        }
    }
}

struct AMTile: View {
    @EnvironmentObject var model: Model
    var album: AMAlbum

    var body: some View {
        let job = model.amJob(album), have = model.inLibrary(album)
        let busy: String? = job.map { $0.state == .queued ? "Queued" : $0.detail }
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    CachedImage(url: model.amArt[album.id], seed: "LibraryViews.swift:8")
                }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay {
                    if let busy {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.45))
                            VStack(spacing: 8) {
                                if job?.state == .queued { Image(systemName: "clock").font(.title3) }
                                else if let p = job?.progress { ProgressView(value: p).frame(width: 90).tint(.white) }
                                else { ProgressView().controlSize(.small) }
                                Text(busy).font(.caption.bold())
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if have && busy == nil { MarkBadge(mark: .onIPod).help("In the library").padding(8) }
                    else if busy == nil {
                        Menu {
                            Button("Import to Library", systemImage: "square.and.arrow.down") { model.importAppleMusic(album, toIPod: false) }
                            Button("Import and Add to iPod", pod: model.ipod?.glyph) { model.importAppleMusic(album, toIPod: true) }
                                .disabled(model.ipod == nil)
                        } label: {
                            Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                                .glassEffect(.regular.tint(.accentColor), in: .circle)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Import")
                        .padding(8)
                    }
                }
            Text(album.title).font(.headline).lineLimit(1)
            Text(album.artist + (album.year > 0 ? " · \(album.year)" : "") + " · \(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .onTapGesture { model.path.append(.amAlbum(album)) }
        .contextMenu { AMMenu(album: album) }
        .task(id: album.id) {
            if model.amArt[album.id] == nil, let u = await AppleMusic.artworkURL(album) { model.amArt[album.id] = u }
        }
    }
}

// MARK: letter index

final class LetterIndexUI: ObservableObject {
    @Published var current: String?
    @Published var pointer: CGFloat = 0         // the pointer's last height over the index
    @Published var strength: CGFloat = 0        // 1 while the pointer is over it; eases back to 0 when it leaves
    var pending: String?                        // the letter to scroll to next
    var scrolling = false                       // a scroll was just sent: the next one waits a moment
}

/// The A–Z strip down the right of a long grid, like the iPod touch's: tap a letter, or drag along
/// the strip to run through them, and `jump` scrolls there.
struct LetterIndex: View {
    var letters: [String]
    var jump: (String) -> Void
    @StateObject private var ui = LetterIndexUI()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let row: CGFloat = 15, inset: CGFloat = 8

    /// Scrolling the list loads covers and holds up drawing: at most one scroll every 60 ms, always to the
    /// latest letter, so the index keeps up while the list catches up behind it.
    private func scroll(to l: String) {
        ui.pending = l
        guard !ui.scrolling else { return }
        ui.scrolling = true
        Task { @MainActor in
            while let next = ui.pending {
                ui.pending = nil
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { jump(next) }
                try? await Task.sleep(for: .milliseconds(60))
            }
            ui.scrolling = false
        }
    }

    /// Like the Dock: the letter under the pointer grows most, its neighbours less, about three rows out.
    private func magnification(_ i: Int) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let d = (ui.pointer - inset) / row - (CGFloat(i) + 0.5)
        return 1 + 0.9 * ui.strength * exp(-d * d / 3)
    }

    static let all = ["#"] + (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }

    /// A title's index letter: its first letter without accents, "#" for digits and symbols.
    static func letter(_ s: String) -> String {
        guard let c = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased().first else { return "#" }
        return c.isLetter ? String(c) : "#"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.element) { i, l in
                let m = max(magnification(i), ui.current == l ? 1.35 : 1)
                // drawn at twice the size and scaled down, so a grown letter stays sharp
                Text(l).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ui.current == l || m > 1.5 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize()
                    // scaled around its centre, so at rest it sits in the middle of the pill; a grown letter
                    // moves out toward the grid, the way the Dock's icons grow away from the screen's edge
                    .scaleEffect(m * 0.5)
                    .offset(x: -(m - 1) * 8)
                    .frame(width: 18, height: row)
            }
        }
        .padding(.vertical, inset).padding(.horizontal, 2)
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            // a short spring between pointer events, so the letters glide instead of stepping
            case .active(let p): withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) { ui.pointer = p.y; ui.strength = 1 }
            case .ended: withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { ui.strength = 0 }
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                // no hover events while the button is down: the drag moves the magnification
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) { ui.pointer = g.location.y; ui.strength = 1 }
                let i = Int(((g.location.y - inset) / row).rounded(.down))
                let l = letters[max(0, min(letters.count - 1, i))]
                if l != ui.current { ui.current = l; scroll(to: l) }
            }
            .onEnded { _ in ui.current = nil })
        .animation(.snappy(duration: 0.15), value: ui.current)
        .glassEffect(.regular, in: .capsule)
        .padding(.trailing, 18)      // clear of the scroll bar, which sits at the very edge
        .help("Jump to a letter (drag to scrub)")
    }
}

// MARK: source artists

/// Artists-first view of a source's albums: one circle per artist (their first album's cover);
/// picking one narrows the album grid to that artist.
struct SourceArtistGrid: View {
    @EnvironmentObject var model: Model
    struct Entry: Identifiable { var id: String { name.lowercased() }; var name: String; var albums: Int; var art: URL?; var seed: String }
    var entries: [Entry]
    var load: ((String) async -> Void)? = nil
    var pick: (String) -> Void
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 26)]

    static func entries<A>(_ albums: [A], artist: (A) -> String, art: (A) -> URL?, seed: (A) -> String) -> [Entry] {
        var order: [String] = [], groups: [String: [A]] = [:]
        for a in albums { let k = artist(a).lowercased(); if groups[k] == nil { order.append(k) }; groups[k, default: []].append(a) }
        let bare = { (s: String) in s.hasPrefix("The ") ? String(s.dropFirst(4)) : s }
        return order.map { k in
            let g = groups[k]!
            return Entry(name: artist(g[0]), albums: g.count, art: g.lazy.compactMap(art).first, seed: seed(g[0]))
        }
        .sorted { bare($0.name).localizedStandardCompare(bare($1.name)) == .orderedAscending }
    }

    var body: some View {
        let marks = ArtistLetters.of(entries.map(\.name))
        LazyVGrid(columns: columns, spacing: 28) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { n, e in
                let lib = model.libraryArtist(e.name)
                Button { pick(e.name) } label: {
                    VStack(spacing: 8) {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay { ArtistPortrait(name: e.name, fallback: e.art) }
                            .clipShape(.circle)
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                            .overlay(alignment: .bottomTrailing) { if let lib { MarkBadge(mark: model.artistMark(lib)).padding(4) } }
                        Text(e.name).font(.headline).lineLimit(1)
                        Text("\(e.albums) album\(e.albums == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .id(marks.first.contains(n) ? ArtistLetters.id(marks.letterOf[n]) : "artist-" + e.id)
                .contextMenu {
                    if let lib {
                        let tracks = lib.albums.flatMap(\.tracks)
                        Button("Play", systemImage: "play.fill") { Task { await model.play(tracks) } }
                        AddToPlaylistMenu(tracks: tracks)
                        Divider()
                        Button("Add All to iPod", systemImage: "plus.circle") { model.addAll(lib) }
                    }
                    Button("Open Artist", systemImage: "music.microphone") { pick(e.name) }
                }
                .task(id: e.id) { if e.art == nil { await load?(e.name) } }
            }
        }
        .padding(24).padding(.bottom, 50)
    }
}

/// Back-to-all-artists bar above one artist's albums in a source.
struct SourceArtistHeader: View {
    var name: String
    var albums: Int
    var back: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: back) { Label("All Artists", systemImage: "chevron.left") }
                .buttonStyle(.glass)
            Text(name).font(.title.bold()).lineLimit(1)
            Text("\(albums) album\(albums == 1 ? "" : "s")").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 12)
    }
}

/// Albums Frogger hides from the iPod's Artists and Albums (Hide from iPod Library, or a hidden playlist):
/// an eye on the cover, with how many of its songs when only some are.
struct HiddenMark: View {
    @EnvironmentObject var model: Model
    @StateObject private var hover = HoverState()
    var album: Album
    var compact = false

    var body: some View {
        let h = model.hiddenCount(album)
        if model.froggerFeatures, h.hidden > 0 {
            let all = h.hidden == h.onIPod
            let help = all ? "Hidden from Artists and Albums on the iPod; it still plays from its playlists"
                           : "\(h.hidden) of \(h.onIPod) songs hidden from Artists and Albums on the iPod"
            if compact {
                Image(systemName: "eye.slash").foregroundStyle(.secondary).help(help)
            } else {
                // says what it means on hover: the eye alone isn't obvious
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                    if hover.on { Text(all ? "Hidden on the iPod" : "\(h.hidden) of \(h.onIPod) hidden on the iPod") }
                    else if !all { Text("\(h.hidden)/\(h.onIPod)").monospacedDigit() }
                }
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, all && !hover.on ? 0 : 8).frame(minWidth: 26, minHeight: 26)
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                .animation(.snappy(duration: 0.15), value: hover.on)
                .onHover { hover.on = $0 }
                .help(help)
            }
        }
    }
}
