import SwiftUI

// Crate in the menu bar: the iPod (sync, eject), what's playing, and what's downloading.

struct MenuBarView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @EnvironmentObject var player: Player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let downloads = model.downloadEntries(slsk).filter { !$0.finished }
        VStack(alignment: .leading, spacing: 12) {
            // iPod
            HStack(spacing: 10) {
                Image.pod(model.ipod?.glyph, height: 24).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.ipod == nil ? "No iPod" : model.podName).font(.headline)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.connected {
                    Button { model.eject() } label: { Image(systemName: "eject.fill") }.buttonStyle(.borderless).disabled(model.syncing).help("Eject")
                }
            }
            if model.ipod != nil {
                CapacityBar(height: 6).opacity(model.connected ? 1 : 0.5)
                if model.syncing {
                    VStack(alignment: .leading, spacing: 4) {
                        SyncBar()
                        Text(model.syncCurrent.isEmpty ? model.syncPhase : model.syncCurrent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if model.pendingCount > 0 {
                    Button {
                        open(); model.reviewSync()
                    } label: { Label("Sync \(model.pendingCount) change\(model.pendingCount == 1 ? "" : "s")…", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).disabled(!model.connected)
                }
            }
            Divider()
            // playing
            if let t = player.current {
                HStack(spacing: 10) {
                    let album = model.albums.first { $0.id == t.album.lowercased() }
                    Cover(image: album.flatMap { model.artwork[$0.id] }, seed: t.album).frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(t.trackArtist.isEmpty ? t.artist : t.trackArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 14) }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.borderless)
                Divider()
            }
            // downloads
            if !downloads.isEmpty {
                Text("Downloading").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(downloads.prefix(4)) { d in
                    HStack(spacing: 8) {
                        Image(symbol: d.source.icon).foregroundStyle(d.source.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.title).font(.callout).lineLimit(1)
                            ProgressView(value: d.progress).controlSize(.mini)
                        }
                    }
                }
                if downloads.count > 4 { Text("and \(downloads.count - 4) more").font(.caption).foregroundStyle(.secondary) }
                Divider()
            }
            HStack {
                Button("Open Crate") { open() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }

    var status: String {
        guard let i = model.ipod, let db = model.db else { return "Connect it over USB" }
        if !model.connected { return "Not connected" + (model.pendingCount > 0 ? " · \(model.pendingCount) queued" : "") }
        return "\(db.tracks.count) songs · \(ByteCountFormatter.string(fromByteCount: i.free, countStyle: .file)) free"
    }

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.title != "" }) { w.makeKeyAndOrderFront(nil) }
        else { openWindow(id: "main") }
    }
}
