import Foundation
import SwiftUI
import AppKit

// Frogger (github.com/jrvgr/frogger): patches for the 3rd gen iPod's firmware, loaded from the
// iPod's firmware partition at boot. Crate installs and removes it with Frogger's own
// tools/install.py, run as root through sudo (Crate asks for the password). Each run saves the whole firmware
// partition to Application Support/Crate/Frogger first. Holding Menu at boot always starts
// Apple's firmware, Frogger installed or not. Every run ends with install.py disk-status, so
// Crate shows what's on the partition rather than what it last did; Check runs only that.

enum Frogger {
    enum Action: Equatable { case install, remove, restore(URL), check }

    /// The Frogger checkout: its built loader and installer are used from there.
    static var checkout: URL {
        get {
            let path = UserDefaults.standard.string(forKey: "froggerCheckout") ?? "~/Projects/frogger"
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "froggerCheckout") }
    }
    static var installer: URL { checkout.appendingPathComponent("tools/install.py") }
    static var loader: URL { checkout.appendingPathComponent("build/loader/frogger-loader.bin") }
    static var backups: URL { PodCache.dir.appendingPathComponent("Frogger") }

    /// What's missing before Crate can install, or nil.
    static func problem(for ipod: IPodInfo?) -> String? {
        guard let ipod else { return "Connect the iPod" }
        guard ipod.modelName == "iPod (3rd generation)" else { return "Frogger is for the 3rd generation iPod only" }
        guard FileManager.default.fileExists(atPath: installer.path) else { return "No Frogger checkout at \(checkout.path)" }
        guard FileManager.default.fileExists(atPath: loader.path) else {
            return "Build the loader first: nix develop -c make -C loader (in \(checkout.path))"
        }
        return nil
    }

    /// Checking needs only the installer, not a built loader.
    static func canCheck(_ ipod: IPodInfo?) -> Bool {
        ipod?.modelName == "iPod (3rd generation)" && FileManager.default.fileExists(atPath: installer.path)
    }

    /// The state disk-status printed last in the installer's output ("stock" or "frogger (N byte loader)").
    static func state(in output: String) -> PodSettings.FroggerState? {
        for line in output.components(separatedBy: "\n").reversed() {
            if line == "stock" { return .removed }
            if line.hasPrefix("frogger (") { return .installed }
        }
        return nil
    }

    private static func diskutil(_ args: [String]) -> [String: Any]? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// ("/dev/disk6", "/dev/disk6s2"): the iPod's disk and its firmware partition. That's the
    /// Apple_MDFW partition on a Mac-formatted iPod and the first (type 0) one on a Windows-formatted one.
    static func devices(of mount: URL) -> (disk: String, firmware: String)? {
        guard let disk = diskutil(["info", "-plist", mount.path])?["ParentWholeDisk"] as? String, disk.hasPrefix("disk"),
              let all = diskutil(["list", "-plist", disk])?["AllDisksAndPartitions"] as? [[String: Any]],
              let parts = all.first?["Partitions"] as? [[String: Any]] else { return nil }
        let fw = parts.first { ($0["Content"] as? String) == "Apple_MDFW" }
            ?? parts.first.flatMap { ["", "0x0", "0x00", "0"].contains($0["Content"] as? String ?? "") ? $0 : nil }
        guard let id = fw?["DeviceIdentifier"] as? String else { return nil }
        return ("/dev/" + disk, "/dev/" + id)
    }

    /// Saved firmware partitions, newest first.
    static var savedBackups: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// "28 Oct 10:32, Apple's firmware" for a backup's file name.
    static func label(_ backup: URL) -> String {
        let parts = backup.deletingPathExtension().lastPathComponent.split(separator: "-")   // firmware-partition-YYYYMMDD-HHMMSS-state
        guard parts.count >= 5 else { return backup.lastPathComponent }
        let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"
        let date = f.date(from: String(parts[2] + parts[3])).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(parts[2])
        return date + (parts[4] == "stock" ? ", Apple's firmware" : ", with Frogger")
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The installer's command line for the firmware partition's raw device (or an image file).
    static func command(_ action: Action, raw: String) -> String {
        var args = [quote(installer.path)]
        switch action {
        case .install: args += ["disk-install", "--partition", quote(raw), quote(loader.path)]
        case .remove: args += ["disk-remove", "--partition", quote(raw)]
        case .restore(let backup): args += ["disk-restore", "--partition", quote(raw), quote(backup.path)]
        case .check: args += ["disk-status", "--partition", quote(raw)]
        }
        if action == .install || action == .remove { args += ["--backup-dir", quote(backups.path), "--owner", String(getuid())] }
        return "/usr/bin/python3 " + args.joined(separator: " ") + " 2>&1"
    }

    /// Unmounts the iPod, runs the installer as root on its raw disk, reads the partition's state and
    /// mounts it again (a check only reads, mounted). Returns the installer's output, or throws with it.
    static func run(_ action: Action, disk: String, firmware: String) async throws -> String {
        let raw = firmware.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let status = command(.check, raw: raw)
        let script = action == .check ? status
            : "/usr/sbin/diskutil unmountDisk \(quote(disk)) >/dev/null || exit 3; "
            + command(action, raw: raw) + "; rc=$?; " + status + "; "
            + "/usr/sbin/diskutil mountDisk \(quote(disk)) >/dev/null; exit $rc"
        return try await Root.run(script, why: "Frogger reads and writes the iPod's firmware partition as root (sudo).")
    }
}

