import SwiftUI

// One overview of everything coming into the library, whatever plugin brings it: Soulseek
// folders from slskd and iTunes Match albums from Music. A new source only has to turn its
// downloads into DownloadEntry values.

struct DownloadEntry: Identifiable {
    struct File: Identifiable { var id: String { name }; var name, state: String; var ok, failed: Bool }
    var id: String
    var source: PluginID
    var title, subtitle, state: String
    var progress: Double
    var finished = false, failed = false, imported = false
    var image: NSImage?
    var artURL: URL?
    var date: Date?
    var files: [File] = []
    var cancel: (() -> Void)?
    var remove: (() -> Void)?
    var reimport: (() -> Void)?
}

enum DownloadFilter: String, CaseIterable { case all = "All", active = "In Progress", finished = "Finished" }

extension Model {
    func downloadEntries(_ slsk: Slskd) -> [DownloadEntry] {
        var out: [DownloadEntry] = []
        if on(.soulseek) {
            for j in slsk.jobs {
                let lib = albums.first { Self.looseMatch($0.title, j.name) }
                out.append(DownloadEntry(
                    id: "slsk:" + j.id, source: .soulseek, title: lib?.title ?? j.name,
                    subtitle: [lib?.artist ?? j.parent, "\(j.succeeded) of \(j.files.count) files", "from \(j.username)",
                               j.finished ? "" : ByteCountFormatter.string(fromByteCount: Int64(j.speed), countStyle: .file) + "/s"]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    state: j.stateText, progress: j.progress, finished: j.finished, failed: j.finished && j.succeeded == 0,
                    imported: slsk.imported.contains(j.id), image: lib.flatMap { artwork[$0.id] },
                    files: j.files.map { f in
                        .init(name: f.name, state: f.done ? f.state.replacingOccurrences(of: "Completed, ", with: "") : "\(Int(f.percent))%",
                              ok: f.succeeded, failed: f.failed)
                    },
                    cancel: j.finished ? nil : { Task { await slsk.cancel(j, remove: false) } },
                    remove: { Task { await slsk.cancel(j, remove: true) } },
                    reimport: j.finished && j.succeeded > 0 ? { [weak self] in
                        slsk.markImported(j); Task { await self?.importDownloaded(j, folder: slsk.localFolder(j)) }
                    } : nil))
            }
        }
        if on(.youtube) {
            for j in yt.jobs {
                let failed = j.items.filter(\.failed).count, done = j.items.filter(\.done).count
                out.append(DownloadEntry(
                    id: "yt:" + j.id.uuidString, source: .youtube, title: j.title,
                    subtitle: [j.subtitle, "\(done) of \(j.items.count) songs"].filter { !$0.isEmpty }.joined(separator: " · "),
                    state: j.finished ? (failed == 0 ? "Done" : "\(failed) not found") : (j.items.first { !$0.done && !$0.failed }?.state ?? ""),
                    progress: j.progress, finished: j.finished, failed: j.finished && done == 0, imported: j.finished && done > 0,
                    artURL: URL(string: j.art), date: j.started,
                    files: j.items.map { .init(name: "\($0.artist) – \($0.title)", state: $0.done ? "Done" : $0.failed ? $0.state : $0.progress > 0 ? "\(Int($0.progress * 100))%" : $0.state, ok: $0.done, failed: $0.failed) },
                    remove: j.finished ? { [weak self] in self?.yt.remove(j.id) } : nil))
            }
        }
        for j in jobs where j.source == .appleMusic {
            let failed: Bool = { if case .failed = j.state { return true }; return false }()
            out.append(DownloadEntry(
                id: "am:" + j.id.uuidString, source: .appleMusic, title: j.title, subtitle: j.subtitle,
                state: j.state == .queued ? "Waiting" : j.detail, progress: j.progress ?? (j.active ? 0 : 1),
                finished: !j.active, failed: failed, imported: j.state == .done,
                image: albums.first { $0.id == j.title.lowercased() }.flatMap { artwork[$0.id] },
                artURL: j.art ?? amArt[j.title.lowercased()], date: j.started,
                remove: j.active ? nil : { [weak self] in self?.jobs.removeAll { $0.id == j.id } }))
        }
        return out
    }

    static func looseMatch(_ a: String, _ b: String) -> Bool {
        let l = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let x = l(a), y = l(b)
        return !x.isEmpty && (x == y || (y.count > 4 && y.contains(x)))
    }
}

@MainActor
final class DownloadsUI: ObservableObject {
    @Published var filter = DownloadFilter.all
    @Published var source: PluginID?
    @Published var expanded: Set<String> = []
}

