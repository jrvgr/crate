import SwiftUI

// MARK: albums

struct AlbumsView: View {
    @EnvironmentObject var model: Model
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    var shown: [Album] {
        model.allAlbums.filter { a in
            let m = model.mark(a)
            switch model.albumFilter {
            case .all: break
            case .onIPod: if m == .none || m == .adding { return false }
            case .notOnIPod: if m == .onIPod || m == .removing { return false }
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

    var body: some View {
        let list = shown
        Group {
            if model.albumView == "flow" && !list.isEmpty {
                CoverFlowAlbums(albums: list)
            } else if model.albumView == "list" && !list.isEmpty {
                AlbumList(albums: list)
            } else {
                ScrollView {
                    if model.albums.isEmpty && model.db == nil {
                        ContentUnavailableView(model.loading ? "Loading library…" : "No music found", systemImage: "music.note",
                                               description: Text("Add your music folders in Settings › Library (or turn on OwnTone), then press Refresh."))
                            .padding(.top, 120)
                    }
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(list) { a in
                            NavigationLink(value: Route.album(a)) { AlbumTile(album: a) }
                                .buttonStyle(.plain)
                                .contextMenu { AlbumMenu(album: a) }
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 50)
                }
            }
        }
        .navigationTitle("Albums")
        .navigationSubtitle("\(list.count) albums")
        .toolbar {
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
                } label: {
                    Label(model.albumFilter == .all ? "Show and Sort" : model.albumFilter.rawValue,
                          systemImage: model.albumFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Show all albums or only those on / not on the iPod, and sort them")
            }
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: model.$albumView) {
                    Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                    Image(systemName: "list.bullet").tag("list").help("List")
                    Image(systemName: "rectangle.stack").tag("flow").help("Cover Flow")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }
}

@MainActor
final class AlbumListUI: ObservableObject {
    @Published var selection: Set<Album.ID> = []
    @Published var sort = [KeyPathComparator(\AlbumRow.artist), KeyPathComparator(\AlbumRow.yearSort), KeyPathComparator(\AlbumRow.title)]
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

    var body: some View {
        let rows = albums.map(AlbumRow.init).sorted(using: ui.sort)
        Table(rows, selection: $ui.selection, sortOrder: $ui.sort) {
            TableColumn("") { (r: AlbumRow) in
                let m = model.mark(r.album)
                Button { model.cycle(r.album) } label: {
                    Image(systemName: m.icon.map { $0 == "checkmark" ? "checkmark.circle.fill" : $0 + ".circle.fill" } ?? "plus.circle")
                        .foregroundStyle(m == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(m.tint))
                }
                .buttonStyle(.plain).help(m == .none ? "Add to the iPod" : m.help)
                .disabled(model.isPodOnly(r.album) && m == .none)
            }
            .width(22)
            TableColumn("Album", value: \.title) { (r: AlbumRow) in
                HStack(spacing: 8) {
                    Cover(image: model.artwork[r.id], seed: r.id).frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 4))
                    Text(r.title).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Artist", value: \.artist)
            TableColumn("Year", value: \.yearSort) { (r: AlbumRow) in Text(r.year > 0 ? "\(r.year)" : "").monospacedDigit() }.width(46)
            TableColumn("Genre", value: \.genre).width(min: 70, ideal: 110)
            TableColumn("Songs", value: \.songs) { (r: AlbumRow) in Text("\(r.songs)").monospacedDigit() }.width(46)
            TableColumn("Time", value: \.length) { (r: AlbumRow) in Text(totalDuration(r.length)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("Added", value: \.added) { (r: AlbumRow) in
                Text(r.album.added?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: Album.ID.self) { ids in
            if ids.count == 1, let a = albums.first(where: { ids.contains($0.id) }) { AlbumMenu(album: a) }
            else if ids.count > 1 {
                let picked = albums.filter { ids.contains($0.id) }
                Button("Add \(ids.count) Albums to iPod", systemImage: "plus.circle") { picked.forEach { if !model.isPodOnly($0) && model.state($0) != .onIPod { model.toAdd.insert($0.id) } } }
                Button("Remove \(ids.count) Albums from iPod", systemImage: "minus.circle") { picked.forEach { if model.state($0) != .none { model.toRemove.insert($0.id) } } }
                Button("Find Metadata for \(ids.count) Albums…", systemImage: "sparkle.magnifyingglass") { model.batchAlbums = picked.filter { !model.isPodOnly($0) } }
                Button("Organise Files…", systemImage: "folder.badge.gearshape") { model.organize = picked }
            }
        } primaryAction: { ids in
            if let a = albums.first(where: { ids.contains($0.id) }) { model.path.append(.album(a)) }
        }
    }
}

struct AlbumMenu: View {
    @EnvironmentObject var model: Model
    var album: Album
    var body: some View {
        let m = model.mark(album)
        if !model.isPodOnly(album), m != .onIPod, m != .removing {
            Button(m == .adding ? "Don't Add to iPod" : m == .partial ? "Add Missing Songs" : "Add to iPod", systemImage: "plus.circle") {
                model.toggleAdd(album)
            }
        }
        if m == .onIPod || m == .partial || m == .removing {
            Button(m == .removing ? "Keep on iPod" : "Remove from iPod", systemImage: "minus.circle") { model.toggleRemove(album) }
        }
        if !model.isPodOnly(album) {
            Divider()
            Button("Play", systemImage: "play.fill") { Task { await model.play(album) } }
            Button("Find Metadata…", systemImage: "sparkle.magnifyingglass") { model.lookupAlbum = album }
            Button("Edit Tags…", systemImage: "pencil") { model.editAlbum = album }
            Button("Organise Files…", systemImage: "folder.badge.gearshape") { model.organize = [album] }
            Button("Quick Look Cover", systemImage: "eye") { model.quickLookCover(album) }
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
    var album: Album

    var body: some View {
        let m = model.mark(album)
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { Cover(image: model.artwork[album.id], seed: album.id) }
                .clipShape(.rect(cornerRadius: 14))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay {
                    if m == .adding || m == .removing { RoundedRectangle(cornerRadius: 14).strokeBorder(m.tint, lineWidth: 3) }
                }
                .opacity(m == .removing ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    Button { model.cycle(album) } label: {
                        if m == .none { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                                            .glassEffect(.clear, in: .circle).help("Add to the iPod") }
                        else { MarkBadge(mark: m) }
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .opacity(m == .none && model.ipod == nil ? 0 : 1)
                }
            Text(album.title).font(.headline).lineLimit(1)
            let year = album.year > 0 ? album.year : (model.metadata[album.id]?.year ?? 0)
            Text(album.artist + (year > 0 ? " · \(year)" : "") + (model.isPodOnly(album) ? " · only on iPod" : ""))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .draggable(URL(fileURLWithPath: album.folder)) {
            Cover(image: model.artwork[album.id], seed: album.id).frame(width: 90, height: 90).clipShape(.rect(cornerRadius: 10))
        }
    }
}

func duration(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60000, ms / 1000 % 60) }

func totalDuration(_ ms: Int) -> String {
    let m = (ms + 30000) / 60000
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

struct AlbumDetail: View {
    @EnvironmentObject var model: Model
    var album: Album

    var body: some View {
        let m = model.mark(album), keys = model.podKeys, podOnly = model.isPodOnly(album)
        let mb = model.metadata[album.id]
        let year = album.year > 0 ? album.year : (mb?.year ?? 0)
        let genre = album.tracks.first { !$0.genre.isEmpty }?.genre ?? mb?.genre ?? ""
        let formats = Set(album.tracks.map { $0.ext.uppercased() }).sorted().joined(separator: "/")
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    Cover(image: model.artwork[album.id], seed: album.id)
                        .frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                        .onTapGesture { model.quickLookCover(album) }
                        .help("Quick Look (⌘Y)")
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
                              totalDuration(album.tracks.map(\.lengthMs).reduce(0, +)), podOnly ? "" : formats]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if !podOnly, m != .onIPod, m != .removing {
                                Button(m == .adding ? "Don't Add" : m == .partial ? "Add Missing Songs" : "Add to iPod",
                                       systemImage: m == .adding ? "xmark" : "plus") { model.toggleAdd(album) }
                                    .buttonStyle(.glassProminent).disabled(model.ipod == nil)
                            }
                            if m == .onIPod || m == .partial || m == .removing {
                                Button(m == .removing ? "Keep on iPod" : "Remove from iPod",
                                       systemImage: m == .removing ? "arrow.uturn.backward" : "minus") { model.toggleRemove(album) }
                                    .buttonStyle(.glass)
                            }
                            if !podOnly {
                                Button("Play", systemImage: "play.fill") { Task { await model.play(album) } }.buttonStyle(.glass)
                                Button { model.lookupAlbum = album } label: { Image(systemName: "sparkle.magnifyingglass") }
                                    .buttonStyle(.glass).help("Find Metadata…")
                                Button { model.editAlbum = album } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.glass).help("Edit Tags…")
                                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: album.folder) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.glass).help("Show in Finder")
                            }
                        }
                        .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
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
                            if keys.contains(t.key) {
                                Image(systemName: m == .removing ? "minus.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(m == .removing ? .red : .green).help(m == .removing ? "Will be removed" : "On the iPod")
                            } else if m == .adding {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.tint).help("Will be added")
                            }
                            Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(model.player.current?.id == t.id ? Color.accentColor.opacity(0.15) : i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { Task { await model.play(album, from: i) } }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(28)
            .padding(.bottom, 50)
        }
        .background { Backdrop(image: model.artwork[album.id]) }
        .navigationTitle(album.title)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    Mosaic(paths: Array(NSOrderedSet(array: all.map(\.artworkPath)).array.compactMap { $0 as? String }.prefix(4)))
                        .frame(width: 200, height: 200).clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.spotifyID != nil ? "Spotify Playlist" : "Playlist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
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
                            if model.on(.ownTone) || playlist.spotifyID != nil {
                                Button(model.on(.ownTone) ? "Play" : "Open in Spotify", systemImage: "play.fill") {
                                    Task { await model.playURIs([playlist.uri]) }
                                }.buttonStyle(.glass)
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
                        TrackRow(track: t, index: i, availability: avail[i])
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(28)
            .padding(.bottom, 50)
        }
        .navigationTitle(playlist.name)
        .task(id: playlist.id) { _ = await model.tracks(for: playlist) }
    }
}

struct TrackRow: View {
    @EnvironmentObject var model: Model
    var track: OTTrack
    var index: Int
    var availability: Model.Availability

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.artURL(track.artworkPath)) { $0.resizable().scaledToFill() }
                placeholder: { Cover(image: nil, seed: track.album) }
                .frame(width: 34, height: 34).clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                Text("\(track.artist) — \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(availability == .streamOnly ? 0.6 : 1)
            Spacer()
            switch availability {
            case .onIPod: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("On the iPod")
            case .file: Image(systemName: "music.note").foregroundStyle(.tint).help("You have the file; goes to the iPod with the playlist")
            case .streamOnly: Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary).help("Only on Spotify")
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
            } else {
                if model.on(.soulseek) {
                    Button("Find “\(track.album)” on Soulseek", systemImage: "arrow.down.circle") {
                        model.findOnSoulseek(track.albumArtist.isEmpty ? track.artist : track.albumArtist, track.album)
                    }
                }
            }
            if model.on(.ownTone) || track.uri.hasPrefix("spotify:") {
                Button(model.on(.ownTone) ? "Play on OwnTone" : "Open in Spotify", systemImage: "play.fill") { Task { await model.playURIs([track.uri]) } }
            }
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
        AsyncImage(url: model.artURL(p)) { $0.resizable().scaledToFill() } placeholder: { Cover(image: nil, seed: p) }
    }
}

struct PodPlaylistView: View {
    @EnvironmentObject var model: Model
    var playlist: PodPlaylist

    var body: some View {
        let byID = Dictionary((model.db?.tracks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = playlist.items.compactMap { byID[$0.trackID] }
        let removing = model.playlistsToRemove.contains(playlist.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    Image(systemName: "music.note.list").font(.system(size: 70, weight: .light))
                        .frame(width: 200, height: 200).glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On the iPod").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(playlist.name).font(.largeTitle.bold())
                        Text("\(tracks.count) songs · \(totalDuration(tracks.map(\.lengthMs).reduce(0, +)))").foregroundStyle(.secondary)
                        Button(removing ? "Keep on iPod" : "Remove from iPod", systemImage: removing ? "arrow.uturn.backward" : "minus") {
                            model.toggleRemove(playlist)
                        }
                        .buttonStyle(.glass).padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: 12) {
                            Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).lineLimit(1)
                                Text("\(t.artist) — \(t.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(duration(t.lengthMs)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(28)
            .opacity(removing ? 0.6 : 1)
        }
        .navigationTitle(playlist.name)
    }
}

struct Cover: View {
    var image: NSImage?
    var seed: String
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            let h = Double(abs(seed.hashValue % 360)) / 360
            LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.75),
                                    Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { Image(systemName: "music.note").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.8)) }
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
        ScrollView {
            HStack {
                Toggle("Only albums without files", isOn: $model.onlyMissing).toggleStyle(.switch)
                Spacer()
                Text("Spotify streams can't be copied to the iPod").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 16)
            if spot.direct && !spot.connected {
                PluginSetupNotice(plugin: .spotify, text: "Connect your Spotify account to see your saved albums and playlists.")
            } else if let e = spot.error, spot.direct {
                ContentUnavailableView("Spotify", systemImage: "exclamationmark.triangle", description: Text(e)).padding(.top, 60)
            } else if list.isEmpty && !model.loading {
                ContentUnavailableView(model.onlyMissing ? "You have files for every saved album" : "No saved albums",
                                       systemImage: PluginID.spotify.icon).padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(list.prefix(600)) { a in
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: model.artURL(a.artworkPath)) {
                                    $0.resizable().scaledToFill()
                                } placeholder: { Cover(image: nil, seed: a.uri) }
                            }
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: model.hasFiles(a) ? "checkmark" : "dot.radiowaves.left.and.right")
                                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .glassEffect(.regular.tint(model.hasFiles(a) ? .green : Color(red: 0.11, green: 0.73, blue: 0.33)), in: .circle)
                                    .padding(7)
                            }
                        Text(a.name).font(.headline).lineLimit(1)
                        Text("\(a.artist) · \(a.trackCount) saved").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contextMenu {
                        if model.on(.soulseek) {
                            Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(a.artist, a.name) }
                        }
                        if model.on(.youtube) {
                            Button("Get from YouTube", systemImage: "play.rectangle") { Task { await model.albumFromYouTube(a) } }
                        }
                        Button(model.on(.ownTone) ? "Play on OwnTone" : "Open in Spotify", systemImage: "play.fill") { Task { await model.playURIs([a.uri]) } }
                        Button("Copy “Artist – Album”", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(a.artist) – \(a.name)", forType: .string)
                        }
                    }
                }
            }
            .padding(24).padding(.bottom, 50)
        }
        .toolbar {
            if model.on(.soulseek) {
                ToolbarItem(placement: .navigation) {
                    Button { model.showMissing = true } label: { Label("Get Missing Albums…", systemImage: "arrow.down.circle") }
                        .help("Find the saved albums you have no files for on Soulseek")
                        .disabled(model.spotify.isEmpty)
                }
            }
        }
        .navigationTitle("Spotify")
        .navigationSubtitle("\(list.count) albums" + (list.count > 600 ? " (first 600 shown, search finds the rest)" : ""))
    }
}