extension Model {
    func runFrogger(_ action: Frogger.Action) async {
        guard let ipod, !syncing, froggerBusy == false else { return }
        guard let dev = Frogger.devices(of: ipod.mount) else { froggerMessage = "Couldn't find the iPod's firmware partition"; return }
        froggerBusy = true; froggerFailed = false; froggerRestart = nil
        defer { froggerBusy = false }
        switch action {
        case .check: froggerMessage = "Checking… (Crate asks for your password)"
        case .install: froggerMessage = "Installing… (Crate asks for your password)"
        case .remove: froggerMessage = "Removing… (Crate asks for your password)"
        case .restore: froggerMessage = "Restoring… (Crate asks for your password)"
        }
        do {
            let out = try await Frogger.run(action, disk: dev.disk, firmware: dev.firmware)
            if let s = Frogger.state(in: out) { podSettings.frogger = s }
            if action != .check { froggerRestart = action }
            // The action's own last line ("installed; backup at …"); a check leaves the state's text.
            froggerMessage = action == .check ? nil
                : out.components(separatedBy: "\n").last { Frogger.state(in: $0) == nil } ?? out
        } catch {
            froggerFailed = true
            // macOS keeps raw disks from apps without Full Disk Access, even running as root
            froggerMessage = error.localizedDescription.contains("Operation not permitted: '/dev/r")
                ? "macOS blocked reading the iPod's firmware partition. Give Crate Full Disk Access in System Settings › "
                  + "Privacy & Security, then restart Crate"
                : error.localizedDescription
        }
    }
}

/// The Frogger card on the iPod page.
struct FroggerSettings: View {
    @EnvironmentObject var model: Model      // @State can't be used (see README), so the question lives in the model
    @StateObject private var studio = CoverStudioUI()

