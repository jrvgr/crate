import SwiftUI
import CryptoKit
import ImageIO

// Cover art kept on this Mac (~/Library/Caches/Crate/art), so covers aren't read from the shares
// or downloaded again on every start. Images are stored at most 700 px, as JPEG.

enum ArtCache {
    static let dir: URL = {
        let d = Demo.dir("art") ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate/art")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let memory = NSCache<NSString, NSImage>()

    static func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".jpg")
    }

    /// Already in memory (safe to call while drawing).
    static func cached(_ key: String) -> NSImage? { memory.object(forKey: key as NSString) }

    /// From memory or disk, decoded right away so drawing doesn't have to. Reads the disk: keep it
    /// off the main thread.
    static func image(_ key: String) -> NSImage? {
        if let m = memory.object(forKey: key as NSString) { return m }
        guard let src = CGImageSourceCreateWithURL(file(key) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    /// Stores (a scaled-down copy of) image data; returns the image.
    @discardableResult
    static func store(_ data: Data, for key: String) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 700,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { return nil }
        try? jpg.write(to: file(key))
        let img = NSImage(cgImage: cg, size: .zero)
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    // An album's cover is cached with where it came from (the cover file's name and size, or "embedded"), so a
    // cover.jpg that turns up or changes later is read again instead of the old picture staying.

    nonisolated static func albumSource(_ folder: String) -> String {
        for n in ["cover.jpg", "folder.jpg", "cover.png", "folder.png", "front.jpg"] {
            if let size = (try? FileManager.default.attributesOfItem(atPath: folder + "/" + n))?[.size] as? Int { return "\(n):\(size)" }
        }
        return "embedded"
    }

    /// The cached cover for an album folder, if it still matches the folder's cover file. Reads the share: off the main thread.
    static func albumImage(_ folder: String) -> NSImage? {
        let key = "album:" + folder
        guard (try? String(contentsOf: file(key).appendingPathExtension("src"), encoding: .utf8)) == albumSource(folder) else { return nil }
        return image(key)
    }

    @discardableResult
    static func storeAlbum(_ data: Data, folder: String) -> NSImage? {
        let key = "album:" + folder
        let img = store(data, for: key)
        try? albumSource(folder).write(to: file(key).appendingPathExtension("src"), atomically: true, encoding: .utf8)
        return img
    }

    static func remove(_ key: String) {
        memory.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: file(key))
    }

    /// Downloads a remote image once. One that isn't there (most releases in the Cover Art Archive have none,
    /// and each miss is a slow redirect) is remembered for a week instead of asked for on every visit.
    static func fetch(_ url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let i = image(key) { return i }
        let missing = file(key).appendingPathExtension("missing")
        if let d = (try? FileManager.default.attributesOfItem(atPath: missing.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < 7 * 86400 { return nil }
        guard let (d, resp) = try? await URLSession.shared.data(from: url) else { return nil }     // offline: try again next time
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        if code == 404 || code == 410 { FileManager.default.createFile(atPath: missing.path, contents: nil); return nil }
        guard code < 400 else { return nil }
        return store(d, for: key)
    }

    static var size: Int64 {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0) { $0 + Int64($1) }
    }
    static func clear() { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
}

@MainActor
final class RemoteImage: ObservableObject {
    @Published var image: NSImage?
    private var url: URL?
    func load(_ u: URL?) async {
        guard u != url else { return }
        url = u; image = nil
        guard let u else { return }
        if let i = ArtCache.cached(u.absoluteString) { image = i; return }
        image = await ArtCache.fetch(u)          // disk or network, off the main thread
    }
}

/// AsyncImage, but through the art cache: downloaded once, kept on disk.
struct CachedImage: View {
    var url: URL?
    var seed: String
    @StateObject private var r = RemoteImage()
    var body: some View {
        Cover(image: r.image, seed: seed)
            .task(id: url) { await r.load(url) }
    }
}
