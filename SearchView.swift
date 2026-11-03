import SwiftUI

// Search across everything: the library (artists, albums, songs), playlists, and the enabled
// sources (Apple Music, Spotify), with a jump to a Soulseek search at the end.

/// The query the results are for (it follows the search field once typing pauses) and the library matches,
/// kept until the query or the library changes.
@MainActor
final class SearchUI: ObservableObject {
    @Published var q = ""
    private var key: Int?
    private var cached: (artists: [Artist], albums: [Album], songs: [LibTrack]) = ([], [], [])
    func library(_ model: Model, _ match: (String, [String]) -> Bool) -> (artists: [Artist], albums: [Album], songs: [LibTrack]) {
        var h = Hasher(); h.combine(q); h.combine(model.libraryVersion); h.combine(model.syncVersion)
        let k = h.finalize()
        if k != key {
            cached = (model.artists.filter { match(q, [$0.name]) },
                      model.allAlbums.filter { match(q, [$0.title, $0.artist, $0.genre]) },
                      model.libTracks.filter { match(q, [$0.title, $0.trackArtist, $0.artist, $0.album]) })
            key = k
        }
        return cached
    }
}

struct SearchView: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = SearchUI()
    private let grid = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 20)]

    var body: some View {
        let q = ui.q
        let (artists, albums, songs) = ui.library(model) { q, fields in matches(q, fields) }
        let lists = model.playlists.filter { matches(q, $0.name) }
        let podLists = model.podOnlyPlaylists.filter { matches(q, $0.name) }
        let am = model.on(.appleMusic) ? model.amAlbums.filter { matches(q, $0.title, $0.artist) && !model.inLibrary($0) } : []
        let sp = model.on(.spotify) ? model.spotify.filter { matches(q, $0.name, $0.artist) && !model.hasFiles($0) } : []
        let nothing = artists.isEmpty && albums.isEmpty && songs.isEmpty && lists.isEmpty && podLists.isEmpty && am.isEmpty && sp.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if nothing {
                    ContentUnavailableView.search(text: q).padding(.top, 40)
                }
                if !artists.isEmpty {
                    ResultSection(title: "Artists", count: artists.count) {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 22) {
                                ForEach(artists.prefix(20)) { a in
                                    NavigationLink(value: Route.artist(a.name)) {
                                        VStack(spacing: 6) {
                                            ArtistImage(artist: a).frame(width: 110, height: 110).clipShape(.circle)
                                                .overlay(alignment: .bottomTrailing) { MarkBadge(mark: model.artistMark(a), size: 22) }
                                            Text(a.name).font(.callout.weight(.medium)).lineLimit(1).frame(width: 120)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
                if !albums.isEmpty {
                    ResultSection(title: "Albums", count: albums.count) {
                        LazyVGrid(columns: grid, spacing: 22) {
                            ForEach(albums.prefix(30)) { a in
                                NavigationLink(value: Route.album(a)) { AlbumTile(album: a) }
                                    .buttonStyle(.plain).contextMenu { AlbumMenu(album: a) }
                            }
                        }
                    }
                }
                if !songs.isEmpty {
                    let keys = model.podKeys
                    ResultSection(title: "Songs", count: songs.count) {
                        VStack(spacing: 0) {
                            ForEach(Array(songs.prefix(40).enumerated()), id: \.element.id) { i, t in
                                let album = model.album(of: t)
                                HStack(spacing: 12) {
                                    Cover(image: album.flatMap { model.artwork[$0.id] }, seed: t.album)
                                        .frame(width: 34, height: 34).clipShape(.rect(cornerRadius: 5))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.title).lineLimit(1)
                                        Text("\(t.trackArtist.isEmpty ? t.artist : t.trackArtist) — \(t.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if keys.contains(t.key) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("On the iPod") }
                                    Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                                .contentShape(.rect)
                                .onTapGesture { if let album { model.path.append(.album(album)) } }
                            }
                        }
                        .clipShape(.rect(cornerRadius: 14))
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    }
                }
                if !lists.isEmpty || !podLists.isEmpty {
                    ResultSection(title: "Playlists", count: lists.count + podLists.count) {
                        FlowRow {
                            ForEach(lists) { p in
                                ChipButton(title: p.name, icon: "music.note.list", mark: model.mark(p)) { model.search = ""; model.pane = .playlist(p.id) }
                            }
                            ForEach(podLists) { p in
                                ChipButton(title: p.name, icon: "ipod", mark: model.mark(p)) { model.search = ""; model.pane = .podPlaylist(p.id) }
                            }
                        }
                    }
                }
                if !am.isEmpty {
                    ResultSection(title: "Apple Music", count: am.count, icon: PluginID.appleMusic.icon) {
                        LazyVGrid(columns: grid, spacing: 22) { ForEach(am.prefix(12)) { AMTile(album: $0) } }
                    }
                }
                if !sp.isEmpty {
                    ResultSection(title: "Spotify – no files yet", count: sp.count, icon: PluginID.spotify.icon) {
                        VStack(spacing: 0) {
                            ForEach(sp.prefix(10)) { a in
                                HStack(spacing: 12) {
                                    CachedImage(url: model.artURL(a.artworkPath), seed: "SearchView.swift:4")
                                    .frame(width: 34, height: 34).clipShape(.rect(cornerRadius: 5))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.name).lineLimit(1)
                                        Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if model.on(.soulseek) {
                                        Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(a.artist, a.name) }
                                            .buttonStyle(.glass).controlSize(.small)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                            }
                        }
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    }
                }
                if model.on(.soulseek) {
                    Button { model.findOnSoulseek("", q) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: PluginID.soulseek.icon).font(.title2).foregroundStyle(PluginID.soulseek.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Search Soulseek for “\(q)”").font(.headline)
                                Text("Download it if you don't have it yet").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(14).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
            }
            .padding(28).padding(.bottom, 60)
        }
        .navigationTitle("Search")
        .navigationSubtitle("“\(q)”")
        .task(id: model.search) {
            // the first query right away, then once typing pauses
            if !ui.q.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            if !Task.isCancelled { ui.q = model.search }
        }
    }

    /// Every word of the query appears in one of the fields.
    func matches(_ q: String, _ fields: String...) -> Bool { matches(q, fields) }
    func matches(_ q: String, _ fields: [String]) -> Bool {
        let hay = fields.joined(separator: " ")
        return q.split(separator: " ").allSatisfy { hay.localizedStandardContains($0) }
    }
}

struct ResultSection<Content: View>: View {
    var title: String
    var count: Int
    var icon: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(title).font(.title2.bold())
                Text("\(count)").foregroundStyle(.secondary)
            }
            content
        }
    }
}

struct ChipButton: View {
    var title, icon: String
    var mark: SyncMark
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
                SidebarMark(mark: mark)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x + d.width > w, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += d.width + spacing; line = max(line, d.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x + d.width > b.maxX, x > b.minX { x = b.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(d))
            x += d.width + spacing; line = max(line, d.height)
        }
    }
}
