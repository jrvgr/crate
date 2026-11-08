import AppKit
import Combine
import MediaPlayer

/// The keyboard's media keys (play/pause, next, previous), headphone buttons and Control Center's Now Playing
/// drive Crate's player from anywhere: macOS sends them to the app that last told it what's playing, so Crate
/// keeps the system's Now Playing up to date (song, album art, where it is) and answers its commands.
/// Works the same for this Mac and a Music Assistant speaker, since both go through the Player.
@MainActor
final class NowPlaying {
    private unowned let player: Player
    private var subs: Set<AnyCancellable> = []
    private var shown: String?                        // the song Now Playing shows, so its art isn't set again every update
    private var artwork: MPMediaItemArtwork?
    private var artTask: Task<Void, Never>?
    private var elapsed = 0.0, stamp = Date()         // the last position sent, and when: the system counts on from there

    /// The album art for a library song, when there is some.
    var art: @MainActor (LibTrack) -> NSImage? = { _ in nil }

    init(_ player: Player) {
        self.player = player
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ act: @escaping @MainActor (Player) -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { [weak player] _ in
                guard player?.current != nil else { return .noActionableNowPlayingItem }
                DispatchQueue.main.async { if let player { act(player) } }
                return .success
            }
        }
        on(c.togglePlayPauseCommand) { $0.toggle() }
        on(c.playCommand) { if !$0.playing { $0.toggle() } }
        on(c.pauseCommand) { if $0.playing { $0.toggle() } }
        on(c.nextTrackCommand) { $0.next() }
        on(c.previousTrackCommand) { $0.previous() }
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak player] e in
            guard let player, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            DispatchQueue.main.async { player.seek(t) }
            return .success
        }
        for cmd in [c.stopCommand, c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand,
                    c.changeRepeatModeCommand, c.changeShuffleModeCommand, c.likeCommand, c.dislikeCommand, c.bookmarkCommand] {
            cmd.isEnabled = false
        }

        // after the change has landed (@Published sends before it does)
        Publishers.Merge4(player.$queue.map { _ in () }, player.$index.map { _ in () },
                          player.$playing.map { _ in () }, player.$length.map { _ in () })
            .merge(with: player.$remoteArt.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subs)
        // a seek (or a speaker that drifted): only when the position jumps from where the system would have it
        player.$time
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self, self.shown != nil else { return }
                let expected = self.elapsed + (self.player.playing ? Date().timeIntervalSince(self.stamp) : 0)
                if abs(t - expected) > 1.5 { self.update() }
            }
            .store(in: &subs)
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = player.current else {
            artTask?.cancel(); shown = nil; artwork = nil
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let key = "\(t.id)|\(t.title)|\(t.artist)|\(player.remoteArt?.absoluteString ?? "")"
        if key != shown { shown = key; loadArt(t) }
        elapsed = player.time; stamp = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.trackArtist.isEmpty ? t.artist : t.trackArtist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyAlbumArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: player.length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.time,
            MPNowPlayingInfoPropertyPlaybackRate: player.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: player.index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: player.queue.count,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = player.playing ? .playing : .paused
    }

    /// The library's cover, or the speaker's art (for songs that aren't in the library).
    private func loadArt(_ t: LibTrack) {
        artTask?.cancel()
        artwork = art(t).map(Self.artwork)
        guard artwork == nil, let url = player.remoteArt else { return }
        artTask = Task { [weak self] in
            guard let (d, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: d), !Task.isCancelled,
                  let self, self.player.remoteArt == url else { return }
            self.artwork = Self.artwork(img)
            self.update()
        }
    }

    private nonisolated static func artwork(_ img: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }
}
