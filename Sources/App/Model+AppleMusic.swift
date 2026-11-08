import SwiftUI
import AppKit

extension Model {
    // MARK: Apple Music

    func loadAppleMusic() async {
        guard !amLoading else { return }       // Music answers one long query at a time; a second one times out
        amLoading = true; defer { amLoading = false }
        do {
            amAlbums = try await AppleMusic.albums(); amError = nil
            amHidden = Set(amAlbums.filter(inLibrary).map(\.id))
        } catch { amError = error.localizedDescription }
    }

    func inLibrary(_ a: AMAlbum) -> Bool { albums.contains { $0.id == a.id } }

    func amJob(_ a: AMAlbum) -> Job? {
        guard let id = amQueue.first(where: { $0.album.id == a.id })?.job else { return nil }
        return jobs.first { $0.id == id }
    }

    /// Queues an iTunes Match album; the queue is worked through one album at a time.
    func importAppleMusic(_ a: AMAlbum, toIPod: Bool) {
        guard !amQueue.contains(where: { $0.album.id == a.id }) else { return }
        let job = startJob(a.title, icon: "icloud.and.arrow.down", detail: "Waiting", queued: true)
        updateJob(job) { $0.source = .appleMusic; $0.subtitle = "\(a.artist) · \(a.tracks.count) songs"; $0.art = self.amArt[a.id] }
        amQueue.append((a, toIPod, job))
        guard !amRunning else { return }
        amRunning = true
        Task {
            while let next = amQueue.first {
                await runAppleMusicImport(next.album, toIPod: next.toIPod, job: next.job)
                amQueue.removeFirst()
            }
            amRunning = false
        }
    }

    func runAppleMusicImport(_ a: AMAlbum, toIPod: Bool, job: UUID) async {
        updateJob(job) { $0.state = .running; $0.detail = "Downloading in Music"; $0.progress = 0 }
        do {
            let paths = try await AppleMusic.download(a) { [weak self] done, total in
                self?.updateJob(job) { $0.detail = "Downloading \(done) of \(total)"; $0.progress = Double(done) / Double(max(total, 1)) }
            }
            let ids = await importFiles(paths.map { URL(fileURLWithPath: $0) }, toIPod: toIPod, job: job)
            if let lib = albums.first(where: { ids.contains($0.id) }) { await saveAppleMusicCover(a, into: lib) }
            if let i = amAlbums.firstIndex(where: { $0.id == a.id }), let fresh = try? await AppleMusic.albums().first(where: { $0.id == a.id }) {
                amAlbums[i] = fresh
            }
        } catch { finishJob(job, error.localizedDescription, failed: true) }
    }

    /// Puts the iTunes Store cover (1200 px) next to an imported album when it has no cover file.
    func saveAppleMusicCover(_ a: AMAlbum, into lib: Album) async {
        let folder = lib.folder
        guard await offMain({ Model.coverFile(in: folder) == nil }) else { return }
        var url = amArt[a.id]
        if url == nil { url = await AppleMusic.artworkURL(a) }
        guard let u = url.flatMap({ URL(string: $0.absoluteString.replacingOccurrences(of: "600x600bb", with: "1200x1200bb")) }),
              let (d, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: d) else { return }
        if await offMain({ FileManager.default.createFile(atPath: folder + "/cover.jpg", contents: d) }) {
            artwork[lib.id] = await offMain { ArtCache.storeAlbum(d, folder: folder) } ?? img
            await rescanServers()
        }
    }
}
