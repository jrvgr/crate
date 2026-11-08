import SwiftUI
import AppKit

// Cover Flow, as in iTunes: the selected album in the middle, the others turned away to either
// side with reflections. Same geometry as the iMac's CoverFlow.app (imac/CoverFlow/main.m):
// side covers 0.62 cover widths out, then 0.18 apart, turned 66°. Scrolling (trackpad, wheel,
// dragging) moves continuously with momentum and settles on the nearest cover.

@MainActor
final class FlowState: ObservableObject {
    @Published var settled = true
    @Published var index = 0              // the cover in the middle once settled
    var pos = 0.0                         // continuous position, drawn every frame
    var target = 0.0
    var velocity = 0.0
    private var last: Date?
    private var scrolling = false

    func clampTarget(_ count: Int) { target = min(max(target, 0), Double(max(count - 1, 0))) }

    /// Moves `pos` toward `target` (a critically damped spring); called once per frame.
    func advance(_ now: Date, count: Int) -> Double {
        let dt = min(now.timeIntervalSince(last ?? now), 1.0 / 30)
        last = now
        if scrolling { return pos }
        let k = 90.0, damping = 2 * sqrt(k)
        let force = -k * (pos - target) - damping * velocity
        velocity += force * dt
        pos += velocity * dt
        if abs(pos - target) < 0.002, abs(velocity) < 0.01 {
            pos = target; velocity = 0; last = nil
            DispatchQueue.main.async { self.settled = true; self.index = Int(self.target.rounded()) }
        }
        return pos
    }

    func go(to i: Int, count: Int) {
        target = Double(i); clampTarget(count)
        index = Int(target)
        wake()
    }

    func step(_ by: Int, count: Int) { go(to: Int(target.rounded()) + by, count: count) }

    /// Live scrolling: follow the fingers directly, settle on the nearest cover when they let go.
    func scroll(by delta: Double, count: Int, ended: Bool) {
        scrolling = !ended
        pos = min(max(pos + delta, -0.4), Double(max(count - 1, 0)) + 0.4)
        velocity = 0
        target = ended ? pos.rounded() : pos
        clampTarget(count)
        if ended { index = Int(target) }
        wake()
    }

    private func wake() { if settled { last = nil; settled = false } }
}

/// The carousel itself, for any covers: library albums, Spotify albums.
struct CoverFlow<Art: View>: View {
    var count: Int
    @ObservedObject var flow: FlowState
    var art: (Int) -> Art
    var horizontalOnly = false          // in a page that scrolls: vertical swipes scroll the page
    var reflection = true               // false: just the covers, centred and as big as the height allows
    var shadow = true
    var fitAll = false                  // every cover in the width (closer together), none faded out
    var onOpen: (Int) -> Void

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.height * (reflection ? 0.68 : 0.86), g.size.width * 0.26)
            let mid = g.size.height * (reflection ? 0.46 : 0.5)
            // fitAll: the side covers close up so that the last one, with the first in the middle, still reaches the edge
            let room = g.size.width / 2 - size * 0.9 - size * 0.55
            let step = fitAll ? min(size * 0.46, max(room / Double(max(count - 1, 1)), 3)) : size * 0.46
            TimelineView(.animation(paused: flow.settled)) { tl in
                let pos = flow.settled ? flow.target : flow.advance(tl.date, count: count)
                let lo = fitAll ? 0 : max(0, Int(pos) - 5), hi = fitAll ? count - 1 : min(count - 1, Int(pos) + 6)
                ZStack {
                    if lo <= hi {
                        ForEach(lo...hi, id: \.self) { i in
                            cover(i, d: Double(i) - pos, size: size)
                                .position(x: g.size.width / 2 + x(Double(i) - pos, size, step: step), y: mid)
                                .zIndex(-abs(Double(i) - pos))
                                .onTapGesture {
                                    if i == Int(flow.target.rounded()) { onOpen(i) } else { flow.go(to: i, count: count) }
                                }
                        }
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .overlay { ScrollCatcher(horizontalOnly: horizontalOnly) { delta, ended in flow.scroll(by: delta / Double(size * 0.2), count: count, ended: ended) } }
        }
        .clipped()
    }

    /// Horizontal position: 0.9 cover widths to the first side cover, then 0.46 apart.
    func x(_ d: Double, _ size: Double, step: Double) -> Double {
        let a = abs(d), s: Double = d < 0 ? -1 : 1
        return a < 1 ? d * size * 0.9 : s * (size * 0.9 + (a - 1) * step)
    }

    func cover(_ i: Int, d: Double, size: Double) -> some View {
        let t = min(abs(d), 1), s: Double = d < 0 ? -1 : 1, far = abs(d)
        let art = self.art(i).frame(width: size, height: size).clipShape(.rect(cornerRadius: 14, style: .continuous))
        return VStack(spacing: 6) {
            art
                .overlay {   // a glassy edge and a soft specular sheen, strongest on the cover in the middle
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.25)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    LinearGradient(colors: [.white.opacity(0.12 * (1 - t)), .clear], startPoint: .topLeading, endPoint: .center)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous)).allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 14, y: 8)
            if reflection {
                art
                    .scaleEffect(x: 1, y: -1)
                    .mask(LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
            }
        }
        .frame(width: size, height: reflection ? size * 2 + 6 : size, alignment: .top)
        .offset(y: reflection ? size / 2 + 3 : 0)
        .rotation3DEffect(.radians(-s * 0.6 * t), axis: (0, 1, 0), anchor: .center, perspective: 0.35)
        .scaleEffect(1 - 0.2 * t - 0.03 * max(0, far - 1))
        .opacity(fitAll ? 1 : far > 4.5 ? max(0, 5.5 - far) : 1 - 0.12 * max(0, far - 1))
    }
}

