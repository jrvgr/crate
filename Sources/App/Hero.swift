import SwiftUI

// The cover you click (or an artist's portrait) flies to its place on the album or artist page, and back to its
// tile when you go back. The sidebar's iPod does the same into the iPod page and the sync panel, so there's
// one iPod that moves around the window. SwiftUI's zoom transition isn't on the Mac, so it's an overlay over the detail column:
// tiles and pages report where their art is, and the copy in the overlay springs from one to the other.
// Frames are in window coordinates: the Mac's NavigationStack hosts each page on its own, so a named
// coordinate space set on the stack doesn't reach into the pages.

@MainActor final class Hero: ObservableObject {
    static let shared = Hero()
    static let space = "hero"

    enum Art {
        case album(Album), artist(String)
        case ipod(String)                               // the sidebar's iPod, going to a place ("page", "sync")
        init?(_ r: Route) {
            switch r {
            case .album(let a): self = .album(a)
            case .artist(let n): self = .artist(n)
            default: return nil
            }
        }
        var key: String {
            switch self {
            case .album(let a): "album:" + a.id
            case .artist(let n): "artist:" + n.lowercased()
            case .ipod(let place): "ipod:" + place
            }
        }
        var round: Bool { if case .artist = self { true } else { false } }
        var drawing: Bool { if case .ipod = self { true } else { false } }     // casts its own shadow, no clipping
        /// The iPod isn't clipped: its own shadow reaches past its frame and would pop in when it lands.
        var shape: AnyShape { drawing ? AnyShape(Rectangle().inset(by: -200)) : round ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 15, style: .continuous)) }
    }

    struct Flight {
        var id = UUID(); var art: Art; var from: CGRect; var to: CGRect; var returning: Bool; var landed = false
        var fromLive = false, toLive = false            // the iPod: the remote at that end, or the plain picture
    }
    @Published var flight: Flight?
    /// Places that opened and wait for their art to fly in: kept hidden until then, or the real one shows a frame early.
    @Published private(set) var waiting: Set<String> = []
    /// The remote while it's dragged (or let go and on its way), drawn here so it can go over the whole window.
    @Published var dragged: CGRect?
    var dock: CGRect = .zero                            // the card's icon the remote is put away in

    private var sources: [String: CGRect] = [:], targets: [String: CGRect] = [:]
    private var settled: [String: CGRect] = [:]          // where the art sat on its page once it stopped moving
    private var launched: (key: String, at: Date, from: CGRect)?    // a page opened; it reports where the art goes
    var origin: CGPoint = .zero                         // the overlay's place in the window
    private var returning: (key: String, at: Date)?     // went back; the tile reports where it is once it's back

    func source(_ art: Art, at r: CGRect) {
        sources[art.key] = r
        if let w = returning, w.key == art.key, -w.at.timeIntervalSinceNow < 0.5,
           let from = dropped ?? settled[art.key] ?? targets[art.key] {
            returning = nil; dropped = nil; fly(art, from: from, to: r, returning: true)
        } else { follow(art, to: r, returning: true) }
    }

    func target(_ art: Art, at r: CGRect) {
        targets[art.key] = r
        if let l = launched, l.key == art.key, -l.at.timeIntervalSinceNow < 0.5 {
            // the page's first layout isn't always its last: fly once it's had a moment to settle
            launched = nil
            DispatchQueue.main.async { [self] in
                if let to = targets[art.key] { fly(art, from: l.from, to: to, returning: false) }
            }
        } else { follow(art, to: r, returning: false) }
        // kept while the page is up, so going back starts where the art really sat, not where the
        // page reports it while it's being taken down
        let key = art.key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in if targets[key] == r, launched?.key != key { settled[key] = r } }
    }

    /// Its view left (scrolled away, or swapped for something else). Kept a moment: the iPod's place is
    /// swapped for an icon in the same update that opens its page, before `open` asks where it was.
    /// The remote was let go over the iPod card: from where it was dropped it flies into the card's iPod
    /// once that shows up (and follows it while the sidebar settles), fading from the remote to the picture.
    func dock(from r: CGRect) {
        dropped = r; returning = ("ipod:page", .now)
    }
    private var dropped: CGRect?

    func gone(_ art: Art) {
        if let r = sources.removeValue(forKey: art.key) { left[art.key] = (r, .now) }
    }
    private var left: [String: (rect: CGRect, at: Date)] = [:]

    private var quiet = Date.distantPast               // just switched pages in the sidebar

    func cancel() { flight = nil; launched = nil; returning = nil; quiet = .now }

    /// A flight on its way lands where its end is now (the page or the grid moved meanwhile).
    private func follow(_ art: Art, to r: CGRect, returning: Bool) {
        guard let f = flight, f.art.key == art.key, f.returning == returning, f.to != r else { return }
        if f.landed { withAnimation(.spring(duration: 0.3)) { flight?.to = r } } else { flight?.to = r }
    }

    /// Opening an album or artist page (from the cover, its label or anywhere else) sends its art there;
    /// going back sends it home.
    func navigated(from old: [Route], to new: [Route]) {
        guard -quiet.timeIntervalSinceNow > 0.3 else { return }     // the pane and path change in either order
        // tiles are on the pane's own page and on artist pages; a page on top of them (a release's details, say)
        // leaves them registered but hidden underneath, so the art would fly from or to somewhere you can't see
        func showsTiles(_ path: [Route]) -> Bool { guard let top = path.last else { return true }; if case .artist = top { return true }; return false }
        if new.count > old.count, Array(new.prefix(old.count)) == old, let last = new.last, let art = Art(last) {
            if showsTiles(old) { open(art) }
            return
        }
        guard new.count < old.count, Array(old.prefix(new.count)) == new, let last = old.last, let art = Art(last), showsTiles(new) else { return }
        close(art)
    }

    /// Its place opened: the art flies there once the place reports where that is.
    func open(_ art: Art) {
        // where the source is right now: once the place is up, what's behind it may report other frames
        let recent = left[art.key].flatMap { -$0.at.timeIntervalSinceNow < 0.5 ? $0.rect : nil }
        if let from = sources[art.key] ?? recent {
            launched = (art.key, .now, from)
            let key = art.key
            waiting.insert(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in waiting.remove(key) }     // no flight after all
        }
        settled[art.key] = nil
    }

    /// Its place closed: the art flies home.
    func close(_ art: Art) {
        if let to = sources[art.key], let from = settled[art.key] ?? targets[art.key] { fly(art, from: from, to: to, returning: true) }
        else { returning = (art.key, .now) }
    }

    private func fly(_ art: Art, from: CGRect, to: CGRect, returning: Bool) {
        defer { waiting.remove(art.key) }
        guard from.width > 0, to.width > 0, from.maxY > 0 else { return }     // not from a page scrolled past its art
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }    // Reduce Motion: the pages just fade
        var f = Flight(art: art, from: from, to: to, returning: returning)
        if case .ipod(let place) = art {
            // the sidebar shows the remote unless it's docked; the iPod page shows it while something plays;
            // the sync panel never does. The copy fades from one look to the other on the way.
            let player = Model.shared?.player
            let playing = player?.current != nil
            let sidebar = playing && player?.docked == false, there = place == "page" && playing
            (f.fromLive, f.toLive) = returning ? (there, sidebar) : (sidebar, there)
        }
        flight = f
        DispatchQueue.main.async {
            // .removed: the spring's last few pixels too, so the copy doesn't snap onto the real one
            withAnimation(.spring(duration: 0.5, bounce: 0.3), completionCriteria: .removed) { self.flight?.landed = true } completion: {
                if self.flight?.id == f.id { self.flight = nil }
            }
        }
    }
}

