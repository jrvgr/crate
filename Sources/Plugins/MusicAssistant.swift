import SwiftUI

// The Music Assistant plugin plays on the house's speakers: MA's players and groups (Snapcast, AirPlay,
// Chromecast…) show up in the toolbar's speaker menu, and with one picked Crate's Play buttons,
// the iPod's controls and the menu bar drive MA's queue instead of this Mac. Songs go to MA as the Subsonic
// server's ids (MA has the same Navidrome as a provider) or as Spotify URIs. It talks to MA's HTTP API
// (POST /api with a long-lived token), and reads the queue back about once a second while it plays.

enum MAError: Error, LocalizedError {
    case notConfigured, unreachable(String), auth, server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter the server and a token in Settings › Plugins › Music Assistant"
        case .unreachable(let why): return "Can't reach Music Assistant: \(why)"
        case .auth: return "Music Assistant didn't accept the token"
        case .server(let m): return m
        }
    }
}

struct MAPlayer: Identifiable, Hashable {
    var id, name: String
    var group: Bool
    var volume: Double?                         // nil: MA can't set its volume
    var members: [String] = []                  // a group's or sync leader's players
    var syncedTo: String?                       // the leader this one plays along with
    var canGroupWith: [String] = []
}

@MainActor
final class MusicAssistant: ObservableObject {
    @AppStorage("maURL") var url = ""

    @Published var players: [MAPlayer] = []
    @Published var status = ""
    @Published var error: String?

    var token: String {
        get { Keychain.get("musicassistant") }
        set {
            objectWillChange.send()
            let status = Keychain.set("musicassistant", newValue)
            if status != errSecSuccess { error = "Couldn't save the token (\(status))" }
        }
    }

    var base: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
    var configured: Bool { !url.isEmpty && !token.isEmpty }

