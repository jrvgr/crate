import Foundation
import SwiftUI
import DiskArbitration

// The iPod's music volume (HFS+) can end up with a damaged catalog: macOS writes to it (Spotlight's index
// among others) and so does the iPod's own firmware, with much simpler HFS+ code. One such case: two files,
// one from each, given the same file ID, which First Aid can't untangle. macOS then won't mount the volume
// for writing. Crate notices an iPod disk whose volume isn't mounted writable, checks it, and repairs it:
// First Aid first; if that fails, it copies the volume's files to this Mac, checks the copy, reformats the
// volume (HFS+, Spotlight off) and copies them back. The firmware partition and partition map stay as they are.

enum DiskRepair {
    struct Broken: Equatable {
        var disk: String            // "disk6"
        var volume: String          // "disk6s4", the music volume
        var name: String
        var problem = ""
    }

    private static func diskutil(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func plist(_ args: [String]) -> [String: Any]? {
        let r = diskutil(args)
        return try? PropertyListSerialization.propertyList(from: Data(r.out.utf8), format: nil) as? [String: Any]
    }

    /// An attached iPod (a disk with an Apple_MDFW firmware partition) whose HFS+ volume isn't mounted
    /// writable, or nil. Slow-ish (diskutil); call it off the main thread.
    static func scan() -> Broken? {
        guard let all = plist(["list", "-plist", "external", "physical"])?["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }
        for d in all {
            let parts = d["Partitions"] as? [[String: Any]] ?? []
            guard parts.contains(where: { ($0["Content"] as? String) == "Apple_MDFW" }),
                  let hfs = parts.first(where: { ($0["Content"] as? String) == "Apple_HFS" }),
                  let disk = d["DeviceIdentifier"] as? String, let volume = hfs["DeviceIdentifier"] as? String else { continue }
            let info = plist(["info", "-plist", volume]) ?? [:]
            if !((info["MountPoint"] as? String) ?? "").isEmpty, info["WritableVolume"] as? Bool == true { continue }
            return Broken(disk: disk, volume: volume, name: info["VolumeName"] as? String ?? hfs["VolumeName"] as? String ?? "iPod")
        }
        return nil
    }

    /// What First Aid's check finds wrong with the volume ("Incorrect number of thread records"), or nil
    /// when it's healthy. Read-only.
    static func verify(_ volume: String) -> String? {
        let r = diskutil(["verifyVolume", volume])
        guard r.status != 0 else { return nil }
        let lines = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let checks = ["Checking", "The volume", "File system", "Error", "Underlying", "Restoring", "Started", "Verifying",
                      "Performing", "Executing", "Volume is", "Finished"]
        return lines.first { l in !l.isEmpty && !checks.contains { l.hasPrefix($0) } } ?? "the file system check failed"
    }

    /// First Aid's repair, then a normal mount. True when the volume ends up mounted writable.
    static func firstAid(_ volume: String) -> Bool {
        guard diskutil(["repairVolume", volume]).status == 0 else { return false }
        _ = diskutil(["mount", volume])
        return plist(["info", "-plist", volume])?["WritableVolume"] as? Bool == true
    }

    /// Where a repair is, from the rebuild script's "@@" lines.
    struct Progress {
        static let steps = 7
        var step = 0, title = ""
        var files = 0, total: Int64 = 0, done: Int64 = 0
        var phaseStart = Date()
        var copying: Bool { step == 2 || step == 5 }

        var fraction: Double? { copying && total > 0 ? min(Double(done) / Double(total), 0.99) : nil }

        /// Seconds until the whole repair is done, from the speed of the copy under way: while copying to
        /// the Mac, copying back is counted at the same speed.
        var secondsLeft: Double? {
            let elapsed = Date().timeIntervalSince(phaseStart)
            guard copying, done > 0, elapsed > 5 else { return nil }
            let rate = Double(done) / elapsed
            return Double(max(total - done, 0)) / rate + (step == 2 ? Double(total) / rate + 20 : 5)
        }
    }

    /// Where a rebuild keeps its copy of the iPod's files.
    static var copies: URL { PodCache.dir.appendingPathComponent("iPod rebuild") }

    /// Copies the volume's files off, reformats it and copies them back, as root. Returns the last line of
    /// the script's output ("rebuilt: …"), or throws with what went wrong. Nothing on the iPod changes until
    /// the copy on this Mac matches it file for file; if a later step fails, that copy stays.
    static func rebuild(_ b: Broken, line: @escaping (String) -> Void) async throws -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let save = copies.appendingPathComponent(f.string(from: Date()))
        let q = Root.quote
        let script = """
        set -eu
        VOL=\(q("/dev/" + b.volume)); NAME=\(q(b.name)); SAVE=\(q(save.path)); ME=\(getuid())
        # files and bytes, without Spotlight's and the Finder's own folders, Spotlight's marker and the Play Counts file
        tally() { (cd "$1" && find . \\( -path ./.Spotlight-V100 -o -path ./.fseventsd -o -path ./.Trashes \
            -o -path ./.TemporaryItems -o -path ./.DocumentRevisions-V100 \\) -prune -o -type f \
            ! -path './iPod_Control/iTunes/Play Counts' ! -path ./.metadata_never_index \
            -print0 | xargs -0 stat -f %z | awk '{n++; s+=$1} END {print n+0, s+0}'); }
        # Crate's progress: "@@step N title", "@@total FILES BYTES", and "@@bytes KB" every 2 s while copying
        step() { echo "@@step $1 $2"; }
        watch() { while kill -0 "$1" 2>/dev/null; do echo "@@bytes $(du -sk "$2" 2>/dev/null | cut -f1)"; sleep 2; done; }
        MNT=$(mktemp -d /tmp/crate-ipod.XXXXXX)
        # set -e reaches into the trap too: a failing umount (already unmounted) would end the script with 1
        trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
        step 1 "Reading the iPod's disk"
        /usr/sbin/diskutil unmount "$VOL" >/dev/null 2>&1 || true
        # nobrowse: hidden, so Crate (and the Finder) don't take a half-copied iPod for a connected one
        /sbin/mount_hfs -o rdonly,nobrowse "$VOL" "$MNT" || { echo "Couldn't read the iPod's disk, even read-only"; exit 3; }
        BEFORE=$(tally "$MNT")
        echo "@@total $BEFORE"
        echo "${BEFORE%% *} files, ${BEFORE#* } bytes on the iPod"
        mkdir -p "$SAVE"
        FREE=$(df -k "$SAVE" | awk 'NR == 2 {print $4 * 1024}')
        [ "$FREE" -gt $(( ${BEFORE#* } + 1073741824 )) ] || { echo "Not enough free space on this Mac for a copy of the iPod"; exit 4; }
        step 2 "Copying the iPod to this Mac"
        echo "copying to $SAVE"
        (
            for f in "$MNT"/* "$MNT"/.[!.]*; do
                [ -e "$f" ] || continue
                case "${f##*/}" in .Spotlight-V100|.fseventsd|.Trashes|.TemporaryItems|.DocumentRevisions-V100) continue ;; esac
                ditto "$f" "$SAVE/${f##*/}"
            done
        ) & COPY=$!
        watch "$COPY" "$SAVE"
        wait "$COPY"
        rm -f "$SAVE/iPod_Control/iTunes/Play Counts"
        chown -R "$ME" "$SAVE"
        step 3 "Checking the copy"
        [ "$(tally "$SAVE")" = "$BEFORE" ] || { echo "The copy on this Mac doesn't match the iPod; nothing was changed on the iPod"; exit 5; }
        echo "the copy matches the iPod"
        umount "$MNT"
        step 4 "Reformatting the iPod's disk"
        /usr/sbin/diskutil eraseVolume HFS+ "$NAME" "$VOL" >/dev/null || { echo "Reformatting failed; the iPod's files are in $SAVE"; exit 6; }
        /usr/sbin/diskutil unmount "$VOL" >/dev/null
        /sbin/mount_hfs -o nobrowse "$VOL" "$MNT"
        # eraseVolume mounts the new volume for a moment, long enough for Spotlight to start a folder
        rm -rf "$MNT/.Spotlight-V100"
        touch "$MNT/.metadata_never_index"
        step 5 "Copying everything back to the iPod"
        ditto "$SAVE" "$MNT" & COPY=$!
        watch "$COPY" "$MNT"
        wait "$COPY"
        chown -R "$ME" "$MNT"
        step 6 "Checking the iPod"
        [ "$(tally "$MNT")" = "$BEFORE" ] || { echo "Copying back didn't finish; the iPod's files are in $SAVE"; exit 7; }
        echo "the iPod matches the copy"
        umount "$MNT"
        step 7 "Mounting the iPod"
        /usr/sbin/diskutil mount "$VOL" >/dev/null
        MP=$(/usr/sbin/diskutil info -plist "$VOL" | plutil -extract MountPoint raw -)
        mdutil -i off "$MP" >/dev/null 2>&1 || true
        echo "rebuilt: ${BEFORE%% *} files back on the iPod; a copy stays in $SAVE"
        """
        let out = try await Root.run(script, why: "Crate copies the iPod's files, reformats its disk and copies them back as root (sudo).", line: line)
        return out.split(separator: "\n").last.map(String.init) ?? out
    }

    /// Keeps Spotlight from writing its index to the iPod (it's one of the two writers that clash).
    static func keepSpotlightOff(_ mount: URL) {
        let marker = mount.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) { FileManager.default.createFile(atPath: marker.path, contents: nil) }
    }
}

