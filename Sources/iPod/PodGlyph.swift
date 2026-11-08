import SwiftUI
import AppKit

// iPod icons traced from Apple's compatibility icons in the iPod Accessory Protocol spec (R38),
// drawn as template images so they tint like SF Symbols and work in menus and the menu bar.

enum PodGlyph {
    enum Kind { case third, fourth, photo, mini, wheel }

    /// Size of the drawing in spec units (points in the PDF); the 3G/4G icons are 19.5 × 32.46.
    static func size(_ k: Kind) -> CGSize { k == .mini ? CGSize(width: 16.07, height: 28.55) : CGSize(width: 19.5, height: 32.46) }

    /// A template image `height` points tall; `badge` adds a plus like `ipod.badge.plus`.
    static func image(_ k: Kind, height: CGFloat, badge: Bool = false) -> NSImage {
        let u = size(k), s = height / u.height
        let w = (u.width * s).rounded(.up) + (badge ? height * 0.3 : 0)
        let img = NSImage(size: CGSize(width: w, height: height), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: s, y: s)
            // the spec's hairlines vanish at icon sizes: about one pixel at menu size, thin like the spec when large
            draw(k, in: c, line: max(0.5, height * 0.028) / s)
            if badge {
                c.setLineWidth(max(0.75, height * 0.045) / s); c.setLineCap(.round)
                let x = (w / s) - 3.2, y = u.height - 6
                c.move(to: CGPoint(x: x - 3, y: y)); c.addLine(to: CGPoint(x: x + 3, y: y))
                c.move(to: CGPoint(x: x, y: y - 3)); c.addLine(to: CGPoint(x: x, y: y + 3))
                c.strokePath()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static func draw(_ k: Kind, in c: CGContext, line lw: CGFloat) {
        c.setStrokeColor(.black); c.setFillColor(.black); c.setLineWidth(lw)
        let h = lw / 2
        // shapes are given by their outer edge in the spec; strokes sit just inside it
        func ring(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, line: CGFloat? = nil) {
            let l = line ?? lw
            c.setLineWidth(l); c.strokeEllipse(in: CGRect(x: x - r + l / 2, y: y - r + l / 2, width: 2 * r - l, height: 2 * r - l)); c.setLineWidth(lw)
        }
        func box(_ r: CGRect, _ radius: CGFloat) {
            let i = r.insetBy(dx: h, dy: h)
            c.addPath(CGPath(roundedRect: i, cornerWidth: min(max(0, radius - h), i.width / 2), cornerHeight: min(max(0, radius - h), i.height / 2), transform: nil))
            c.strokePath()
        }
        if k == .mini {
            box(CGRect(x: 0, y: 0, width: 16.07, height: 28.55), 0.6)
            box(CGRect(x: 2.53, y: 1.85, width: 10.94, height: 8.56), 0.4)
            ring(8.04, 19.64, 6.13); ring(8.04, 19.64, 2.16)
            return
        }
        box(CGRect(x: 0, y: 0, width: 19.5, height: 32.46), 2.05)
        box(CGRect(x: 3.06, y: 1.93, width: 13.38, height: 10.95), 0.5)
        switch k {
        case .third:
            // the four touch buttons are thinner so they stay apart at small sizes
            for x in [3.44, 7.65, 11.86, 16.06] as [CGFloat] { ring(x, 15.7, 1.95, line: lw * 0.6) }
            ring(9.77, 24.21, 6.21); ring(9.77, 24.21, 2.38)
        case .wheel:
            ring(9.75, 23.92, 6.4); ring(9.75, 23.92, 2.3)
        case .fourth, .photo:
            // a dark wheel with a light centre button
            c.addEllipse(in: CGRect(x: 9.75 - 6.6, y: 23.92 - 6.6, width: 13.2, height: 13.2))
            c.addEllipse(in: CGRect(x: 9.75 - 2.13, y: 23.92 - 2.13, width: 4.26, height: 4.26))
            c.fillPath(using: .evenOdd)
            if k == .photo { c.addPath(flower); c.fillPath() }
        case .mini: break
        }
    }

    /// The colour-display flower that marks the iPod photo icon.
    static let flower: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 9.84, y: 12.65))
        p.addCurve(to: CGPoint(x: 9.86, y: 12.0), control1: CGPoint(x: 9.85, y: 12.43), control2: CGPoint(x: 9.85, y: 12.21))
        p.addCurve(to: CGPoint(x: 13.53, y: 9.24), control1: CGPoint(x: 11.46, y: 12.01), control2: CGPoint(x: 14.05, y: 12.44))
        p.addCurve(to: CGPoint(x: 11.14, y: 10.25), control1: CGPoint(x: 12.84, y: 9.92), control2: CGPoint(x: 11.9, y: 9.8))
        p.addCurve(to: CGPoint(x: 9.87, y: 11.83), control1: CGPoint(x: 10.53, y: 10.61), control2: CGPoint(x: 10.27, y: 11.32))
        p.addCurve(to: CGPoint(x: 10.03, y: 9.28), control1: CGPoint(x: 9.94, y: 10.56), control2: CGPoint(x: 9.99, y: 9.58))
        p.addCurve(to: CGPoint(x: 10.39, y: 8.87), control1: CGPoint(x: 10.03, y: 9.28), control2: CGPoint(x: 10.39, y: 9.3))
        p.addCurve(to: CGPoint(x: 10.39, y: 8.68), control1: CGPoint(x: 10.39, y: 8.85), control2: CGPoint(x: 10.39, y: 8.69))
        p.addLine(to: CGPoint(x: 10.39, y: 8.67))
        p.addLine(to: CGPoint(x: 10.39, y: 8.67))
        p.addCurve(to: CGPoint(x: 10.8, y: 5.65), control1: CGPoint(x: 12.13, y: 7.57), control2: CGPoint(x: 10.8, y: 5.65))
        p.addCurve(to: CGPoint(x: 10.46, y: 6.55), control1: CGPoint(x: 10.74, y: 5.94), control2: CGPoint(x: 10.56, y: 6.26))
        p.addCurve(to: CGPoint(x: 9.73, y: 5.37), control1: CGPoint(x: 10.38, y: 6.22), control2: CGPoint(x: 9.87, y: 5.66))
        p.addCurve(to: CGPoint(x: 9.14, y: 6.59), control1: CGPoint(x: 9.73, y: 5.37), control2: CGPoint(x: 9.2, y: 6.09))
        p.addCurve(to: CGPoint(x: 8.72, y: 5.63), control1: CGPoint(x: 9.02, y: 6.28), control2: CGPoint(x: 8.8, y: 5.96))
        p.addCurve(to: CGPoint(x: 9.32, y: 8.7), control1: CGPoint(x: 8.72, y: 5.63), control2: CGPoint(x: 7.39, y: 7.64))
        p.addCurve(to: CGPoint(x: 9.34, y: 8.71), control1: CGPoint(x: 9.33, y: 8.7), control2: CGPoint(x: 9.33, y: 8.7))
        p.addCurve(to: CGPoint(x: 9.7, y: 9.31), control1: CGPoint(x: 9.34, y: 8.8), control2: CGPoint(x: 9.34, y: 9.31))
        p.addLine(to: CGPoint(x: 9.7, y: 9.31))
        p.addCurve(to: CGPoint(x: 9.67, y: 11.34), control1: CGPoint(x: 9.71, y: 10.02), control2: CGPoint(x: 9.7, y: 10.7))
        p.addCurve(to: CGPoint(x: 8.4, y: 9.74), control1: CGPoint(x: 9.27, y: 10.82), control2: CGPoint(x: 9.01, y: 10.1))
        p.addCurve(to: CGPoint(x: 6.01, y: 8.73), control1: CGPoint(x: 7.64, y: 9.29), control2: CGPoint(x: 6.69, y: 9.4))
        p.addCurve(to: CGPoint(x: 9.67, y: 11.48), control1: CGPoint(x: 5.48, y: 11.93), control2: CGPoint(x: 8.07, y: 11.5))
        p.addCurve(to: CGPoint(x: 9.66, y: 11.68), control1: CGPoint(x: 9.67, y: 11.55), control2: CGPoint(x: 9.66, y: 11.62))
        p.addLine(to: CGPoint(x: 9.59, y: 12.65))
        p.addLine(to: CGPoint(x: 9.84, y: 12.65))
        p.closeSubpath()
        return p
    }()
}