// MARK: artists

struct ArtistImage: View {
    @EnvironmentObject var model: Model
    var artist: Artist
    var body: some View {
        if let img = model.artistArt[artist.id] { Image(nsImage: img).resizable().scaledToFill() }
        else if let p = model.artistInfo[artist.id]?.photo, let u = URL(string: p), !p.isEmpty {
            AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Cover(image: artist.albums.lazy.compactMap { model.artwork[$0.id] }.first, seed: artist.id) }
        }
        else { Cover(image: artist.albums.lazy.compactMap { model.artwork[$0.id] }.first, seed: artist.id) }
    }
}

struct ArtistsView: View {
    @EnvironmentObject var model: Model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 26)]

    var body: some View {
        let list = model.artists
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(list) { a in
                    NavigationLink(value: Route.artist(a.name)) {
                        VStack(spacing: 8) {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { ArtistImage(artist: a) }
                                .clipShape(.circle)
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                                .overlay(alignment: .bottomTrailing) { MarkBadge(mark: model.artistMark(a)).padding(4) }
                            Text(a.name).font(.headline).lineLimit(1)
                            Text("\(a.albums.count) album\(a.albums.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Add All to iPod", systemImage: "plus.circle") { model.addAll(a) }
                        Button("Remove All from iPod", systemImage: "minus.circle") { model.removeAll(a) }
                    }
                }
            }
            .padding(24).padding(.bottom, 50)
        }
        .navigationTitle("Artists")
        .navigationSubtitle("\(list.count) artists")
    }
}