    /// One command; its result.
    @discardableResult
    func call(_ command: String, _ args: [String: Any] = [:]) async throws -> Any? {
        guard configured, let u = URL(string: base + "/api") else { throw MAError.notConfigured }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["command": command, "args": args])
        let d: Data, resp: URLResponse
        do { (d, resp) = try await URLSession.shared.data(for: r) }
        catch { throw MAError.unreachable(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
        if code == 401 || code == 403 { throw MAError.auth }
        if let e = j as? [String: Any], let details = e["details"] as? String, e["error_code"] != nil {
            throw e["error_code"] as? Int == 20 ? MAError.auth : MAError.server(details)
        }
        guard code == 200 else { throw MAError.server("Music Assistant answered HTTP \(code)") }
        return j
    }

    /// Reads the players (groups first) and says which server answered.
    func check() async {
        do {
            try await loadPlayers()
            status = "Connected, \(players.count) players"
            error = nil
        } catch {
            status = ""
            self.error = error.localizedDescription
        }
    }

    func loadPlayers() async throws {
        let all = try await call("players/all") as? [[String: Any]] ?? []
        players = all.compactMap { p in
            guard let id = p["player_id"] as? String, p["available"] as? Bool ?? false, p["enabled"] as? Bool ?? true,
                  !(p["hide_in_ui"] as? Bool ?? false) else { return nil }
            let group = p["type"] as? String == "group"
            let volume = (p["volume_control"] as? String == "none" ? nil : (group ? p["group_volume"] : p["volume_level"]) as? Int)
            return MAPlayer(id: id, name: p["display_name"] as? String ?? p["name"] as? String ?? id, group: group,
                            volume: volume.map { Double($0) / 100 }, members: (p["group_members"] as? [String] ?? []).filter { $0 != id },
                            syncedTo: p["synced_to"] as? String, canGroupWith: p["can_group_with"] as? [String] ?? [])
        }.sorted { ($0.group ? 0 : 1, $0.name.lowercased()) < ($1.group ? 0 : 1, $1.name.lowercased()) }
    }

    func name(_ id: String) -> String { players.first { $0.id == id }?.name ?? "Music Assistant" }

    // MARK: playing

    /// Replaces the player's queue with these items (track, album or playlist URIs) and starts it.
    func play(_ uris: [String], on queue: String) async throws {
        try await call("player_queues/play_media", ["queue_id": queue, "media": uris, "option": "replace"])
    }

    func command(_ c: String, _ queue: String, _ extra: [String: Any] = [:]) async {
        do { try await call("player_queues/" + c, extra.merging(["queue_id": queue]) { a, _ in a }) }
        catch { self.error = error.localizedDescription }
    }

    /// Lets a speaker play along with `leader` (in sync), or stops it doing so.
    func sync(_ id: String, with leader: String, _ on: Bool) async {
        do {
            try await call("players/cmd/set_members", ["target_player": leader, on ? "player_ids_to_add" : "player_ids_to_remove": [id]])
            try await loadPlayers()
        } catch { self.error = error.localizedDescription }
    }

    /// One speaker's volume, sent while a slider moves: at most every 150 ms, always ending on the last value.
    func slide(_ v: Double, on id: String) {
        if let i = players.firstIndex(where: { $0.id == id }) { players[i].volume = v }
        pendingVolume[id] = v
        guard volumeSends[id] == nil else { return }
        volumeSends[id] = Task {
            while let v = pendingVolume.removeValue(forKey: id) {
                await setVolume(v, on: id)
                try? await Task.sleep(for: .milliseconds(150))
            }
            volumeSends[id] = nil
        }
    }
    private var pendingVolume: [String: Double] = [:]
    private var volumeSends: [String: Task<Void, Never>] = [:]

    func setVolume(_ v: Double, on id: String) async {
        let group = players.first { $0.id == id }?.group ?? false
        do { try await call(group ? "players/cmd/group_volume" : "players/cmd/volume_set", ["player_id": id, "volume_level": Int(v * 100)]) }
        catch { self.error = error.localizedDescription }
    }

    struct QueueState {
        var index, items: Int; var elapsed, duration: Double; var playing: Bool; var volume: Double?
        var title = "", artist = "", album = ""          // what's playing, for a queue Crate didn't start
        var image: URL?                                  // its cover (Spotify's, or through MA's image proxy)
    }

    func state(_ queue: String) async -> QueueState? {
        guard let q = try? await call("player_queues/get", ["queue_id": queue]) as? [String: Any] else { return nil }
        let p = try? await call("players/get", ["player_id": queue]) as? [String: Any]
        let vol = (p?["group_volume"] as? Int ?? p?["volume_level"] as? Int).map { Double($0) / 100 }
        var elapsed = q["elapsed_time"] as? Double ?? 0
        let playing = q["state"] as? String == "playing"
        // MA stamps the position when it last reported; add the time since
        if playing, let at = q["elapsed_time_last_updated"] as? Double { elapsed += max(0, Date().timeIntervalSince1970 - at) }
        let item = q["current_item"] as? [String: Any], media = item?["media_item"] as? [String: Any]
        return QueueState(index: q["current_index"] as? Int ?? 0, items: q["items"] as? Int ?? 0, elapsed: elapsed,
                          duration: item?["duration"] as? Double ?? 0, playing: playing, volume: vol,
                          title: media?["name"] as? String ?? item?["name"] as? String ?? "",
                          artist: ((media?["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? "",
                          album: ((media?["album"] as? [String: Any])?["name"] as? String) ?? "",
                          image: image(item, media))
    }

    /// The queue item's picture, else the song's or its album's first: a URL as it is when MA says it's
    /// reachable from anywhere, else through MA's image proxy (a provider's local file, say).
    func image(_ item: [String: Any]?, _ media: [String: Any]?) -> URL? {
        let first = { (m: [String: Any]?) in ((m?["metadata"] as? [String: Any])?["images"] as? [[String: Any]])?.first }
        let img = item?["image"] as? [String: Any] ?? media?["image"] as? [String: Any] ?? first(media) ?? first(media?["album"] as? [String: Any])
        guard let path = img?["path"] as? String, !path.isEmpty else { return nil }
        if img?["remotely_accessible"] as? Bool == true || path.hasPrefix("http") { return URL(string: path) }
        var c = URLComponents(string: base + "/imageproxy")
        c?.queryItems = [.init(name: "path", value: path), .init(name: "provider", value: img?["provider"] as? String ?? ""), .init(name: "size", value: "256")]
        return c?.url
    }

    /// A library song as MA knows it: the Subsonic server's id, or its Spotify URI.
    static func uri(subsonicID: String?, uri: String) -> String? {
        if uri.hasPrefix("spotify:") { return uri }
        return subsonicID.map { "opensubsonic://track/" + $0 }
    }
}

struct MusicAssistantSettings: View {
    @EnvironmentObject var model: Model
    @ObservedObject var ma: MusicAssistant
    @StateObject private var ui = SettingsUI()

    var body: some View {
        TextField("Server", text: ma.$url, prompt: Text("http://host:8095"))
        LabeledContent("Token") {
            HStack {
                SecureField("", text: $ui.password, prompt: Text(ma.token.isEmpty ? "A long-lived token from Music Assistant" : "Saved – paste to change"))
                    .onSubmit { save() }
                Button("Save") { save() }.disabled(ui.password.isEmpty)
            }
        }
        LabeledContent("Status") {
            HStack {
                if ui.testing == .musicAssistant { ProgressView().controlSize(.small) }
                Text(ma.error ?? (ma.status.isEmpty ? (ma.configured ? "Not checked" : "Not set up") : ma.status))
                    .foregroundStyle(ma.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(2)
                Button("Test") { ui.testing = .musicAssistant; Task { await ma.check(); ui.testing = nil } }
                    .disabled(!ma.configured)
            }
        }
        Text("Make a token in Music Assistant under your profile › Long-lived access tokens. Pick a speaker with the toolbar's speaker button; songs play there through the Subsonic server (also added to Music Assistant) or Spotify.")
            .font(.caption).foregroundStyle(.secondary)
    }

    func save() {
        ma.token = ui.password.trimmingCharacters(in: .whitespacesAndNewlines)
        ui.password = ""
        ui.testing = .musicAssistant
        Task { await ma.check(); ui.testing = nil }
    }
}

/// The toolbar's speaker button: where Play sends music, like AirPlay in Music. A panel like the Mac's
/// Sound menu: pick the speaker, set each one's volume, and let others play along with it in sync.
struct PlayOnMenu: View {
    @EnvironmentObject var model: Model
    @ObservedObject var player: Player
    @ObservedObject var ma: MusicAssistant
    @StateObject private var shown = PopoverState()

    var body: some View {
        let remote = player.output != "mac"
        Button { shown.on.toggle() } label: {
            Label(remote ? model.remoteName ?? "Speaker" : "This Mac", systemImage: remote ? "hifispeaker.fill" : "hifispeaker")
        }
        .popover(isPresented: $shown.on, arrowEdge: .bottom) {
            SpeakerPanel(player: player, ma: ma).environmentObject(model)
                .task { if model.on(.musicAssistant), ma.configured { try? await ma.loadPlayers() } }
        }
        .help(remote ? "Playing on \(model.remoteName ?? "a speaker"); click to change" : "Play on this Mac or a speaker")
        .task(id: model.on(.musicAssistant)) {
            guard model.on(.musicAssistant), ma.configured else { return }
            try? await ma.loadPlayers()
            // music started on the speaker from elsewhere (Home Assistant, the MA app) shows up within a few seconds
            while !Task.isCancelled {
                player.pickUp()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

@MainActor
final class PopoverState: ObservableObject { @Published var on = false }

struct SpeakerPanel: View {
    @EnvironmentObject var model: Model
    @ObservedObject var player: Player
    @ObservedObject var ma: MusicAssistant

    var body: some View {
        let leader = player.output.hasPrefix("ma:") ? String(player.output.dropFirst(3)) : nil
        let lead = leader.flatMap { id in ma.players.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 4) {
            Text("Play On").font(.headline).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            row("This Mac", icon: "laptopcomputer", tag: "mac", volume: player.output == "mac" ? player.volume : nil) { player.setVolume($0) }
            if model.on(.musicAssistant) {
                ForEach(ma.players) { p in
                    let picked = p.id == leader
                    // others that can play along with the picked speaker: a checkbox, like the Mac's AirPlay list
                    let along = lead.map { !picked && !$0.group && !p.group && $0.canGroupWith.contains(p.id) } ?? false
                    let inSync = lead.map { $0.members.contains(p.id) || p.syncedTo == $0.id } ?? false
                    row(p.name, icon: p.group ? "hifispeaker.2" : "hifispeaker", tag: "ma:" + p.id, volume: p.volume,
                        sync: along ? (inSync, { on in _ = Task { await ma.sync(p.id, with: lead!.id, on) } }) : nil,
                        moveHere: !picked && !inSync && player.canTransfer ? { player.transfer(to: "ma:" + p.id) } : nil) { ma.slide($0, on: p.id) }
                }
                if ma.players.isEmpty { Text(ma.error ?? "No speakers found").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14) }
                if let e = ma.error, !ma.players.isEmpty { Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 14) }
            }
            if model.on(.ownTone) { row("OwnTone's speakers", icon: "hifispeaker.2", tag: "owntone", volume: nil) { _ in } }
        }
        .padding(.bottom, 12)
        .frame(width: 320)
    }

    /// A speaker: click to play on it; its volume under it; a checkbox when it can play along in sync.
    func row(_ name: String, icon: String, tag: String, volume: Double?, sync: (Bool, (Bool) -> Void)? = nil,
             moveHere: (() -> Void)? = nil, setVolume: @escaping (Double) -> Void) -> some View {
        let picked = player.output == tag
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(name).fontWeight(picked ? .semibold : .regular).lineLimit(1)
                Spacer()
                if let moveHere {
                    // Music Assistant's queue transfer: the whole queue, Spotify songs too, from where it plays now
                    Button("Move Here", systemImage: "arrow.turn.down.right", action: moveHere)
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Move what's playing (the whole queue) to \(name)")
                }
                if let (on, set) = sync {
                    Toggle("In sync", isOn: Binding(get: { on }, set: set)).toggleStyle(.checkbox).labelsHidden()
                        .help(on ? "Playing along with the speaker you picked; uncheck to stop" : "Play along with the speaker you picked, in sync")
                } else if picked { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
            .contentShape(.rect)
            .onTapGesture { if !picked { player.move(to: tag) } }
            if let v = volume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { v }, set: setVolume), in: 0...1).controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(picked ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 6)
    }
}