/// Catches trackpad/wheel scrolling (and click-drags) over Cover Flow, in points.
struct ScrollCatcher: NSViewRepresentable {
    var horizontalOnly = false
    var onScroll: (Double, Bool) -> Void

    final class Catcher: NSView {
        var onScroll: ((Double, Bool) -> Void)?
        var horizontalOnly = false
        private var dragX: CGFloat?
        private var vertical: Bool?           // the swipe's direction, decided on its first event

        override func scrollWheel(with e: NSEvent) {
            if horizontalOnly {
                if e.phase == .began || vertical == nil || (!e.hasPreciseScrollingDeltas) {
                    vertical = abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX)
                }
                let done = e.momentumPhase == .ended || e.momentumPhase == .cancelled || (e.phase == .ended && e.momentumPhase == [])
                if vertical == true {
                    super.scrollWheel(with: e)          // on to the page's scroll view
                    if done { vertical = nil }
                    return
                }
                if done { vertical = nil }          // a sideways swipe ended: the next one decides again
            }
            let dx = abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) ? -e.scrollingDeltaX : -e.scrollingDeltaY
            let lines = e.hasPreciseScrollingDeltas ? 1.0 : 18.0       // a mouse wheel moves in lines
            let finished = e.momentumPhase == .ended || e.momentumPhase == .cancelled
                || (e.phase == .ended && e.momentumPhase == []) || (!e.hasPreciseScrollingDeltas)
            onScroll?(Double(dx) * lines, finished)
        }
        override func mouseDown(with e: NSEvent) { dragX = e.locationInWindow.x; super.mouseDown(with: e) }
        override func mouseDragged(with e: NSEvent) {
            guard let x0 = dragX else { return }
            onScroll?(Double(x0 - e.locationInWindow.x), false)
            dragX = e.locationInWindow.x
        }
        override func mouseUp(with e: NSEvent) {
            if dragX != nil { onScroll?(0, true) }
            dragX = nil
            super.mouseUp(with: e)
        }
        // clicks go through to the covers (SwiftUI handles taps); only drags and scrolls are ours
        override func hitTest(_ p: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            return [.scrollWheel, .leftMouseDragged].contains(e.type) ? self : nil
        }
    }

    func makeNSView(context: Context) -> Catcher { let v = Catcher(); v.onScroll = onScroll; v.horizontalOnly = horizontalOnly; return v }
    func updateNSView(_ v: Catcher, context: Context) { v.onScroll = onScroll; v.horizontalOnly = horizontalOnly }
}

/// Albums as Cover Flow over a blurred wash of the middle album's art, its songs on glass below.
struct CoverFlowAlbums: View {
    @EnvironmentObject var model: Model
    var albums: [Album]
    @StateObject private var flow = FlowState()
    @FocusState private var focused: Bool

    var body: some View {
        let i = min(flow.index, max(albums.count - 1, 0))
        let current = albums.indices.contains(i) ? albums[i] : nil
        GeometryReader { g in
            VStack(spacing: 10) {
                CoverFlow(count: albums.count, flow: flow, art: { Cover(image: model.artwork[albums[$0].id], seed: albums[$0].id) }) {
                    model.path.append(.album(albums[$0]))
                }
                    .frame(height: max(280, g.size.height * 0.52))
                    .background { FlowGlow(image: current.flatMap { model.artwork[$0.id] }, seed: current?.id ?? "") }
                if let a = current {
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Text(a.title).font(.title3.bold()).lineLimit(1)
                            SidebarMark(mark: model.mark(a))
                        }
                        Text(a.artist + (a.year > 0 ? " · \(a.year)" : "")).foregroundStyle(.secondary).lineLimit(1)
                        Scrubber(count: albums.count, index: i) { flow.go(to: $0, count: albums.count) }
                            .frame(width: 260).padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    CoverFlowTracks(album: a)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 6)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { flow.step(-1, count: albums.count); return .handled }
        .onKeyPress(.rightArrow) { flow.step(1, count: albums.count); return .handled }
        .onKeyPress(.return) { if let a = current { model.path.append(.album(a)) }; return .handled }
        .onChange(of: i, initial: true) { model.flowAlbum = albums.indices.contains(i) ? albums[i] : nil }
        .onChange(of: albums.map(\.id)) { flow.go(to: min(flow.index, max(albums.count - 1, 0)), count: albums.count) }
    }
}

/// A faint glow of the middle album's colours behind the carousel (not the whole window).
struct FlowGlow: View {
    var image: NSImage?
    var seed: String
    var body: some View {
        Cover(image: image, seed: seed)
            .frame(width: 420, height: 260)
            .blur(radius: 110)
            .opacity(0.32)
            .id(seed)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.5), value: seed)
            .allowsHitTesting(false)
    }
}

