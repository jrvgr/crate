import SwiftUI

// An Apple Music album's own page, and its albums as a list and in Cover Flow, like Spotify's and the library's.

extension Model {
    /// Fetches an album's cover URL once (the grid, list and Cover Flow all ask).
    func loadAMArt(_ a: AMAlbum) async {
        if amArt[a.id] == nil, let u = await AppleMusic.artworkURL(a) { amArt[a.id] = u }
    }
}

/// The import buttons, or how far an import has got.
struct AMImportButtons: View {
    @EnvironmentObject var model: Model
    var album: AMAlbum
    var body: some View {
        if let job = model.amJob(album) {
            HStack(spacing: 8) {
                if let p = job.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                Text(job.state == .queued ? "Queued" : job.detail).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let lib = model.albums.first(where: { $0.id == album.id }) {
            Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(lib)) }.buttonStyle(.glassProminent)
        } else {
            Button("Import to Library", systemImage: "square.and.arrow.down") { model.importAppleMusic(album, toIPod: false) }
                .buttonStyle(.glassProminent)
            Button("Import and Add to iPod", pod: model.ipod?.glyph) { model.importAppleMusic(album, toIPod: true) }
                .buttonStyle(.glass).disabled(model.ipod == nil)
        }
    }
}

struct AMAlbumView: View {
    @EnvironmentObject var model: Model
    var album: AMAlbum

