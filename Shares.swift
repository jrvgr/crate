import SwiftUI
import NetFS

// The library lives on network shares (/Volumes/share, /Volumes/media from Home Assistant). When
// one isn't mounted, the sidebar says so and a Connect button mounts it the way Finder would
// (the keychain's password, or macOS asks), then reloads the library.

extension Model {
    /// Volume names of library folders whose share isn't mounted right now.
    var missingShares: [String] {
        let mounted = Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []).map(\.path))
        let names = libraryRoots.compactMap { f -> String? in
            let parts = f.split(separator: "/")
            guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
            return String(parts[1])
        }
        var seen = Set<String>()
        return names.filter { !mounted.contains("/Volumes/" + $0) && seen.insert($0).inserted }
    }
}

@MainActor
final class ShareUI: ObservableObject {
    @AppStorage("shareServer") var server = ""
    @Published var busy: Set<String> = []
    @Published var error: String?
    @Published var tick = 0                       // redraw when something mounts or unmounts

    /// Mounts smb://server/name under /Volumes; nil when it worked, else what went wrong.
    func connect(_ name: String) async -> String? {
        guard !server.isEmpty else { return "No file server set" }
        guard let url = URL(string: "smb://\(server)/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)") else { return "Bad share address" }
        busy.insert(name); defer { busy.remove(name) }
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            var request: AsyncRequestID?
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionAllowUI
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &request, .main) { status, _, _ in
                done.resume(returning: status == 0 ? nil : "Couldn't connect to \(url.absoluteString) (\(Self.describe(status)))")
            }
            if status != 0 { done.resume(returning: "Couldn't connect to \(url.absoluteString) (\(Self.describe(status)))") }
        }
    }

    nonisolated static func describe(_ status: Int32) -> String {
        switch status {
        case -128: return "cancelled"
        case Int32(ENOENT): return "no such share"
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM): return "not allowed; check the login"
        case Int32(EHOSTUNREACH), Int32(ETIMEDOUT), Int32(ENETUNREACH): return "server unreachable"
        default: return String(cString: strerror(status))
        }
    }
}

/// Sidebar notice for unmounted shares, with a Connect button each.
struct ShareNotice: View {
    @EnvironmentObject var model: Model
    @StateObject private var ui = ShareUI()

    var body: some View {
        let missing = model.missingShares
        let _ = ui.tick
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(missing, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.xmark").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("“\(name)” isn't connected").font(.caption.weight(.semibold)).lineLimit(1)
                            Text(ui.server).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if ui.busy.contains(name) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Connect") {
                                Task {
                                    ui.error = await ui.connect(name)
                                    ui.tick += 1
                                    if ui.error == nil { await model.reload() }
                                }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                            .help("Mount smb://\(ui.server)/\(name) and reload the library")
                        }
                    }
                }
                if let e = ui.error { Text(e).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in ui.tick += 1 }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in ui.tick += 1 }
        } else {
            // still notice a share going away
            Color.clear.frame(height: 0)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in ui.tick += 1 }
        }
    }
}