/// A slim glass track with a thumb; click or drag anywhere on it.
struct Scrubber: View {
    var count: Int
    var index: Int
    var go: (Int) -> Void
    var body: some View {
        GeometryReader { g in
            let f = count > 1 ? Double(index) / Double(count - 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12)).frame(height: 4)
                Capsule().fill(.primary.opacity(0.35)).frame(width: max(4, g.size.width * f), height: 4)
                Circle().fill(.white).frame(width: 12, height: 12).shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: (g.size.width - 12) * f)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard count > 1 else { return }
                go(Int((min(max(v.location.x / g.size.width, 0), 1) * Double(count - 1)).rounded()))
            })
        }
        .frame(height: 20)
        .help("\(index + 1) of \(count)")
    }
}

/// The songs of the album in the middle, with its iPod state and buttons.
struct CoverFlowTracks: View {
    @EnvironmentObject var model: Model
    var album: Album
    var scrolls = true                  // false: all its songs, in a page that scrolls

    var body: some View {
        let m = model.mark(album), keys = model.podKeys, podOnly = model.isPodOnly(album)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(totalDuration(album.lengthMs) + (album.genre.isEmpty ? "" : " · " + album.genre)).foregroundStyle(.secondary)
                Spacer()
                if !podOnly, m != .onIPod, m != .removing {
                    Button(m == .adding ? "Don't Add" : m == .partial ? "Add Missing" : "Add to iPod",
                           systemImage: m == .adding ? "xmark" : "plus") { model.toggleAdd(album) }
                        .buttonStyle(.glassProminent).disabled(model.ipod == nil)
                }
                if m == .onIPod || m == .partial || m == .removing {
                    Button(m == .removing ? "Keep" : "Remove", systemImage: m == .removing ? "arrow.uturn.backward" : "minus") { model.toggleRemove(album) }
                        .buttonStyle(.glass)
                }
                Button("Open", systemImage: "chevron.right") { model.path.append(.album(album)) }.buttonStyle(.glass)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider().opacity(0.5)
            if scrolls { ScrollView { rows(keys) } } else { rows(keys) }
        }
    }

    func rows(_ keys: Set<String>) -> some View {
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { n, t in
                        HStack(spacing: 12) {
                            Text(t.trackNumber > 0 ? "\(t.trackNumber)" : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            Text(t.title).lineLimit(1)
                            if !t.trackArtist.isEmpty, t.trackArtist != album.artist {
                                Text(t.trackArtist).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if keys.contains(t.key) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("On the iPod") }
                            Text(t.lengthMs > 0 ? duration(t.lengthMs) : "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 5)
                        .background(n % 2 == 1 ? Color.primary.opacity(0.05) : .clear)
                    }
                }
                .padding(.bottom, 12)
    }
}

/// Cover Flow for saved Spotify albums: the carousel, the album in the middle and its buttons.
struct SpotifyCoverFlow: View {
    @EnvironmentObject var model: Model
    var albums: [SpotifyAlbum]
    @StateObject private var flow = FlowState()
    @FocusState private var focused: Bool

    var body: some View {
        let i = min(flow.index, max(albums.count - 1, 0))
        let current = albums.indices.contains(i) ? albums[i] : nil
        GeometryReader { g in
            VStack(spacing: 10) {
                CoverFlow(count: albums.count, flow: flow, art: { CachedImage(url: model.artURL(albums[$0].artworkPath), seed: albums[$0].uri) }) {
                    model.path.append(.spotifyAlbum(albums[$0]))
                }
                .frame(height: max(280, g.size.height * 0.6))
                .background {
                    if let a = current {
                        CachedImage(url: model.artURL(a.artworkPath), seed: a.uri)
                            .frame(width: 420, height: 260).blur(radius: 110).opacity(0.32)
                            .id(a.uri).transition(.opacity).animation(.easeInOut(duration: 0.5), value: a.uri)
                            .allowsHitTesting(false)
                    }
                }
                if let a = current {
                    VStack(spacing: 3) {
                        Text(a.name).font(.title3.bold()).lineLimit(1)
                        Text(a.artist + (a.year > 0 ? " · \(a.year)" : "") + " · \(a.trackCount) saved").foregroundStyle(.secondary).lineLimit(1)
                        Scrubber(count: albums.count, index: i) { flow.go(to: $0, count: albums.count) }
                            .frame(width: 260).padding(.top, 6)
                        HStack(spacing: 10) {
                            Button("Open", systemImage: "chevron.right") { model.path.append(.spotifyAlbum(a)) }
                            Button(model.playURILabel, systemImage: "play.fill") { Task { await model.playURIs([a.uri]) } }
                            if model.on(.soulseek), !model.hasFiles(a) {
                                Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(a.artist, a.name) }
                            }
                        }
                        .buttonStyle(.glass).padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { flow.step(-1, count: albums.count); return .handled }
        .onKeyPress(.rightArrow) { flow.step(1, count: albums.count); return .handled }
        .onKeyPress(.return) { if let a = current { model.path.append(.spotifyAlbum(a)) }; return .handled }
        .onChange(of: albums.map(\.id)) { flow.go(to: min(flow.index, max(albums.count - 1, 0)), count: albums.count) }
    }
}

/// Cover Flow of the artists: their portraits in the carousel; under it a smaller one of the middle artist's albums,
/// newest first, and the middle album's songs. The page scrolls; the carousels take only sideways swipes.
struct CoverFlowArtists: View {
    @EnvironmentObject var model: Model
    var artists: [Artist]
    @StateObject private var flow = FlowState()
    @StateObject private var albumFlow = FlowState()
    @FocusState private var focused: Bool

    var body: some View {
        let i = min(flow.index, max(artists.count - 1, 0))
        let current = artists.indices.contains(i) ? artists[i] : nil
        let albums = current.map { $0.albums.sorted { ($0.year, $0.title) > ($1.year, $1.title) } } ?? []
        let j = min(albumFlow.index, max(albums.count - 1, 0))
        let album = albums.indices.contains(j) ? albums[j] : nil
        GeometryReader { page in
        ScrollView {
            VStack(spacing: 10) {
                CoverFlow(count: artists.count, flow: flow, art: { ArtistImage(artist: artists[$0]) }, horizontalOnly: true) {
                    model.path.append(.artist(artists[$0].name))
                }
                .frame(height: 360)
                .background { FlowGlow(image: current.flatMap { model.artistArt[$0.id] }, seed: current?.id ?? "") }
                if let a = current {
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Text(a.name).font(.title3.bold()).lineLimit(1)
                            SidebarMark(mark: model.artistMark(a))
                        }
                        Text("\(a.albums.count) album\(a.albums.count == 1 ? "" : "s") · \(a.trackCount) songs").foregroundStyle(.secondary).lineLimit(1)
                        Scrubber(count: artists.count, index: i) { flow.go(to: $0, count: artists.count) }
                            .frame(width: 260).padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                }
                // the artist's albums and the middle one's songs, together on one card
                if let al = album {
                    VStack(spacing: 0) {
                        CoverFlow(count: albums.count, flow: albumFlow, art: { Cover(image: model.artwork[albums[$0].id], seed: albums[$0].id) },
                                  horizontalOnly: true, reflection: false, shadow: false, fitAll: true) { _ in }   // a click only scrolls; Open opens
                            .frame(height: 170)
                            .padding(.top, 14)
                        VStack(spacing: 2) {
                            HStack(spacing: 6) {
                                Text(al.title).font(.headline).lineLimit(1)
                                SidebarMark(mark: model.mark(al))
                            }
                            if al.year > 0 { Text(String(al.year)).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4).padding(.bottom, 4)
                        Divider().opacity(0.5)
                        CoverFlowTracks(album: al, scrolls: false)
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)       // down to the bottom of the page, however few songs
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 14)
                }
            }
            .frame(minHeight: page.size.height, alignment: .top)
        }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        // ← → the artists, ⌥← ⌥→ the albums
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { k in
            let by = k.key == .leftArrow ? -1 : 1
            if k.modifiers.contains(.option) { albumFlow.step(by, count: albums.count) } else { flow.step(by, count: artists.count) }
            return .handled
        }
        .onKeyPress(.return) { if let a = current { model.path.append(.artist(a.name)) }; return .handled }
        .onChange(of: artists.map(\.id)) { flow.go(to: min(flow.index, max(artists.count - 1, 0)), count: artists.count) }
        .onChange(of: current?.id) { albumFlow.go(to: 0, count: max(albums.count, 1)) }   // another artist: their newest album
    }
}
