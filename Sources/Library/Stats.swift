import SwiftUI
import Charts

// What the iPod knows about listening (plays, ratings, last played, merged from its Play Counts
// on every sync), smart playlists built from that and the library, and a year in review.

struct PodStat: Hashable { var rating = 0, plays = 0, skips = 0; var lastPlayed, lastSkipped: Date? }
/// Skips recorded by Frogger on the iPod, summed over syncs (the 2.3 iTunesDB has no skip count).
struct PodSkip: Codable, Hashable { var count = 0; var last: Date? }

extension PodSkips {
    /// `skips` with the iPod's added: counts summed, the later last skip kept.
    static func add(_ entries: [(String, Entry)], to skips: [String: PodSkip]) -> [String: PodSkip] {
        var s = skips
        for (key, e) in entries {
            s[key, default: PodSkip()].count += e.count
            if let t = e.last, t > s[key]?.last ?? .distantPast { s[key]?.last = t }
        }
        return s
    }
}

extension PodTrack {
    private func u32(_ o: Int) -> Int {
        guard let r = raw, r.count >= o + 4 else { return 0 }
        let b = r.startIndex + o
        return Int(r[b]) | Int(r[b + 1]) << 8 | Int(r[b + 2]) << 16 | Int(r[b + 3]) << 24
    }
    /// Stars 0–5 (the database keeps 0–100).
    var stars: Int { guard let r = raw, r.count > 0x1F else { return 0 }; return Int(r[r.startIndex + 0x1F]) / 20 }
    var plays: Int { u32(0x50) }
    var lastPlayed: Date? { let v = u32(0x58); return v > 0 ? Date(timeIntervalSince1970: Double(v - 2_082_844_800)) : nil }
    var stat: PodStat { PodStat(rating: stars, plays: plays, lastPlayed: lastPlayed) }
}

// MARK: smart playlists

struct SmartRule: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable {
        case artist = "Artist", album = "Album", genre = "Genre", year = "Year", added = "Added", rating = "Rating"
        case plays = "Plays", lastPlayed = "Last played", format = "Format", onIPod = "On the iPod", skips = "Skips"
        var numeric: Bool { [.year, .rating, .plays, .skips].contains(self) }
        var days: Bool { self == .added || self == .lastPlayed }
        var ops: [Op] {
            if numeric { return [.atLeast, .atMost, .is] }
            if days { return [.withinDays, .notWithinDays] }
            if self == .onIPod { return [.yes, .no] }
            return [.contains, .is, .isNot]
        }
    }
    enum Op: String, Codable, CaseIterable {
        case contains = "contains", `is` = "is", isNot = "is not", atLeast = "is at least", atMost = "is at most"
        case withinDays = "in the last (days)", notWithinDays = "not in the last (days)", yes = "yes", no = "no"
    }
    var id = UUID()
    var field = Field.genre
    var op = Op.contains
    var value = ""
}

struct SmartPlaylist: Codable, Hashable, Identifiable {
    enum Order: String, Codable, CaseIterable { case random = "Random", mostPlayed = "Most played", recent = "Recently added", artist = "Artist", rating = "Rating" }
    var id = UUID()
    var name = "Smart Playlist"
    var rules: [SmartRule] = [SmartRule()]
    var matchAll = true
    var limit = 0                 // songs, 0 = no limit
    var order = Order.random
    var onIPod = false
}

