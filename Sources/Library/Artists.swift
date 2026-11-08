import SwiftUI

// One artist page for every source: what's in the library (with the iPod actions), the artist's albums on
// Spotify and in Apple Music that aren't in the library yet, the MusicBrainz discography and the Wikipedia
// bio. Each section shows only when it has something, so an artist you only have on Spotify gets a page too.

extension Model {
    /// The library artist with this name, if any.
    func libraryArtist(_ name: String) -> Artist? {
        let k = name.lowercased()
        return artists.first { $0.id == k }
    }

    /// Plays songs on the chosen output, like an album's Play.
    func play(_ tracks: [LibTrack]) async {
        if player.output == "owntone", on(.ownTone) {
            let uris = tracks.map(\.uri).filter { !$0.isEmpty }
            if uris.isEmpty { notify("These songs aren't in OwnTone's library yet"); return }
            await OwnTonePlaylists.play(uris, base: ownToneURL)
        } else {
            player.play(tracks.filter { libraryTrack(key: $0.key) != nil })      // not songs that are only on the iPod
        }
    }
}

/// An artist's round picture: your own or the Wikipedia photo, else an album cover.
struct ArtistPortrait: View {
    @EnvironmentObject var model: Model
    var name: String
    var fallback: URL? = nil      // a source album's cover, for artists not in the library

    var body: some View {
        if let a = model.libraryArtist(name) { ArtistImage(artist: a) }
        else if let p = model.artistInfo[name.lowercased()]?.photo, let u = URL(string: p), !p.isEmpty { CachedImage(url: u, seed: name) }
        else { CachedImage(url: fallback, seed: name) }
    }
}

/// Spotify's mark (a disc with three arcs cut out), for what's only on Spotify; the radio waves didn't say Spotify.
/// Monotone in the secondary colour, like the other marks around it: the green logo shouted everywhere.
struct SpotifyMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .style(.secondary))
            ctx.blendMode = .clear
            for (p, line) in Self.arcs(w) { ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: line, lineCap: .round)) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Spotify")
    }

    /// The three arcs at width `w`, widest on top, each a little lower on the right; with their line widths.
    static func arcs(_ w: CGFloat) -> [(Path, CGFloat)] {
        [(0.22, 0.79, 0.36, 0.105), (0.26, 0.74, 0.53, 0.085), (0.3, 0.69, 0.68, 0.07)].enumerated().map { i, a in
            let (x0, x1, y, line) = a
            var p = Path()
            p.move(to: CGPoint(x: x0 * w, y: y * w))
            p.addQuadCurve(to: CGPoint(x: x1 * w, y: (y + 0.05) * w), control: CGPoint(x: 0.5 * w, y: (y - 0.12 + Double(i) * 0.015) * w))
            return (p, line * w)
        }
    }

    /// The mark as a template image: a sidebar tints it like an SF Symbol (the accent, white when selected),
    /// which a Canvas in a Label's icon doesn't get.
    static let template: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { r in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.addEllipse(in: r.insetBy(dx: 0.5, dy: 0.5)); cg.setFillColor(.black); cg.fillPath()
            cg.setBlendMode(.clear); cg.setLineCap(.round)
            for (p, line) in arcs(r.width) { cg.addPath(p.cgPath); cg.setLineWidth(line); cg.strokePath() }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// A Spotify album in a grid: its cover with whether you have the files.
struct SpotifyTile: View {
    @EnvironmentObject var model: Model
    var album: SpotifyAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { CachedImage(url: model.artURL(album.artworkPath), seed: album.uri) }
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay(alignment: .topTrailing) {
                    SpotifyMark().frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .help("Only on Spotify")
                        .padding(7)
                }
            Text(album.name).font(.headline).lineLimit(1)
            Text(album.year > 0 ? String(album.year) : "Spotify").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
    }
}

