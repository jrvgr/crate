import SwiftUI

// Library health: albums with no cover, no year or genre, odd track numbers, the same song twice,
// low bit rate MP3s or missing files, each with a way to fix it; and Find Metadata for many
// albums at once, reviewed before anything is written.

enum Issue: String, CaseIterable, Identifiable {
    case noCover = "No cover", noYear = "No year", noGenre = "No genre", numbering = "Track numbers"
    case incomplete = "Missing songs", duplicates = "Duplicates", lowQuality = "Low bit rate", missing = "Missing files"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .noCover: return "photo"
        case .noYear: return "calendar"
        case .noGenre: return "guitars"
        case .numbering: return "number"
        case .incomplete: return "rectangle.badge.minus"
        case .duplicates: return "square.on.square"
        case .lowQuality: return "waveform.badge.minus"
        case .missing: return "questionmark.folder"
        }
    }
    /// Issues Find Metadata can fix.
    var metadata: Bool { self == .noCover || self == .noYear || self == .noGenre }
}

extension Model {
    /// `sizes`: each song's file size, nil when the file is gone (probed off the main thread).
    func issues(_ a: Album, sizes: [String: Int?]) -> [Issue] {
        var out: [Issue] = []
        if artwork[a.id] == nil { out.append(.noCover) }
        if a.year == 0 && (metadata[a.id]?.year ?? 0) == 0 { out.append(.noYear) }
        if a.genre.isEmpty && (metadata[a.id]?.genre ?? "").isEmpty { out.append(.noGenre) }
        let nums = a.tracks.map { $0.discNumber * 1000 + $0.trackNumber }
        if a.tracks.count > 1, a.tracks.contains(where: { $0.trackNumber == 0 }) || Set(nums).count < nums.count { out.append(.numbering) }
        if expectedSongs(a) != nil { out.append(.incomplete) }
        let titles = a.tracks.map { $0.title.lowercased().filter { $0.isLetter || $0.isNumber } }
        if Set(titles).count < titles.count, Set(a.tracks.map(\.discNumber)).count <= 1 { out.append(.duplicates) }
        let kbps = { (t: LibTrack) in ((sizes[t.path] ?? nil) ?? 0) * 8 / max(t.lengthMs, 1) }
        if a.tracks.contains(where: { $0.ext == "mp3" && $0.lengthMs > 0 && (1..<160).contains(kbps($0)) }) { out.append(.lowQuality) }
        // server songs not on the share live in the download cache until a sync needs them: not missing
        let cache = Subsonic.cache.path
        if a.tracks.contains(where: { !$0.path.hasPrefix(cache) && (sizes[$0.path].map { $0 == nil } ?? false) }) { out.append(.missing) }
        return out
    }

    /// Library albums with at least one issue (albums only on the iPod aren't checked).
    func unhealthy(sizes: [String: Int?]) -> [(Album, [Issue])] {
        guard !loading else { return [] }
        return albums.compactMap { a in let i = issues(a, sizes: sizes); return i.isEmpty ? nil : (a, i) }
    }

    /// Size of each file (nil when missing), read in the background: the files are on shares, and
    /// a stat each on the main thread froze the window.
    nonisolated static func probe(_ paths: [String]) async -> [String: Int?] {
        await Task.detached {
            Dictionary(paths.map { p in (p, (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int) }, uniquingKeysWith: { a, _ in a })
        }.value
    }
}

@MainActor
final class HealthUI: ObservableObject {
    @Published var filter: Issue?
    @Published var cache: [(Album, [Issue])] = []
    @Published var checked = false                    // the first pass is done: until then empty means "don't know yet"
    var sizes: [String: Int?] = [:]                   // file probes so far
    @Published var dedupe = false
    @Published var genres = false
}

struct HealthView: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = HealthUI()

