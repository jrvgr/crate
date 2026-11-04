import SwiftUI

// Spotify albums you have no files for, matched on Soulseek one by one with the quality rules;
// you check the matches and download the ones you want.

@MainActor
final class MissingState: ObservableObject {
    struct Row: Identifiable {
        var id: String { album.uri }
        var album: SpotifyAlbum
        var include = false
        var state = ""
        var match: SlskFolder?
        var queued = false
    }
    @Published var rows: [Row] = []
    @Published var finding = false
    @Published var current = 0
    private var task: Task<Void, Never>?

    func find(_ slsk: Slskd, exactCounts: Bool) {
        task?.cancel()
        task = Task {
            finding = true; defer { finding = false }
            let todo = rows.indices.filter { rows[$0].include && rows[$0].match == nil && !rows[$0].queued }
            for (n, i) in todo.enumerated() {
                guard !Task.isCancelled else { return }
                current = n + 1
                let a = rows[i].album
                rows[i].state = "Searching…"
                do {
                    let q = (a.artist == "Various Artists" ? "" : a.artist + " ") + a.name
                    let folders = try await slsk.find(q)
                    rows[i].match = slsk.best(folders, album: a.name, songs: exactCounts ? a.trackCount : 0)
                    rows[i].state = rows[i].match == nil ? (folders.isEmpty ? "Not on Soulseek" : "\(folders.count) folders, none pass the quality rules") : ""
                    if rows[i].match == nil { rows[i].include = false }
                } catch { rows[i].state = error.localizedDescription }
            }
        }
    }

    func stop() { task?.cancel() }

    func download(_ slsk: Slskd) async -> Int {
        var n = 0
        for i in rows.indices where rows[i].include && !rows[i].queued {
            guard let m = rows[i].match else { continue }
            do { try await slsk.download(m); rows[i].queued = true; rows[i].state = "Downloading"; n += 1 }
            catch { rows[i].state = error.localizedDescription }
        }
        return n
    }
}

struct MissingAlbumsSheet: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @EnvironmentObject var spot: SpotifyAPI
    @Environment(\.dismiss) private var dismiss
    @StateObject private var s = MissingState()

    var body: some View {
        let picked = s.rows.filter(\.include).count
        let ready = s.rows.filter { $0.include && $0.match != nil && !$0.queued }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get Missing Albums").font(.title2.bold())
                    Text(s.finding ? "Searching Soulseek: \(s.current) of \(picked)… (about 15 s each)"
                         : "\(s.rows.count) saved Spotify albums you have no files for. Pick some, find them on Soulseek, check the matches, download.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                QualityMenu()
            }
            HStack {
                Button("Select All") { for i in s.rows.indices where !s.rows[i].queued { s.rows[i].include = true } }
                Button("Select None") { for i in s.rows.indices { s.rows[i].include = false } }
                Spacer()
            }
            .controlSize(.small).disabled(s.finding)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach($s.rows) { $r in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $r.include).labelsHidden().disabled(r.queued || s.finding)
                            CachedImage(url: model.artURL(r.album.artworkPath), seed: "Missing.swift:3")
                                .frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.album.name).font(.headline).lineLimit(1)
                                Text(r.album.artist + (r.album.year > 0 ? " · \(r.album.year)" : "")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let m = r.match {
                                    Text(m.name).font(.callout).lineLimit(1)
                                    Text([m.username, "\(m.audio.count) songs", m.formats, m.quality, m.freeSlot ? "free slot" : "queue \(m.queue)"]
                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if !r.state.isEmpty {
                                    Text(r.state).font(.caption).foregroundStyle(r.queued ? .green : .secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: 280, alignment: .trailing)
                            Button { model.findOnSoulseek(r.album.artist, r.album.name); dismiss() } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.glass).help("Search yourself on the Soulseek page")
                        }
                        .padding(8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    }
                }
            }
            HStack {
                if s.finding {
                    ProgressView().controlSize(.small)
                    Button("Stop") { s.stop() }
                }
                Spacer()
                Button("Close") { s.stop(); dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Find \(s.rows.filter { $0.include && $0.match == nil && !$0.queued }.count) on Soulseek") { s.find(slsk, exactCounts: spot.direct) }
                    .buttonStyle(.glass).disabled(s.finding || !s.rows.contains { $0.include && $0.match == nil && !$0.queued } || !slsk.configured)
                Button("Download \(ready)") {
                    Task { let n = await s.download(slsk); if n > 0 { model.notify("Downloading \(n) album\(n == 1 ? "" : "s") from Soulseek") } }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(ready == 0 || s.finding)
            }
        }
        .padding(22)
        .frame(width: 760, height: 620)
        .onAppear { s.rows = model.spotify.filter { !model.hasFiles($0) }.map { MissingState.Row(album: $0) } }
    }
}
