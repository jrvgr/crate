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
            return MAPlayer(id: id, name: p["display_name"] as? String ?? p["name"] as? String ?? id, group: p["type"] as? String == "group")
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

    func setVolume(_ v: Double, on id: String) async {
        let group = players.first { $0.id == id }?.group ?? false
        do { try await call(group ? "players/cmd/group_volume" : "players/cmd/volume_set", ["player_id": id, "volume_level": Int(v * 100)]) }
        catch { self.error = error.localizedDescription }
    }

    struct QueueState {
        var index, items: Int; var elapsed, duration: Double; var playing: Bool; var volume: Double?
        var title = "", artist = "", album = ""          // what's playing, for a queue Crate didn't start
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
                          album: ((media?["album"] as? [String: Any])?["name"] as? String) ?? "")
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

/// The toolbar's speaker button: where Play sends music, like AirPlay in Music.
struct PlayOnMenu: View {
    @EnvironmentObject var model: Model
    @ObservedObject var player: Player
    @ObservedObject var ma: MusicAssistant

    var body: some View {
        let remote = player.output != "mac"
        Menu {
            Picker("Play On", selection: Binding(get: { player.output }, set: { player.move(to: $0) })) {
                Label("This Mac", systemImage: "laptopcomputer").tag("mac")
                if model.on(.musicAssistant) {
                    ForEach(ma.players) { p in Label(p.name, systemImage: p.group ? "hifispeaker.2" : "hifispeaker").tag("ma:" + p.id) }
                }
                if model.on(.ownTone) { Label("OwnTone's speakers", systemImage: "hifispeaker.2").tag("owntone") }
            }
            .pickerStyle(.inline)
            if model.on(.musicAssistant), ma.players.isEmpty {
                Text(ma.error ?? "No speakers found")
            }
        } label: {
            Label(remote ? model.remoteName ?? "Speaker" : "This Mac", systemImage: remote ? "hifispeaker.fill" : "hifispeaker")
        }
        .help(remote ? "Playing on \(model.remoteName ?? "a speaker"); click to change" : "Play on this Mac or a speaker")
        .task(id: model.on(.musicAssistant)) {
            if model.on(.musicAssistant), ma.configured { try? await ma.loadPlayers(); player.pickUp() }
        }
    }
}
