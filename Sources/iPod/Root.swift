import Foundation
import AppKit

// Shell scripts run as root, for Frogger (the iPod's firmware partition) and DiskRepair (its music volume).
//
// sudo, not osascript's "with administrator privileges": that runs the script from a macOS helper without
// Crate's Full Disk Access, and macOS keeps raw disks from those even as root. Under sudo the script stays
// Crate's child. The password goes to sudo -S through a pipe; none while sudo's cached. With Touch ID for
// sudo, that comes first and Crate asks only if it's cancelled.

enum Root {
    /// Runs the script as root and returns its output, or throws with it. `why` is shown when Crate asks
    /// for the password. `line` gets each output line as it comes; lines starting with "@@" are progress
    /// for it and are left out of what's returned.
    static func run(_ script: String, why: String, line: ((String) -> Void)? = nil) async throws -> String {
        func failed(_ text: String) -> NSError {
            NSError(domain: "Root", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        if sudoCached() || touchIDForSudo {
            switch try await sudo(script, password: nil, line: line) {
            case .done(let out): return out
            case .failed(let out): throw failed(out)
            case .noAuth: break                                    // Touch ID cancelled: ask for the password
            }
        }
        guard let password = await askPassword(why) else { throw failed("Cancelled") }
        switch try await sudo(script, password: password, line: line) {
        case .done(let out): return out
        case .failed(let out): throw failed(out.isEmpty ? "Cancelled" : out)
        case .noAuth: throw failed("Wrong password")
        }
    }

    /// The string as one shell word.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private enum SudoResult { case done(String), failed(String), noAuth }

    /// Runs the script as root. noAuth when sudo itself refused (no or a wrong password), before running it.
    private static func sudo(_ script: String, password: String?, line: ((String) -> Void)?) async throws -> SudoResult {
        try await Task.detached {
            let p = Process(), out = Pipe(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-S", "-p", "", "/bin/sh", "-c", script]
            p.standardInput = input
            p.standardOutput = out
            p.standardError = out
            let lock = NSLock()
            var all = Data(), pending = Data()
            func take(_ d: Data) {                   // whole lines go to `line` as they arrive
                lock.lock()
                all.append(d); pending.append(d)
                var lines: [String] = []
                while let nl = pending.firstIndex(of: 10) {
                    lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...nl)
                }
                lock.unlock()
                lines.forEach { line?($0) }
            }
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { take(d) }
            }
            try p.run()
            if let password { input.fileHandleForWriting.write(Data((password + "\n").utf8)) }
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            take(out.fileHandleForReading.readDataToEndOfFile() + Data([10]))
            let text = String(decoding: all, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("@@") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 { return .done(text) }
            let refused = text.split(separator: "\n").contains { $0.hasPrefix("sudo:") && $0.contains("password") }
            return refused ? .noAuth : .failed(text)
        }.value
    }

    /// Whether sudo uses Touch ID (pam_tid in /etc/pam.d/sudo_local or sudo): it then asks by itself.
    private static var touchIDForSudo: Bool {
        ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"].contains { path in
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
                .contains { !$0.hasPrefix("#") && $0.contains("pam_tid.so") }
        }
    }

    /// Whether sudo still has a recent password, so it won't ask.
    private static func sudoCached() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @MainActor private static func askPassword(_ why: String) -> String? {
        let a = NSAlert()
        a.messageText = "Crate needs your password"
        a.informativeText = why
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.window.initialFirstResponder = field
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
