import SwiftUI
import AppKit

extension Model {
    // MARK: plugins

    func on(_ p: PluginID) -> Bool { plugins.contains(p) && (p.requires.map { on($0) } ?? true) }

    func setPlugin(_ p: PluginID, _ enabled: Bool) {
        if enabled { plugins.insert(p); if let r = p.requires { plugins.insert(r) } }
        else { plugins.remove(p) }

        if case .playlist = pane, !on(.ownTone), !on(.subsonic) { pane = .albums }
        Task { await reload() }
    }

    /// Where imports go: the folder picked in Settings, else the Subsonic server's music folder, else the first music
    /// folder, else ~/Music/Crate, so Crate works on its own with no server or share set up.
    var importRoot: String {
        if !importFolder.isEmpty { return importFolder }
        if on(.subsonic), subsonic.useShare, !subsonic.musicFolder.isEmpty { return subsonic.musicFolder }
        return folders.first ?? Self.localMusic
    }
    nonisolated static var localMusic: String {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate").path
    }

    /// The folders library files live in (for the organiser, the trash and telling dropped library files apart).
    /// With OwnTone the import folder sat inside its music folder, so that counts too.
    var libraryRoots: [String] {
        var r = folders + [importRoot]
        if on(.subsonic), subsonic.useShare { r.append(subsonic.musicFolder) }
        if on(.ownTone) { r.append((importRoot as NSString).deletingLastPathComponent) }
        var seen = Set<String>()
        return r.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var folders: [String] {
        get { foldersText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { foldersText = newValue.joined(separator: "\n"); objectWillChange.send() }
    }
}
