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

/// A Spotify album in a grid: its cover with whether you have the files.
struct SpotifyTile: View {
    @EnvironmentObject var model: Model
    var album: SpotifyAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { CachedImage(url: model.artURL(album.artworkPath), seed: album.uri) }
                .clipShape(.rect(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .glassEffect(.regular.tint(PluginID.spotify.tint), in: .circle)
                        .padding(7)
                }
            Text(album.name).font(.headline).lineLimit(1)
            Text(album.year > 0 ? "\(album.year)" : "Spotify").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
    }
}

struct ArtistDetail: View {
    @EnvironmentObject var model: Model
    var name: String
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    var body: some View {
        let k = name.lowercased()
        let lib = model.libraryArtist(name)
        let spotify = model.on(.spotify) ? model.spotify.filter { $0.artist.lowercased() == k && !model.hasFiles($0) } : []
        let apple = model.on(.appleMusic) ? model.amAlbums.filter { $0.artist.lowercased() == k && !model.inLibrary($0) } : []
        let display = lib?.name ?? spotify.first?.artist ?? apple.first?.artist ?? name
        let tracks = lib?.albums.flatMap(\.tracks) ?? []
        if lib == nil && spotify.isEmpty && apple.isEmpty && model.artistInfo[k] == nil && !model.artistLoading.contains(k) {
            ContentUnavailableView("Artist not found", systemImage: "music.microphone")
                .task { await model.loadArtistInfo(name) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(display, lib: lib, tracks: tracks, spotify: spotify, apple: apple)
                    if let lib {
                        // albums, EPs and singles apart, like a record shop's bins
                        ForEach(ReleaseKind.allCases, id: \.self) { kind in
                            let list = lib.albums.filter { ReleaseKind.of($0) == kind }
                            if !list.isEmpty {
                                section(kind.title, count: list.count)
                                LazyVGrid(columns: columns, spacing: 26) {
                                    ForEach(list) { al in
                                        NavigationLink(value: Route.album(al)) { AlbumTile(album: al) }
                                            .buttonStyle(.plain)
                                            .contextMenu { AlbumMenu(album: al) }
                                    }
                                }
                            }
                        }
                    }
                    if !spotify.isEmpty {
                        section("On Spotify", count: spotify.count, note: "not in your library yet", icon: PluginID.spotify.icon, tint: PluginID.spotify.tint)
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(spotify) { a in
                                NavigationLink(value: Route.spotifyAlbum(a)) { SpotifyTile(album: a) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !apple.isEmpty {
                        section("In Apple Music", count: apple.count, note: "not in your library yet", icon: PluginID.appleMusic.icon, tint: PluginID.appleMusic.tint)
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(apple) { a in AMTile(album: a) }
                        }
                    }
                    ArtistExtras(artist: lib ?? Artist(name: display, albums: []))
                }
                .padding(28).padding(.bottom, 50)
            }
            .background { Backdrop(image: lib.flatMap { a in model.artistArt[a.id] ?? a.albums.lazy.compactMap { model.artwork[$0.id] }.first }) }
            .navigationTitle(display)
        }
    }

    func header(_ display: String, lib: Artist?, tracks: [LibTrack], spotify: [SpotifyAlbum], apple: [AMAlbum]) -> some View {
        HStack(alignment: .center, spacing: 26) {
            ArtistPortrait(name: display, fallback: spotify.first.flatMap { model.artURL($0.artworkPath) } ?? apple.first.flatMap { model.amArt[$0.id] })
                .frame(width: 180, height: 180).clipShape(.circle)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Artist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(display).font(.system(size: 40, weight: .bold)).lineLimit(2)
                Text(stats(lib, tracks: tracks, spotify: spotify.count, apple: apple.count)).foregroundStyle(.secondary)
                if let lib {
                    let m = model.artistMark(lib)
                    HStack(spacing: 10) {
                        Button("Play", systemImage: "play.fill") { Task { await model.play(tracks) } }
                            .buttonStyle(.glassProminent)
                        Button { Task { await model.play(tracks.shuffled()) } } label: { Image(systemName: "shuffle") }
                            .buttonStyle(.glass).help("Shuffle")
                        let kept = model.keptArtists.contains(lib.id)
                        Menu {
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
                            Label { Text(ipodTitle(m, kept: kept)) } icon: { Image(symbol: kept ? "pin.fill" : m == .none ? "plus" : "ipod") }
                        }
                        .glassMenu()
                        .help(kept ? "Every album by \(lib.name) goes to the iPod, also ones you add later" : "Put \(lib.name) on the iPod")
                        Menu {
                            AddToPlaylistMenu(tracks: tracks)
                        } label: { Image(systemName: "ellipsis") }
                            .glassMenu(indicator: false)
                            .help("More")
                    }
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

    func stats(_ lib: Artist?, tracks: [LibTrack], spotify: Int, apple: Int) -> String {
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
        if spotify > 0 { parts.append("\(spotify) more on Spotify") }
        if apple > 0 { parts.append("\(apple) more in Apple Music") }
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

/// What a release is, from its number of songs: up to 3 a single, up to 6 an EP, longer an album.
enum ReleaseKind: CaseIterable {
    case album, ep, single
    static func of(_ a: Album) -> ReleaseKind { a.tracks.count <= 3 ? .single : a.tracks.count <= 6 ? .ep : .album }
    var title: String { switch self { case .album: "Albums"; case .ep: "EPs"; case .single: "Singles" } }
    var one: String { switch self { case .album: "album"; case .ep: "EP"; case .single: "single" } }
}