extension SmartPlaylist {
    /// Ready-made smart playlists, plus one for each of the library's biggest genres.
    static func suggestions(genres: [String]) -> [SmartPlaylist] {
        func r(_ f: SmartRule.Field, _ o: SmartRule.Op, _ v: String = "") -> SmartRule { SmartRule(field: f, op: o, value: v) }
        var out = [
            SmartPlaylist(name: "Recently Added", rules: [r(.added, .withinDays, "30")], limit: 0, order: .recent),
            SmartPlaylist(name: "Most Played", rules: [r(.plays, .atLeast, "3")], limit: 100, order: .mostPlayed),
            SmartPlaylist(name: "Top Rated", rules: [r(.rating, .atLeast, "4")], order: .rating),
            SmartPlaylist(name: "Forgotten Favourites", rules: [r(.plays, .atLeast, "5"), r(.lastPlayed, .notWithinDays, "180")], limit: 100, order: .random),
            SmartPlaylist(name: "Skipped a Lot", rules: [r(.skips, .atLeast, "3")], limit: 100, order: .random),
            SmartPlaylist(name: "Not Played Yet", rules: [r(.onIPod, .yes), r(.plays, .atMost, "0")], limit: 100, order: .random),
            SmartPlaylist(name: "Something New for the iPod", rules: [r(.onIPod, .no)], limit: 50, order: .random),
            SmartPlaylist(name: "Lossless", rules: [r(.format, .is, "flac")], order: .artist),
            SmartPlaylist(name: "The 90s", rules: [r(.year, .atLeast, "1990"), r(.year, .atMost, "1999")], order: .random),
            SmartPlaylist(name: "The 2000s", rules: [r(.year, .atLeast, "2000"), r(.year, .atMost, "2009")], order: .random),
        ]
        out += genres.prefix(4).map { g in SmartPlaylist(name: g, rules: [r(.genre, .contains, g)], limit: 100, order: .random) }
        return out
    }
}

extension Model {
    /// The library's most common genres ("Electronic, Idm" counts for both).
    var topGenres: [String] {
        if let g = genreCache { return g }
        let all = libTracks.flatMap { t in t.genre.split(whereSeparator: { ",;/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces).capitalized } }
            .filter { !$0.isEmpty }
        let g = Dictionary(grouping: all) { $0 }.sorted { $0.value.count > $1.value.count }.map(\.key)
        genreCache = g
        return g
    }
}

enum SmartStore {
    static var url: URL { PodCache.dir.appendingPathComponent("smart-playlists.json") }
    static func load() -> [SmartPlaylist] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SmartPlaylist].self, from: $0) } ?? [] }
    static func save(_ s: [SmartPlaylist]) { try? JSONEncoder().encode(s).write(to: url) }
}

extension Model {
    func stat(_ t: LibTrack) -> PodStat {
        let k = podKey(t.key)
        var s = podStats[k] ?? PodStat()
        if let sk = skips[k] { s.skips = sk.count; s.lastSkipped = sk.last }
        return s
    }

    func matches(_ r: SmartRule, _ t: LibTrack) -> Bool {
        let s = stat(t), v = r.value.trimmingCharacters(in: .whitespaces), n = Int(v) ?? 0
        func text(_ x: String) -> Bool {
            switch r.op {
            case .is: return x.localizedCaseInsensitiveCompare(v) == .orderedSame
            case .isNot: return x.localizedCaseInsensitiveCompare(v) != .orderedSame
            default: return v.isEmpty || x.localizedCaseInsensitiveContains(v)
            }
        }
        func num(_ x: Int) -> Bool { r.op == .atLeast ? x >= n : r.op == .atMost ? x <= n : x == n }
        func days(_ d: Date?) -> Bool {
            let inside = d.map { Date().timeIntervalSince($0) <= Double(n) * 86400 } ?? false
            return r.op == .withinDays ? inside : !inside
        }
        switch r.field {
        case .artist: return text(t.trackArtist.isEmpty ? t.artist : t.trackArtist) || (r.op != .isNot && text(t.artist))
        case .album: return text(t.album)
        case .genre: return text(t.genre.isEmpty ? (metadata[t.album.lowercased()]?.genre ?? "") : t.genre)
        case .year: return num(t.year > 0 ? t.year : (metadata[t.album.lowercased()]?.year ?? 0))
        case .added: return days(t.added)
        case .rating: return num(rating(t))
        case .plays: return num(s.plays)
        case .skips: return num(s.skips)
        case .lastPlayed: return days(s.lastPlayed)
        case .format: return text(t.ext)
        case .onIPod: return (podKeys.contains(t.key)) == (r.op == .yes)
        }
    }