/// Calls back when a disk appears or disappears, including the ones that don't mount.
final class DiskWatch {
    private let session: DASession
    private let changed: () -> Void

    init?(_ changed: @escaping () -> Void) {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
        self.changed = changed
        let me = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { _, ctx in Unmanaged<DiskWatch>.fromOpaque(ctx!).takeUnretainedValue().changed() }, me)
        DARegisterDiskDisappearedCallback(s, nil, { _, ctx in Unmanaged<DiskWatch>.fromOpaque(ctx!).takeUnretainedValue().changed() }, me)
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
}

extension Model {
    /// Disks came or went: look for a broken iPod volume once things settle (macOS checks a volume before
    /// mounting it, which takes a few seconds).
    func diskChanged() {
        diskCheck?.cancel()
        diskCheck = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await checkPodDisk()
        }
    }

    @MainActor func checkPodDisk() async {
        guard !podRepairBusy else { return }
        guard let found = await Task.detached(operation: { DiskRepair.scan() }).value else { brokenPod = nil; return }
        if brokenPod?.volume == found.volume { return }
        let problem = await Task.detached { DiskRepair.verify(found.volume) }.value
        brokenPod = problem.map { var b = found; b.problem = $0; return b }
    }

    @MainActor func repairPod() async {
        guard let b = brokenPod, !syncing, !podRepairBusy else { return }
        podRepairBusy = true
        defer { podRepairBusy = false; podRepairProgress = nil }
        podRepairLog = []
        podRepairMessage = nil
        repairLog("Running First Aid on \(b.volume)")
        podRepairProgress = DiskRepair.Progress(title: "Running First Aid (a minute or two)")
        if await Task.detached(operation: { DiskRepair.firstAid(b.volume) }).value {
            podRepairMessage = "First Aid repaired the iPod's disk"
        } else {
            repairLog("First Aid couldn't fix it; rebuilding the disk")
            podRepairProgress = DiskRepair.Progress(title: "Waiting for your password")
            do {
                podRepairMessage = try await DiskRepair.rebuild(b) { l in Task { @MainActor in self.repairLine(l) } }
            } catch {
                podRepairMessage = error.localizedDescription
                repairLog("Failed: \(error.localizedDescription)")
                return
            }
        }
        repairLog(podRepairMessage ?? "")
        brokenPod = nil
        loadIPod()
    }

    /// One line from the rebuild script: progress, or a line for the details.
    @MainActor func repairLine(_ l: String) {
        let words = l.split(separator: " ", maxSplits: 2).map(String.init)
        var p = podRepairProgress ?? DiskRepair.Progress()
        switch words.first {
        case "@@step" where words.count == 3:
            p.step = Int(words[1]) ?? p.step; p.title = words[2]; p.done = 0; p.phaseStart = Date()
            repairLog("Step \(p.step) of \(DiskRepair.Progress.steps): \(p.title)")
        case "@@total" where words.count == 3:
            p.files = Int(words[1]) ?? 0; p.total = Int64(words[2]) ?? 0
        case "@@bytes" where words.count == 2:
            p.done = (Int64(words[1]) ?? 0) * 1024
        default:
            if !l.trimmingCharacters(in: .whitespaces).isEmpty { repairLog(l) }
        }
        podRepairProgress = p
    }

    @MainActor func repairLog(_ l: String) {
        podRepairLog.append(Date().formatted(date: .omitted, time: .standard) + "  " + l)
        if podRepairLog.count > 500 { podRepairLog.removeFirst() }
    }
}

