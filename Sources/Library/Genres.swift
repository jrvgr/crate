import SwiftUI

// Genre spellings that are the same genre ("Hip Hop", "Hip-Hop", "hip hop"; "Idm", "IDM"), merged into one
// spelling in the files' tags. Different genres ("Alternative Hip Hop") stay apart.

struct GenreGroup: Identifiable {
    var id: String                                   // the genre without case, spaces or punctuation
    var variants: [(name: String, songs: Int)]       // most songs first
    var keep: String
}

extension Model {
    nonisolated static func genreKey(_ g: String) -> String { g.lowercased().filter { $0.isLetter || $0.isNumber } }

    var genreGroups: [GenreGroup] {
        let cache = Subsonic.cache.path
        var counts: [String: Int] = [:]
        for t in libTracks where !t.genre.isEmpty && !t.path.hasPrefix(cache) { counts[t.genre, default: 0] += 1 }
        return Dictionary(grouping: counts.keys, by: Self.genreKey).compactMap { k, names in
            guard names.count > 1, !k.isEmpty else { return nil }
            let v = names.map { (name: $0, songs: counts[$0]!) }.sorted { $0.songs > $1.songs }
            // the most used spelling, unless it's all lower case and another isn't
            let keep = v.first { $0.name != $0.name.lowercased() }?.name ?? v[0].name
            return GenreGroup(id: k, variants: v, keep: keep)
        }
        .sorted { $0.keep.localizedStandardCompare($1.keep) == .orderedAscending }
    }

    /// Writes each group's kept spelling into the songs that have another one.
    func mergeGenres(_ groups: [GenreGroup]) async -> (files: Int, error: String?) {
        var rename: [String: String] = [:]
        for g in groups { for v in g.variants where v.name != g.keep { rename[v.name] = g.keep } }
        let tagr = viaTagr
        let tracks = libTracks.filter { rename[$0.genre] != nil && (Subsonic.serverOnly($0.path) ? tagr : TagWriter.canWrite($0.path)) }
        guard !tracks.isEmpty else { return (0, nil) }
        let r = await saveTags(tracks.map { (path: $0.path, edit: TagEdit(genre: rename[$0.genre]!)) })
        await refreshFiles(tracks.map(\.path).filter { !Subsonic.serverOnly($0) })
        return (r.written.count, r.failures.first)
    }
}

@MainActor
final class GenreSheetUI: ObservableObject {
    @Published var keep: [String: String] = [:]      // group → chosen spelling
    @Published var skip: Set<String> = []
    @Published var busy = false
    @Published var result: String?
}

struct GenreMergeSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = GenreSheetUI()

    var body: some View {
        let groups = model.genreGroups
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Genre Spellings").font(.title2.bold())
            Text("These are the same genre spelled differently. The spelling you pick is written into the other songs' tags.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if groups.isEmpty {
                ContentUnavailableView("Every genre has one spelling", systemImage: "checkmark.seal").frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { g in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(get: { !ui.skip.contains(g.id) },
                                                     set: { if $0 { ui.skip.remove(g.id) } else { ui.skip.insert(g.id) } }))
                                .labelsHidden()
                            Picker("Keep", selection: Binding(get: { ui.keep[g.id] ?? g.keep }, set: { ui.keep[g.id] = $0 })) {
                                ForEach(g.variants, id: \.name) { v in Text(v.name).tag(v.name) }
                            }
                            .labelsHidden().fixedSize()
                            Text(g.variants.map { "\($0.name) (\($0.songs))" }.joined(separator: ", "))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .disabled(ui.busy)
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                if ui.busy { ProgressView().controlSize(.small); Text("Writing tags…").foregroundStyle(.secondary) }
                else if let r = ui.result { Text(r).foregroundStyle(.secondary) }
                Spacer()
                Button(ui.result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                let picked = groups.filter { !ui.skip.contains($0.id) }.map { g in var g = g; g.keep = ui.keep[g.id] ?? g.keep; return g }
                Button("Merge \(picked.count)") {
                    ui.busy = true
                    Task {
                        let r = await model.mergeGenres(picked)
                        ui.busy = false
                        ui.result = "Tags written to \(r.files) files" + (r.error.map { " · \($0)" } ?? "")
                    }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || ui.busy)
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
    }
}
