import SwiftUI
import CryptoKit
import ImageIO

// Cover art kept on this Mac (~/Library/Caches/Crate/art), so covers aren't read from the shares
// or downloaded again on every start. Images are stored at most 700 px, as JPEG.

enum ArtCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Crate/art")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let memory = NSCache<NSString, NSImage>()

    static func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".jpg")
    }

    static func image(_ key: String) -> NSImage? {
        if let m = memory.object(forKey: key as NSString) { return m }
        guard let img = NSImage(contentsOf: file(key)) else { return nil }
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

    static func remove(_ key: String) {
        memory.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: file(key))
    }

    /// Downloads a remote image once.
    static func fetch(_ url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let i = image(key) { return i }
        guard let (d, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
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
        if let i = ArtCache.image(u.absoluteString) { image = i; return }
        image = await ArtCache.fetch(u)
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
