import SwiftUI
import AppKit

extension Model {
    // MARK: single songs

    // MARK: Hidden songs (Frogger's hide flag)
    //
    // A song is hidden from the iPod's Artists/Albums when you hid it yourself, or when it's only
    // in playlists you marked as hidden. Showing a song yourself wins over the playlists. Your choices are
    // kept in `hides`; the flags are written on Sync, so the playlists keep their own names. Older versions
    // marked them "~Name" or "Name ~": those still count as hidden and lose the mark at the next sync.

    static let hideMark = "~"

    func baseName(_ name: String) -> String {
        var n = name
        if n.hasPrefix(Self.hideMark) { n = String(n.dropFirst(Self.hideMark.count)).trimmingCharacters(in: .whitespaces) }
        else if n.hasSuffix(Self.hideMark) { n = String(n.dropLast(Self.hideMark.count)).trimmingCharacters(in: .whitespaces) }
        return n
    }

    func samePlaylist(_ a: String, _ b: String) -> Bool { baseName(a) == baseName(b) }

    /// A playlist you marked, or one already named with the mark (in Spotify, say) that you didn't unmark.
    func isHiddenPlaylist(_ name: String) -> Bool { podSettings.hiddenPlaylists[baseName(name)] ?? (baseName(name) != name) }

    /// The name a playlist gets on the iPod: without an old mark on the playlists you chose, as they were otherwise.
    func podName(forPlaylist name: String) -> String {
        podSettings.hiddenPlaylists[baseName(name)] == nil ? name : baseName(name)
    }

    func toggleHiddenPlaylist(_ name: String) {
        podSettings.hiddenPlaylists[baseName(name)] = !isHiddenPlaylist(name)
    }

    /// Keys of songs that are in a hidden playlist and in no other playlist, unless their whole album is on
    /// the iPod for another reason: an album you loaded keeps all its songs in Artists/Albums. An album
    /// that is only there because hidden playlists hold every song of it (a single, say) still hides.
    /// `tracks`: the iPod's tracks as they are at that moment (during a sync, already retagged: their keys are the
    /// new ones), by default the database Crate last read.
    func ruleHidden(_ lists: [PodPlaylist], tracks: [PodTrack]? = nil) -> Set<String> {
        let keyByID = Dictionary((tracks ?? db?.tracks ?? []).map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        var marked = Set<String>(), other = Set<String>()
        for p in lists {
            let keys = p.items.compactMap { keyByID[$0.trackID] }
            if isHiddenPlaylist(p.name) { marked.formUnion(keys) } else { other.formUnion(keys) }
        }
        var hidden = marked.subtracting(other)
        for a in albums where state(a) == .onIPod {
            let keys = a.tracks.map { podKey($0.key) }
            if !keys.allSatisfy(hidden.contains) { hidden.subtract(keys) }
        }
        return hidden
    }

    func wantsHidden(_ podKey: String, _ rule: Set<String>) -> Bool { hides[podKey] ?? rule.contains(podKey) }

    /// Whether a song on the iPod is (or will be, after the next sync) hidden from Artists/Albums.
    func isHidden(_ t: LibTrack) -> Bool { hiddenOnIPod.contains(podKey(t.key)) }

    /// The iPod keys of the songs Frogger hides from Artists/Albums after the next sync (a song renamed at that
    /// sync under both names). Kept until the database, the library or a hide choice changes: albums ask per tile.
    var hiddenOnIPod: Set<String> {
        if let c = hiddenCache { return c }
        let rule = podRule
        var s = Set<String>()
        for t in db?.tracks ?? [] where wantsHidden(t.key, rule) {
            s.insert(t.key)
            if let r = retags[t.key] { s.insert(r.key) }
        }
        hiddenCache = s
        return s
    }
    var podRule: Set<String> {
        if let r = ruleCache { return r }
        let r = ruleHidden(db?.playlists ?? [])
        ruleCache = r
        return r
    }

    /// How many of an album's songs on the iPod are hidden there, of how many on the iPod.
    func hiddenCount(_ a: Album) -> (hidden: Int, onIPod: Int) {
        let keys = a.tracks.map { podKey($0.key) }.filter(podKeys.contains), hidden = hiddenOnIPod
        return (keys.filter(hidden.contains).count, keys.count)
    }

    /// Hides or shows these songs' copies on the iPod at the next sync; songs not on the iPod are left alone.
    func setHidden(_ tracks: [LibTrack], _ on: Bool) {
        let rule = ruleHidden(db?.playlists ?? [])
        var h = hides
        for t in tracks {
            let k = podKey(t.key)
            guard podKeys.contains(t.key) || podKeys.contains(k) else { continue }
            h[k] = rule.contains(k) == on ? nil : on
        }
        hides = h
        objectWillChange.send()
    }

    /// Hide flags and playlist marks the next sync would change.
    var hidePending: Int {
        guard let db else { return 0 }
        let rule = podRule
        return db.tracks.filter { $0.hidden != wantsHidden($0.key, rule) }.count
            + db.playlists.filter { $0.name != podName(forPlaylist: $0.name) }.count
    }

    func songMark(_ t: LibTrack) -> SyncMark {
        if songsToAdd.contains(t.path) { return .adding }
        if songsToRemove.contains(podKey(t.key)) { return .removing }
        let a = album(of: t)
        if podKeys.contains(t.key) { return a.map { toRemove.contains($0.id) } == true ? .removing : .onIPod }
        return a.map { toAdd.contains($0.id) } == true ? .adding : .none
    }

    /// Queues one song for the iPod, or for removal from it (or takes it out of the queue again).
    func toggleSong(_ t: LibTrack) {
        if songsToAdd.contains(t.path) { songsToAdd.remove(t.path) }
        else if songsToRemove.contains(podKey(t.key)) { songsToRemove.remove(podKey(t.key)) }
        else if podKeys.contains(t.key) { songsToRemove.insert(podKey(t.key)) }
        else { songsToAdd.insert(t.path) }
    }
}
