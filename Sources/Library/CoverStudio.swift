import SwiftUI
import AppKit

// The Cover Studio: tune how covers become Frogger's 72×72 four-grey pictures (FroggerArt.Look)
// while watching an album on a mock of the iPod's cover page, next to Crate's old defaults and a
// sheet of other albums. The look is saved as it changes and used by every sync; "Write to iPod"
// redoes the iPod's FroggerArt now, without a sync.

final class CoverStudioUI: ObservableObject {
    @Published var open = false
    @Published var look = FroggerArt.Look.saved {
        didSet { rerender(); save() }
    }
    @Published var query = ""
    @Published var album: Album?
    @Published var original: NSImage?
    @Published var preview: CGImage?            // the album with the look
    @Published var before: CGImage?             // … and with Crate's defaults
    @Published var others: [(id: String, image: CGImage)] = []
    @Published var writing = false
    @Published var message: String?
    private var gray: [Double]?
    private var otherGrays: [(id: String, gray: [Double])] = []
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// The palette is emupod's (tools/emupod/npcycle.py): level 0 white … 3 black.
    static let lcd: [(UInt8, UInt8, UInt8)] = [(0xc6, 0xd0, 0xc0), (0x8c, 0x95, 0x88), (0x50, 0x56, 0x4e), (0x10, 0x12, 0x10)]

    @MainActor
    func select(_ a: Album, model: Model) async {
        album = a; original = nil; gray = nil; before = nil; rerender()
        // the full-size file when the album folder has one, else the cover Crate already shows
        let data = await LibraryLoader.artwork(for: a) ?? model.artwork[a.id]?.tiffRepresentation
        guard album == a else { return }
        original = data.flatMap { NSImage(data: $0) } ?? model.artwork[a.id]
        gray = data.flatMap(FroggerArt.gray)
        before = gray.map { Self.image(FroggerArt.render($0, look: FroggerArt.Look())) }
        rerender()
    }

    /// The covers the library has already loaded, for the sheet of other albums.
    @MainActor
    func loadOthers(_ model: Model) {
        otherGrays = model.albums.lazy.compactMap { a -> (String, [Double])? in
            guard let d = model.artwork[a.id]?.tiffRepresentation, let g = FroggerArt.gray(d) else { return nil }
            return (a.id, g)
        }.prefix(12).map { (id: $0.0, gray: $0.1) }
        rerender()
    }

    /// Off the main thread, so a slider stays smooth; a newer look cancels the one still rendering.
    func rerender() {
        renderTask?.cancel()
        let look = look, gray = gray, otherGrays = otherGrays
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let preview = gray.map { Self.image(FroggerArt.render($0, look: look)) }
            guard !Task.isCancelled else { return }
            let others = otherGrays.map { (id: $0.id, image: Self.image(FroggerArt.render($0.gray, look: look))) }
            await self?.show(preview, others)
        }
    }

    @MainActor private func show(_ preview: CGImage?, _ others: [(id: String, image: CGImage)]) {
        guard !Task.isCancelled else { return }      // a newer look is on its way
        self.preview = preview; self.others = others
    }

    /// Saved once the look stops changing: every save wakes whatever draws covers with it (the sidebar's iPod).
    private func save() {
        saveTask?.cancel()
        let look = look
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { FroggerArt.Look.saved = look }
        }
    }

    /// The four levels in `palette` (white … black, each with its alpha; emupod's LCD by default).
    static func image(_ px: Data, palette: [(UInt8, UInt8, UInt8, UInt8)] = lcd.map { ($0.0, $0.1, $0.2, 255) }) -> CGImage {
        let n = FroggerArt.size
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rgb = ctx.data!.assumingMemoryBound(to: UInt8.self)      // the context's own buffer: row 0 is the top
        for y in 0..<n {
            for x in 0..<n {
                let c = palette[FroggerArt.level(px, x, y)], i = (y * n + x) * 4
                let a = UInt16(c.3)
                rgb[i] = UInt8(UInt16(c.0) * a / 255); rgb[i + 1] = UInt8(UInt16(c.1) * a / 255); rgb[i + 2] = UInt8(UInt16(c.2) * a / 255); rgb[i + 3] = c.3
            }
        }
        return ctx.makeImage()!
    }

    @MainActor
    func writeToIPod(_ model: Model) async {
        guard let ipod = model.ipod, let db = try? ITunesDB.read(Data(contentsOf: ipod.dbURL)) else {
            message = "Couldn't read the iPod's database"; return
        }
        saveTask?.cancel(); FroggerArt.Look.saved = look        // the write reads the saved look
        writing = true; message = nil
        let n = await FroggerArt.write(db, to: ipod, albums: model.albums)
        writing = false
        message = n > 0 ? "Wrote \(n) covers. They show from the next song that starts after you eject." : "No covers were written"
    }
}