    var body: some View {
        let tracks = album.tracks.sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
        let discs = Set(tracks.map(\.discNumber)).count > 1
        let lib = model.albums.first { $0.id == album.id }
        let have = Set((lib?.tracks ?? []).map { LinkMatch.loose($0.title) })
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 24) {
                    CachedImage(url: model.amArt[album.id], seed: album.id)
                        .frame(width: 220, height: 220).clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Apple Music", systemImage: "icloud").font(.caption.weight(.semibold)).foregroundStyle(PluginID.appleMusic.tint)
                        Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                        Button { model.path.append(.artist(album.artist)) } label: {
                            Text(album.artist).font(.title2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Go to artist")
                        let genre = album.tracks.first { !$0.genre.isEmpty }?.genre ?? ""
                        Text([album.year > 0 ? "\(album.year)" : "", genre, "\(tracks.count) songs", totalDuration(album.lengthMs),
                              album.downloaded == tracks.count ? "on this Mac" : album.downloaded == 0 ? "in iCloud" : "\(album.downloaded) on this Mac",
                              lib != nil ? "in your library" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) { AMImportButtons(album: album) }.padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.pid) { i, t in
                        let inLib = have.contains(LinkMatch.loose(t.name))
                        HStack(spacing: 12) {
                            Text(discs ? "\(t.discNumber)-\(t.trackNumber)" : t.trackNumber > 0 ? "\(t.trackNumber)" : "")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name).lineLimit(1)
                                if !t.artist.isEmpty && t.artist != album.artist { Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if inLib { Image(systemName: "music.note").foregroundStyle(.tint).help("In your library") }
                            else if t.location.isEmpty { Image(systemName: "icloud").foregroundStyle(.tertiary).help("In iCloud; downloaded on import") }
                            else { Image(systemName: "laptopcomputer").foregroundStyle(.tertiary).help("On this Mac") }
                            Text(duration(Int(t.seconds * 1000))).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(28).padding(.bottom, 60)
        }
        .navigationTitle(album.title)
        .task { await model.loadAMArt(album) }
    }
}

struct AMMenu: View {
    @EnvironmentObject var model: Model
    var album: AMAlbum
    var body: some View {
        Button("Open", systemImage: "chevron.right") { model.path.append(.amAlbum(album)) }
        if !model.inLibrary(album) {
            Button("Import to Library", systemImage: "square.and.arrow.down") { model.importAppleMusic(album, toIPod: false) }
            Button("Import and Add to iPod", pod: model.ipod?.glyph) { model.importAppleMusic(album, toIPod: true) }.disabled(model.ipod == nil)
        }
    }
}

/// One row of the Apple Music album list (sortable fields).
struct AMRow: Identifiable {
    var album: AMAlbum
    var id: AMAlbum.ID { album.id }
    var title: String { album.title }
    var artist: String { album.artist }
    var year: Int { album.year == 0 ? 9999 : album.year }
    var genre: String { album.tracks.first { !$0.genre.isEmpty }?.genre ?? "" }
    var songs: Int { album.tracks.count }
    var length: Int { album.lengthMs }
    var onMac: Int { album.downloaded }
}

@MainActor
final class AMListUI: ObservableObject {
    @Published var selection: Set<AMAlbum.ID> = []
    @Published var sort = [KeyPathComparator(\AMRow.artist), KeyPathComparator(\AMRow.year), KeyPathComparator(\AMRow.title)]
}

struct AMAlbumList: View {
    @EnvironmentObject var model: Model
    var albums: [AMAlbum]
    @StateObject private var ui = AMListUI()

    var body: some View {
        Table(albums.map(AMRow.init).sorted(using: ui.sort), selection: $ui.selection, sortOrder: $ui.sort) {
            TableColumn("") { (r: AMRow) in
                let have = model.inLibrary(r.album), busy = model.amJob(r.album) != nil
                Image(systemName: busy ? "arrow.down.circle" : have ? "checkmark.circle.fill" : "icloud")
                    .foregroundStyle(have ? AnyShapeStyle(.green) : busy ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .help(busy ? "Importing" : have ? "In the library" : "Not imported")
            }
            .width(22)
            TableColumn("Album", value: \.title) { (r: AMRow) in
                HStack(spacing: 8) {
                    CachedImage(url: model.amArt[r.id], seed: r.id).frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 4))
                    Text(r.title).lineLimit(1)
                }
                .task(id: r.id) { await model.loadAMArt(r.album) }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.artist)
            TableColumn("Year", value: \.year) { (r: AMRow) in Text(r.album.year > 0 ? String(r.album.year) : "").monospacedDigit() }.width(46)
            TableColumn("Genre", value: \.genre).width(min: 70, ideal: 110)
            TableColumn("Songs", value: \.songs) { (r: AMRow) in Text("\(r.songs)").monospacedDigit() }.width(46)
            TableColumn("Time", value: \.length) { (r: AMRow) in Text(totalDuration(r.length)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("On Mac", value: \.onMac) { (r: AMRow) in
                Text(r.onMac == r.songs ? "All" : r.onMac == 0 ? "iCloud" : "\(r.onMac) of \(r.songs)").foregroundStyle(.secondary)
            }
            .width(64)
        }
        .contextMenu(forSelectionType: AMAlbum.ID.self) { ids in
            let picked = albums.filter { ids.contains($0.id) }
            if picked.count == 1 { AMMenu(album: picked[0]).environmentObject(model) }
            else if picked.count > 1 {
                let todo = picked.filter { !model.inLibrary($0) }
                Button("Import \(todo.count) Albums to Library", systemImage: "square.and.arrow.down") { todo.forEach { model.importAppleMusic($0, toIPod: false) } }
                    .disabled(todo.isEmpty)
                Button("Import and Add to iPod", pod: model.ipod?.glyph) { todo.forEach { model.importAppleMusic($0, toIPod: true) } }
                    .disabled(todo.isEmpty || model.ipod == nil)
            }
        } primaryAction: { ids in
            if let a = albums.first(where: { ids.contains($0.id) }) { model.path.append(.amAlbum(a)) }
        }
    }
}

struct AMCoverFlow: View {
    @EnvironmentObject var model: Model
    var albums: [AMAlbum]
    @StateObject private var flow = FlowState()
    @FocusState private var focused: Bool

    var body: some View {
        let i = min(flow.index, max(albums.count - 1, 0))
        let current = albums.indices.contains(i) ? albums[i] : nil
        GeometryReader { g in
            VStack(spacing: 10) {
                CoverFlow(count: albums.count, flow: flow, art: { n in
                    CachedImage(url: model.amArt[albums[n].id], seed: albums[n].id).task(id: albums[n].id) { await model.loadAMArt(albums[n]) }
                }) {
                    model.path.append(.amAlbum(albums[$0]))
                }
                .frame(height: max(280, g.size.height * 0.6))
                .background {
                    if let a = current {
                        CachedImage(url: model.amArt[a.id], seed: a.id)
                            .frame(width: 420, height: 260).blur(radius: 110).opacity(0.32)
                            .id(a.id).transition(.opacity).animation(.easeInOut(duration: 0.5), value: a.id)
                            .allowsHitTesting(false)
                    }
                }
                if let a = current {
                    VStack(spacing: 3) {
                        Text(a.title).font(.title3.bold()).lineLimit(1)
                        Text(a.artist + (a.year > 0 ? " · \(a.year)" : "") + " · \(a.tracks.count) song\(a.tracks.count == 1 ? "" : "s")").foregroundStyle(.secondary).lineLimit(1)
                        Scrubber(count: albums.count, index: i) { flow.go(to: $0, count: albums.count) }
                            .frame(width: 260).padding(.top, 6)
                        HStack(spacing: 10) {
                            Button("Open", systemImage: "chevron.right") { model.path.append(.amAlbum(a)) }.buttonStyle(.glass)
                            AMImportButtons(album: a)
                        }
                        .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { flow.step(-1, count: albums.count); return .handled }
        .onKeyPress(.rightArrow) { flow.step(1, count: albums.count); return .handled }
        .onKeyPress(.return) { if let a = current { model.path.append(.amAlbum(a)) }; return .handled }
        .onChange(of: albums.map(\.id)) { flow.go(to: min(flow.index, max(albums.count - 1, 0)), count: albums.count) }
    }
}
