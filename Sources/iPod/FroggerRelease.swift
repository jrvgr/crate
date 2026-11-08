import Foundation
import CryptoKit

// Where Crate's Frogger comes from: by default the newest release of github.com/jrvgr/frogger (on the Beta
// update channel prereleases included), downloaded once per tag into Application Support/Crate/Frogger/releases/<tag>/ and checked against
// the release's SHA256SUMS; or, when Settings › Frogger says so, a local checkout with a loader you built.
// Without the network the last downloaded release is used.

@MainActor
final class FroggerSource: ObservableObject {
    static let shared = FroggerSource()
    static let repo = "jrvgr/frogger"

    @Published var useCheckout = UserDefaults.standard.bool(forKey: "froggerUseCheckout") {
        didSet { UserDefaults.standard.set(useCheckout, forKey: "froggerUseCheckout") }
    }
    @Published var checkoutPath = UserDefaults.standard.string(forKey: "froggerCheckout") ?? "~/Projects/frogger" {
        didSet { UserDefaults.standard.set(checkoutPath, forKey: "froggerCheckout") }
    }
    /// Crate's update channel: Beta also takes Frogger's prereleases. (Crate's own Sparkle updates have one channel.)
    @Published var beta = UserDefaults.standard.string(forKey: "updateChannel") == "beta" {
        didSet { UserDefaults.standard.set(beta ? "beta" : "stable", forKey: "updateChannel") }
    }
    @Published var debug = UserDefaults.standard.bool(forKey: "froggerDebug") {
        didSet { UserDefaults.standard.set(debug, forKey: "froggerDebug") }
    }
    /// The downloaded, verified release Crate installs (its folder under releases/).
    @Published private(set) var tag = UserDefaults.standard.string(forKey: "froggerRelease") {
        didSet { UserDefaults.standard.set(tag, forKey: "froggerRelease") }
    }
    @Published private(set) var checking = false
    @Published private(set) var error: String?          // the last check's failure
    @Published private(set) var newest = false           // the last check found nothing newer
    private var lastCheck: Date?

    private init() {
        if let t = tag, !FileManager.default.fileExists(atPath: Self.dir(t).path) { tag = nil }
    }

    static var releases: URL { Frogger.backups.appendingPathComponent("releases") }
    static func dir(_ tag: String) -> URL { releases.appendingPathComponent(tag) }
    var releaseDir: URL? { tag.map(Self.dir) }

    /// "v0.1.0-beta.1", "v0.1.0-beta.1 (debug)" or "local checkout ~/Projects/frogger".
    var summary: String {
        if useCheckout { return "local checkout " + (checkoutPath as NSString).abbreviatingWithTildeInPath }
        guard let tag else { return checking ? "Downloading…" : "Not downloaded" }
        return tag + (debug ? " (debug)" : "")
    }

    /// Checks GitHub at most every hour unless asked (Check for Updates).
    func refresh(force: Bool = false) async {
        guard !useCheckout, !checking else { return }
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        checking = true; newest = false
        defer { checking = false; lastCheck = Date() }
        do {
            let found = try await Self.fetchNewest(beta: beta)
            newest = found == tag
            tag = found; error = nil
        } catch {
            self.error = (error as? FroggerDownloadError)?.message ?? error.localizedDescription
        }
    }

    // MARK: Download

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    private static func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Crate", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: r) }
        catch { throw FroggerDownloadError("Couldn't reach GitHub for Frogger (\(error.localizedDescription))") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw FroggerDownloadError(code == 403 || code == 429 ? "GitHub limits how often Crate can ask; try again later"
                                       : "GitHub answered \(code) for \(url.lastPathComponent)")
        }
        return data
    }

    /// The newest non-draft release's tag (a prerelease only on Beta), downloaded and verified into releases/<tag>/
    /// unless it's there already.
    private static func fetchNewest(beta: Bool) async throws -> String {
        let list = try await get(URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10")!)
        guard let all = try? JSONDecoder().decode([Release].self, from: list) else { throw FroggerDownloadError("GitHub's list of Frogger releases didn't read") }
        guard let rel = all.first(where: { !$0.draft && (beta || !$0.prerelease) }) else {
            throw FroggerDownloadError(beta ? "Frogger has no release yet" : "Frogger has no stable release yet; the Beta channel has its prereleases")
        }
        let tag = rel.tag_name
        guard !tag.isEmpty, !tag.hasPrefix("."), !tag.contains("/"), !tag.contains(":") else { throw FroggerDownloadError("Frogger's release has an odd tag: \(tag)") }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir(tag).path) { return tag }

        func asset(_ name: String) -> URL? { rel.assets.first { $0.name == name }?.browser_download_url }
        guard let sumsURL = asset("SHA256SUMS") else { throw FroggerDownloadError("Frogger \(tag) has no SHA256SUMS") }
        let sums = parseSums(String(decoding: try await get(sumsURL), as: UTF8.self))

        var files: [String: Data] = [:]
        for name in ["frogger-loader.bin", "frogger-loader-debug.bin"] {
            guard let u = asset(name) else {
                if name == "frogger-loader.bin" { throw FroggerDownloadError("Frogger \(tag) has no frogger-loader.bin") }
                continue
            }
            let d = try await get(u)
            guard let want = sums[name] else { throw FroggerDownloadError("\(name) isn't in Frogger \(tag)'s SHA256SUMS") }
            guard hex(d) == want else { throw FroggerDownloadError("\(name) of Frogger \(tag) doesn't match its SHA256SUMS; not used") }
            files[name] = d
        }
        // install.py is a release asset from the release after v0.1.0-beta.1 on; before that, the tag's own copy
        let installer = try await get(asset("install.py") ?? URL(string: "https://raw.githubusercontent.com/\(repo)/\(tag)/tools/install.py")!)
        if let want = sums["install.py"], hex(installer) != want {
            throw FroggerDownloadError("install.py of Frogger \(tag) doesn't match its SHA256SUMS; not used")
        }
        files["install.py"] = installer
        files["SHA256SUMS"] = Data(sums.map { "\($0.value)  \($0.key)" }.sorted().joined(separator: "\n").utf8)

        // written next to its place and moved there whole, so a half download never looks like a release
        try fm.createDirectory(at: releases, withIntermediateDirectories: true)
        let part = releases.appendingPathComponent(".\(tag).partial")
        try? fm.removeItem(at: part)
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        for (name, d) in files { try d.write(to: part.appendingPathComponent(name)) }
        try fm.moveItem(at: part, to: dir(tag))
        return tag
    }

    /// sha256sum's lines, "<hex>  <name>" (or "<hex> *<name>"): name → lowercase hex.
    static func parseSums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64 else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            out[(name as NSString).lastPathComponent] = parts[0].lowercased()
        }
        return out
    }

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

struct FroggerDownloadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
