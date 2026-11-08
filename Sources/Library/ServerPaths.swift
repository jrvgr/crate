import SwiftUI

/// Where the OwnTone or Subsonic server's paths are on this Mac, for a server that sees the music under other
/// paths than the Mac does: one in a container or on a NAS, say, with /music there being /Volumes/media/music
/// here. Each mapping swaps a leading folder; none (the default) means the server and the Mac use the same paths.
/// Settings › Library › Server Paths.
enum ServerPaths {
    struct Mapping: Codable, Hashable, Identifiable {
        var id = UUID()
        var server = "", mac = ""
    }

    static let key = "serverPaths"

    /// Read from UserDefaults, which is safe off the main thread; callers converting many paths read it once.
    static var mappings: [Mapping] {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Mapping].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// `p` with the first matching folder (`from`) swapped for its counterpart (`to`); unchanged when none match.
    static func convert(_ p: String, _ map: [Mapping], from: KeyPath<Mapping, String>, to: KeyPath<Mapping, String>) -> String {
        for m in map {
            let a = trimmed(m[keyPath: from]), b = trimmed(m[keyPath: to])
            guard !a.isEmpty, !b.isEmpty, p == a || p.hasPrefix(a + "/") else { continue }
            return b + p.dropFirst(a.count)
        }
        return p
    }

    private static func trimmed(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// The mappings as rows: the server's folder, the same folder on this Mac.
struct ServerPathsEditor: View {
    @State private var maps = ServerPaths.mappings

    var body: some View {
        ForEach($maps) { $m in
            HStack(spacing: 8) {
                TextField("Server", text: $m.server, prompt: Text("/music")).labelsHidden()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("This Mac", text: $m.mac, prompt: Text("/Volumes/media/music")).labelsHidden()
                Button("Choose…") { if let p = chooseFolder("Where the server's \(m.server.isEmpty ? "folder" : m.server) is on this Mac", start: m.mac.isEmpty ? "/Volumes" : m.mac) { m.mac = p } }
                Button { maps.removeAll { $0.id == m.id } } label: { Image(systemName: "minus.circle") }
                    .help("Remove this mapping")
            }
            .buttonStyle(.borderless)
        }
        Button("Add Mapping") { maps.append(.init()) }.buttonStyle(.borderless)
            .onChange(of: maps) { ServerPaths.mappings = maps }
    }
}
