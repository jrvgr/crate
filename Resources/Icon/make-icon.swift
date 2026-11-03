// Draws Crate's app icon (the 3rd gen iPod's face: Frogger's Now Playing page on the LCD and the four
// red touch buttons) and writes Crate.icns next to this file:  swiftc -parse-as-library make-icon.swift -o /tmp/mk && /tmp/mk
import SwiftUI
import AppKit
import CoreText

// The screen and buttons keep the proportions of the 3G drawing in the iPod Accessory Protocol spec
// (see PodGlyph): LCD window 13.38 × 10.95 units at (3.06, 1.93), buttons 3.9 across at y 15.7.
// The wheel is left out and the block is scaled up and centred.
let unit: CGFloat = 43.5
let top = (824 - 15.72 * unit) / 2 - 1.93 * unit              // LCD top 1.93 to button bottom 17.65
let lcdPalette: [Color] = [(0xc6, 0xd0, 0xc0), (0x8c, 0x95, 0x88), (0x50, 0x56, 0x4e), (0x10, 0x12, 0x10)]   // CoverStudioUI.lcd
    .map { Color(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255) }
let buttonRed = Color(red: 1, green: 0.22, blue: 0.16)

/// A 72×72 cover in the LCD's four greys (0 = lightest), ordered-dithered like FroggerArt: a record sliding out of its sleeve.
func cover() -> [[Int]] {
    let n = 72
    let cs = CGColorSpaceCreateDeviceGray()
    let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: cs, bitmapInfo: 0)!
    c.setFillColor(gray: 0.92, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
    // record
    c.setFillColor(gray: 0.08, alpha: 1); c.fillEllipse(in: CGRect(x: 22, y: 22, width: 46, height: 46))
    c.setStrokeColor(gray: 0.3, alpha: 1); c.setLineWidth(0.8)
    for r in stride(from: 8.0, through: 21.0, by: 4.0) { c.strokeEllipse(in: CGRect(x: 45 - r, y: 45 - r, width: 2 * r, height: 2 * r)) }
    c.setFillColor(gray: 0.85, alpha: 1); c.fillEllipse(in: CGRect(x: 39, y: 39, width: 12, height: 12))
    c.setFillColor(gray: 0.08, alpha: 1); c.fillEllipse(in: CGRect(x: 44, y: 44, width: 2, height: 2))
    // sleeve, shaded
    let g = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.35, alpha: 1)] as CFArray, locations: nil)!
    c.saveGState(); c.clip(to: CGRect(x: 4, y: 4, width: 44, height: 44))
    c.drawLinearGradient(g, start: CGPoint(x: 4, y: 48), end: CGPoint(x: 48, y: 4), options: [])
    c.restoreGState()
    c.setStrokeColor(gray: 0.05, alpha: 1); c.setLineWidth(1.5); c.stroke(CGRect(x: 4.75, y: 4.75, width: 42.5, height: 42.5))
    let px = c.data!.assumingMemoryBound(to: UInt8.self)
    let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
    return (0..<n).map { y in (0..<n).map { x in
        let v = 1 - Double(px[y * n + x]) / 255               // 0 = white … 1 = black
        let t = v * 3 + (Double(bayer[y % 4][x % 4]) + 0.5) / 16 - 0.5
        return min(3, max(0, Int(t.rounded())))
    } }
}