struct DownloadsView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @StateObject private var ui = DownloadsUI()

    var sources: [PluginID] { [.soulseek, .appleMusic, .youtube].filter { model.on($0) } }

    var body: some View {
        let all = model.downloadEntries(slsk)
        let shown = all.filter { e in
            (ui.source == nil || e.source == ui.source)
                && (ui.filter == .all || (ui.filter == .active ? !e.finished : e.finished))
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(all)
                HStack {
                    Picker("", selection: $ui.filter) {
                        ForEach(DownloadFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Picker("Source", selection: $ui.source) {
                        Text("All Sources").tag(PluginID?.none)
                        ForEach(sources) { Label($0.name, systemImage: $0.icon).tag(PluginID?.some($0)) }
                    }
                    .fixedSize()
                }
                if shown.isEmpty {
                    ContentUnavailableView(all.isEmpty ? "Nothing downloading" : "Nothing here", systemImage: "tray",
                                           description: Text(sources.isEmpty ? "Turn on Soulseek or Apple Music in Settings › Plugins."
                                                             : "Download from Soulseek or import from Apple Music; everything shows up here."))
                        .padding(.top, 50)
                }
                let active = shown.filter { !$0.finished }, done = shown.filter(\.finished)
                if !active.isEmpty {
                    SectionTitle(text: "In Progress", count: active.count)
                    ForEach(active) { DownloadCard(entry: $0, ui: ui) }
                }
                if !done.isEmpty {
                    SectionTitle(text: "Finished", count: done.count)
                    ForEach(done) { DownloadCard(entry: $0, ui: ui) }
                }
            }
            .padding(24).padding(.bottom, 50)
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem {
                Menu {
                    if model.on(.soulseek) {
                        Button("Clear Finished Soulseek Downloads") { Task { await slsk.clearFinished() } }
                    }
                    Button("Clear Finished Apple Music Imports") { model.jobs.removeAll { $0.source == .appleMusic && !$0.active } }
                    if model.on(.youtube) { Button("Clear Finished YouTube Downloads") { model.yt.jobs.removeAll(where: \.finished) } }
                } label: { Label("Clear", systemImage: "checkmark.circle") }
                .help("Remove finished downloads from the list")
            }
        }
        .task { await slsk.refreshDownloads() }
    }

    func header(_ all: [DownloadEntry]) -> some View {
        let active = all.filter { !$0.finished }
        return HStack(spacing: 16) {
            Image(systemName: active.isEmpty ? "arrow.down.circle" : "arrow.down.circle.dotted")
                .font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: !active.isEmpty)
            VStack(alignment: .leading, spacing: 3) {
                Text(active.isEmpty ? "All caught up" : "Downloading \(active.count) album\(active.count == 1 ? "" : "s")").font(.title2.bold())
                Text(sources.map { s in
                    let n = active.filter { $0.source == s }.count
                    if s == .soulseek { return "Soulseek: " + (slsk.error != nil ? "unreachable" : n > 0 ? "\(n) active" : slsk.configured ? "idle" : "not set up") }
                    return "\(s.name): " + (n > 0 ? "\(n) active" : "idle")
                }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.on(.soulseek) {
                Button("Search Soulseek", systemImage: "magnifyingglass") { model.pane = .soulseek }.buttonStyle(.glass)
            }
            if model.on(.appleMusic) {
                Button("Apple Music", systemImage: "icloud") { model.pane = .appleMusic }.buttonStyle(.glass)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct SectionTitle: View {
    var text: String
    var count: Int?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.title3.bold())
            if let count { Text("\(count)").font(.callout).foregroundStyle(.secondary) }
        }
        .padding(.top, 6)
    }
}

struct DownloadCard: View {
    var entry: DownloadEntry
    @ObservedObject var ui: DownloadsUI

    var body: some View {
        let open = ui.expanded.contains(entry.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Group {
                    if let img = entry.image { Image(nsImage: img).resizable().scaledToFill() }
                    else if let u = entry.artURL { CachedImage(url: u, seed: "Downloads.swift:10") }
                    else { Cover(image: nil, seed: entry.title) }
                }
                .frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: entry.source.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(entry.source.tint, in: .circle)
                        .offset(x: 5, y: 5).help(entry.source.name)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text(entry.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        if !entry.finished {
                            ProgressView(value: entry.progress).frame(width: 160)
                        }
                        Label(entry.state, systemImage: entry.failed ? "exclamationmark.triangle.fill"
                              : entry.finished ? (entry.imported ? "checkmark.circle.fill" : "checkmark.circle") : "arrow.down")
                            .font(.caption).foregroundStyle(entry.failed ? .red : entry.finished ? .green : .secondary)
                            .lineLimit(1)
                        if entry.finished, entry.imported, entry.source == .soulseek {
                            Text("· in library").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if let r = entry.reimport {
                    Button(entry.imported ? "Import Again" : "Import", systemImage: "square.and.arrow.down", action: r).buttonStyle(.glass)
                }
                if let c = entry.cancel {
                    Button(action: c) { Image(systemName: "xmark") }.buttonStyle(.glass).help("Cancel")
                }
                if let r = entry.remove {
                    Button(action: r) { Image(systemName: "trash") }.buttonStyle(.glass).help("Remove from the list (files stay)")
                }
                if !entry.files.isEmpty {
                    Button {
                        withAnimation(.snappy) { if open { ui.expanded.remove(entry.id) } else { ui.expanded.insert(entry.id) } }
                    } label: {
                        Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).frame(width: 18)
                    }
                    .buttonStyle(.glass).help(open ? "Hide files" : "Show files")
                }
            }
            .padding(12)
            if open {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(entry.files) { f in
                        HStack(spacing: 10) {
                            Image(systemName: f.ok ? "checkmark.circle.fill" : f.failed ? "xmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(f.ok ? .green : f.failed ? .red : .secondary)
                            Text(f.name).lineLimit(1)
                            Spacer()
                            Text(f.state).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout).padding(.horizontal, 16).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 8).padding(.leading, 70)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
