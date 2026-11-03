import SwiftUI

// Deleting (to the Trash) and merging albums in the library.

extension Model {
    /// Moves the files to the Trash and takes them out of the library and the iPod queue.
    func trash(_ tracks: [LibTrack]) async {
        let paths = tracks.map(\.path)
        var failed = 0
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        for p in paths {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) } catch { failed += 1 }
        }
        // album folders left with only covers or nothing go too
        for f in folders {
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: f)) ?? []).filter { $0 != ".DS_Store" }
            if !left.contains(where: { LibraryLoader.audioExts.contains(($0 as NSString).pathExtension.lowercased()) }) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil)
            }
        }
        let gone = Set(paths)
        libTracks.removeAll { gone.contains($0.path) && !FileManager.default.fileExists(atPath: $0.path) }
        let ids = Set(albums.map(\.id))
        rebuild()
        toAdd = toAdd.filter { id in albums.contains { $0.id == id } || !ids.contains(id) }
        if on(.ownTone) { await ownToneRescan(ownToneURL) }
        notify("Moved \(paths.count - failed) file\(paths.count - failed == 1 ? "" : "s") to the Trash" + (failed > 0 ? ", \(failed) couldn't be moved" : ""))
    }
}

@MainActor
final class MergeState: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var oneFolder = true
    @Published var working = false
    @Published var error: String?
}

/// Merges albums into one: the same album title and album artist in every file, optionally one folder.
struct MergeSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var albums: [Album]
    @StateObject private var s = MergeState()

    var body: some View {
        let tracks = albums.flatMap(\.tracks)
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \(albums.count) Albums").font(.title2.bold())
            Text("All \(tracks.count) songs get the same album and album artist in their files, so they show up as one album (and go to the iPod as one).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(albums.prefix(6)) { a in
                    VStack(spacing: 4) {
                        Cover(image: model.artwork[a.id], seed: a.id).frame(width: 74, height: 74).clipShape(.rect(cornerRadius: 8))
                        Text(a.title).font(.caption).lineLimit(1).frame(width: 80)
                    }
                    .onTapGesture { s.title = a.title; s.artist = a.artist }
                    .help("Use this album's name")
                }
            }
            Form {
                Picker("Album", selection: $s.title) {
                    ForEach(Array(Set(albums.map(\.title))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("Album title", text: $s.title)
                Picker("Album artist", selection: $s.artist) {
                    ForEach(Array(Set(albums.map(\.artist))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("Album artist", text: $s.artist)
                Toggle("Move the files into one folder", isOn: $s.oneFolder)
            }
            .formStyle(.grouped)
            if let e = s.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack {
                if s.working { ProgressView().controlSize(.small); Text("Merging…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction).disabled(s.working)
                Button("Merge") { Task { await merge() } }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(s.working || s.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(s.working)
        .onAppear {
            let biggest = albums.max { $0.tracks.count < $1.tracks.count }
            s.title = biggest?.title ?? ""; s.artist = biggest?.artist ?? ""
        }
    }

    func merge() async {
        s.working = true; s.error = nil
        let tracks = albums.flatMap(\.tracks).filter { TagWriter.canWrite($0.path) }
        let e = TagEdit(albumArtist: s.artist, album: s.title)
        var failed: [String] = []
        for t in tracks {
            let p = t.path
            if let err = await Task.detached(operation: { () -> String? in
                do { try TagWriter.write(p, e); return nil } catch { return error.localizedDescription }
            }).value { failed.append(err) }
        }
        let wasAdding = albums.contains { model.toAdd.contains($0.id) }
        await model.refreshFiles(tracks.map(\.path), oldID: albums.first?.id)
        if wasAdding { model.toAdd.insert(s.title.lowercased()) }
        if s.oneFolder, let merged = model.albums.first(where: { $0.id == s.title.lowercased() }) {
            let roots = model.folders + [model.importFolder, (model.importFolder as NSString).deletingLastPathComponent]
            let moves = Organizer.plan([merged], roots: roots, withYear: false)
            let r = await Task.detached { Organizer.apply(moves) }.value
            await model.moved(r.done)
            failed += r.failed
        }
        s.working = false
        if failed.isEmpty { model.notify("Merged into “\(s.title)”"); dismiss() } else { s.error = "\(failed.count) failed: \(failed[0])" }
    }
}