extension IPodInfo {
    var glyph: PodGlyph.Kind {
        switch modelName {
        case "iPod (4th generation)": return .fourth
        case "iPod photo": return .photo
        case "iPod mini": return .mini
        case "iPod (1st/2nd generation)": return .wheel
        default: return .third
        }
    }
}

extension Image {
    /// The iPod icon, by default the 3rd generation one; sized like a symbol at body text.
    /// An SF Symbol by name, except "ipod", which gets the drawn iPod.
    init(symbol name: String) { self = name == "ipod" ? .pod() : Image(systemName: name) }

    static func pod(_ k: PodGlyph.Kind? = nil, height: CGFloat = 16, badge: Bool = false) -> Image {
        Image(nsImage: PodGlyph.image(k ?? .third, height: height, badge: badge))
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, pod k: PodGlyph.Kind?) { self.init { Text(title) } icon: { Image.pod(k) } }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, pod k: PodGlyph.Kind?, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, pod: k) }
    }
}

/// The iPod with where something stands on it as a badge in its corner, as on the album tiles' marks:
/// a grey plus when it isn't there, then the mark's own symbol and colour.
struct PodStateIcon: View {
    var mark: SyncMark
    var pinned = false                  // an artist kept on the iPod
    var body: some View {
        // only on the iPod: the iPod on its own
        let symbol: String? = pinned ? "pin.fill" : mark == .podOnly ? nil : mark.icon ?? "plus"
        // the state's symbol just past the iPod's corner, in the text's colour: in a glass button colours wash out
        // (a blue + came out pale cyan, on a disc or not), while the label's own colour stays crisp
        HStack(alignment: .bottom, spacing: 0) {
            Image(symbol: "ipod")
            if let symbol {
                Image(systemName: symbol).font(.system(size: 7.5, weight: .black))
                    .offset(x: -1, y: 1)
            }
        }
    }
}

/// A song's (or a list row's) place on the iPod: the state's plain symbol, like the corner of the album page's
/// iPod button, not a bright filled disc; the iPod glyph itself only for a song that's only on the iPod.
/// On the iPod, the usual case, is quiet; only queued changes take a colour.
struct SongMark: View {
    var mark: SyncMark
    var body: some View {
        Group {
            if mark == .podOnly { Image(symbol: "ipod") }
            else { Image(systemName: mark.icon ?? "plus").font(.system(size: 11, weight: .bold)) }
        }
            .foregroundStyle(style)
            .frame(width: 22, alignment: .center)
            .help(mark == .none ? "Not on the iPod" : mark.help)
    }
    private var style: AnyShapeStyle {
        switch mark {
        case .none: AnyShapeStyle(.quaternary)
        case .onIPod, .podOnly: AnyShapeStyle(.secondary)
        case .adding, .removing, .partial: AnyShapeStyle(mark.tint)
        }
    }
}
