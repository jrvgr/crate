import Foundation

// The Mac's Apple Music library (iTunes Match: matched tracks come down as DRM-free 256 kbps AAC,
// uploaded ones as the original files). Albums are read and downloaded through Music's AppleScript
// dictionary, then copied into OwnTone's folder by the Importer.

struct AMTrack: Hashable {
    var pid, title, artist, albumArtist, album, genre, cloud, location: String
    var year, trackNumber, discNumber: Int
    var seconds: Double
}

struct AMAlbum: Identifiable, Hashable {
    var id: String { title.lowercased() }
    var title, artist: String
    var tracks: [AMTrack]
    var year: Int { tracks.map(\.year).max() ?? 0 }
    var downloaded: Int { tracks.filter { !$0.location.isEmpty }.count }
    var lengthMs: Int { Int(tracks.map(\.seconds).reduce(0, +) * 1000) }
}

enum AppleMusicError: Error, LocalizedError {
    case script(String), timeout(String)
    var errorDescription: String? {
        switch self {
        case .script(let s): return "Music: \(s)"
        case .timeout(let s): return "Music didn't finish downloading \(s)"
        }
    }
}

enum AppleMusic {
    static let fs = "\u{1F}", rs = "\u{1E}"

    static func run(_ script: String) async throws -> String {
        try await Task.detached {
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = out; p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw AppleMusicError.script(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }.value
    }

    /// Every library track, fetched property by property (one Apple Event per property).
    static func tracks() async throws -> [AMTrack] {
        let props = ["persistent ID", "name", "artist", "album artist", "album", "genre", "cloud status",
                     "year", "track number", "disc number", "duration"]
        let script = """
        set AppleScript's text item delimiters to (character id 31)
        set out to {}
        with timeout of 900 seconds
        tell application "Music"
            set lib to library playlist 1
        \(props.map { "    set end of out to ((\($0) of every track of lib) as text)" }.joined(separator: "\n"))
            set pids to persistent ID of every file track of lib
            set locs to {}
            repeat with t in (every file track of lib)
                set l to location of t
                if l is missing value then
                    set end of locs to ""
                else
                    set end of locs to POSIX path of l
                end if
            end repeat
            set end of out to (pids as text)
            set end of out to (locs as text)
        end tell
        end timeout
        set AppleScript's text item delimiters to (character id 30)
        return out as text
        """
        let cols = try await run(script).components(separatedBy: rs).map { $0.components(separatedBy: fs) }
        guard cols.count == props.count + 2, let n = cols.first?.count, cols.prefix(props.count).allSatisfy({ $0.count == n }) else {
            throw AppleMusicError.script("unexpected answer")
        }
        let filePIDs = cols[props.count], locs = cols[props.count + 1]
        let location = Dictionary(zip(filePIDs, locs).map { ($0, $1) }, uniquingKeysWith: { a, _ in a })
        return (0..<n).map { i in
            let c = { (k: Int) in cols[k][i] }
            return AMTrack(pid: c(0), title: c(1), artist: c(2), albumArtist: c(3), album: c(4), genre: c(5), cloud: c(6),
                           location: location[c(0)] ?? "", year: Int(c(7)) ?? 0, trackNumber: Int(c(8)) ?? 0,
                           discNumber: Int(c(9)) ?? 0, seconds: Double(c(10).replacingOccurrences(of: ",", with: ".")) ?? 0)
        }
    }

    static func albums() async throws -> [AMAlbum] {
        let ts = try await tracks().filter { !$0.album.isEmpty && $0.cloud != "subscription" }    // Apple Music streams have DRM
        return Dictionary(grouping: ts) { $0.album.lowercased() }.values.map { g in
            let artists = Set(g.map { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist })
            return AMAlbum(title: g[0].album, artist: artists.count == 1 ? artists.first! : "Various Artists",
                           tracks: g.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) })
        }.sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    /// Asks Music to download the album's cloud tracks and waits until all of them have a file.
    static func download(_ a: AMAlbum, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> [String] {
        let pids = a.tracks.map(\.pid)
        let list = "{" + pids.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        if a.downloaded < a.tracks.count {
            _ = try await run("""
            tell application "Music"
                repeat with p in \(list)
                    set t to (first track of library playlist 1 whose persistent ID is (p as text))
                    if class of t is not file track or location of t is missing value then
                        try
                            download t
                        end try
                    end if
                end repeat
            end tell
            """)
        }
        let deadline = Date().addingTimeInterval(Double(60 + 45 * pids.count))
        while true {
            let answer = try await run("""
            set AppleScript's text item delimiters to (character id 31)
            set out to {}
            tell application "Music"
                repeat with p in \(list)
                    set t to (first track of library playlist 1 whose persistent ID is (p as text))
                    set l to missing value
                    try
                        set l to location of t
                    end try
                    if l is missing value then
                        set end of out to ""
                    else
                        set end of out to POSIX path of l
                    end if
                end repeat
            end tell
            return out as text
            """)
            let paths = answer.components(separatedBy: fs)
            let done = paths.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            await progress(done.count, pids.count)
            if done.count == pids.count { return done }
            if Date() > deadline { throw AppleMusicError.timeout(a.title) }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// Album cover from the iTunes Search API (the library's own artwork isn't reachable without
    /// a slow Apple Event per album).
    static func artworkURL(_ a: AMAlbum) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: (a.artist == "Various Artists" ? "" : a.artist + " ") + a.title),
                        .init(name: "entity", value: "album"), .init(name: "limit", value: "5")]
        guard let (d, _) = try? await URLSession.shared.data(from: c.url!),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let results = j["results"] as? [[String: Any]] else { return nil }
        let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let hit = results.first { loose($0["collectionName"] as? String ?? "").hasPrefix(loose(a.title)) } ?? results.first
        guard let s = hit?["artworkUrl100"] as? String else { return nil }
        return URL(string: s.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}
