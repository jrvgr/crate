import SwiftUI
import AVFoundation

// Playback on this Mac (AVFoundation plays FLAC, MP3 and AAC; a Subsonic song that isn't downloaded
// streams from the server), or on a Music Assistant player when one is picked as the output: then the
// queue goes to MA and the controls drive it, while Crate reads MA's position back to show it.
// The iPod drawn in the sidebar card is the player: its buttons and wheel are the controls.

@MainActor
final class Player: ObservableObject {
    @AppStorage("playOn") var output = "mac"          // "mac", "owntone" or "ma:<player id>"
    @Published var queue: [LibTrack] = []
    @Published var index = 0
    @Published var playing = false
    @Published var time = 0.0
    @Published var length = 0.0
    @Published var volume = 1.0 { didSet { if remoteQueue == nil { player.volume = Float(volume) } } }
    var current: LibTrack? { queue.indices.contains(index) ? queue[index] : nil }
    /// Where a song without a file on this Mac streams from (a Subsonic server's), if anywhere.
    var stream: @MainActor (LibTrack) -> URL? = { _ in nil }
    /// The Music Assistant player picked as the output (when that plugin is on), and a song's URI for it.
    var remote: @MainActor () -> (MusicAssistant, String)? = { nil }
    var remoteURI: @MainActor (LibTrack) -> String? = { _ in nil }
    var onRemoteError: @MainActor (String) -> Void = { _ in }
    private var remoteQueue: String?                  // the MA queue Crate started, while it shows it
    private var ma: MusicAssistant?
    private var poll: Task<Void, Never>?
    private var volumeSend: Task<Void, Never>?

    private let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self, self.remoteQueue == nil else { return }
                // while a seek is under way the player still reports the old spot; keep the target
                if self.seeks == 0 { self.time = t.seconds.isFinite ? t.seconds : 0 }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.length = d }
                self.playing = self.player.rate > 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    func play(_ tracks: [LibTrack], from start: Int = 0) {
        if let (ma, q) = remote() { playRemote(Array(tracks.dropFirst(start)), ma: ma, queue: q); return }
        endRemote()
        let playable = tracks.filter { FileManager.default.fileExists(atPath: $0.path) || stream($0) != nil }
        guard !playable.isEmpty else { return }
        queue = playable
        index = min(max(0, playable.firstIndex { $0.id == tracks[safe: start]?.id } ?? 0), playable.count - 1)
        load()
    }

    private func load() {
        guard let t = current else { stop(); return }
        let url = FileManager.default.fileExists(atPath: t.path) ? URL(fileURLWithPath: t.path) : stream(t) ?? URL(fileURLWithPath: t.path)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        time = 0; length = Double(t.lengthMs) / 1000
        player.play(); playing = true
    }

    func toggle() {
        guard current != nil else { return }
        if let q = remoteQueue { playing.toggle(); Task { await ma?.command("play_pause", q) }; return }
        if player.rate > 0 { player.pause(); playing = false } else { player.play(); playing = true }
    }
    func next() {
        if let q = remoteQueue { Task { await ma?.command("next", q) }; return }
        if index + 1 < queue.count { index += 1; load() } else { stop() } }
    func previous() {
        if let q = remoteQueue { Task { await ma?.command("previous", q) }; return }
        if time > 3 || index == 0 { player.seek(to: .zero) } else { index -= 1; load() }
    }
    private var seeks = 0                               // seeks still in flight
    func seek(_ seconds: Double) {
        time = seconds
        if let q = remoteQueue { Task { await ma?.command("seek", q, ["position": Int(seconds)]) }; return }
        seeks += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeks -= 1 }
        }
    }
    func stop() { endRemote(); player.pause(); player.replaceCurrentItem(with: nil); playing = false; queue = []; index = 0; time = 0 }

    // MARK: Music Assistant

    private func playRemote(_ tracks: [LibTrack], ma: MusicAssistant, queue q: String) {
        let pairs = tracks.compactMap { t in remoteURI(t).map { (t, $0) } }
        guard !pairs.isEmpty else { onRemoteError("These songs aren't on the Subsonic server yet, so \(ma.name(q)) can't play them"); return }
        player.pause(); player.replaceCurrentItem(with: nil)
        self.ma = ma; remoteQueue = q
        queue = pairs.map(\.0); index = 0; time = 0; length = Double(pairs[0].0.lengthMs) / 1000; playing = true
        Task {
            do { try await ma.play(pairs.map(\.1), on: q) }
            catch { onRemoteError(error.localizedDescription); endRemote(); queue = []; playing = false; return }
            follow()
        }
    }

    /// Plays URIs that aren't library songs (a Spotify album or playlist) on the picked MA player; nothing to show.
    func playRemote(uris: [String]) async -> Bool {
        guard let (ma, q) = remote() else { return false }
        do { try await ma.play(uris, on: q) } catch { onRemoteError(error.localizedDescription); return true }
        stop()
        return true
    }

    /// Reads MA's queue about once a second, until it's replaced elsewhere or stops at the end.
    private func follow() {
        poll?.cancel()
        poll = Task { [weak self] in
            var settled = false                      // MA's queue still shows the old one for a moment
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let q = self.remoteQueue, let ma = self.ma, let s = await ma.state(q), !Task.isCancelled else { return }
                if s.items != self.queue.count { if settled { self.endRemote(); self.queue = []; self.playing = false; return }; continue }
                settled = true
                self.index = min(s.index, self.queue.count - 1)
                if self.seeks == 0 { self.time = s.elapsed }
                self.length = s.duration > 0 ? s.duration : Double(self.queue[self.index].lengthMs) / 1000
                self.playing = s.playing
                if let v = s.volume, self.volumeSend == nil { self.volume = v }
            }
        }
    }

    private func endRemote() { poll?.cancel(); poll = nil; remoteQueue = nil }

    /// The wheel's volume: on MA, sent once it stops moving for a moment.
    func setVolume(_ v: Double) {
        volume = v
        guard let q = remoteQueue, let ma else { return }
        volumeSend?.cancel()
        volumeSend = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await ma.setVolume(v, on: q)
            self?.volumeSend = nil
        }
    }

    // OwnTone's player, for when its speakers are the output
    static func ownTone(_ base: String, _ action: String) async {
        var r = URLRequest(url: URL(string: base + "/api/player/" + action)!); r.httpMethod = "PUT"
        _ = try? await URLSession.shared.data(for: r)
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
