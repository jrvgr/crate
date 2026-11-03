import SwiftUI
import AVFoundation

// Playback on this Mac (AVFoundation plays FLAC, MP3 and AAC), or on OwnTone's speakers when
// that's picked as the output. The mini player sits in the middle of the toolbar.

@MainActor
final class Player: ObservableObject {
    @AppStorage("playOn") var output = "mac"          // "mac" or "owntone"
    @Published var queue: [LibTrack] = []
    @Published var index = 0
    @Published var playing = false
    @Published var time = 0.0
    @Published var length = 0.0
    var current: LibTrack? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
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
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil); playing = false; queue = []; index = 0; time = 0 }

    // OwnTone's player, for when its speakers are the output
    static func ownTone(_ base: String, _ action: String) async {
        var r = URLRequest(url: URL(string: base + "/api/player/" + action)!); r.httpMethod = "PUT"
        _ = try? await URLSession.shared.data(for: r)
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

/// The toolbar's mini player: cover, song, position and the transport buttons.
struct MiniPlayer: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var player: Player

    var body: some View {
        let t = player.current
        HStack(spacing: 10) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }.disabled(t == nil)
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 16) }
                .disabled(t == nil)
            Button { player.next() } label: { Image(systemName: "forward.fill") }.disabled(t == nil || player.index + 1 >= player.queue.count)
            Group {
                if let t {
                    let album = model.albums.first { $0.id == t.album.lowercased() }
                    Cover(image: album.flatMap { model.artwork[$0.id] }, seed: t.album)
                        .frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 5))
                        .onTapGesture { if let album { model.search = ""; model.path = [.album(album)] } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(t.trackArtist.isEmpty ? t.artist : t.trackArtist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .help("\(duration(Int(player.time * 1000))) / \(duration(Int(player.length * 1000)))")
                        ProgressView(value: min(player.time, max(player.length, 0.01)), total: max(player.length, 0.01))
                            .progressViewStyle(.linear).controlSize(.mini)
                            .overlay { GeometryReader { g in Color.clear.contentShape(.rect).onTapGesture { p in player.seek(p.x / g.size.width * player.length) } } }
                    }
                    .frame(width: 150)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.tertiary).frame(width: 22, height: 22)
                    Text("Not playing").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
    }
}
