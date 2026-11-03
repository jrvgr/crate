// Draws Crate's app icon (a glass record crate with album sleeves, the front one an iPod wheel)
// and writes Crate.icns next to this file:  swiftc -parse-as-library make-icon.swift -o /tmp/mk && /tmp/mk
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon shape: rounded square on the 1024 grid with 100 px margin
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.93, green: 0.22, blue: 0.36)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.15), startRadius: 0, endRadius: 600)))
                .frame(width: 824, height: 824)
            // sleeves sticking out of the crate, fanned
            sleeve(Color(red: 0.22, green: 0.55, blue: 0.95), angle: -14, x: -150, y: -150)
            sleeve(Color(red: 0.98, green: 0.82, blue: 0.25), angle: 9, x: 130, y: -170)
            sleeve(Color(red: 0.35, green: 0.85, blue: 0.62), angle: -3, x: -10, y: -205)
            // the front sleeve: white, with the click wheel
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.97))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                Circle().fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color(white: 0.72), lineWidth: 5))
                    .frame(width: 250, height: 250)
                Circle().fill(Color(white: 0.97)).overlay(Circle().strokeBorder(Color(white: 0.75), lineWidth: 4)).frame(width: 92, height: 92)
                ForEach(0..<4) { i in       // MENU on top, then clockwise: next, play/pause, previous
                    Image(systemName: ["line.3.horizontal", "forward.end.alt.fill", "playpause.fill", "backward.end.alt.fill"][i])
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(Color(white: 0.55))
                        .offset(x: [0, 86, 0, -86][i], y: [-86, 0, 86, 0][i])
                }
            }
            .frame(width: 370, height: 370)
            .offset(y: -40)
            // the glass crate front
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3)], startPoint: .top, endPoint: .bottom), lineWidth: 6))
                .overlay(alignment: .bottom) {   // a little label on the crate
                    Capsule().fill(.white.opacity(0.75)).frame(width: 150, height: 14).padding(.bottom, 52)
                }
                .shadow(color: .black.opacity(0.2), radius: 24, y: 14)
                .frame(width: 620, height: 330)
                .offset(y: 170)
        }
        .frame(width: 1024, height: 1024)
    }

    func sleeve(_ c: Color, angle: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(c)
            Circle().fill(.black.opacity(0.85)).frame(width: 250, height: 250).offset(x: 120)      // record peeking out
                .mask(RoundedRectangle(cornerRadius: 26).frame(width: 340, height: 340).offset(x: 0)).opacity(0)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 10).frame(width: 150, height: 150)
        }
        .frame(width: 340, height: 340)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
        .rotationEffect(.degrees(angle))
        .offset(x: x, y: y + 120)
    }
}

@main
struct Make {
    @MainActor static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
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
