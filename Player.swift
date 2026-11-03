import SwiftUI
import AVFoundation

// Playback on this Mac (AVFoundation plays FLAC, MP3 and AAC), or on OwnTone's speakers when
// that's picked as the output. The iPod drawn in the sidebar card is the player: its buttons and wheel are the controls.

@MainActor
final class Player: ObservableObject {
    @AppStorage("playOn") var output = "mac"          // "mac" or "owntone"
    @Published var queue: [LibTrack] = []
    @Published var index = 0
    @Published var playing = false
    @Published var time = 0.0
    @Published var length = 0.0
    @Published var volume = 1.0 { didSet { player.volume = Float(volume) } }
    var current: LibTrack? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
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
        let playable = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !playable.isEmpty else { return }
        queue = playable
        index = min(max(0, playable.firstIndex { $0.id == tracks[safe: start]?.id } ?? 0), playable.count - 1)
        load()
    }

    private func load() {
        guard let t = current else { stop(); return }
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: t.path)))
        time = 0; length = Double(t.lengthMs) / 1000
        player.play(); playing = true
    }

    func toggle() {
        guard current != nil else { return }
        if player.rate > 0 { player.pause(); playing = false } else { player.play(); playing = true }
    }
    func next() { if index + 1 < queue.count { index += 1; load() } else { stop() } }
    func previous() {
        if time > 3 || index == 0 { player.seek(to: .zero) } else { index -= 1; load() }
    }
    private var seeks = 0                               // seeks still in flight
    func seek(_ seconds: Double) {
        time = seconds
        seeks += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeks -= 1 }
        }
    }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil); playing = false; queue = []; index = 0; time = 0 }

    // OwnTone's player, for when its speakers are the output
    static func ownTone(_ base: String, _ action: String) async {
        var r = URLRequest(url: URL(string: base + "/api/player/" + action)!); r.httpMethod = "PUT"
        _ = try? await URLSession.shared.data(for: r)
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
