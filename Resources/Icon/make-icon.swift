// Draws Crate's app icon (a glass record crate with album sleeves, the front one an iPod wheel)
// and writes Crate.icns next to this file:  swiftc -parse-as-library make-icon.swift -o /tmp/mk && /tmp/mk
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        ZStack {
            // background: deep indigo, lit from the top left
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.2, blue: 0.55), Color(red: 0.07, green: 0.06, blue: 0.2)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.45, blue: 1).opacity(0.45), .clear], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 520)))
                .frame(width: 824, height: 824)
            // the record, pulled halfway out
            record.frame(width: 560, height: 560).offset(y: -95)
            // frosted glass sleeve over its lower half
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(.white.opacity(0.16))
                .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Color(red: 0.1, green: 0.08, blue: 0.28).opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 5))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                        .clipShape(.rect(topLeadingRadius: 44, topTrailingRadius: 44))
                }
                .frame(width: 640, height: 360)
                .offset(y: 200)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        }
        .frame(width: 1024, height: 1024)
    }

    var record: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            ForEach(0..<14) { i in          // grooves
                Circle().strokeBorder(Color(white: 0.16), lineWidth: 1.5).padding(CGFloat(18 + i * 12))
            }
            // the light catching the grooves
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.22), .clear, .clear, .white.opacity(0.12), .clear],
                                          center: .center, angle: .degrees(-30)))
            // label: warm orange with a little click wheel
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.25), Color(red: 0.95, green: 0.3, blue: 0.35)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 210, height: 210)
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 10).frame(width: 130, height: 130)
            Circle().fill(.white.opacity(0.9)).frame(width: 42, height: 42)
            Circle().fill(Color(white: 0.06)).frame(width: 14, height: 14)
        }
        .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
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
