import SwiftUI
import AppKit
import ScreenCaptureKit

// For reviewing the UI without Screen Recording permission (only when launched with --snapshots): another process posts the distributed
// notification "nl.jrvgr.crate.snapshot" with an object like "albums /tmp/a.png" (a pane, "album:<title>",
// "artist:<name>" or "settings:<tab>", then the file), and Crate shows that page and draws its own window into the PNG.

@MainActor
enum Snapshot {
    private static var observer: NSObjectProtocol?

    static func listen(_ model: Model) {
        guard observer == nil, CommandLine.arguments.contains("--snapshots") else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("nl.jrvgr.crate.snapshot"), object: nil, queue: .main) { n in
            guard let s = n.object as? String, let space = s.lastIndex(of: " ") else { return }
            let what = String(s[..<space]), file = String(s[s.index(after: space)...])
            Task { @MainActor in await take(what, to: file, model) }
        }
    }

    private static let panes: [String: Pane] = ["recent": .recent, "albums": .albums, "artists": .artists, "songs": .songs, "playlists": .playlists,
                                                 "ipod": .ipod, "health": .health, "spotify": .spotify, "downloads": .downloads,
                                                 "soulseek": .soulseek, "apple-music": .appleMusic, "youtube": .youtube, "lidarr": .lidarr]

    static func take(_ what: String, to file: String, _ model: Model) async {
        if what.hasPrefix("album-info:") {       // where an album's songs and cover come from, as text
            let t = String(what.dropFirst(11))
            let out = model.allAlbums.filter { $0.title == t }.map { a in
                (["folder: " + a.folder, "id: " + a.id, "artwork: \(model.artwork[a.id] != nil)",
                  "cached: \(FileManager.default.fileExists(atPath: ArtCache.file("album:" + a.folder).path))"]
                 + a.tracks.map { "track: " + $0.path }).joined(separator: "\n")
            }.joined(separator: "\n--\n")
            try? out.write(toFile: file, atomically: true, encoding: .utf8)
            return
        }
        if what == "pending-info" {                // what the Sync button's count is made of, as text
            let m = model
            let parts: [(String, Int)] = [("toAdd", m.toAdd.count), ("toRemove", m.toRemove.count), ("songsToAdd", m.songsToAdd.count),
                ("songsToRemove", m.songsToRemove.count), ("playlistsToAdd", m.playlistsToAdd.count), ("playlistsToRemove", m.playlistsToRemove.count),
                ("podSavedLists", m.podSavedLists.count), ("pendingName", m.pendingName == nil ? 0 : 1), ("smartPending", m.smartPending),
                ("retags", m.retags.count), ("hidePending", m.hidePending), ("crateNeedsSync", m.cratePlaylists.filter(m.crateNeedsSync).count),
                ("podEditsPending", m.podEditsPending), ("pendingCount", m.pendingCount)]
            let p = m.makePlan()
            let out = parts.map { "\($0.0): \($0.1)" } + ["plan hide \(p.hide) show \(p.unhide) marks \(p.markPlaylists) add \(p.playlistsAdd)"]
            try? out.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
            return
        }
        var settings = false
        if what.hasPrefix("settings:") {
            UserDefaults.standard.set(String(what.dropFirst(9)), forKey: "settingsTab")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            settings = true
        } else if what.hasPrefix("album:"), let a = model.allAlbums.first(where: { $0.title == String(what.dropFirst(6)) }) {
            model.search = ""; model.pane = .albums; model.path = [.album(a)]
        } else if what.hasPrefix("artist:") {
            model.search = ""; model.pane = .artists; model.path = [.artist(String(what.dropFirst(7)))]
        } else if what.hasPrefix("soulseek-search:") {      // "soulseek-search:<songs>:<query>", as an album page's Find on Soulseek
            let parts = what.dropFirst(16).split(separator: ":", maxSplits: 1).map(String.init)
            model.findOnSoulseek("", parts.last ?? "", songs: Int(parts.first ?? "") ?? 0)
        } else if what.hasPrefix("lidarr-choose:") {        // "lidarr-choose:<artist>|<album>", as Get with Lidarr
            let parts = what.dropFirst(14).split(separator: "|", maxSplits: 1).map(String.init)
            model.chooseWithLidarr(parts.first ?? "", parts.last ?? "")
        } else if what.hasPrefix("push-artist:") {          // an artist page over whatever is showing (a search's results, say)
            model.path.append(.artist(String(what.dropFirst(12))))
        } else if what.hasPrefix("search:") {
            model.search = String(what.dropFirst(7))
        } else if let p = panes[what] {
            model.search = ""; model.path = []; model.pane = p
        }
        try? await Task.sleep(for: .seconds(1.5))
        // Crate's own windows: the one in front of the kind asked for (Settings, or the main window)
        let mine = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
        let isSettings = { (w: NSWindow) in w.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
        let target = settings ? mine.first(where: isSettings) : mine.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? mine.first { !isSettings($0) }
        try? mine.map { "\($0.identifier?.rawValue ?? "-") \($0.title) \(Int($0.frame.width))" }.joined(separator: "\n")
            .write(toFile: file + ".windows", atomically: true, encoding: .utf8)
        guard let target else { return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let w = content.windows.first(where: { $0.windowID == CGWindowID(target.windowNumber) }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let config = SCStreamConfiguration()
            config.width = Int(w.frame.width * 2); config.height = Int(w.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
        } catch {
            try? ("error: " + error.localizedDescription).write(toFile: file + ".txt", atomically: true, encoding: .utf8)
        }
    }
}