/// On the iPod page (and in place of it when the iPod can't be mounted): its disk has errors, and the repair.
struct DiskRepairCard: View {
    @EnvironmentObject var model: Model      // @State can't be used (see README), so the question lives in the model

    var body: some View {
        if model.brokenPod != nil || model.podRepairMessage != nil {
            SettingsCard {
                SettingRow(icon: model.brokenPod == nil ? "checkmark.circle" : "exclamationmark.triangle", title: title, detail: detail) {
                    if model.podRepairBusy { ProgressView().controlSize(.small) }
                    if model.brokenPod != nil {
                        Button("Repair…") { model.podRepairConfirm = true }.disabled(model.podRepairBusy || model.syncing)
                    } else if !model.podRepairBusy {
                        Button("OK") { model.podRepairMessage = nil; model.podRepairLog = [] }
                    }
                }
                if let p = model.podRepairProgress { progress(p) }
                if !model.podRepairLog.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(model.podRepairLog.joined(separator: "\n"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 180)
                    }
                    .font(.caption)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
            .alert("Repair the iPod's disk?", isPresented: $model.podRepairConfirm) {
                Button("Repair") { Task { await model.repairPod() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Crate runs First Aid first. If that can't fix it, Crate copies everything on the iPod to this Mac, checks the "
                     + "copy, reformats the iPod's disk and copies it all back: songs, playlists and settings. Only the plays recorded "
                     + "on the iPod since the last sync are lost. Keep the iPod plugged in; macOS asks for your password.")
            }
        }
    }

    /// "Step 2 of 7 · Copying the iPod to this Mac", a bar, "2.1 GB of 5.2 GB · about 4 min left".
    func progress(_ p: DiskRepair.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.step > 0 ? "Step \(p.step) of \(DiskRepair.Progress.steps) · \(p.title)" : p.title).font(.callout.weight(.medium))
            if let f = p.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            HStack {
                if p.copying {
                    Text(ByteCountFormatter.string(fromByteCount: p.done, countStyle: .file) + " of "
                         + ByteCountFormatter.string(fromByteCount: p.total, countStyle: .file))
                }
                if let s = p.secondsLeft {
                    Text("· about " + (s < 90 ? "\(max(Int(s / 10) * 10, 10)) s" : "\(Int((s / 60).rounded())) min") + " left")
                }
                Spacer()
                Text("Keep the iPod plugged in and Crate open")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    var title: String { model.brokenPod.map { "\($0.name)'s disk has errors" } ?? "iPod disk" }

    var detail: String {
        if let m = model.podRepairMessage { return m }
        guard let b = model.brokenPod else { return "" }
        return "macOS won't mount it for writing (\(b.problem)), so Crate can't sync. Repair fixes the disk and keeps what's on it"
    }
}