    var body: some View {
        let all = ui.cache
        let shown = all.filter { ui.filter == nil || $0.1.contains(ui.filter!) }
        let fixable = shown.filter { $0.1.contains(where: \.metadata) }.map(\.0)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !all.isEmpty {        // nothing to filter: no "All 0"
                    HStack(spacing: 8) {
                        Chip(title: "All", count: all.count, on: ui.filter == nil) { ui.filter = nil }
                        ForEach(Issue.allCases) { i in
                            let n = all.filter { $0.1.contains(i) }.count
                            if n > 0 { Chip(title: i.rawValue, icon: i.icon, count: n, on: ui.filter == i) { ui.filter = i } }
                        }
                    }
                }
                if all.isEmpty && (model.loading || !ui.checked) {
                    ProgressView("Checking the library…").frame(maxWidth: .infinity).padding(.top, 60)
                } else if all.isEmpty {
                    // "every album", not "everything": duplicates and genre spellings can still be listed below
                    ContentUnavailableView("Every album looks good", systemImage: "checkmark.seal",
                                           description: Text("Every album has a cover, year, genre and tidy track numbers.")).padding(.top, 60)
                }
                if !fixable.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkle.magnifyingglass").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find metadata for \(fixable.count) album\(fixable.count == 1 ? "" : "s")").font(.headline)
                            Text("Looks each one up on MusicBrainz and iTunes; you check the matches before anything is written.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review Matches…") { model.batchAlbums = fixable }.buttonStyle(.glassProminent)
                    }
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
                if !model.loading, !model.libTracks.isEmpty, ui.filter == nil || ui.filter == .duplicates {
                    HStack(spacing: 12) {
                        Image(systemName: "square.on.square").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find duplicate songs").font(.headline)
                            Text("The same song in more than one file, across all albums; the best copy stays, you check the rest before they go to the Trash.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review Duplicates…") { ui.dedupe = true }.buttonStyle(.glass)
                    }
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
                let genreGroups = model.loading || ui.filter != nil ? [] : model.genreGroups
                if !genreGroups.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "guitars").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Merge \(genreGroups.count) genre spelling\(genreGroups.count == 1 ? "" : "s")").font(.headline)
                            Text(genreGroups.prefix(3).map { $0.variants.map(\.name).joined(separator: " / ") }.joined(separator: ", ")
                                 + (genreGroups.count > 3 ? "…" : ""))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Review Genres…") { ui.genres = true }.buttonStyle(.glass)
                    }
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
                LazyVStack(spacing: 8) {
                    ForEach(shown, id: \.0.id) { a, issues in
                        HStack(spacing: 12) {
                            Cover(image: model.artwork[a.id], seed: a.id).frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.title).font(.headline).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(a.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    ForEach(issues) { i in
                                        Label(i.rawValue, systemImage: i.icon).font(.caption).foregroundStyle(.orange)
                                            .padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.12), in: .capsule)
                                    }
                                }
                            }
                            Spacer()
                            if issues.contains(.incomplete), model.on(.soulseek), let full = model.expectedSongs(a) {
                                Button("Complete", systemImage: "arrow.down.circle") { model.findOnSoulseek(a.artist, a.title, songs: full) }.buttonStyle(.glass)
                                    .help("Search Soulseek for a copy with all \(full) songs")
                            }
                            if issues.contains(where: \.metadata) {
                                Button("Find Metadata", systemImage: "sparkle.magnifyingglass") { model.lookupAlbum = a }.buttonStyle(.glass)
                                    .help("Look the album up on MusicBrainz and iTunes")
                            }
                            Button("Edit Tags", systemImage: "pencil") { model.editAlbum = a }.buttonStyle(.glass).help("Edit the album's tags by hand")
                            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: a.folder) } label: { Image(systemName: "folder") }
                                .buttonStyle(.glass).help("Show in Finder")
                        }
                        .padding(10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { model.path.append(.album(a)) }
                    }
                }
            }
            .padding(24).padding(.bottom, 60)
        }
        .sheet(isPresented: $ui.dedupe) { DedupeSheet() }
        .sheet(isPresented: $ui.genres) { GenreMergeSheet().environmentObject(model) }
        .navigationTitle("Needs Attention")
        .navigationSubtitle("\(all.count) album\(all.count == 1 ? "" : "s")")
        .task(id: "\(model.albums.count)-\(model.artwork.count)-\(model.metadata.count)-\(model.loading)") {
            let paths = model.albums.flatMap { $0.tracks.map(\.path) }.filter { ui.sizes[$0] == nil }
            if !paths.isEmpty { ui.sizes.merge(await Model.probe(paths)) { _, new in new } }
            ui.cache = model.unhealthy(sizes: ui.sizes)
            if !model.loading { ui.checked = true }
        }
    }
}

struct Chip: View {
    var title: String
    var icon: String?
    var count: Int
    var on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
                Text("\(count)").foregroundStyle(on ? .white.opacity(0.8) : .secondary)
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(on ? .white : .primary)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.accentColor) : .regular, in: .capsule)
    }
}

// MARK: batch metadata

