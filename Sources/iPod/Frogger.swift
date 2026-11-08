import Foundation
import SwiftUI
import AppKit

// Frogger (github.com/jrvgr/frogger): patches for the 3rd gen iPod's firmware, loaded from the
// iPod's firmware partition at boot. Crate installs and removes it with Frogger's own
// tools/install.py, run as root through sudo (Crate asks for the password). Each run saves the whole firmware
// partition to Application Support/Crate/Frogger first. Holding Menu at boot always starts
// Apple's firmware, Frogger installed or not. Every run ends with install.py disk-status, so
// Crate shows what's on the partition rather than what it last did; Check runs only that. The loader and
// install.py come from Frogger's newest GitHub release, or a local checkout (FroggerRelease.swift).

enum Frogger {
    enum Action: Equatable { case install, remove, restore(URL), check }

    /// A local Frogger checkout (Settings › Frogger › Use a local Frogger checkout): its built loader and installer.
    static var useCheckout: Bool { UserDefaults.standard.bool(forKey: "froggerUseCheckout") }
    static var checkout: URL {
        get {
            let path = UserDefaults.standard.string(forKey: "froggerCheckout") ?? "~/Projects/frogger"
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "froggerCheckout") }
    }
    /// Otherwise the downloaded release's folder (see FroggerSource), nil before the first download.
    static var release: URL? { UserDefaults.standard.string(forKey: "froggerRelease").map(FroggerSource.dir) }
    static var installer: URL {
        useCheckout ? checkout.appendingPathComponent("tools/install.py") : (release ?? backups).appendingPathComponent("install.py")
    }
    static var loader: URL {
        useCheckout ? checkout.appendingPathComponent("build/loader/frogger-loader.bin")
            : (release ?? backups).appendingPathComponent(UserDefaults.standard.bool(forKey: "froggerDebug") ? "frogger-loader-debug.bin" : "frogger-loader.bin")
    }
    static var backups: URL { PodCache.dir.appendingPathComponent("Frogger") }

    /// What's missing before Crate can install, or nil.
    @MainActor static func problem(for ipod: IPodInfo?) -> String? {
        guard let ipod else { return "Connect the iPod" }
        guard ipod.modelName == "iPod (3rd generation)" else { return "Frogger is for the 3rd generation iPod only" }
        if !useCheckout { return releaseProblem }
        guard FileManager.default.fileExists(atPath: installer.path) else { return "No Frogger checkout at \(checkout.path)" }
        guard FileManager.default.fileExists(atPath: loader.path) else {
            return "Build the loader first: nix develop -c make -C loader (in \(checkout.path))"
        }
        return nil
    }

    /// Why the downloaded release can't be used yet, or nil.
    @MainActor private static var releaseProblem: String? {
        let source = FroggerSource.shared
        guard let tag = source.tag else {
            return source.checking ? "Downloading Frogger from GitHub…" : source.error ?? "Frogger isn't downloaded yet (Settings › Frogger)"
        }
        guard FileManager.default.fileExists(atPath: loader.path) else { return "Frogger \(tag) has no \(loader.lastPathComponent)" }
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

/// Frogger's switches (its Settings rows), kept as bits of Apple's prefs flags word. Apple saves its
/// prefs struct to iPod_Control/Device/Preferences from prefs+8, so the word (prefs+0xb04) is the
/// little-endian u32 at file offset 0xafc (Frogger's docs/tcmd.md, "On the disk"). The iPod reads the
/// file when it starts, so a change made here in disk mode applies from its next start.
enum FroggerSwitch: Int, CaseIterable, Identifiable {
    case coverPage, holdMenu, quickSettings, batteryPercent, pageSlide, lockCover, jumpByLetter, resumeMixes, showHidden
    var id: Int { rawValue }

    /// Frogger's payload/settings.h: FROGGER_PREF_FEATURE(f) is bit 19 + f for the first five switches, 27 for
    /// the sixth (24-26 hold the backlight timer, 28-29 Flash Storage).
    var bit: UInt32 {
        switch self {
        case .showHidden: 16
        case .jumpByLetter: 17
        case .resumeMixes: 18
        case .lockCover: 27                       // FEATURE_LOCK
        default: UInt32(19 + rawValue)            // FEATURE_COVER … FEATURE_SLIDE
        }
    }
    /// Show Hidden's bit means On; the others' mean Off (they're on by default).
    var setMeansOn: Bool { self == .showHidden }

    var title: String {
        switch self {
        case .coverPage: "Cover Page"
        case .holdMenu: "Hold Menu"
        case .quickSettings: "Quick Settings"
        case .batteryPercent: "Battery Percent"
        case .pageSlide: "Page Slide"
        case .lockCover: "Lock Cover"
        case .jumpByLetter: "Jump by Letter"
        case .resumeMixes: "Resume Mixes"
        case .showHidden: "Show Hidden"
        }
    }
    var detail: String {
        switch self {
        case .coverPage: "Now Playing opens on a page with the cover and the progress bar"
        case .holdMenu: "Hold Select on a song, album, artist or playlist: queue, play next, add to a playlist, hide"
        case .quickSettings: "Hold Menu anywhere: Backlight, Shuffle, Repeat, Sleep"
        case .batteryPercent: "The battery percentage in the title bar"
        case .pageSlide: "The cover page slides to Apple's Now Playing and back"
        case .lockCover: "With Hold on while a song plays or is paused: its cover large, the title and the progress bar"
        case .jumpByLetter: "Spin the wheel fast in a long list to move a letter at a time"
        case .resumeMixes: "Songs of 20 minutes or longer start where you left them"
        case .showHidden: "Hidden songs show in Artists, Albums, Genres and Composers again"
        }
    }
    var icon: String {
        switch self {
        case .coverPage: "photo"
        case .holdMenu: "hand.tap"
        case .quickSettings: "slider.horizontal.3"
        case .batteryPercent: "battery.75percent"
        case .pageSlide: "rectangle.portrait.and.arrow.right"
        case .lockCover: "lock"
        case .jumpByLetter: "textformat.abc"
        case .resumeMixes: "bookmark"
        case .showHidden: "eye"
        }
    }

    func isOn(_ flags: UInt32) -> Bool { (flags >> bit & 1 == 1) == setMeansOn }
    func set(_ on: Bool, in flags: UInt32) -> UInt32 { on == setMeansOn ? flags | 1 << bit : flags & ~(1 << bit) }
}

/// Frogger's Flash Storage (after the switches in its Settings): a flash mod's disk goes to standby 1 s after its
/// last use instead of Apple's 2-15 s. Auto does that only when the drive says it's flash. Prefs bits 28-29.
enum FroggerFlash: UInt32, CaseIterable, Identifiable {
    case off = 0, auto = 1, on = 2
    var id: UInt32 { rawValue }
    var title: String { switch self { case .off: "Off"; case .auto: "Auto"; case .on: "On" } }
    static let shift: UInt32 = 28
    static func get(_ flags: UInt32) -> FroggerFlash { FroggerFlash(rawValue: flags >> shift & 3) ?? .off }
    func set(in flags: UInt32) -> UInt32 { flags & ~(3 << Self.shift) | rawValue << Self.shift }
}

/// The click wheel's click: Apple's Clicker (prefs bit 0, set: On) and, when on, where Frogger plays it, bits 30-31
/// (FROGGER_PREF_CLICK_IN: 0 Speaker, 1 Headphones, 2 Both). Off is only bit 0 clear; where it played is kept.
enum FroggerClicker: Int, CaseIterable, Identifiable {
    case off, speaker, headphones, both
    var id: Int { rawValue }
    var title: String { switch self { case .off: "Off"; case .speaker: "Speaker"; case .headphones: "Headphones"; case .both: "Both" } }
    static let shift: UInt32 = 30
    static func get(_ flags: UInt32) -> FroggerClicker {
        guard flags & 1 == 1 else { return .off }
        return FroggerClicker(rawValue: Int(flags >> shift & 3) + 1) ?? .speaker
    }
    func set(in flags: UInt32) -> UInt32 {
        if self == .off { return flags & ~1 }
        return flags & ~(3 << Self.shift) | UInt32(rawValue - 1) << Self.shift | 1
    }
}

/// Frogger's Click Volume: how loud the click is in the headphones. Prefs bits 14-15 (FROGGER_PREF_CLICK_VOL).
enum FroggerClickVolume: UInt32, CaseIterable, Identifiable {
    case quiet = 0, medium = 1, loud = 2
    var id: UInt32 { rawValue }
    var title: String { switch self { case .quiet: "Quiet"; case .medium: "Medium"; case .loud: "Loud" } }
    static let shift: UInt32 = 14
    static func get(_ flags: UInt32) -> FroggerClickVolume { FroggerClickVolume(rawValue: flags >> shift & 3) ?? .quiet }
    func set(in flags: UInt32) -> UInt32 { flags & ~(3 << Self.shift) | rawValue << Self.shift }
}

enum FroggerPrefs {
    static let offset = 0xafc
    static let size = 2872                   // firmware 2.3's file; anything else isn't the layout we know

    static func url(_ ipod: IPodInfo) -> URL { ipod.control.appendingPathComponent("Device/Preferences") }

    static func flags(_ ipod: IPodInfo) -> UInt32? {
        guard let d = try? Data(contentsOf: url(ipod)), d.count == size else { return nil }
        return d[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    /// Changes only the flags word; every other byte stays as the iPod wrote it.
    static func write(_ flags: UInt32, to ipod: IPodInfo) throws {
        var d = try Data(contentsOf: url(ipod))
        guard d.count == size else { throw SyncError.missingSource("a Preferences file of the size Frogger's layout is known for") }
        for i in 0..<4 { d[offset + i] = UInt8(flags >> (8 * UInt32(i)) & 0xff) }
        try d.write(to: url(ipod))
    }
}

@MainActor
final class FroggerSwitchesUI: ObservableObject {
    @Published var flags: UInt32?
    @Published var error: String?
    @Published var changed = false              // written since the iPod last started

    func load(_ ipod: IPodInfo?, connected: Bool) {
        flags = connected ? ipod.flatMap(FroggerPrefs.flags) : nil
    }

    func set(_ s: FroggerSwitch, _ on: Bool, ipod: IPodInfo) {
        guard let f = flags else { return }
        write(s.set(on, in: f), ipod: ipod)
    }

    func set(_ flash: FroggerFlash, ipod: IPodInfo) {
        guard let f = flags else { return }
        write(flash.set(in: f), ipod: ipod)
    }

    func set(_ click: FroggerClicker, ipod: IPodInfo) {
        guard let f = flags else { return }
        write(click.set(in: f), ipod: ipod)
    }

    func set(_ volume: FroggerClickVolume, ipod: IPodInfo) {
        guard let f = flags else { return }
        write(volume.set(in: f), ipod: ipod)
    }

    private func write(_ new: UInt32, ipod: IPodInfo) {
        do { try FroggerPrefs.write(new, to: ipod); flags = new; changed = true; error = nil }
        catch { self.error = "Couldn't change the iPod's settings: \(error.localizedDescription)" }
    }
}

/// The Frogger card on the iPod page.
struct FroggerSettings: View {
    @EnvironmentObject var model: Model      // @State can't be used (see README), so the question lives in the model
    @StateObject private var studio = CoverStudioUI()
    @StateObject private var switches = FroggerSwitchesUI()
    @ObservedObject private var source = FroggerSource.shared

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
                }
                Spacer(minLength: 12)
                if model.froggerBusy { ProgressView().controlSize(.small) }
                let busy = model.froggerBusy || model.syncing
                Button("Check") { Task { await model.runFrogger(.check) } }
                    .help("Reads the iPod's firmware partition to see whether Frogger is on it (Crate asks for your password)")
                    .disabled(!Frogger.canCheck(model.ipod) || busy)
                if installed {
                    Button("Update…") { model.froggerConfirm = .install }
                        .help("Writes Frogger \(source.summary) over the one on the iPod")
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
            if installed { switchRows }
        }
        .onAppear { switches.load(model.ipod, connected: model.connected) }
        .task { await source.refresh() }
        .onChange(of: model.connected) { _, on in switches.load(model.ipod, connected: on); if !on { switches.changed = false } }
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
                 : "Writes the loader of Frogger \(source.summary) into the iPod's firmware partition. A copy of the partition is saved first, the iPod is "
                   + "unmounted for a moment, and Crate asks for your password. Hold Menu while the iPod starts to get Apple's "
                   + "firmware without Frogger. Restart the iPod afterwards (hold Menu + Play).")
        }
    }

    /// Frogger's Settings switches, the same as Frogger! › Settings on the iPod.
    @ViewBuilder var switchRows: some View {
        Divider().padding(.leading, 50)
        HStack(spacing: 6) {
            Text("On the iPod").font(.headline)
            Spacer()
            Text(!model.connected ? "Connect the iPod to change these"
                 : switches.flags == nil ? "Can't read this iPod's settings"
                 : switches.changed ? "Applies when the iPod restarts (eject it, then hold Menu and Play)"
                 : "The same switches as Frogger! on the iPod; a change applies when it restarts")
                .font(.caption).foregroundStyle(switches.changed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 2)
        ForEach(FroggerSwitch.allCases) { s in
            SettingRow(icon: s.icon, title: s.title, detail: s.detail) {
                Toggle(s.title, isOn: Binding(get: { switches.flags.map(s.isOn) ?? !s.setMeansOn },
                                              set: { on in if let i = model.ipod { switches.set(s, on, ipod: i) } }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(switches.flags == nil || model.syncing)
            }
        }
        SettingRow(icon: "memorychip", title: "Flash Storage",
                   detail: "With a flash mod the disk sleeps 1 s after its last use instead of 2–15 s. Auto: only when the drive says it's flash") {
            Picker("Flash Storage", selection: Binding(get: { switches.flags.map(FroggerFlash.get) ?? .off },
                                                       set: { f in if let i = model.ipod { switches.set(f, ipod: i) } })) {
                ForEach(FroggerFlash.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .disabled(switches.flags == nil || model.syncing)
        }
        let clicker = switches.flags.map(FroggerClicker.get) ?? .speaker
        SettingRow(icon: "speaker.wave.2", title: "Clicker",
                   detail: "Where the click wheel's click plays. With nothing playing, the headphone click comes from the speaker.") {
            Picker("Clicker", selection: Binding(get: { clicker }, set: { c in if let i = model.ipod { switches.set(c, ipod: i) } })) {
                ForEach(FroggerClicker.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .disabled(switches.flags == nil || model.syncing)
        }
        SettingRow(icon: "headphones", title: "Click Volume",
                   detail: "How loud the click is in the headphones (it follows the volume too). The speaker click stays as it is.") {
            Picker("Click Volume", selection: Binding(get: { switches.flags.map(FroggerClickVolume.get) ?? .quiet },
                                                      set: { v in if let i = model.ipod { switches.set(v, ipod: i) } })) {
                ForEach(FroggerClickVolume.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .disabled(switches.flags == nil || model.syncing || clicker == .off || clicker == .speaker)     // only the headphones click has a volume
        }
        .opacity(clicker == .off || clicker == .speaker ? 0.5 : 1)
        if let e = switches.error { Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 11) }
        Text("An older Frogger on the iPod may not have every switch yet: Update puts \(source.summary) on it.")
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 11)
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
