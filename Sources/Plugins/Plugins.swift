import SwiftUI
import Security

// Crate's core is the library (music folders on disk), the iPod and metadata lookups. Everything
// that talks to another service is a plugin that can be switched off in Settings › Plugins; with
// all of them off Crate is a plain folder → iPod manager.

enum PluginID: String, CaseIterable, Identifiable, Codable {
    case ownTone, subsonic, musicAssistant, spotify, soulseek, appleMusic, youtube
    var id: String { rawValue }

    var name: String {
        switch self {
        case .ownTone: return "OwnTone"
        case .subsonic: return "Subsonic"
        case .musicAssistant: return "Music Assistant"
        case .spotify: return "Spotify"
        case .soulseek: return "Soulseek"
        case .appleMusic: return "Apple Music"
        case .youtube: return "YouTube"
        }
    }

    var icon: String {
        switch self {
        case .ownTone: return "hifispeaker.2"
        case .subsonic: return "server.rack"
        case .musicAssistant: return "hifispeaker.2.fill"
        case .spotify: return "dot.radiowaves.left.and.right"
        case .soulseek: return "arrow.down.circle"
        case .appleMusic: return "icloud"
        case .youtube: return "play.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .ownTone: return .indigo
        case .subsonic: return .teal
        case .musicAssistant: return .blue
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .soulseek: return .orange
        case .appleMusic: return .pink
        case .youtube: return .red
        }
    }

    var summary: String {
        switch self {
        case .ownTone: return "Adds the OwnTone server's library and playlists, plays albums on its speakers and rescans it after imports."
        case .subsonic: return "Adds a Subsonic server's library and playlists (Navidrome), rescans it after imports and sends it the iPod's plays."
        case .musicAssistant: return "Plays on Music Assistant's speakers and groups instead of this Mac; the iPod's buttons and the menu bar control them."
        case .spotify: return "Your saved Spotify albums and playlists: see which ones you have files for, copy playlists to the iPod, find the rest on Soulseek."
        case .soulseek: return "Searches Soulseek through your slskd server, downloads albums and imports them into the library."
        case .appleMusic: return "Imports iTunes Match albums from this Mac's Music app (256 kbps AAC, no DRM)."
        case .youtube: return "Searches YouTube and downloads songs, playlists, Spotify albums or a playlist's missing songs with yt-dlp, tagged and with covers."
        }
    }

    /// Another plugin this one needs (Spotify comes through OwnTone's library).
    var requires: PluginID? { self == .spotify && UserDefaults.standard.string(forKey: "spotifyMode") == "owntone" ? .ownTone : nil }
}

/// Which plugins are switched on, stored in the defaults.
enum PluginStore {
    static let key = "enabledPlugins"
    static func load() -> Set<PluginID> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return Set(PluginID.allCases).subtracting([.youtube, .ownTone, .musicAssistant]) }
        return Set(raw.compactMap(PluginID.init(rawValue:)))
    }
    static func save(_ s: Set<PluginID>) { UserDefaults.standard.set(s.map(\.rawValue).sorted(), forKey: key) }
}

/// Secrets (slskd and Subsonic passwords, Spotify token) in a file only this user can read (0600), like command
/// line tools keep their tokens. The login keychain was used before, but without an Apple team ID
/// macOS ties its "Always Allow" to one exact build and asks again after every update; entries
/// still there are moved over once.
enum Keychain {
    static let service = "nl.jaccogroen.crate"        // where the old entries are (Crate's id before nl.jrvgr.crate)
    static var url: URL { PodCache.dir.appendingPathComponent("secrets.json") }
    private static var cache: [String: String]?

    private static func load() -> [String: String] {
        if let c = cache { return c }
        let c = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = c
        return c
    }

    private static func store(_ c: [String: String]) -> OSStatus {
        cache = c
        do {
            try JSONEncoder().encode(c).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return errSecSuccess
        } catch { return errSecIO }
    }

    static func get(_ account: String) -> String {
        if let v = load()[account] { return v }
        // once: take it out of the old keychain entry (may ask one last time)
        guard !migrated.contains(account) else { return "" }
        migrated.insert(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        let v = String(decoding: d, as: UTF8.self)
        var c = load(); c[account] = v; _ = store(c)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        return v
    }
    private static var migrated = Set<String>()

    @discardableResult
    static func set(_ account: String, _ value: String) -> OSStatus {
        var c = load()
        c[account] = value.isEmpty ? nil : value
        return store(c)
    }
}