    /// The songs a smart playlist holds right now (random order is stable per playlist).
    func evaluate(_ p: SmartPlaylist) -> [LibTrack] {
        var ts = libTracks.filter { t in
            p.rules.isEmpty || (p.matchAll ? p.rules.allSatisfy { matches($0, t) } : p.rules.contains { matches($0, t) })
        }
        switch p.order {
        case .random:
            var seed = UInt64(truncatingIfNeeded: p.id.hashValue) | 1
            ts = ts.map { t -> (UInt64, LibTrack) in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return (seed ^ UInt64(truncatingIfNeeded: t.path.hashValue), t)
            }.sorted { $0.0 < $1.0 }.map(\.1)
        case .mostPlayed: ts.sort { stat($0).plays > stat($1).plays }
        case .recent: ts.sort { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .artist: ts.sort { ($0.artist.lowercased(), $0.album.lowercased(), $0.discNumber, $0.trackNumber) < ($1.artist.lowercased(), $1.album.lowercased(), $1.discNumber, $1.trackNumber) }
        case .rating: ts.sort { rating($0) > rating($1) }
        }
        return p.limit > 0 ? Array(ts.prefix(p.limit)) : ts
    }

    /// Smart playlists set to go to the iPod whose songs or playlist aren't there yet.
    func smartNeedsSync(_ p: SmartPlaylist) -> Bool {
        guard p.onIPod, db != nil else { return false }
        let ts = evaluate(p), keys = podKeys
        guard let pod = db?.playlists.first(where: { samePlaylist($0.name, p.name) }) else { return !ts.isEmpty }
        let byID = Dictionary((db?.tracks ?? []).map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        return ts.contains { !keys.contains($0.key) } || pod.items.compactMap { byID[$0.trackID] } != ts.map(\.key)
    }

    func saveSmart() { SmartStore.save(smartPlaylists); refreshSmartPending() }
    func refreshSmartPending() {
        smartNeedingSync = Set(smartPlaylists.filter(smartNeedsSync).map(\.id))
        smartPending = smartNeedingSync.count
    }
}

struct SmartPlaylistView: View {
    @EnvironmentObject var model: Model
    var id: UUID

    var body: some View {
        if let i = model.smartPlaylists.firstIndex(where: { $0.id == id }) {
            let p = model.smartPlaylists[i]
            let ts = model.evaluate(p), keys = model.podKeys
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: 22) {
                        Image(systemName: "gearshape.2").font(.system(size: 60, weight: .light)).foregroundStyle(.tint)
                            .frame(width: 170, height: 170).glassEffect(.regular.tint(.accentColor.opacity(0.3)), in: .rect(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Smart Playlist").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(p.name).font(.largeTitle.bold())
                            Text(summary(p)).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(ts.count) songs · \(totalDuration(ts.map(\.lengthMs).reduce(0, +))) · \(ts.filter { keys.contains($0.key) }.count) on the iPod")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Toggle("Keep on the iPod", isOn: Binding(get: { p.onIPod }, set: { model.smartPlaylists[i].onIPod = $0; model.saveSmart() }))
                                    .toggleStyle(.switch)
                                Button("Edit Rules…", systemImage: "slider.horizontal.3") { model.editSmart = p }.buttonStyle(.glass)
                                Button("Play", systemImage: "play.fill") { model.player.play(ts) }.buttonStyle(.glass).disabled(ts.isEmpty)
                            }
                            .padding(.top, 6)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(ts.prefix(500).enumerated()), id: \.element.id) { n, t in
                            HStack(spacing: 12) {
                                Text("\(n + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).lineLimit(1)
                                    Text("\(t.trackArtist.isEmpty ? t.artist : t.trackArtist) — \(t.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Stars(value: model.stat(t).rating)
                                if model.stat(t).plays > 0 { Text("\(model.stat(t).plays)×").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                                if keys.contains(t.key) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(n % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { model.player.play(ts, from: n) }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
                .padding(28).padding(.bottom, 60)
            }
            .pageTitle(p.name)
            .contextMenu { Button("Delete Smart Playlist", role: .destructive) { model.deleteSmart(p) } }
        } else {
            ContentUnavailableView("Smart playlist not found", systemImage: "gearshape.2")
        }
    }

    func summary(_ p: SmartPlaylist) -> String {
        let rules = p.rules.map { "\($0.field.rawValue) \($0.op.rawValue) \($0.value)".trimmingCharacters(in: .whitespaces) }
        return (rules.isEmpty ? "All songs" : rules.joined(separator: p.matchAll ? " and " : " or "))
            + (p.limit > 0 ? ", \(p.limit) songs" : "") + ", " + p.order.rawValue.lowercased()
    }
}

struct Stars: View {
    var value: Int
    var body: some View {
        if value > 0 {
            HStack(spacing: 1) { ForEach(0..<value, id: \.self) { _ in Image(systemName: "star.fill") } }
                .font(.system(size: 9)).foregroundStyle(.secondary).help("\(value) stars on the iPod")
        }
    }
}

@MainActor
final class SmartEditorState: ObservableObject { @Published var p = SmartPlaylist() }

struct SmartEditor: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var playlist: SmartPlaylist
    @StateObject private var s = SmartEditorState()

    var body: some View {
        let count = model.evaluate(s.p).count
        VStack(alignment: .leading, spacing: 14) {
            Text(model.smartPlaylists.contains { $0.id == playlist.id } ? "Edit Smart Playlist" : "New Smart Playlist").font(.title2.bold())
            TextField("Name", text: $s.p.name).textFieldStyle(.roundedBorder).font(.title3)
            HStack {
                Picker("Match", selection: $s.p.matchAll) { Text("all").tag(true); Text("any").tag(false) }.fixedSize()
                Text("of these rules").foregroundStyle(.secondary)
                Spacer()
                Button { s.p.rules.append(SmartRule()) } label: { Label("Add Rule", systemImage: "plus") }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($s.p.rules) { $r in
                        HStack(spacing: 8) {
                            Picker("", selection: $r.field) { ForEach(SmartRule.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 130)
                                .onChange(of: r.field) { if !r.field.ops.contains(r.op) { r.op = r.field.ops[0] } }
                            Picker("", selection: $r.op) { ForEach(r.field.ops, id: \.self) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 180)
                            if r.field != .onIPod {
                                TextField(r.field.numeric || r.field.days ? "number" : "text", text: $r.value).textFieldStyle(.roundedBorder)
                            } else { Spacer() }
                            Button { s.p.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                Picker("Order", selection: $s.p.order) { ForEach(SmartPlaylist.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize()
                Picker("Limit", selection: $s.p.limit) {
                    Text("No limit").tag(0); ForEach([25, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) songs").tag($0) }
                }
                .fixedSize()
                Toggle("Keep on the iPod", isOn: $s.p.onIPod)
            }
            Text("Rating, Plays, Skips and Last played come from the iPod (what you played and rated on it, saved on every sync).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(count) songs match").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = model.smartPlaylists.firstIndex(where: { $0.id == s.p.id }) { model.smartPlaylists[i] = s.p }
                    else { model.smartPlaylists.append(s.p) }
                    model.saveSmart()
                    model.search = ""; model.pane = .smart(s.p.id)
                    dismiss()
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(s.p.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640, height: 480)
        .onAppear { s.p = playlist }
    }
}

// MARK: most played (iPod page)

struct MostPlayed: View {
    @EnvironmentObject var model: Model
    var body: some View {
        let tracks = (model.db?.tracks ?? []).filter { $0.plays > 0 }.sorted { $0.plays > $1.plays }
        let recent = (model.db?.tracks ?? []).filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Listening on the iPod").font(.title2.bold())
                HStack(alignment: .top, spacing: 16) {
                    list("Most Played", tracks.prefix(10).map { ($0, "\($0.plays)×") })
                    list("Recently Played", recent.prefix(10).map { ($0, $0.lastPlayed!.formatted(.relative(presentation: .named))) })
                }
            }
        }
    }

    func list(_ title: String, _ rows: [(PodTrack, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(12)
            ForEach(Array(rows.enumerated()), id: \.offset) { n, r in
                HStack(spacing: 10) {
                    Text("\(n + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.0.title).lineLimit(1)
                        Text(r.0.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    StarPicker(value: model.rating(r.0)) { model.rate(r.0, $0) }
                    Text(r.1).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: year in review

@MainActor
final class ReviewUI: ObservableObject { @Published var year = Calendar.current.component(.year, from: Date()) }

struct YearInReview: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = ReviewUI()

    var body: some View {
        let cal = Calendar.current
        let years = Set(model.albums.compactMap { $0.added.map { cal.component(.year, from: $0) } }).sorted(by: >)
        let added = model.albums.filter { $0.added.map { cal.component(.year, from: $0) } == ui.year }
        let tracks = added.flatMap(\.tracks)
        let artists = Dictionary(grouping: added, by: \.artist).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let genres = Dictionary(grouping: tracks.flatMap { t in      // "Electronic, Idm" counts for both
            t.genre.split(whereSeparator: { ",;/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces).capitalized }.filter { !$0.isEmpty }
        }) { $0 }.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let months = (1...12).map { m in (m, added.filter { cal.component(.month, from: $0.added!) == m }.count) }
        let played = (model.db?.tracks ?? []).filter { $0.lastPlayed.map { cal.component(.year, from: $0) } == ui.year }
            .sorted { $0.plays > $1.plays }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your \(String(ui.year))").font(.system(size: 40, weight: .bold))
                    Spacer()
                    Menu {
                        Picker("Year", selection: $ui.year) { ForEach(years.isEmpty ? [ui.year] : years, id: \.self) { Text(String($0)).tag($0) } }
                            .pickerStyle(.inline)
                    } label: { Text(String(ui.year)) }
                    .glassMenu()
                }
                HStack(spacing: 14) {
                    Stat(value: "\(added.count)", label: "albums added")
                    Stat(value: "\(tracks.count)", label: "songs")
                    Stat(value: totalDuration(tracks.map(\.lengthMs).reduce(0, +)), label: "of new music")
                    Stat(value: "\(Set(added.map(\.artist)).count)", label: "artists")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Albums added per month").font(.title3.bold())
                    Chart(months, id: \.0) { m in
                        BarMark(x: .value("Month", cal.shortMonthSymbols[m.0 - 1]), y: .value("Albums", m.1))
                            .foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                    }
                    .frame(height: 180)
                }
                .padding(16).glassEffect(.regular, in: .rect(cornerRadius: 18))
                HStack(alignment: .top, spacing: 16) {
                    ranking("Top artists", artists.prefix(8).map { ($0.0, "\($0.1) album\($0.1 == 1 ? "" : "s")") })
                    ranking("Top genres", genres.prefix(8).map { ($0.0, "\($0.1) songs") })
                }
                if !played.isEmpty {
                    ranking("Most played on the iPod", played.prefix(10).map { ("\($0.title) – \($0.artist)", "\($0.plays)×") })
                }
                if !added.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Added in \(String(ui.year))").font(.title3.bold())
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 16) {
                                ForEach(added.sorted { $0.added! > $1.added! }) { a in
                                    AlbumTile(album: a).frame(width: 140).albumLink(a)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(28).padding(.bottom, 60)
        }
        .pageTitle("Year in Review")
    }

    func ranking(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(12)
            ForEach(Array(rows.enumerated()), id: \.offset) { n, r in
                HStack {
                    Text("\(n + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                    Text(r.0).lineLimit(1)
                    Spacer()
                    Text(r.1).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