struct ArtistDetail: View {
    @EnvironmentObject var model: Model
    var name: String
    @StateObject private var filter = ArtistFilter()
    @StateObject private var flash = Flash()
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]
    private let rows = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 18)]

    var body: some View {
        let k = name.lowercased()
        let lib = model.libraryArtist(name)
        let spotify = model.on(.spotify) ? model.spotify.filter { $0.artist.lowercased() == k && !model.hasFiles($0) } : []
        let apple = model.on(.appleMusic) ? model.amAlbums.filter { $0.artist.lowercased() == k && !model.inLibrary($0) } : []
        let display = lib?.name ?? spotify.first?.artist ?? apple.first?.artist ?? name
        let tracks = lib?.albums.flatMap(\.tracks) ?? []
        if lib == nil && spotify.isEmpty && apple.isEmpty && model.artistInfo[k] == nil && model.artistFailed.contains(k) {
            ContentUnavailableView {
                Label("Artist not found", systemImage: "music.microphone")
            } description: { Text("MusicBrainz didn't answer, or doesn't know “\(name)”") } actions: {
                Button("Try Again") { Task { await model.loadArtistInfo(name) } }.buttonStyle(.glass)
            }
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(display, lib: lib, tracks: tracks, spotify: spotify, apple: apple)
                    ArtistExtras(artist: lib ?? Artist(name: display, albums: []))
                    // what you can play, albums, EPs and singles apart like a record shop's bins, newest first:
                    // the library's, then Spotify's and Apple Music's that it doesn't have
                    let all = discography(lib: lib, spotify: spotify, apple: apple, info: model.artistInfo[k])
                    let releases = all.filter { r in
                        if matchesQuery(filter.query, r.words) || filter.titles.contains(Release.loose(r.title)) { return true }
                        if case .missing(let g) = r.source { return filter.groups.contains(g.id) }
                        return false
                    }
                    if all.count > 6 {
                        FilterField(prompt: "Release, song or year", text: $filter.query)
                        if releases.isEmpty { Text("Nothing by \(display) matches “\(filter.query)”").foregroundStyle(.secondary) }
                    }
                    let own = releases.filter { if case .missing = $0.source { false } else { true } }
                    ForEach(ReleaseKind.allCases, id: \.self) { kind in
                        let list = own.filter { $0.kind == kind }
                        if !list.isEmpty {
                            section(kind.title, count: list.count)
                            LazyVGrid(columns: columns, spacing: 26) {
                                ForEach(list) { r in flashing(tile(r, artist: display), r.title) }
                            }
                        }
                    }
                    // the rest of the discography is on its way (MusicBrainz takes a request a second), or didn't come
                    if model.artistLoading.contains(k) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking up the rest of \(display)'s releases on MusicBrainz…")
                        }
                        .foregroundStyle(.secondary)
                    } else if model.artistFailed.contains(k) {
                        HStack(spacing: 10) {
                            Label("Couldn't get \(display)'s other releases from MusicBrainz", systemImage: "exclamationmark.triangle")
                            Button("Try Again") { Task { await model.loadArtistInfo(name) } }.buttonStyle(.glass).controlSize(.small)
                        }
                        .foregroundStyle(.secondary)
                    }
                    // the rest of the MusicBrainz discography, compact and below, so the grids don't move when it arrives
                    let missing = releases.compactMap { r -> (ReleaseKind, ReleaseGroup)? in if case .missing(let g) = r.source { (r.kind, g) } else { nil } }
                    if !missing.isEmpty {
                        section("Not in your library", count: missing.count)
                        ForEach(ReleaseKind.allCases, id: \.self) { kind in
                            let list = missing.filter { $0.0 == kind }.map(\.1)
                            if !list.isEmpty {
                                Text("\(kind.title) · \(list.count)").font(.headline).foregroundStyle(.secondary)
                                LazyVGrid(columns: rows, alignment: .leading, spacing: 10) {
                                    ForEach(list) { g in flashing(MissingRow(release: g, artist: display), g.title) }
                                }
                            }
                        }
                    }
                }
                .padding(28).padding(.bottom, 50)
            }
            .task(id: k) { await model.loadArtistInfo(name) }      // the discography (ArtistExtras' own task only runs once it has a bio to show)
            .task(id: model.highlight) {
                let ids = discography(lib: lib, spotify: spotify, apple: apple, info: model.artistInfo[k]).map { Model.releaseHighlight($0.title) }
                await showHighlight(model, ids: ids, proxy: proxy, flash: flash)
            }
            }
            .task(id: filter.query) {
                let api = model.on(.spotify) && model.spotifyAPI.direct && model.spotifyAPI.connected ? model.spotifyAPI : nil
                let mbid = model.artistInfo[k]?.mbid
                await filter.lookUp(display, mbid: mbid?.isEmpty == false ? mbid : nil, spotify: api)
            }
            .background { Backdrop(image: lib.flatMap { a in model.artistArt[a.id] ?? a.albums.lazy.compactMap { model.artwork[$0.id] }.first }) }
            .pageTitle(display)
        }
    }

    @ViewBuilder func tile(_ r: Release, artist: String) -> some View {
        switch r.source {
        case .library(let al):
            AlbumTile(album: al).albumLink(al).contextMenu { AlbumMenu(album: al) }
        case .spotify(let a): NavigationLink(value: Route.spotifyAlbum(a)) { SpotifyTile(album: a) }.buttonStyle(.plain)
        case .apple(let a): AMTile(album: a)
        case .missing: EmptyView()
        }
    }

    /// A release the remote jumped to (Model.highlight), lit up a moment.
    func flashing<V: View>(_ v: V, _ title: String) -> some View {
        let id = Model.releaseHighlight(title)
        return v.overlay {
            if flash.id == id {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08))
                    .strokeBorder(Color.primary.opacity(0.5), lineWidth: 3).padding(-6).allowsHitTesting(false)
            }
        }
        .id(id)
    }

    /// Every release once (by title, ignoring punctuation): the library's own first, then Spotify, Apple Music, MusicBrainz.
    func discography(lib: Artist?, spotify: [SpotifyAlbum], apple: [AMAlbum], info: ArtistInfo?) -> [Release] {
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var seen = Set<String>(), out: [Release] = []
        func add(_ title: String, _ r: Release) { if seen.insert(loose(title)).inserted { out.append(r) } }
        for a in lib?.albums ?? [] {
            add(a.title, Release(source: .library(a), kind: .of(a), year: a.year > 0 ? a.year : model.metadata[a.id]?.year ?? 0))
        }
        for a in spotify { add(a.name, Release(source: .spotify(a), kind: a.trackCount > 0 ? .of(count: a.trackCount) : .album, year: a.year)) }
        for a in apple { add(a.title, Release(source: .apple(a), kind: .of(count: a.tracks.count), year: a.year)) }
        for g in info?.releases ?? [] {
            add(g.title, Release(source: .missing(g), kind: g.type == "Single" ? .single : g.type == "EP" ? .ep : .album, year: g.year))
        }
        return out.sorted { ($0.year == 0 ? -1 : $0.year) > ($1.year == 0 ? -1 : $1.year) }
    }

    func header(_ display: String, lib: Artist?, tracks: [LibTrack], spotify: [SpotifyAlbum], apple: [AMAlbum]) -> some View {
        HStack(alignment: .center, spacing: 26) {
            ArtistPortrait(name: display, fallback: spotify.first.flatMap { model.artURL($0.artworkPath) } ?? apple.first.flatMap { model.amArt[$0.id] })
                .frame(width: 180, height: 180).clipShape(.circle)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .heroTarget(.artist(display))
            VStack(alignment: .leading, spacing: 6) {
                Text("Artist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(display).font(.system(size: 40, weight: .bold)).lineLimit(2)
                HStack(spacing: 10) {
                    Text(stats(lib, tracks: tracks))
                    if !spotify.isEmpty {
                        Label { Text("\(spotify.count)") } icon: { SpotifyMark().frame(width: 15, height: 15) }
                            .help("\(spotify.count) \(spotify.count == 1 ? "release" : "releases") only on Spotify")
                    }
                    if !apple.isEmpty { elsewhere(.appleMusic, apple.count, "only in Apple Music") }
                }
                .foregroundStyle(.secondary)
                if let lib {
                    let m = model.artistMark(lib)
                    HStack(spacing: 10) {
                        Button("Play", systemImage: "play.fill") { Task { await model.play(tracks) } }
                            .buttonStyle(.glassProminent)
                        Button { Task { await model.play(tracks.shuffled()) } } label: { Image(systemName: "shuffle") }
                            .help("Shuffle")
                        let kept = model.keptArtists.contains(lib.id)
                        GlassMenu {
                            if m != .onIPod {
                                Button("Add All to iPod", systemImage: "plus") { model.addAll(lib) }.disabled(model.ipod == nil)
                            }
                            if m != .none {
                                Button("Remove All from iPod", systemImage: "minus") { model.removeAll(lib) }
                            }
                            Divider()
                            Toggle(isOn: Binding(get: { kept }, set: { _ in model.toggleKeep(lib) })) {
                                Label("Keep on iPod", systemImage: "pin")
                            }
                        } label: {
                            // the ipod glyph is narrow, so Label's own gap reads as cramped
                            HStack(spacing: 7) { PodStateIcon(mark: m, pinned: kept); Text(ipodTitle(m, kept: kept)) }
                        }
                        .help(kept ? "Every album by \(lib.name) goes to the iPod, also ones you add later" : "Put \(lib.name) on the iPod")
                        GlassMenu {
                            AddToPlaylistMenu(tracks: tracks)
                            if model.on(.soulseek) {
                                Divider()
                                Button("Find \(lib.name) on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(lib.name, "") }
                            }
                        } label: { MoreLabel() }
                            .help("More")
                    }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).menuStyle(.button).fixedSize()
                    .padding(.top, 8)
                } else if model.on(.soulseek) {
                    Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(display, "") }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
                        .help("Search Soulseek for everything by \(display)")
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    func ipodTitle(_ m: SyncMark, kept: Bool) -> String {
        if kept { return "Kept on iPod" }
        switch m {
        case .none: return "Add to iPod"
        case .onIPod: return "On iPod"
        case .partial: return "Partly on iPod"
        case .adding: return "Adding to iPod"
        case .removing: return "Removing from iPod"
        }
    }

    /// A source's icon with how many of the artist's releases are only there.
    func elsewhere(_ p: PluginID, _ n: Int, _ what: String) -> some View {
        Label { Text("\(n)") } icon: { Image(systemName: p.icon).foregroundStyle(p.tint) }
            .help("\(n) \(n == 1 ? "release" : "releases") \(what)")
    }

    func stats(_ lib: Artist?, tracks: [LibTrack]) -> String {
        var parts: [String] = []
        if let lib {
            let kinds = ReleaseKind.allCases.compactMap { k in
                let n = lib.albums.filter { ReleaseKind.of($0) == k }.count
                return n > 0 ? "\(n) \(n == 1 ? k.one : k.title.lowercased())" : nil
            }
            parts.append(kinds.joined(separator: " · ") + " · \(tracks.count) songs · "
                         + totalDuration(tracks.map(\.lengthMs).reduce(0, +)))
        } else {
            parts.append("Not in your library")
        }
        return parts.joined(separator: " · ")
    }

    func section(_ title: String, count: Int, note: String = "", icon: String? = nil, tint: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(tint) }
            Text(title).font(.title2.bold())
            Text(note.isEmpty ? "\(count)" : "\(count) · \(note)").foregroundStyle(.secondary)
        }
    }
}

// MARK: artist grids

/// Where each letter of an artist grid starts: the first artist under it, in the grid's order.
enum ArtistLetters {
    static func id(_ letter: String) -> String { "artist-letter-" + letter }

    /// Each name's letter, and the letters in order (for the index).
    static func of(_ names: [String], letter: (String) -> String = AppleMusicView.letter) -> (first: Set<Int>, letters: [String], letterOf: [String]) {
        var seen = Set<String>(), first = Set<Int>(), order: [String] = []
        let ls = names.map(letter)
        for (i, l) in ls.enumerated() where seen.insert(l).inserted { first.insert(i); order.append(l) }
        return (first, order, ls)
    }

    /// The index, jumping to a letter or the next one that has artists.
    @ViewBuilder static func index(_ letters: [String], proxy: ScrollViewProxy) -> some View {
        if letters.count > 3 {
            LetterIndex(letters: LetterIndex.all) { l in
                let i = LetterIndex.all.firstIndex(of: l) ?? 0
                if let t = letters.first(where: { (LetterIndex.all.firstIndex(of: $0) ?? LetterIndex.all.count) >= i }) ?? letters.last {
                    proxy.scrollTo(id(t), anchor: .top)
                }
            }
        }
    }
}

/// The filter on an artist page.
final class ArtistFilter: ObservableObject {
    @Published var query = ""
    /// Releases with a song matching the query, which Crate has no song lists for: MusicBrainz's release groups
    /// (by id) from a recording search, and release titles (loose) from those and from Spotify's search.
    @Published var groups: Set<String> = []
    @Published var titles: Set<String> = []

    @MainActor func lookUp(_ artist: String, mbid: String?, spotify: SpotifyAPI?) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, mbid != nil || spotify != nil else { groups = []; titles = []; return }
        try? await Task.sleep(for: .milliseconds(400))          // wait for the typing to settle
        guard !Task.isCancelled else { return }
        var ids = Set<String>(), names = Set<String>()
        if let mbid {
            var c = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
            c.queryItems = [.init(name: "query", value: "recording:\"\(q)\" AND arid:\(mbid)"), .init(name: "fmt", value: "json"), .init(name: "limit", value: "100")]
            if let j = try? await MusicBrainz.get(c.url!) {
                for rec in (j["recordings"] as? [[String: Any]]) ?? [] {
                    for r in (rec["releases"] as? [[String: Any]]) ?? [] {
                        guard let g = r["release-group"] as? [String: Any] else { continue }
                        if let id = g["id"] as? String { ids.insert(id) }
                        if let t = g["title"] as? String { names.insert(Release.loose(t)) }
                    }
                }
            }
        }
        if let spotify, let n = try? await spotify.albums(withSong: q, by: artist) { names.formUnion(n.map(Release.loose)) }
        guard !Task.isCancelled else { return }
        groups = ids; titles = names
    }
}