@MainActor
final class BatchState: ObservableObject {
    struct Row: Identifiable {
        var id: Album.ID { album.id }
        var album: Album
        var candidates: [MBRelease] = []
        var choice = 0
        var include = true
        var state = "Waiting"
        var chosen: MBRelease? { candidates.indices.contains(choice) ? candidates[choice] : nil }
    }
    @Published var rows: [Row] = []
    @Published var searching = false
    @Published var applying = false
    @Published var done = 0
    @Published var replaceCovers = false

    func search() async {
        searching = true; defer { searching = false }
        for i in rows.indices {
            guard !Task.isCancelled else { return }
            let a = rows[i].album
            rows[i].state = "Searching…"
            async let it = (try? ITunesLookup.search(album: a.title, artist: a.artist)) ?? []
            async let mb = (try? MusicBrainz.search(album: a.title, artist: a.artist)) ?? []
            let all = await it + mb
            let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
            // same title first, then the same number of songs, iTunes before MusicBrainz (it has the cover right away)
            rows[i].candidates = all.sorted { x, y in
                let kx = (loose(x.title) == loose(a.title) ? 1 : 0, x.trackCount == a.tracks.count ? 1 : 0, x.source == "iTunes" ? 1 : 0, x.score)
                let ky = (loose(y.title) == loose(a.title) ? 1 : 0, y.trackCount == a.tracks.count ? 1 : 0, y.source == "iTunes" ? 1 : 0, y.score)
                return kx > ky
            }
            rows[i].state = rows[i].candidates.isEmpty ? "No match" : ""
            rows[i].include = !rows[i].candidates.isEmpty && loose(rows[i].candidates[0].title) == loose(a.title)
            try? await Task.sleep(for: .seconds(1.1))     // MusicBrainz allows one request a second
        }
    }

    func apply(_ model: Model) async {
        applying = true; done = 0
        for i in rows.indices where rows[i].include {
            guard let r = rows[i].chosen else { continue }
            rows[i].state = "Saving…"
            rows[i].state = await model.apply(r, to: rows[i].album, replaceCover: replaceCovers) { _ in }
            done += 1
        }
        applying = false
    }
}

struct BatchMetadataSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var albums: [Album]
    @StateObject private var s = BatchState()

    var body: some View {
        let picked = s.rows.filter { $0.include && $0.chosen != nil }.count
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Metadata").font(.title2.bold())
                Text(s.searching ? "Looking up \(s.rows.filter { !$0.candidates.isEmpty || $0.state == "No match" }.count + 1) of \(s.rows.count)…"
                     : s.applying ? "Saving \(s.done) of \(picked)…" : "\(picked) of \(s.rows.count) albums will be updated")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($s.rows) { $r in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $r.include).labelsHidden().disabled(r.chosen == nil || s.applying)
                            Cover(image: model.artwork[r.album.id], seed: r.album.id).frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6, style: .continuous))
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            CachedImage(url: r.chosen.map { MusicBrainz.coverURL($0, size: 250) }, seed: "Health.swift:2")
                                .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.album.title).font(.headline).lineLimit(1)
                                if let c = r.chosen {
                                    Text([c.source, c.title == r.album.title ? "" : "“\(c.title)”", c.date, c.genre,
                                          c.trackCount > 0 ? "\(c.trackCount) songs" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Text(r.state).font(.caption).foregroundStyle(.secondary)
                                }
                                if r.chosen != nil, !r.state.isEmpty { Text(r.state).font(.caption).foregroundStyle(.green).lineLimit(1) }
                            }
                            Spacer()
                            if r.candidates.count > 1 {
                                Picker("", selection: $r.choice) {
                                    ForEach(Array(r.candidates.enumerated()), id: \.offset) { i, c in
                                        Text("\(c.source): \(c.title) \(c.date.prefix(4))").tag(i)
                                    }
                                }
                                .labelsHidden().frame(width: 170).disabled(s.applying)
                            }
                        }
                        .padding(8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    }
                }
            }
            HStack {
                Toggle("Replace existing covers", isOn: $s.replaceCovers).toggleStyle(.checkbox)
                if s.searching || s.applying { ProgressView().controlSize(.small) }
                Spacer()
                Button(s.done > 0 && !s.applying ? "Done" : "Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save \(picked)") { Task { await s.apply(model) } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(picked == 0 || s.searching || s.applying || s.done > 0)
            }
        }
        .padding(22)
        .frame(width: 720, height: 600)
        .interactiveDismissDisabled(s.applying)
        .task {
            s.rows = albums.map { BatchState.Row(album: $0) }
            await s.search()
        }
    }
}
