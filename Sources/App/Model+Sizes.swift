import SwiftUI
import AppKit

extension Model {
    // MARK: sizes

    /// What a song takes on the iPod: converted ones by length and bit rate, the rest by file size.
    func podSize(_ t: LibTrack) -> Int64 {
        if t.needsConversion { return Int64(t.lengthMs) * Int64(podSettings.aacKbps) / 8 }
        return fileSizes[t.path] ?? Int64(t.lengthMs) * 256 / 8
    }
    func podSize(_ a: Album) -> Int64 { a.tracks.reduce(0) { $0 + podSize($1) } }

    /// Roughly what the queued changes add (positive) or free up on the iPod.
    var queuedBytes: Int64 {
        if let c = syncCache.bytes { return c }
        let add = addWork(have: podKeys).reduce(Int64(0)) { $0 + podSize($1.1) }
        let keys = removalKeys
        let out = Int64((db?.tracks ?? []).filter { keys.contains($0.key) }.map(\.size).reduce(0, +))
        syncCache.bytes = add - out
        return add - out
    }

    func loadSizes() async {
        let paths = libTracks.map(\.path).filter { fileSizes[$0] == nil }
        guard !paths.isEmpty else { return }
        let found = await Task.detached { () -> [String: Int64] in
            var out: [String: Int64] = [:]
            for p in paths { if let n = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int { out[p] = Int64(n) } }
            return out
        }.value
        fileSizes.merge(found) { a, _ in a }
    }

    func estimateSizes() async {
        let work = addWork(have: podKeys).map(\.1), s = podSettings
        let bytes = await Task.detached { () -> Int64 in
            work.reduce(Int64(0)) { sum, t in
                if s.needsConversion(t) { return sum + Int64(t.lengthMs) * Int64(s.aacKbps) / 8 }
                return sum + Int64((try? FileManager.default.attributesOfItem(atPath: t.path))?[.size] as? Int ?? 0)
            }
        }.value
        plan?.bytesIn = bytes
    }

}
