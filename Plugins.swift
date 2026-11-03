import SwiftUI
import Security

// Crate's core is the library (music folders on disk), the iPod and metadata lookups. Everything
// that talks to another service is a plugin that can be switched off in Settings › Plugins; with
// all of them off Crate is a plain folder → iPod manager.

enum PluginID: String, CaseIterable, Identifiable, Codable {
    case ownTone, spotify, soulseek, appleMusic, youtube
    var id: String { rawValue }

    var name: String {
        switch self {
        case .ownTone: return "OwnTone"
        case .spotify: return "Spotify"
        case .soulseek: return "Soulseek"
        case .appleMusic: return "Apple Music"
        case .youtube: return "YouTube"
        }
    }

    var icon: String {
        switch self {
        case .ownTone: return "hifispeaker.2"
        case .spotify: return "dot.radiowaves.left.and.right"
        case .soulseek: return "arrow.down.circle"
        case .appleMusic: return "icloud"
        case .youtube: return "play.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .ownTone: return .indigo
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .soulseek: return .orange
        case .appleMusic: return .pink
        case .youtube: return .red
        }
    }

    var summary: String {
        switch self {
        case .ownTone: return "Adds the OwnTone server's library and playlists, plays albums on its speakers and rescans it after imports."
        case .spotify: return "Your saved Spotify albums and playlists: see which ones you have files for, copy playlists to the iPod, find the rest on Soulseek."
        case .soulseek: return "Searches Soulseek through your slskd server, downloads albums and imports them into the library."
        case .appleMusic: return "Imports iTunes Match albums from this Mac's Music app (256 kbps AAC, no DRM)."
        case .youtube: return "Searches YouTube and downloads songs, playlists, Spotify albums or a playlist's missing songs with yt-dlp, tagged and with covers."
        }
    }

    /// Another plugin this one needs (Spotify comes through OwnTone's library).
    var requires: PluginID? { self == .spotify && [nil, "owntone"].contains(UserDefaults.standard.string(forKey: "spotifyMode")) ? .ownTone : nil }
}

/// Which plugins are switched on, stored in the defaults.
enum PluginStore {
    static let key = "enabledPlugins"
    static func load() -> Set<PluginID> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return Set(PluginID.allCases).subtracting([.youtube]) }
        return Set(raw.compactMap(PluginID.init(rawValue:)))
    }
    static func save(_ s: Set<PluginID>) { UserDefaults.standard.set(s.map(\.rawValue).sorted(), forKey: key) }
}

/// Passwords live in the login keychain, not in the defaults.
enum Keychain {
    static let service = "nl.jaccogroen.crate"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> OSStatus {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return errSecSuccess }
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Crate (\(account))"
        return SecItemAdd(add as CFDictionary, nil)
    }
}