struct CoverStudio: View {
    @EnvironmentObject var model: Model
    @ObservedObject var ui: CoverStudioUI
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            albumList.frame(width: 200)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(ui.album.map { "\($0.title) · \($0.artist)" } ?? "Cover Studio").font(.title2.bold()).lineLimit(1)
                ScrollView {           // the sheet can't be larger than the window, so the middle scrolls
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            screen.frame(width: 320, height: 256)
                            VStack(spacing: 10) {
                                tile(ui.original.map { Image(nsImage: $0).resizable().scaledToFill() }, "Original")
                                tile(ui.before.map { pixels($0) }, "Crate's defaults")
                            }
                        }
                        controls
                        if !ui.others.isEmpty {
                            Text("Other albums with this look").font(.headline)
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(ui.others, id: \.id) { o in pixels(o.image).frame(width: 72, height: 72) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 660, idealWidth: 760, maxWidth: 900, minHeight: 420, idealHeight: 600, maxHeight: 760)
        .task {
            ui.loadOthers(model)
            if ui.album == nil, let a = model.albums.first(where: { model.artwork[$0.id] != nil }) ?? model.albums.first {
                await ui.select(a, model: model)
            }
        }
    }

    var albumList: some View {
        let q = ui.query.lowercased()
        let shown = q.isEmpty ? model.albums : model.albums.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
        return VStack(spacing: 0) {
            TextField("Filter albums", text: $ui.query).textFieldStyle(.roundedBorder).padding(10)
            List(shown) { a in
                Button { Task { await ui.select(a, model: model) } } label: {
                    HStack(spacing: 8) {
                        Cover(image: model.artwork[a.id], seed: a.id).frame(width: 30, height: 30).clipShape(.rect(cornerRadius: 4, style: .continuous))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.title).lineLimit(1)
                            Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(ui.album == a ? Color.accentColor.opacity(0.2) : Color.clear)
            }
            .listStyle(.sidebar)
        }
    }

    /// The cover page as Frogger draws it (payload/nowplaying.h), at 2×: the title on top, the
    /// cover at (44, 19), the progress bar and times below.
    var screen: some View {
        let u: CGFloat = 2, bg = CoverStudioUI.lcd[0], ink = CoverStudioUI.lcd[3]
        let inkColor = Color(red: Double(ink.0) / 255, green: Double(ink.1) / 255, blue: Double(ink.2) / 255)
        _ = IPodArt.chicagoRegistered
        let chicago: Font = IPodArt.chicagoRegistered ? .custom("ChicagoFLF", fixedSize: 12 * u) : .system(size: 12 * u, weight: .bold)
        return ZStack(alignment: .topLeading) {
            Color(red: Double(bg.0) / 255, green: Double(bg.1) / 255, blue: Double(bg.2) / 255)
            Text(ui.album?.tracks.first?.title ?? "Song Title").font(chicago).lineLimit(1)
                .frame(width: 156 * u).offset(x: 2 * u, y: 2 * u)
            if let p = ui.preview {
                pixels(p).frame(width: 72 * u, height: 72 * u).offset(x: 44 * u, y: 19 * u)
            } else {
                ProgressView().offset(x: 72 * u, y: 48 * u)
            }
            RoundedRectangle(cornerRadius: 3 * u).stroke(inkColor, lineWidth: u)
                .frame(width: 144 * u, height: 8 * u).offset(x: 8 * u, y: 96 * u)
            HStack {
                Text("0:00"); Spacer(); Text("-3:00")
            }
            .font(chicago).frame(width: 144 * u).offset(x: 8 * u, y: 107 * u)
        }
        .foregroundStyle(inkColor)
        .clipShape(.rect(cornerRadius: 6))
    }

    var controls: some View {
        Form {
            Toggle("Stretch levels", isOn: $ui.look.autoLevels)
            Slider(value: $ui.look.brightness, in: -0.5...0.5) { Text("Brightness") }
            Slider(value: $ui.look.contrast, in: 0.5...2.5) { Text("Contrast") }
            Slider(value: $ui.look.gamma, in: 0.4...2.5) { Text("Midtones") }
            Slider(value: $ui.look.sharpen, in: 0...2) { Text("Sharpen") }
            Picker("Dither", selection: $ui.look.dither) {
                ForEach(FroggerArt.Look.Dither.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        .formStyle(.columns)
        .frame(maxWidth: 460)
    }

    var footer: some View {
        HStack {
            Button("Reset to Defaults") { ui.look = FroggerArt.Look() }.buttonStyle(.glass)
                .disabled(ui.look == FroggerArt.Look())
            if let m = ui.message { Text(m).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            if ui.writing { ProgressView().controlSize(.small) }
            Button("Write to iPod") { Task { await ui.writeToIPod(model) } }.buttonStyle(.glass)
                .help("Makes the iPod's covers again with this look, now (the next sync does it too)")
                .disabled(model.ipod == nil || model.syncing || ui.writing)
            Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
        }
    }

    func tile<V: View>(_ v: V?, _ label: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let v { v } else { Color.secondary.opacity(0.15) }
            }
            .frame(width: 108, height: 108).clipped().clipShape(.rect(cornerRadius: 6, style: .continuous))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    func pixels(_ cg: CGImage) -> some View {
        Image(decorative: cg, scale: 1).interpolation(.none).resizable()
    }
}

/// An album cover that shows its iPod picture under the pointer: hovering wipes from the
/// artwork to the 72×72 four-grey version with the saved look, split where the pointer is.
struct IPodCover: View {
    var image: NSImage?
    var seed: String
    @StateObject private var ui = IPodCoverUI()

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Cover(image: image, seed: seed)       // centred and cropped like the iPod picture (FroggerArt.gray), for non-square art
                    .frame(width: g.size.width, height: g.size.height).clipped()
                if let px = ui.pixels, let s = ui.split {
                    Image(decorative: px, scale: 1).interpolation(.none).resizable()
                        .mask(alignment: .trailing) { Rectangle().frame(width: g.size.width * (1 - s)) }
                        .transition(.opacity)
                    Rectangle().fill(.white).frame(width: 2, height: g.size.height)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: g.size.width * s - 1)
                        .transition(.opacity)
                    HStack {
                        label("Original").opacity(s > 0.3 ? 1 : 0)
                        Spacer()
                        label("iPod · 72 px").opacity(s < 0.7 ? 1 : 0)
                    }
                    .padding(8).frame(width: g.size.width, height: g.size.height, alignment: .bottom)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: ui.split == nil)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    ui.split = min(1, max(0, p.x / g.size.width))
                    ui.render(image, seed: seed)
                case .ended:
                    ui.split = nil
                }
            }
        }
    }

    func label(_ s: String) -> some View {
        Text(s).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule).foregroundStyle(.white)
    }
}

final class IPodCoverUI: ObservableObject {
    @Published var split: CGFloat?
    @Published var pixels: CGImage?
    private var key = ""

    /// Makes the iPod picture the first time the pointer comes over, and again after the look or cover changed.
    func render(_ image: NSImage?, seed: String) {
        let look = FroggerArt.Look.saved
        let key = seed + "\u{1f}" + String(describing: look) + "\u{1f}" + String(image.map { ObjectIdentifier($0).hashValue } ?? 0)
        guard key != self.key, let data = image?.tiffRepresentation else { return }
        self.key = key
        Task.detached {
            guard let g = FroggerArt.gray(data) else { return }
            let cg = CoverStudioUI.image(FroggerArt.render(g, look: look))
            await MainActor.run { if self.key == key { self.pixels = cg } }
        }
    }
}