struct Icon: View {
    let art = cover()
    func u(_ v: CGFloat) -> CGFloat { v * unit }
    func x(_ v: CGFloat) -> CGFloat { 412 + (v - 9.75) * unit }
    func y(_ v: CGFloat) -> CGFloat { top + v * unit }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // white polycarbonate, a little cooler towards the bottom
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 1), Color(red: 0.89, green: 0.9, blue: 0.92)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            ForEach(0..<4) { i in button(i).offset(x: x([3.44, 7.65, 11.86, 16.06][i] - 1.95), y: y(15.7 - 1.95)) }
            screen.offset(x: x(3.06), y: y(1.93))
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .frame(width: 1024, height: 1024)
    }

    // Frogger's Now Playing page (payload/nowplaying.h, as in Cover Studio) behind a dark glass bezel
    var screen: some View {
        let w = u(13.38), h = u(10.95), inset = w * 0.045
        let lw = w - 2 * inset, p = lw / 160                  // one LCD pixel
        let chicago = Font.custom("ChicagoFLF", fixedSize: 12 * p)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.16))
            ZStack(alignment: .topLeading) {
                lcdPalette[0]
                Text("Crate").font(chicago).frame(width: 156 * p).offset(x: 2 * p, y: 1 * p)
                Rectangle().frame(width: 160 * p, height: p).offset(y: 16 * p)
                Canvas { ctx, _ in
                    for (y, row) in art.enumerated() { for (x, v) in row.enumerated() where v > 0 {
                        ctx.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p + 0.5, height: p + 0.5)), with: .color(lcdPalette[v]))
                    } }
                }
                .frame(width: 72 * p, height: 72 * p).offset(x: 44 * p, y: 20 * p)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3 * p).stroke(lineWidth: p)
                    RoundedRectangle(cornerRadius: 3 * p).frame(width: 60 * p)
                }
                .frame(width: 144 * p, height: 8 * p).offset(x: 8 * p, y: 98 * p)
                HStack { Text("1:12"); Spacer(); Text("-2:31") }.font(chicago).frame(width: 144 * p).offset(x: 8 * p, y: 109 * p)
            }
            .foregroundStyle(lcdPalette[3])
            .frame(width: lw, height: lw * 128 / 160)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .offset(x: inset, y: (h - lw * 128 / 160) / 2)
            // glass glare across the top
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.5)))
        }
        .frame(width: w, height: h)
    }

    // a touch button: a faint ring, its label lit from behind and the light spilling softly into the plastic
    func button(_ i: Int) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [buttonRed.opacity(0.13), buttonRed.opacity(0.03), .clear], center: .center, startRadius: 0, endRadius: u(1.95)))
            Circle().strokeBorder(Color(white: 0.8), lineWidth: 2.5)
            label(i).foregroundStyle(buttonRed).blur(radius: 16).opacity(0.5)
            label(i).foregroundStyle(buttonRed).blur(radius: 2.5).opacity(0.45)
            label(i).foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.32, blue: 0.24), Color(red: 0.93, green: 0.16, blue: 0.12)], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: u(3.9), height: u(3.9))
    }

    @ViewBuilder func label(_ i: Int) -> some View {
        switch i {
        case 0: HStack(spacing: 0) { Rectangle().frame(width: 6, height: 31); tri(left: true); tri(left: true) }
        case 1: Text("MENU").font(.system(size: 31, weight: .bold, design: .rounded))
        case 2: HStack(spacing: 6) { tri(left: false); Rectangle().frame(width: 7, height: 31); Rectangle().frame(width: 7, height: 31) }
        default: HStack(spacing: 0) { tri(left: false); tri(left: false); Rectangle().frame(width: 6, height: 31) }
        }
    }

    func tri(left: Bool) -> some View {
        Path { p in
            p.move(to: CGPoint(x: left ? 24 : 0, y: 0)); p.addLine(to: CGPoint(x: left ? 0 : 24, y: 15.5)); p.addLine(to: CGPoint(x: left ? 24 : 0, y: 31)); p.closeSubpath()
        }
        .frame(width: 24, height: 31)
    }
}

@main
struct Make {
    @MainActor static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        CTFontManagerRegisterFontsForURL(dir.appendingPathComponent("../Fonts/ChicagoFLF.ttf").standardizedFileURL as CFURL, .process, nil)
        let set = dir.appendingPathComponent("Crate.iconset")
        try? FileManager.default.removeItem(at: set)
        try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let px = size * scale
            let r = ImageRenderer(content: Icon().scaleEffect(CGFloat(px) / 1024).frame(width: CGFloat(px), height: CGFloat(px)))
            r.scale = 1
            guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
            try! png.write(to: set.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
            if px == 1024 { try! png.write(to: dir.appendingPathComponent("icon-1024.png")) }
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", dir.appendingPathComponent("Crate.icns").path]
        try! p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(at: set)
        print("wrote Crate.icns")
    }
}