/// A release in an artist's discography.
struct Release: Identifiable {
    enum Source { case library(Album), spotify(SpotifyAlbum), apple(AMAlbum), missing(ReleaseGroup) }
    var source: Source
    var kind: ReleaseKind
    var year: Int
    var id: String {
        switch source {
        case .library(let a): "lib:" + a.id
        case .spotify(let a): "sp:" + a.id
        case .apple(let a): "am:" + a.id
        case .missing(let g): "mb:" + g.id
        }
    }
    var inLibrary: Bool { if case .library = source { true } else { false } }
    var title: String {
        switch source {
        case .library(let a): a.title
        case .spotify(let a): a.name
        case .apple(let a): a.title
        case .missing(let g): g.title
        }
    }
    static func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    /// What the artist page's filter looks in: the title, the year and, for the library's, the songs.
    var words: [String] {
        let y = year > 0 ? String(year) : ""
        switch source {
        case .library(let a): return [a.title, y] + a.tracks.map(\.title)
        case .spotify(let a): return [a.name, y]
        case .apple(let a): return [a.title, y] + a.tracks.map(\.title)
        case .missing(let g): return [g.title, y]
        }
    }
}

/// What a release is, from its number of songs: up to 3 a single, up to 6 an EP, longer an album.
enum ReleaseKind: CaseIterable {
    case album, ep, single
    static func of(_ a: Album) -> ReleaseKind { of(count: a.tracks.count) }
    static func of(count n: Int) -> ReleaseKind { n <= 3 ? .single : n <= 6 ? .ep : .album }
    var title: String { switch self { case .album: "Albums"; case .ep: "EPs"; case .single: "Singles" } }
    var one: String { switch self { case .album: "album"; case .ep: "EP"; case .single: "single" } }
}