struct ArtistDetail: View {
    @EnvironmentObject var model: Model
    var name: String
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    var body: some View {
        if let a = model.artists.first(where: { $0.name == name }) {
            let m = model.artistMark(a)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center, spacing: 26) {
                        ArtistImage(artist: a).frame(width: 180, height: 180).clipShape(.circle)
                            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Artist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(a.name).font(.system(size: 40, weight: .bold)).lineLimit(2)
                            Text("\(a.albums.count) album\(a.albums.count == 1 ? "" : "s") · \(a.trackCount) songs · "
                                 + totalDuration(a.albums.flatMap(\.tracks).map(\.lengthMs).reduce(0, +)))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                if m != .onIPod {
                                    Button("Add All to iPod", systemImage: "plus") { model.addAll(a) }
                                        .buttonStyle(.glassProminent).disabled(model.ipod == nil)
                                }
                                if m != .none {
                                    Button("Remove All", systemImage: "minus") { model.removeAll(a) }.buttonStyle(.glass)
                                }
                                if model.on(.ownTone) {
                                    Button("Play", systemImage: "play.fill") {
                                        Task { await OwnTonePlaylists.play(a.albums.flatMap(\.tracks).map(\.uri).filter { !$0.isEmpty }, base: model.ownToneURL) }
                                    }.buttonStyle(.glass)
                                }
                            }
                            .padding(.top, 8)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("In Your Library").font(.title2.bold())
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(a.albums) { al in
                            NavigationLink(value: Route.album(al)) { AlbumTile(album: al) }
                                .buttonStyle(.plain)
                                .contextMenu { AlbumMenu(album: al) }
                        }
                    }
                    ArtistExtras(artist: a)
                }
                .padding(28).padding(.bottom, 50)
            }
            .background { Backdrop(image: model.artistArt[a.id] ?? a.albums.lazy.compactMap { model.artwork[$0.id] }.first) }
            .navigationTitle(a.name)
        } else {
            ContentUnavailableView("Artist not found", systemImage: "music.microphone")
        }
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
    enum Where: String, CaseIterable { case all = "All", mac = "On This Mac", cloud = "In iCloud" }
    @Published var query = ""
    @Published var sort = Sort.artist
    @Published var group = Group.letter
    @Published var place = Where.all
}