struct HeroOverlay: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var player: Player
    @ObservedObject private var hero = Hero.shared

    var body: some View {
        ZStack {
            if let d = hero.dragged {
                // drawn at one size and scaled, so its screen moves along with it
                let h: CGFloat = 200
                LiveIPod(height: h).frame(width: h * IPodArt.aspect, height: h)
                    .scaleEffect(d.height / h)
                    .position(x: d.midX - hero.origin.x, y: d.midY - hero.origin.y)
            }
            if let f = hero.flight {
                let r = f.landed ? f.to : f.from
                Group {
                    switch f.art {
                    case .album(let a): Cover(image: model.artwork[a.id], seed: a.id)
                    case .artist(let n): ArtistPortrait(name: n)
                    case .ipod:
                        // drawn once at its larger size and scaled: redrawn per size, the screen's text
                        // would jump to its end layout and only slide, while the iPod around it springs
                        let base = max(f.from.height, f.to.height)
                        let live = f.landed ? f.toLive : f.fromLive
                        ZStack {
                            PodPicture(height: base).opacity(live ? 0 : 1)
                            if player.current != nil { LiveIPod(height: base).opacity(live ? 1 : 0) }
                        }
                        .scaleEffect(r.height / base).frame(width: r.width, height: r.height)
                    }
                }
                .frame(width: r.width, height: r.height)
                .clipShape(f.art.shape)
                .shadow(color: .black.opacity(f.art.drawing ? 0 : 0.3), radius: 14, y: 6)
                .position(x: r.midX - hero.origin.x, y: r.midY - hero.origin.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { hero.origin = $0 }
        .allowsHitTesting(false)
    }
}

extension View {
    /// A tile's art: opening its page sends a copy flying there. `away`: its place is open, so it shows there instead.
    func heroSource(_ art: Hero.Art, away: Bool = false) -> some View { modifier(HeroSource(art: art, away: away)) }
    /// Where the art lands on an album or artist page.
    func heroTarget(_ art: Hero.Art) -> some View { modifier(HeroTarget(art: art)) }
}

// No tap gesture of its own: on the Mac one inside a NavigationLink swallows the link's click.
private struct HeroSource: ViewModifier {
    @ObservedObject private var hero = Hero.shared
    var art: Hero.Art
    var away = false

    func body(content: Content) -> some View {
        content
            .opacity(away || hero.flight?.art.key == art.key ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hero.source(art, at: $0) }
            .onDisappear { hero.gone(art) }
    }
}

private struct HeroTarget: ViewModifier {
    @ObservedObject private var hero = Hero.shared
    var art: Hero.Art

    func body(content: Content) -> some View {
        content
            .opacity(hero.flight?.art.key == art.key || hero.waiting.contains(art.key) ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hero.target(art, at: $0) }
    }
}

