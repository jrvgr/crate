import SwiftUI
import Charts

// Recently Added, the iPod's own page with its settings, and the song list.

struct BigNumber: View {
    var value: Int
    var label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Albums by when they arrived in the library, newest first, in groups by month.
struct RecentView: View {
    @EnvironmentObject var model: Model
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22)]

    var body: some View {
        let albums = Array(model.recentlyAdded.prefix(300))
        let cal = Calendar.current
        let groups = Dictionary(grouping: albums) { cal.dateInterval(of: .month, for: $0.added!)!.start }
            .sorted { $0.key > $1.key }
        ScrollView {
            if albums.isEmpty {
                ContentUnavailableView(model.loading ? "Loading library…" : "Nothing added yet", systemImage: "clock",
                                       description: Text("Albums show up here as they arrive in the library."))
                    .padding(.top, 120)
            }
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(groups, id: \.key) { month, list in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(title(month)).font(.title2.bold())
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(Self.items(list)) { item in
                                switch item {
                                case .album(let a):
                                    NavigationLink(value: Route.album(a)) { AlbumTile(album: a) }
                                        .buttonStyle(.plain)
                                        .contextMenu { AlbumMenu(album: a) }
                                case .singles(let artist, let singles):
                                    NavigationLink(value: Route.artist(artist)) { SinglesTile(artist: artist, albums: singles) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24).padding(.bottom, 80)
        }
        .navigationTitle("Recently Added")
    }

    enum Item: Identifiable {
        case album(Album), singles(String, [Album])
        var id: String { switch self { case .album(let a): a.id; case .singles(let n, _): "singles:" + n } }
    }

    /// A month's albums, with an artist's singles (three songs or fewer) folded into one stack when
    /// there are three or more of them, where the first of them came in.
    static func items(_ list: [Album]) -> [Item] {
        let isSingle = { (a: Album) in a.tracks.count <= 3 }
        let counts = Dictionary(grouping: list.filter(isSingle)) { $0.artist.lowercased() }.mapValues(\.count)
        var out: [Item] = [], placed: Set<String> = []
        for a in list {
            let k = a.artist.lowercased()
            guard isSingle(a), (counts[k] ?? 0) >= 3 else { out.append(.album(a)); continue }
            if placed.insert(k).inserted { out.append(.singles(a.artist, list.filter { isSingle($0) && $0.artist.lowercased() == k })) }
        }
        return out
    }

    func title(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, equalTo: Date(), toGranularity: .month) { return "This Month" }
        return d.formatted(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
    }
}

/// An artist's singles as one stack of covers; opens the artist.
struct SinglesTile: View {
    @EnvironmentObject var model: Model
    var artist: String
    var albums: [Album]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ForEach(Array(albums.prefix(3).enumerated().reversed()), id: \.offset) { i, a in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { Cover(image: model.artwork[a.id], seed: a.id) }
                        .clipShape(.rect(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .scaleEffect(1 - CGFloat(i) * 0.06)
                        .offset(y: CGFloat(i) * -9)
                        .brightness(Double(i) * -0.12)
                }
            }
            .padding(.top, 9)
            Text(artist).font(.headline).lineLimit(1)
            Text("\(albums.count) singles").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .help(albums.map(\.title).joined(separator: ", "))
    }
}

// MARK: iPod

@MainActor
final class IPodUI: ObservableObject {
    @Published var confirmRestore = false
    @Published var confirmOrphans = false
    @Published var checking = false
}

struct IPodView: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = IPodUI()

    var body: some View {
        if let i = model.ipod, let db = model.db {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(i, db)
                    DiskRepairCard()
                    capacity(i)
                    storageHistory
                    if model.pendingCount > 0 { pending }
                    if !model.podOnlyAlbums.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.podOnlyAlbums.count) album\(model.podOnlyAlbums.count == 1 ? " is" : "s are") only on the iPod").font(.headline)
                                Text(model.podOnlyAlbums.prefix(4).map(\.title).joined(separator: ", ") + (model.podOnlyAlbums.count > 4 ? "…" : ""))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Show") { model.albumFilter = .podOnly; model.pane = .albums }.buttonStyle(.glass)
                            Button("Copy to Library") { Task { await model.copyFromIPod(model.podOnlyAlbums) } }
                                .buttonStyle(.glassProminent).disabled(!model.connected)
                        }
                        .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 18))
                    }
                    MostPlayed()
                    settings
                    maintenance(i, db)
                }
                .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 90)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(model.podName)
            .confirmationDialog("Restore the previous database?", isPresented: $ui.confirmRestore) {
                Button("Restore", role: .destructive) { model.restoreBackup() }
            } message: {
                Text("Puts back the database from before Crate's last write to the iPod. Songs copied since then stay as files but leave the song list.")
            }
            .confirmationDialog("Delete \(model.orphans?.count ?? 0) stray files?", isPresented: $ui.confirmOrphans) {
                Button("Delete", role: .destructive) { model.deleteOrphans() }
            } message: {
                Text("These files are in iPod_Control/Music but not in the song list, so the iPod can't play them.")
            }
        } else {
            if model.brokenPod != nil || model.podRepairMessage != nil {
                DiskRepairCard().padding(28).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView { Label { Text("No iPod connected") } icon: { Image.pod(height: 44) } } description: { Text("Connect it over USB; it shows up here when it's mounted.") }
            }
        }
    }

    func header(_ i: IPodInfo, _ db: ITunesDB) -> some View {
        HStack(spacing: 22) {
            PodPicture(height: 220)
            VStack(alignment: .leading, spacing: 6) {
                Text(i.modelName).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(model.podName).font(.largeTitle.bold())
                if let e = model.podReadError {
                    Label("Crate can't read this iPod's song database (\(e)). It shows the last copy it read and won't sync until that's fixed: unplug and replug it, and if that doesn't help, run First Aid on it in Disk Utility.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !model.connected {
                    Label("Not connected · last seen \((model.lastSeen ?? Date()).formatted(.relative(presentation: .named))). Changes you queue sync \(model.podSettings.syncOnConnect ? "by themselves when it's plugged in" : "when you press Sync").",
                          systemImage: "powerplug").font(.callout).foregroundStyle(.orange)
                }
                Text([ByteCountFormatter.string(fromByteCount: i.capacity, countStyle: .file),
                      (try? i.mount.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?.volumeLocalizedFormatDescription ?? "",
                      i.firmware.isEmpty ? "" : "software \(i.firmware)", i.model, i.serial.isEmpty ? "" : "serial \(i.serial)"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 10) {
                    if model.connected {
                        // while it's away the toolbar's Sync (and Waiting for Sync below) review the queue
                        Button("Sync", systemImage: "arrow.triangle.2.circlepath") { model.reviewSync() }
                            .buttonStyle(.glassProminent).disabled(model.pendingCount == 0 || model.syncing || model.podRepairBusy || model.brokenPod != nil)
                        Button("Eject", systemImage: "eject") { model.eject() }.buttonStyle(.glass).disabled(model.syncing)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([i.mount]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.glass).help("Show in Finder")
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    func capacity(_ i: IPodInfo) -> some View {
        let db = model.db
        let other = max(0, i.used - model.musicBytes)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 22) {
                BigNumber(value: db?.tracks.count ?? 0, label: "songs")
                BigNumber(value: model.podAlbums.count, label: "albums")
                BigNumber(value: Set(model.podAlbums.map { $0.artist.lowercased() }).count, label: "artists")
                BigNumber(value: db?.playlists.count ?? 0, label: "playlists")
                VStack(alignment: .leading, spacing: 0) {
                    Text(totalDuration((db?.tracks ?? []).map(\.lengthMs).reduce(0, +))).font(.title.bold())
                    Text("of music").font(.caption).foregroundStyle(.secondary)
                }
            }
            CapacityBar(height: 14).opacity(model.connected ? 1 : 0.5)
            HStack(spacing: 16) {
                Legend(color: .accentColor, text: "Music", bytes: model.musicBytes)
                Legend(color: .orange, text: "Other", bytes: other)
                Legend(color: .secondary.opacity(0.3), text: "Free", bytes: i.free)
                Spacer()
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    var pending: some View {
        let p = model.makePlan()
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Waiting for Sync").font(.headline)
                Spacer()
                Button("Discard") { model.discardChanges() }.buttonStyle(.glass).controlSize(.small)
                Button("Review & Sync…") { model.reviewSync() }.buttonStyle(.glassProminent).controlSize(.small)
            }
            .padding(14)
            if p.addSongs > 0 { PlanRow(icon: "plus.circle.fill", tint: .accentColor, title: "\(p.addSongs) songs to add", detail: p.addAlbums.map(\.title).joined(separator: ", ")) }
            if p.removeSongs > 0 { PlanRow(icon: "minus.circle.fill", tint: .red, title: "\(p.removeSongs) songs to remove", detail: p.removeAlbums.map(\.title).joined(separator: ", ")) }
            if !(p.playlistsAdd + p.playlistsRemove + p.playlistsEdit).isEmpty {
                PlanRow(icon: "music.note.list", tint: .accentColor, title: "\(p.playlistsAdd.count + p.playlistsRemove.count + p.playlistsEdit.count) playlist changes",
                        detail: (p.playlistsAdd.map { "+ " + $0 } + p.playlistsRemove.map { "− " + $0 } + p.playlistsEdit.map { "~ " + $0 }).joined(separator: ", "))
            }
            if p.onTheGo > 0 { PlanRow(icon: "music.note.list", tint: .green, title: "\(p.onTheGo) playlist\(p.onTheGo == 1 ? "" : "s") from the iPod to save", detail: "") }
            if let n = p.rename { PlanRow(icon: "pencil.circle.fill", tint: .purple, title: "Rename to “\(n)”", detail: "") }
            if p.retag > 0 { PlanRow(icon: "pencil.circle.fill", tint: .purple, title: "Update the tags of \(p.retag) song\(p.retag == 1 ? "" : "s")", detail: "") }
            if !p.markPlaylists.isEmpty { PlanRow(icon: "eye.slash", tint: .secondary, title: "Rename \(p.markPlaylists.count) playlist\(p.markPlaylists.count == 1 ? "" : "s")", detail: "") }
            if p.hide + p.unhide > 0 { PlanRow(icon: "eye.slash", tint: .secondary, title: hideTitle(p), detail: "") }
        }
        .padding(.bottom, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    var settings: some View {
        let name = Binding<String>(get: { model.podName }, set: { v in model.pendingName = v == model.db?.name ? nil : v })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.title2.bold())
            SettingsCard {
                SettingRow(icon: "character.cursor.ibeam", title: "Name", detail: "Shown on the iPod's main menu; changes on the next Sync") {
                    TextField("", text: name).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            SettingsCard {
                SettingRow(icon: "waveform", title: "Convert lossless files to", detail: "FLAC, WAV and AIFF don't play on the iPod") {
                    Picker("", selection: $model.podSettings.aacKbps) {
                        ForEach([128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps AAC").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 50)
                SettingRow(icon: "arrow.down.right.and.arrow.up.left", title: "Shrink large MP3s",
                           detail: "Re-encode MP3s above a bit rate to save space") {
                    if model.podSettings.convertHighMP3 {
                        Picker("", selection: $model.podSettings.mp3Limit) {
                            ForEach([128, 160, 192, 256], id: \.self) { Text("above \($0) kbps").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Toggle("", isOn: $model.podSettings.convertHighMP3).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsCard {
                SettingRow(icon: "music.note.list", title: "Save On-The-Go lists", detail: "On-The-Go becomes an “On-The-Go N” playlist (playlists saved or changed on the iPod are always kept)") {
                    Toggle("", isOn: $model.podSettings.importOnTheGo).toggleStyle(.switch).labelsHidden()
                }
                if model.froggerFeatures {
                Divider().padding(.leading, 50)
                SettingRow(icon: "eye.slash", title: "Hidden playlists",
                           detail: "Right-click a playlist › Hide Its Songs from iPod Library. Songs only in those playlists stay out of Artists and Albums (needs Frogger on the iPod)") {
                    Picker("", selection: $model.podSettings.hideMarkAtEnd) {
                        Text("~Name").tag(false)
                        Text("Name ~").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
                }
                Divider().padding(.leading, 50)
                SettingRow(icon: "person.2", title: "File collaborations under the main artist",
                           detail: "“Ski Aggu, SEZA” and “UNKLE feat. Thom Yorke” show up under Ski Aggu and UNKLE in Artists. Duos like “Roni Size & Reprazent” stay") {
                    Toggle("", isOn: $model.podSettings.mainArtistOnly).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 50)
                SettingRow(icon: "sparkle.magnifyingglass", title: "Fill in year and genre", detail: "From Find Metadata, when a file has none") {
                    Toggle("", isOn: $model.podSettings.fillTagsFromMetadata).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 50)
                SettingRow(icon: "speaker.wave.2", title: "Sound Check", detail: "Measure each song's loudness on Sync; turn on Sound Check in the iPod's Settings too") {
                    Toggle("", isOn: $model.podSettings.soundCheck).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 50)
                SettingRow(icon: "powerplug", title: "Sync when connected", detail: "Changes queued while it's unplugged sync as soon as you plug it in") {
                    Toggle("", isOn: $model.podSettings.syncOnConnect).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 50)
                SettingRow(icon: "eject", title: "Eject after syncing", detail: "So it's safe to unplug when the sync is done") {
                    Toggle("", isOn: $model.podSettings.ejectAfterSync).toggleStyle(.switch).labelsHidden()
                }
            }
            if model.froggerFeatures { FroggerSettings() }
            CalendarSettings()
        }
    }

    var checkText: String {
        guard let c = model.podCheck else { return "Every song's file is there with the right size, and no stray files take up space" }
        var parts: [String] = []
        if !c.missing.isEmpty { parts.append("\(c.missing.count) songs have no file") }
        if !c.wrongSize.isEmpty { parts.append("\(c.wrongSize.count) files have another size than the list says") }
        if !c.stray.isEmpty {
            let bytes = c.stray.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int }.reduce(0, +)
            parts.append("\(c.stray.count) stray files (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))")
        }
        return parts.isEmpty ? "All good: every song has its file and there are no stray files" : parts.joined(separator: " · ")
    }

    @ViewBuilder var storageHistory: some View {
        if model.history.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Storage over time").font(.headline)
                Chart(model.history, id: \.date) { s in
                    AreaMark(x: .value("Day", s.date), y: .value("GB", Double(s.used) / 1e9))
                        .foregroundStyle(Color.accentColor.opacity(0.25).gradient)
                    LineMark(x: .value("Day", s.date), y: .value("GB", Double(s.used) / 1e9)).foregroundStyle(Color.accentColor)
                }
                .chartYAxisLabel("GB used")
                .frame(height: 140)
            }
            .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    func maintenance(_ i: IPodInfo, _ db: ITunesDB) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maintenance").font(.title2.bold())
            VStack(spacing: 0) {
                MaintenanceRow(icon: "checkmark.shield", title: "Check the iPod",
                               detail: checkText) {
                    if let o = model.orphans, !o.isEmpty {
                        Button("Delete Stray Files…") { ui.confirmOrphans = true }.buttonStyle(.glass)
                    }
                    if let m = model.podCheck?.missing, !m.isEmpty {
                        Button("Remove \(m.count) from List") { model.removeMissing() }.buttonStyle(.glass)
                            .help("Songs in the iPod's list whose file is gone; the iPod skips them")
                    }
                    Button(ui.checking ? "Checking…" : "Check") {
                        ui.checking = true
                        Task { await model.scanOrphans(); ui.checking = false }
                    }
                    .buttonStyle(.glass).disabled(ui.checking || model.syncing || !model.connected)
                }
                Divider().padding(.leading, 50)
                let pairs = model.matchSuggestions().count
                MaintenanceRow(icon: "link", title: "Fix matching",
                               detail: pairs > 0 ? "\(pairs) songs on the iPod look like library songs with slightly different tags"
                                                 : model.aliases.isEmpty ? "Every song on the iPod matches the library or has no look-alike" : "\(model.aliases.count) songs paired") {
                    Button(pairs > 0 ? "Review…" : "Open…") { model.showMatch = true }.buttonStyle(.glass)
                }
                Divider().padding(.leading, 50)
                MaintenanceRow(icon: "clock.arrow.circlepath", title: "Previous database",
                               detail: model.hasBackup ? "Crate keeps the song list from before its last write" : "No backup yet; one is made on the first sync") {
                    Button("Restore…") { ui.confirmRestore = true }.buttonStyle(.glass).disabled(!model.hasBackup || model.syncing)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }.glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct SettingRow<Control: View>: View {
    var icon, title, detail: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

struct Legend: View {
    var color: Color, text: String, bytes: Int64
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct MaintenanceRow<Actions: View>: View {
    var icon, title, detail: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(14)
    }
}

// MARK: songs

/// The search field at the left of a list's filter bar.
extension View {
    /// A Menu drawn as a glass button, like the buttons around it: Menu ignores `.buttonStyle(.glass)` and
    /// comes out as a flat grey button.
    func glassMenu(indicator: Bool = true) -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(indicator ? .visible : .hidden)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
    }
}

struct FilterField: View {
    var prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 320)
    }
}

/// Every word has to appear in one of the fields.
func matchesQuery(_ q: String, _ fields: [String]) -> Bool {
    let terms = q.lowercased().split(separator: " ")
    if terms.isEmpty { return true }
    let hay = fields.joined(separator: " ").lowercased()
    return terms.allSatisfy { hay.contains($0) }
}

@MainActor
final class SongsUI: ObservableObject {
    @Published var sort = [KeyPathComparator(\LibTrack.artist), KeyPathComparator(\LibTrack.album), KeyPathComparator(\LibTrack.trackNumber)]
    @Published var selection: Set<LibTrack.ID> = []
    @Published var query = ""
    @Published var show = Show.all
    @Published var genre = ""                  // "" = every genre
    @Published var kind = ""                   // file extension, "" = every kind
    @Published var stars: Set<Int> = []         // ratings to show (0 = unrated); empty: any
    @Published var unplayed = false
    // which columns show (right-click the header); remembered
    @Published var columns: TableColumnCustomization<LibTrack> = {
        (UserDefaults.standard.data(forKey: "songColumns")).flatMap { try? JSONDecoder().decode(TableColumnCustomization<LibTrack>.self, from: $0) } ?? .init()
    }() { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(columns), forKey: "songColumns") } }

    enum Show: String, CaseIterable { case all = "All Songs", onIPod = "On iPod", notOnIPod = "Not on iPod", queued = "Waiting for Sync" }

    var filtering: Bool { !query.isEmpty || show != .all || !genre.isEmpty || !kind.isEmpty || !stars.isEmpty || unplayed }
    /// "Electronic, IDM; Ambient" counts as three genres.
    static func genres(_ s: String) -> [String] {
        s.split { $0 == "," || $0 == ";" }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func clear() { query = ""; show = .all; genre = ""; kind = ""; stars = []; unplayed = false }

    // The filtered, sorted rows and the genre/kind menus, kept until their inputs change: the whole library
    // was filtered and sorted again on every redraw (any change anywhere in Crate).
    private var rowsKey: Int?, cachedRows: [LibTrack] = []
    func rows(_ key: Int, _ make: () -> [LibTrack]) -> [LibTrack] {
        if key != rowsKey { cachedRows = make(); rowsKey = key }
        return cachedRows
    }
    private var menusKey: Int?, cachedMenus: (genres: [String], kinds: [String]) = ([], [])
    func menus(_ version: Int, _ tracks: [LibTrack]) -> (genres: [String], kinds: [String]) {
        if version != menusKey {
            cachedMenus = (Set(tracks.flatMap { Self.genres($0.genre) }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                           Set(tracks.map(\.ext)).filter { !$0.isEmpty }.sorted())
            menusKey = version
        }
        return cachedMenus
    }
}

struct SongsView: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = SongsUI()

    var body: some View {
        let rows = ui.rows(rowsKey) { filtered.sorted(using: ui.sort) }
        Table(rows, selection: $ui.selection, sortOrder: $ui.sort, columnCustomization: $ui.columns) {
            TableColumn("") { (t: LibTrack) in
                // on the iPod is the usual state: faint; queued, partly and removing stand out, as on album covers
                let m = model.songMark(t)
                Button { model.toggleSong(t) } label: {
                    Image(systemName: m.icon.map { $0 == "checkmark" ? "checkmark.circle" : $0 + ".circle.fill" } ?? "plus.circle")
                        .foregroundStyle(m == .none ? AnyShapeStyle(.quaternary) : m == .onIPod ? AnyShapeStyle(.tertiary) : AnyShapeStyle(m.tint))
                }
                .buttonStyle(.plain)
                .help(m == .none ? "Add this song to the iPod" : m.help)
            }
            .width(22).customizationID("ipod").disabledCustomizationBehavior(.visibility)
            TableColumn("Title", value: \.title) { (t: LibTrack) in
                HStack(spacing: 8) {
                    Group {
                        if let img = model.artwork[t.album.lowercased()] { Image(nsImage: img).resizable().scaledToFill() }
                        else { Color.secondary.opacity(0.15) }
                    }
                    .frame(width: 26, height: 26).clipShape(.rect(cornerRadius: 4))
                    Text(t.title).lineLimit(1)
                    if model.player.current?.id == t.id { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint) }
                }
            }
            .width(min: 160, ideal: 280).customizationID("title").disabledCustomizationBehavior(.visibility)
            TableColumn("Artist", value: \.artist) { (t: LibTrack) in Text(t.trackArtist.isEmpty ? t.artist : t.trackArtist).foregroundStyle(.secondary) }
                .customizationID("artist")
            TableColumn("Album", value: \.album) { (t: LibTrack) in Text(t.album).foregroundStyle(.secondary) }
                .customizationID("album")
            TableColumn("Genre", value: \.genre) { (t: LibTrack) in Text(t.genre).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 90).customizationID("genre").defaultVisibility(.hidden)
            TableColumn("Year", value: \.year) { (t: LibTrack) in Text(t.year > 0 ? String(t.year) : "").monospacedDigit().foregroundStyle(.secondary) }
                .width(44).customizationID("year")
            TableColumn("Time", value: \.lengthMs) { (t: LibTrack) in Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary) }
                .width(48).customizationID("time")
            Group {     // (a Table takes 10 columns per block)
                TableColumn("Plays") { (t: LibTrack) in Text(model.stat(t).plays > 0 ? "\(model.stat(t).plays)" : "").monospacedDigit().foregroundStyle(.secondary) }
                    .width(40).customizationID("plays")
                TableColumn("Skips") { (t: LibTrack) in Text(model.stat(t).skips > 0 ? "\(model.stat(t).skips)" : "").monospacedDigit().foregroundStyle(.secondary) }
                    .width(40).customizationID("skips").defaultVisibility(.hidden)
            }
            TableColumn("Rating") { (t: LibTrack) in StarPicker(value: model.rating(t)) { model.rate(t, $0) } }.width(64).customizationID("rating")
            TableColumn("Kind", value: \.ext) { (t: LibTrack) in Text(t.ext.uppercased()).font(.caption).foregroundStyle(.tertiary) }
                .width(44).customizationID("kind").defaultVisibility(.hidden)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: LibTrack.ID.self) { ids in
            let picked = model.libTracks.filter { ids.contains($0.id) }
            let off = picked.filter { model.songMark($0) == .none }, on = picked.filter { model.songMark($0) == .onIPod }
            if !off.isEmpty { Button("Add \(off.count) Song\(off.count == 1 ? "" : "s") to iPod", systemImage: "plus.circle") { off.forEach(model.toggleSong) } }
            if !on.isEmpty { Button("Remove \(on.count) Song\(on.count == 1 ? "" : "s") from iPod", systemImage: "minus.circle") { on.forEach(model.toggleSong) } }
            if !on.isEmpty, model.froggerFeatures {
                let hidden = on.allSatisfy(model.isHidden)
                Button(hidden ? "Show in iPod Library" : "Hide from iPod Library", systemImage: hidden ? "eye" : "eye.slash") {
                    model.setHidden(on, !hidden)
                }
            }
            if !picked.isEmpty { AddToPlaylistMenu(tracks: picked) }
            Divider()
            if ids.count == 1, let a = album(ids.first) {
                Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(a)) }
                AlbumMenu(album: a)
            }
        } primaryAction: { ids in
            if let a = album(ids.first) { model.path.append(.album(a)) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .overlay { if rows.isEmpty && ui.filtering { ContentUnavailableView("No Songs Match", systemImage: "line.3.horizontal.decrease.circle") } }
        .navigationTitle("Songs")
        .navigationSubtitle(ui.filtering ? "\(rows.count) of \(model.libTracks.count) songs" : "\(rows.count) songs")
    }

    /// What the rows depend on: the songs, the filters and sort, and (when a filter looks at them) the iPod and queue,
    /// ratings and play counts.
    var rowsKey: Int {
        var h = Hasher()
        h.combine(model.libraryVersion); h.combine(ui.sort); h.combine(ui.query); h.combine(ui.show)
        h.combine(ui.genre); h.combine(ui.kind); h.combine(ui.stars); h.combine(ui.unplayed)
        if ui.show != .all || ui.unplayed { h.combine(model.syncVersion) }
        if !ui.stars.isEmpty { h.combine(model.ratings) }
        return h.finalize()
    }

    /// Every search word has to appear in the title, artist, album, genre or year.
    var filtered: [LibTrack] {
        model.libTracks.filter { t in
            if !ui.genre.isEmpty && !SongsUI.genres(t.genre).contains(ui.genre) { return false }
            if !ui.kind.isEmpty && t.ext != ui.kind { return false }
            switch ui.show {
            case .all: break
            case .onIPod: if model.songMark(t) != .onIPod { return false }
            case .notOnIPod: if model.songMark(t) != .none { return false }
            case .queued: if model.songMark(t) != .adding && model.songMark(t) != .removing { return false }
            }
            if !ui.stars.isEmpty && !ui.stars.contains(model.rating(t)) { return false }
            if ui.unplayed && model.stat(t).plays > 0 { return false }
            return matchesQuery(ui.query, [t.title, t.artist, t.trackArtist, t.album, t.genre, t.year > 0 ? String(t.year) : ""])
        }
    }

    /// The same glass controls as the other pages: a search capsule and menus that say what they're set to.
    var filterBar: some View {
        let (genres, kinds) = ui.menus(model.libraryVersion, model.libTracks)
        return HStack(spacing: 8) {
            FilterField(prompt: "Title, artist, album, genre, year", text: $ui.query)
            Menu {
                Picker("Show", selection: $ui.show) { ForEach(SongsUI.Show.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.inline)
            } label: { Text(ui.show.rawValue) }
            .glassMenu()
            Menu {
                Picker("Genre", selection: $ui.genre) {
                    Text("All Genres").tag("")
                    Divider()
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text(ui.genre.isEmpty ? "All Genres" : ui.genre) }
            .glassMenu()
            Menu {
                // pick any mix of ratings ("★★★★★ and ★★★★"); none ticked shows every song
                Section("Rating") {
                    ForEach([5, 4, 3, 2, 1, 0], id: \.self) { n in
                        Toggle(n == 0 ? "Unrated" : String(repeating: "★", count: n), isOn: Binding(
                            get: { ui.stars.contains(n) },
                            set: { if $0 { ui.stars.insert(n) } else { ui.stars.remove(n) } }))
                    }
                    if !ui.stars.isEmpty { Button("Any Rating") { ui.stars = [] } }
                }
                Picker("Kind", selection: $ui.kind) {
                    Text("All Kinds").tag("")
                    ForEach(kinds, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Never Played", isOn: $ui.unplayed)
            } label: {
                Label(moreLabel, systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.titleAndIcon)
            }
            .glassMenu()
            Spacer()
            if ui.filtering { Button("Clear") { ui.clear() }.buttonStyle(.glass) }
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
    }

    /// The extra filters, as the menu's label: "Filters" or what's set ("★★★ · FLAC · Never Played").
    var moreLabel: String {
        let rated = ui.stars.sorted(by: >).map { $0 == 0 ? "Unrated" : String(repeating: "★", count: $0) }
        let parts = [rated.count > 2 ? "\(rated.count) ratings" : rated.joined(separator: ", "), ui.kind.uppercased(), ui.unplayed ? "Never Played" : ""]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Filters" : parts.joined(separator: " · ")
    }

    func album(_ id: LibTrack.ID?) -> Album? {
        guard let id, let t = model.libTracks.first(where: { $0.id == id }) else { return nil }
        return model.album(of: t)
    }
}