struct AppleMusicView: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = AMUI()
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    static func letter(_ s: String) -> String {
        let t = s.hasPrefix("The ") ? String(s.dropFirst(4)) : s
        guard let c = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased().first else { return "#" }
        return c.isLetter ? String(c) : "#"
    }

    var shown: [AMAlbum] {
        let words = ui.query.split(separator: " ")
        return model.amAlbums.filter { a in
            (!model.amHideImported || !model.amHidden.contains(a.id))
                && (ui.place == .all || (ui.place == .mac ? a.downloaded == a.tracks.count : a.downloaded < a.tracks.count))
                && words.allSatisfy { (a.title + " " + a.artist + " " + (a.tracks.first?.genre ?? "")).localizedStandardContains($0) }
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
        let letters = ui.group == .letter ? order : []
        return ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter albums", text: $ui.query).textFieldStyle(.plain)
                        if !ui.query.isEmpty { Button { ui.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: 280)
                    Picker("", selection: $ui.place) { ForEach(AMUI.Where.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Toggle("Hide imported", isOn: $model.amHideImported).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 24).padding(.top, 16)
                if let e = model.amError {
                    ContentUnavailableView("Can't read Apple Music", systemImage: "exclamationmark.triangle",
                                           description: Text(e + "\nAllow Crate to control Music in System Settings › Privacy & Security › Automation."))
                        .padding(.top, 80)
                } else if model.amLoading && model.amAlbums.isEmpty {
                    ProgressView("Reading your Apple Music library…").padding(.top, 120)
                } else if list.isEmpty {
                    ContentUnavailableView(ui.query.isEmpty ? "No albums" : "No albums match “\(ui.query)”", systemImage: "icloud").padding(.top, 80)
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
            .overlay(alignment: .trailing) {
                if letters.count > 3 {
                    VStack(spacing: 1) {
                        ForEach(letters, id: \.self) { l in
                            Button(l) { withAnimation(.snappy) { proxy.scrollTo("am-" + l, anchor: .top) } }
                                .buttonStyle(.plain).font(.caption2.bold()).foregroundStyle(.tint)
                                .frame(width: 18, height: 15).contentShape(.rect)
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 2)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.trailing, 6)
                }
            }
        }
        .navigationTitle("Apple Music")
        .navigationSubtitle("\(list.count) albums")
        .task { if model.amAlbums.isEmpty { await model.loadAppleMusic() } }
        .onChange(of: model.amHideImported) { model.amHidden = Set(model.amAlbums.filter(model.inLibrary).map(\.id)) }
        .onDisappear { model.amHidden = Set(model.amAlbums.filter(model.inLibrary).map(\.id)) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Sort By", selection: $ui.sort) { ForEach(AMUI.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline)
                    Picker("Group By", selection: $ui.group) { ForEach(AMUI.Group.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.inline)
                } label: { Label("Sort and Group", systemImage: "arrow.up.arrow.down") }
                .help("Sort and group")
            }
            ToolbarItem(placement: .navigation) {
                Button { Task { await model.loadAppleMusic() } } label: { Label("Reload Apple Music", systemImage: "arrow.clockwise.icloud") }
                    .disabled(model.amLoading).help("Read the Music library again")
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
                    AsyncImage(url: model.amArt[album.id]) { $0.resizable().scaledToFill() } placeholder: { Cover(image: nil, seed: album.id) }
                }
                .clipShape(.rect(cornerRadius: 14))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay {
                    if let busy {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.45))
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
                            Button("Import and Add to iPod", systemImage: "ipod") { model.importAppleMusic(album, toIPod: true) }
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
            Text(album.artist + (album.year > 0 ? " · \(album.year)" : "") + " · \(album.tracks.count) songs")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contextMenu {
            Button("Import to Library", systemImage: "square.and.arrow.down") { model.importAppleMusic(album, toIPod: false) }
            Button("Import and Add to iPod", systemImage: "ipod") { model.importAppleMusic(album, toIPod: true) }
        }
        .task(id: album.id) {
            if model.amArt[album.id] == nil, let u = await AppleMusic.artworkURL(album) { model.amArt[album.id] = u }
        }
    }
}