    var body: some View {
        let confirm = model.froggerConfirm
        let problem = Frogger.problem(for: model.ipod)
        let installed = model.podSettings.frogger == .installed
        SettingsCard {
            HStack(spacing: 14) {
                FrogSticker(size: 30).frame(width: 34, height: 34)
                    .saturation(installed ? 1 : 0.15).opacity(installed ? 1 : 0.7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Frogger").font(.headline)
                        Text(installed ? "Installed" : model.podSettings.frogger == .removed ? "Not installed" : "Not checked")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(installed ? .green : .secondary)
                            .background((installed ? Color.green : Color.secondary).opacity(0.15), in: .capsule)
                    }
                    Text(detail(problem)).font(.callout)
                        .foregroundStyle(model.froggerFailed ? .red : problem != nil && model.froggerMessage == nil ? .orange : .secondary)
                    if model.froggerFailed, model.froggerMessage?.contains("Full Disk Access") == true {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .controlSize(.small)
                    }
                    if installed {
                        HStack(spacing: 6) {
                            ForEach([("eye.slash", "Hidden songs"), ("gearshape", "Show Hidden setting"),
                                     ("photo", "Now Playing covers"), ("music.mic", "Album artists")], id: \.1) { icon, name in
                                Label(name, systemImage: icon).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .glassEffect(.regular, in: .capsule)
                            }
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 12)
                if model.froggerBusy { ProgressView().controlSize(.small) }
                let busy = model.froggerBusy || model.syncing
                Button("Check") { Task { await model.runFrogger(.check) } }
                    .help("Reads the iPod's firmware partition to see whether Frogger is on it (Crate asks for your password)")
                    .disabled(!Frogger.canCheck(model.ipod) || busy)
                if installed {
                    Button("Update…") { model.froggerConfirm = .install }
                        .help("Writes the Frogger you last built over the one on the iPod")
                        .disabled(problem != nil || busy)
                } else {
                    Button("Install…") { model.froggerConfirm = .install }
                        .buttonStyle(.glassProminent)
                        .disabled(problem != nil || busy)
                }
                let saved = Frogger.savedBackups
                if installed || !saved.isEmpty {
                    Menu {
                        if installed {
                            Button("Remove Frogger…", systemImage: "arrow.uturn.backward") { model.froggerConfirm = .remove }
                                .disabled(problem != nil)
                        }
                        if !saved.isEmpty {
                            Menu("Restore a Backup") {
                                ForEach(saved, id: \.self) { b in Button(Frogger.label(b)) { model.froggerConfirm = .restore(b) } }
                            }
                            Button("Show Backups in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([saved[0]]) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                    .help("Remove Frogger, or put back a saved copy of the firmware")
                    .disabled(model.ipod == nil || busy)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if let done = model.froggerRestart {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart the iPod").font(.headline)
                        Text("Eject it, then hold Menu and Play until the Apple logo shows. "
                             + (done == .install ? "Its main menu says “Frogger!” instead of “Settings” when Frogger is running."
                                : "Its main menu says “Settings” again."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.connected { Button("Eject") { model.eject() }.controlSize(.small) }
                    Button { model.froggerRestart = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 14).padding(.bottom, 11)
            }
            Divider().padding(.leading, 50)
            SettingRow(icon: "photo", title: "Now Playing covers", detail: "How album covers look in four greys on Frogger's Now Playing page") {
                Button("Cover Studio…") { studio.open = true }
            }
        }
        .sheet(isPresented: $studio.open) { CoverStudio(ui: studio).environmentObject(model) }
        .alert(title(confirm), isPresented: Binding(get: { model.froggerConfirm != nil }, set: { if !$0 { model.froggerConfirm = nil } })) {
            Button(confirm == .install ? "Install" : confirm == .remove ? "Remove" : "Restore") {
                if let a = confirm { Task { await model.runFrogger(a) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirm == .remove
                 ? "Puts Apple's firmware back as it was. The iPod is unmounted for a moment, and Crate asks for your password."
                 : confirm != .install
                 ? "Writes this saved copy back over the iPod's whole firmware partition, exactly as it was then. The iPod is "
                   + "unmounted for a moment, and Crate asks for your password. Restart the iPod afterwards (hold Menu + Play)."
                 : "Writes Frogger's loader into the iPod's firmware partition. A copy of the partition is saved first, the iPod is "
                   + "unmounted for a moment, and Crate asks for your password. Hold Menu while the iPod starts to get Apple's "
                   + "firmware without Frogger. Restart the iPod afterwards (hold Menu + Play).")
        }
    }

    func title(_ a: Frogger.Action?) -> String {
        switch a {
        case .remove?: return "Remove Frogger?"
        case .restore(let b)?: return "Restore the firmware from \(Frogger.label(b))?"
        default: return "Install Frogger?"
        }
    }

    func detail(_ problem: String?) -> String {
        if let m = model.froggerMessage { return m }
        if let problem { return problem }
        switch model.podSettings.frogger {
        case .installed: return "Patches Apple's firmware 2.3; changes take effect after the iPod restarts"
        case .removed: return "Not installed; the iPod runs Apple's firmware"
        case .unknown: return "Patches for the iPod's firmware, like hidden songs. Check reads whether it's on this iPod. Backups go to Application Support › Crate › Frogger"
        }
    }
}
