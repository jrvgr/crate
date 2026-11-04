import SwiftUI

// Links between streamed songs (Spotify, OwnTone playlists) and your own files, for when the tags
// differ a bit ("Song - 2011 Remaster" on Spotify, "Song" in the file). A linked song counts as a
// file everywhere: playlists, the sync, the Spotify album page. Kept in links.json.

extension Model {
    func linkedPath(_ t: OTTrack) -> String? { (t.uri.isEmpty ? nil : links[t.uri]) ?? links[t.key] }

    func link(_ t: OTTrack, to lib: LibTrack) {
        if !t.uri.isEmpty { links[t.uri] = lib.path }
        links[t.key] = lib.path
    }

    func unlink(_ t: OTTrack) {
        links[t.uri] = nil
        links[t.key] = nil
    }

    /// Library songs that look like `t`, best first: titles compared without remaster/feat/live
    /// suffixes and punctuation, then artist, album and length.
    func linkSuggestions(_ t: OTTrack, limit: Int = 25) -> [LibTrack] {
        let title = LinkMatch.core(t.title), artist = LinkMatch.loose(t.artist), album = LinkMatch.core(t.album)
        let words = LinkMatch.words(t.title)
        let scored: [(LibTrack, Double)] = libTracks.compactMap { l in
            let lt = LinkMatch.core(l.title)
            var s = 0.0
            if lt == title { s += 4 }
            else if !lt.isEmpty && !title.isEmpty && (lt.contains(title) || title.contains(lt)) { s += 2.5 }
            else {
                let lw = LinkMatch.words(l.title)
                let shared = Double(words.intersection(lw).count) / Double(max(1, words.union(lw).count))
                guard shared >= 0.5 else { return nil }
                s += 2 * shared
            }
            let la = LinkMatch.loose(l.trackArtist.isEmpty ? l.artist : l.trackArtist), aa = LinkMatch.loose(l.artist)
            if !artist.isEmpty, la == artist || aa == artist { s += 2 }
            else if !artist.isEmpty, la.contains(artist) || artist.contains(la) || aa.contains(artist) || artist.contains(aa) { s += 1 }
            let lal = LinkMatch.core(l.album)
            if !album.isEmpty, lal == album { s += 1 } else if !album.isEmpty, !lal.isEmpty, lal.contains(album) || album.contains(lal) { s += 0.5 }
            if t.lengthMs > 0 && l.lengthMs > 0 {
                let d = abs(t.lengthMs - l.lengthMs)
                s += d < 3000 ? 1 : d < 10000 ? 0.3 : d > 30000 ? -1 : 0
            }
            return (l, s)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

enum LinkMatch {
    static func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The title without "(feat. …)", "[Live]", "- 2011 Remaster" and the like.
    static func core(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"(?i)\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        let c = loose(t)
        return c.isEmpty ? loose(s) : c
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }
}

/// Context-menu items for a streamed song: link it to a file, or undo the link.
struct LinkMenu: View {
    @EnvironmentObject var model: Model
    var track: OTTrack
    var body: some View {
        if model.linkedPath(track) != nil {
            Button("Change Linked Song…", systemImage: "link") { model.linking = track }
            Button("Unlink from Local Song", systemImage: "link.badge.minus") { model.unlink(track) }
        } else {
            Button("Link to Local Song…", systemImage: "link") { model.linking = track }
        }
    }
}

@MainActor
final class LinkState: ObservableObject {
    @Published var query = ""
    @Published var picked: LibTrack.ID?
}

struct LinkSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var s = LinkState()
    var track: OTTrack

    var results: [LibTrack] {
        let q = s.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.linkSuggestions(track) }
        let terms = q.lowercased().split(separator: " ").map(String.init)
        return Array(model.libTracks.filter { l in
            let hay = [l.title, l.artist, l.trackArtist, l.album].joined(separator: " ").lowercased()
            return terms.allSatisfy(hay.contains)
        }.prefix(200))
    }

    var body: some View {
        let rows = results, current = model.linkedPath(track)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CachedImage(url: model.artURL(track.artworkPath), seed: "Links.swift")
                    .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link “\(track.title)” to a song you have").font(.headline).lineLimit(1)
                    Text("\(track.artist) — \(track.album)\(track.lengthMs > 0 ? " · " + duration(track.lengthMs) : "")")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TextField("Search your songs", text: $s.query).textFieldStyle(.roundedBorder)
            List(rows, selection: $s.picked) { l in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.title).lineLimit(1)
                        Text("\(l.trackArtist.isEmpty ? l.artist : l.trackArtist) — \(l.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if l.path == current { Image(systemName: "link").foregroundStyle(.tint).help("Linked now") }
                    if l.lengthMs > 0 {
                        let d = (l.lengthMs - track.lengthMs) / 1000
                        Text(duration(l.lengthMs) + (track.lengthMs > 0 && abs(d) >= 2 ? " (\(d > 0 ? "+" : "")\(d)s)" : ""))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tag(l.id)
                .contentShape(.rect)
                .onTapGesture(count: 2) { model.link(track, to: l); dismiss() }
            }
            .frame(minHeight: 300)
            .overlay { if rows.isEmpty { ContentUnavailableView.search(text: s.query) } }
            HStack {
                if current != nil { Button("Unlink", role: .destructive) { model.unlink(track); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let l = model.libTracks.first(where: { $0.id == s.picked }) { model.link(track, to: l) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(s.picked == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear { s.picked = current ?? model.linkSuggestions(track, limit: 1).first?.id }
    }
}
