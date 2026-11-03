import SwiftUI
import CoreText
import AVFoundation

// A drawn 3rd gen iPod (2003) that shows what Crate is doing. Proportions are measured off
// photos of the real thing: a 160×128 LCD in a dark bezel, four round touch buttons whose
// labels glow red, and a plain touch wheel. The LCD uses ChicagoFLF (a public-domain Chicago
// revival, Fonts/ChicagoFLF.ttf) and copies the firmware's screens: the main menu, the ⊘
// "Do not disconnect." screen while syncing (plus a progress bar the real one doesn't have)
// and the ✓ "OK to disconnect." one after. The whole thing grows and bounces when something
// happens (hover, a drop, a sync starting or finishing).

struct IPodArt: View {
    enum Mode: Equatable { case idle, syncing(Double), done, offline, dropping }
    var mode: Mode
    var name: String
    var height: CGFloat
    /// What's playing, for the Now Playing screen (shown instead of the menu when idle).
    var nowPlaying: NowPlaying? = nil
    /// Makes the buttons and wheel work as the player's controls.
    var controls: Controls? = nil
    /// The iPod runs Frogger: it wears a frog sticker.
    var frogger = false
    @StateObject private var wheelState = WheelState()

    init(mode: Mode, name: String, height: CGFloat, nowPlaying: NowPlaying? = nil, controls: Controls? = nil, frogger: Bool = false) {
        self.mode = mode; self.name = name; self.height = height
        self.nowPlaying = nowPlaying; self.controls = controls; self.frogger = frogger
    }

    struct Controls {
        var previous, toggle, next, menu, select: () -> Void
        var openArtist: () -> Void
        var seek: (Double) -> Void                     // 0…1 of the song
        var position: Double                           // 0…1 of the song
        var volume: Double
        var setVolume: (Double) -> Void
    }

    final class WheelState: ObservableObject {
        var lastAngle: Double?
        var turned = 0.0
        @Published var dragging = false
        @Published var adjustedAt = Date.distantPast
        /// The centre button switches the wheel from volume to scrubbing, until it's left alone
        /// for 3 s, like the real one.
        @Published var scrubbing = false
        var scrubActive: Bool { scrubbing && Date().timeIntervalSince(adjustedAt) < 3 }
        var showingVolume: Bool { !scrubActive && Date().timeIntervalSince(adjustedAt) < 1.5 }
    }

    struct NowPlaying: Equatable {
        var title, artist, album: String
        var index, count: Int
        var time, length: Double
        var playing: Bool
    }

    /// Real 3G: 61.8 × 104 mm.
    static let aspect: CGFloat = 0.594

    static let chicagoRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "ChicagoFLF", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    var body: some View {
        _ = Self.chicagoRegistered
        let w = height * Self.aspect
        return TimelineView(.animation(paused: !(mode.isSyncing || mode == .dropping))) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                shell(w: w)
                screen(w: w)
                    .position(x: w / 2, y: height * 0.054 + w * 0.68 * 0.815 / 2)
                buttons(w: w)
                    .position(x: w / 2, y: height * 0.474)
                wheel(w: w, t: t)
                    .position(x: w / 2, y: height * 0.743)
                if frogger {
                    if height > 120 {      // in the corner below the wheel, half over the edge
                        FrogSticker(size: w * 0.2).position(x: w * 0.87, y: height * 0.935)
                    } else {               // small: a bigger sticker on the corner, so it still reads as a frog
                        let s = max(w * 0.2, 15)
                        FrogSticker(size: s).position(x: w - s * 0.2, y: height - s * 0.3)
                    }
                }
            }
            .frame(width: w, height: height)
            .saturation(mode == .offline ? 0 : 1)
            .opacity(mode == .offline ? 0.6 : 1)
        }
    }

    // MARK: parts

    /// White polycarbonate front inside a slightly darker polished edge.
    func shell(w: CGFloat) -> some View {
        let r = w * 0.1, edge = w * 0.022
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.8)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.3), radius: w * 0.06, y: w * 0.03)
            RoundedRectangle(cornerRadius: r - edge, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.985), Color(white: 0.94)], startPoint: .top, endPoint: .bottom))
                .padding(edge)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, w * 0.006))
        }
        .frame(width: w, height: height)
    }

    var lcdInk: Color { Color(red: 0.17, green: 0.2, blue: 0.29) }

    func screen(w: CGFloat) -> some View {
        let bw = w * 0.68, bh = bw * 0.815          // bezel, 232:189 in the photos
        let inset = bw * 0.03
        let sw = bw - inset * 2, sh = sw / 1.25     // 160 × 128 LCD
        let lit = mode != .offline
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: w * 0.022, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.3)], startPoint: .top, endPoint: .bottom))
                .frame(width: bw, height: bh)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(lit
                    ? LinearGradient(colors: [Color(red: 0.86, green: 0.9, blue: 0.96), Color(red: 0.76, green: 0.82, blue: 0.9)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color(red: 0.66, green: 0.69, blue: 0.66), Color(red: 0.6, green: 0.63, blue: 0.6)], startPoint: .top, endPoint: .bottom))
                if lit, height > 70 {
                    lcd(u: sw / 160).transition(.opacity)
                }
            }
            .frame(width: sw, height: sh)
            .clipShape(RoundedRectangle(cornerRadius: sw * 0.012))
            .padding(.top, inset)   // the bezel is deeper below the LCD
        }
        .frame(width: bw, height: bh)
        .animation(.easeInOut(duration: 0.3), value: mode)
    }

    func chicago(_ size: CGFloat) -> Font {
        Self.chicagoRegistered ? .custom("ChicagoFLF", fixedSize: size) : .system(size: size, weight: .bold)
    }

    /// The firmware's screens, laid out on the LCD's 160 × 128 pixel grid (u = one pixel).
    func lcd(u: CGFloat) -> some View {
        let titleH = 19 * u
        return VStack(spacing: 0) {
            // title bar: title centred, battery on the right, rule underneath
            ZStack {
                if let np = nowPlaying, mode == .idle {
                    Group {
                        if np.playing { PlayGlyph().frame(width: 7 * u, height: 8 * u) }
                        else { PauseGlyph().frame(width: 7 * u, height: 8 * u) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 5 * u)
                }
                Text(title).font(chicago(12 * u)).lineLimit(1).frame(maxWidth: 110 * u)
                Battery(u: u, charging: mode.isSyncing || mode == .done || mode == .dropping)
                    .frame(width: 17 * u, height: 8 * u)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4 * u)
            }
            .frame(height: titleH)
            Rectangle().frame(height: max(0.5, u))
            page(u: u).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(lcdInk)
    }

    var title: String {
        switch mode {
        case .dropping: return "Add Songs"
        case .idle where nowPlaying != nil: return "Now Playing"
        default: return "iPod"
        }
    }

    @ViewBuilder func page(u: CGFloat) -> some View {
        switch mode {
        case .syncing(let p):
            VStack(spacing: 6 * u) {
                NoSign().stroke(lcdInk, lineWidth: 4.5 * u).frame(width: 46 * u, height: 46 * u)
                Text("Do not disconnect.").font(chicago(12 * u))
                // not on the real iPod: the Now Playing scrubber, used as sync progress
                ZStack(alignment: .leading) {
                    Capsule().strokeBorder(lineWidth: u)
                    Capsule().frame(width: max(6 * u, 120 * u * min(max(p, 0), 1)))
                }
                .frame(width: 120 * u, height: 6 * u)
            }
            .padding(.top, 9 * u)
        case .done:
            VStack(spacing: 8 * u) {
                Check().stroke(lcdInk, style: StrokeStyle(lineWidth: 6 * u, lineCap: .square, lineJoin: .miter))
                    .frame(width: 44 * u, height: 40 * u)
                Text("OK to disconnect.").font(chicago(12 * u))
            }
            .padding(.top, 18 * u)
        case .dropping:
            VStack(spacing: 8 * u) {
                Image(systemName: "arrow.down").font(.system(size: 38 * u, weight: .heavy))
                Text("Drop to add").font(chicago(12 * u))
            }
            .padding(.top, 18 * u)
        case .idle where nowPlaying != nil:
            nowPlayingPage(nowPlaying!, u: u)
        default:
            VStack(spacing: 0) {
                ForEach(Array(["Music", "Extras", "Settings", "Shuffle Songs", "Backlight"].enumerated()), id: \.offset) { i, item in
                    let sel = i == 0
                    HStack(spacing: 0) {
                        Text(item).font(chicago(12 * u)).lineLimit(1)
                        Spacer(minLength: 0)
                        if i < 3 { Chevron().stroke(style: StrokeStyle(lineWidth: 2 * u, lineCap: .square)).frame(width: 4 * u, height: 7 * u) }
                    }
                    .padding(.leading, 4 * u).padding(.trailing, 5 * u)
                    .frame(height: 18 * u)
                    .foregroundStyle(sel ? Color(red: 0.84, green: 0.89, blue: 0.95) : lcdInk)
                    .background(sel ? lcdInk : .clear)
                }
            }
            .padding(.top, 1 * u)
        }
    }

    /// The firmware's Now Playing screen: "3 of 12", song / artist / album, the scrubber, and
    /// elapsed and remaining time.
    func nowPlayingPage(_ np: NowPlaying, u: CGFloat) -> some View {
        let p = np.length > 0 ? min(max(np.time / np.length, 0), 1) : 0
        let clock = { (s: Double) in String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        return VStack(spacing: 0) {
            Text("\(np.index) of \(np.count)").font(chicago(9 * u))
                .frame(maxWidth: .infinity, alignment: .leading)
            // song and album open the album in the library, the artist opens the artist
            VStack(spacing: 2 * u) {
                ForEach(Array([(np.title, "Show the album"), (np.artist, "Show the artist"), (np.album, "Show the album")].enumerated()), id: \.offset) { i, line in
                    if !line.0.isEmpty {
                        Text(line.0).font(chicago(12 * u)).lineLimit(1)
                            .highPriorityGesture(TapGesture().onEnded { if let c = controls { Clicker.press(); i == 1 ? c.openArtist() : c.select() } },
                                                 including: controls == nil ? .subviews : .all)
                            .pointerStyle(controls == nil ? nil : .link)
                            .help(controls == nil ? "" : line.1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 3 * u)
            Spacer(minLength: 0)
            if let c = controls, wheelState.showingVolume {
                // turning the wheel: the firmware's volume bar, speaker to loud speaker
                HStack(spacing: 4 * u) {
                    Image(systemName: "speaker.fill").font(.system(size: 8 * u))
                    ZStack(alignment: .leading) {
                        Capsule().strokeBorder(lineWidth: u)
                        Capsule().frame(width: max(7 * u, 118 * u * c.volume))
                    }
                    .frame(width: 118 * u, height: 7 * u)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 8 * u))
                }
                .padding(.bottom, 8 * u)
            } else {
                ZStack(alignment: .leading) {
                    Capsule().strokeBorder(lineWidth: u)
                    if wheelState.scrubActive {
                        // the firmware's scrub marker
                        Rectangle().frame(width: 6 * u, height: 6 * u).rotationEffect(.degrees(45))
                            .offset(x: 150 * u * p - 3 * u)
                    } else {
                        Capsule().frame(width: max(7 * u, 150 * u * p))
                    }
                }
                .frame(width: 150 * u, height: 7 * u)
                .padding(.vertical, 4 * u).contentShape(.rect)          // easier to hit
                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { g in
                    controls?.seek(min(max(g.location.x / (150 * u), 0), 1))
                }, including: controls == nil ? .subviews : .all)
                .pointerStyle(controls == nil ? nil : .link)
                .padding(.vertical, -4 * u)
                HStack {
                    Text(clock(np.time))
                    Spacer()
                    Text("-" + clock(max(np.length - np.time, 0)))
                }
                .font(chicago(10 * u))
                .padding(.top, 3 * u)
            }
        }
        .padding(.horizontal, 5 * u).padding(.top, 3 * u).padding(.bottom, 5 * u)
    }

    /// The four touch buttons between screen and wheel; their labels glow red like the 3G's
    /// backlight while syncing.
    func buttons(w: CGFloat) -> some View {
        let glow = mode.isSyncing || mode == .dropping
        let ink = glow ? Color(red: 1, green: 0.33, blue: 0.25) : Color(white: 0.7)
        let d = w * 0.17, lh = w * 0.024
        return HStack(spacing: w * 0.22 - d) {
            ForEach(0..<4, id: \.self) { i in
                let action = controls.map { c in [c.previous, c.menu, c.toggle, c.next][i] }
                Button { action?() } label: {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.97)], startPoint: .top, endPoint: .bottom))
                    Circle().strokeBorder(Color(white: 0.8), lineWidth: max(0.4, w * 0.004))
                    Group {
                        switch i {
                        case 0: SkipGlyph().scale(x: -1, y: 1).fill(ink).frame(width: lh * 2.4, height: lh)
                        case 1: Text("MENU").font(.system(size: lh * 1.05, weight: .heavy)).kerning(lh * 0.05).foregroundStyle(ink).fixedSize()
                        case 2: PlayPauseGlyph().fill(ink).frame(width: lh * 2.3, height: lh)
                        default: SkipGlyph().fill(ink).frame(width: lh * 2.4, height: lh)
                        }
                    }
                    .shadow(color: glow ? ink.opacity(0.9) : .clear, radius: w * 0.012)
                }
                .frame(width: d, height: d)
                .contentShape(Circle())
                }
                .buttonStyle(TouchButton())
                .disabled(action == nil)
                .help(["Previous", "Back", "Play/Pause", "Next"][i])
            }
        }
    }

    /// The touch wheel: plain, with a slightly raised centre button. A highlight goes round
    /// while syncing.
    func wheel(w: CGFloat, t: Double) -> some View {
        let d = w * 0.64
        return ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.97)], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color(white: 0.8), lineWidth: max(0.4, w * 0.004))
            if mode.isSyncing {
                Circle().trim(from: 0, to: 0.16)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: d * 0.14, lineCap: .round))
                    .padding(d * 0.18)
                    .rotationEffect(.degrees(t * 200))
                    .blur(radius: d * 0.05)
            }
            Button {
                guard controls != nil else { return }
                wheelState.scrubbing = !wheelState.scrubActive
                wheelState.adjustedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { wheelState.objectWillChange.send() }
            } label: {
                Circle().fill(LinearGradient(colors: [Color(white: 0.985), Color(white: 0.91)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color(white: 0.8), lineWidth: max(0.4, w * 0.004)))
                    .shadow(color: .black.opacity(0.08), radius: d * 0.02, y: d * 0.01)
                    .frame(width: d * 0.36, height: d * 0.36)
                    .contentShape(Circle())
            }
            .buttonStyle(TouchButton())
            .disabled(controls == nil)
            .pointerStyle(controls == nil ? nil : .link)
            .help("Scrub with the wheel")
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .pointerStyle(controls == nil ? nil : wheelState.dragging ? .grabActive : .grabIdle)
        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
            if !wheelState.dragging { wheelState.dragging = true }
            turn(g.location, d: d)
        }.onEnded { _ in
            wheelState.lastAngle = nil; wheelState.turned = 0; wheelState.dragging = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { wheelState.objectWillChange.send() }
        }, including: controls == nil ? .subviews : .all)
    }

    /// Turning the wheel changes the volume in steps of 5%, 24 a turn, each one clicking; after
    /// the centre button it scrubs through the song in steps of 2% instead.
    func turn(_ p: CGPoint, d: CGFloat) {
        guard let c = controls else { return }
        let angle = atan2(p.y - d / 2, p.x - d / 2)    // grows clockwise (y is down)
        defer { wheelState.lastAngle = angle }
        guard let last = wheelState.lastAngle else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        wheelState.turned += delta
        let click = 2 * Double.pi / 24
        if wheelState.scrubActive {
            var pos = c.position
            while abs(wheelState.turned) >= click {
                let dir: Double = wheelState.turned > 0 ? 1 : -1
                wheelState.turned -= dir * click
                let np = min(max(pos + dir * 0.02, 0), 1)
                if np != pos { pos = np; Clicker.tick() }
            }
            if pos != c.position { c.seek(pos) }
            wheelState.adjustedAt = Date()
            return
        }
        var v = c.volume
        while abs(wheelState.turned) >= click {
            let dir: Double = wheelState.turned > 0 ? 1 : -1
            wheelState.turned -= dir * click
            let nv = min(max(v + dir * 0.05, 0), 1)
            if nv != v { v = nv; Clicker.tick() }
        }
        if v != c.volume { c.setVolume(v) }
        wheelState.adjustedAt = Date()
    }
}

// MARK: touch feel

/// The iPod's clicker plus a trackpad tick. The 3G has no click sample: its firmware drives
/// a piezo with a short square wave. Rockbox's iPod driver (firmware/target/arm/ipod/piezo.c)
/// copies Apple's: PWM period 91 (≈1 kHz by Rockbox's table), 50% duty, for 4 ms. That pulse
/// is generated here, softened a little the way the piezo's own mass rounds it off.
@MainActor
enum Clicker {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        click()
    }
    static func press() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        click()
    }

    private static let engine = AVAudioEngine()
    private static let node = AVAudioPlayerNode()
    private static var started = false
    private static let pulse: AVAudioPCMBuffer = {
        let rate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let n = Int(rate * 0.01)                          // 4 ms of tone, then it rings out
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        var y: Float = 0
        for i in 0..<n {
            let t = Double(i) / rate
            let x: Float = t < 0.004 ? (t * 91225 / 91).truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1 : 0
            y += 0.35 * (x - y)                           // one-pole low-pass, ≈4 kHz
            out[i] = y * 0.22
        }
        return buf
    }()

    static func click() {
        guard UserDefaults.standard.object(forKey: "ipodClicker") as? Bool ?? true else { return }
        if !started {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: pulse.format)
            guard (try? engine.start()) != nil else { return }
            node.play()
            started = true
        }
        node.scheduleBuffer(pulse, at: nil, options: .interrupts)
    }
}

/// The touch buttons dim a little and click when pressed.
private struct TouchButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .onChange(of: configuration.isPressed) { _, down in if down { Clicker.press() } }
    }
}

// MARK: LCD and button glyphs

private struct Battery: View {
    var u: CGFloat
    var charging: Bool
    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Rectangle().strokeBorder(lineWidth: u)
                Rectangle().padding(2 * u).frame(maxWidth: .infinity, alignment: .leading)
                    .mask(alignment: .leading) { Rectangle().frame(width: charging ? 15 * u * 0.6 : 15 * u * 0.85) }
            }
            Rectangle().frame(width: 2 * u, height: 4 * u)
        }
    }
}

private struct NoSign: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(ellipseIn: r)
        let k = r.width / 2 * 0.707
        p.move(to: CGPoint(x: r.midX - k, y: r.midY - k))
        p.addLine(to: CGPoint(x: r.midX + k, y: r.midY + k))
        return p
    }
}

private struct Check: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.05, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY + r.height * 0.08))
        return p
    }
}

private struct Chevron: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

/// ▶▶| (mirrored for |◀◀).
private struct SkipGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let h = r.height, tw = h * 0.85
        var p = Path()
        for x0 in [r.minX, r.minX + tw] {
            p.move(to: CGPoint(x: x0, y: r.minY))
            p.addLine(to: CGPoint(x: x0 + tw, y: r.midY))
            p.addLine(to: CGPoint(x: x0, y: r.maxY))
            p.closeSubpath()
        }
        p.addRect(CGRect(x: r.minX + tw * 2, y: r.minY, width: h * 0.24, height: h))
        return p
    }
}

private struct PlayGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct PauseGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRect(CGRect(x: r.minX, y: r.minY, width: r.width * 0.35, height: r.height))
        p.addRect(CGRect(x: r.maxX - r.width * 0.35, y: r.minY, width: r.width * 0.35, height: r.height))
        return p
    }
}

/// ▶❚❚
private struct PlayPauseGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let h = r.height, tw = h * 0.9, bar = h * 0.26
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tw, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        let x = r.minX + tw + h * 0.3
        p.addRect(CGRect(x: x, y: r.minY, width: bar, height: h))
        p.addRect(CGRect(x: x + bar + h * 0.2, y: r.minY, width: bar, height: h))
        return p
    }
}

extension IPodArt.Mode {
    var isSyncing: Bool { if case .syncing = self { return true }; return false }
}

extension Model {
    var podArtMode: IPodArt.Mode {
        if dropTarget == .ipod { return .dropping }
        if syncing { return .syncing(Double(syncDone) / Double(max(syncTotal, 1))) }
        if report != nil && report?.error == nil { return .done }
        return connected ? .idle : .offline
    }
}

/// The iPod drawing with the player's song on its Now Playing screen.
/// While something plays, its buttons are the player's controls: |◀◀ ▶❚❚ ▶▶|, MENU goes back,
/// the centre button shows the album and the wheel turns the volume.
struct LiveIPod: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var player: Player
    var height: CGFloat
    @StateObject private var last = LastPlaying()
    var body: some View {
        let t = player.current
        let np = t.map { t in
            IPodArt.NowPlaying(title: t.title, artist: t.trackArtist.isEmpty ? t.artist : t.trackArtist, album: t.album,
                               index: player.index + 1, count: player.queue.count, time: player.time, length: player.length, playing: player.playing)
        }
        // a drawn remote, not the real iPod: always lit, no sync state; it keeps the frog so the sticker
        // travels along when it lifts out. Once the music stops it still shrinks back into the card: keep
        // the last song (paused) on its screen meanwhile instead of flipping to the menu.
        IPodArt(mode: .idle, name: "", height: height, nowPlaying: np ?? last.value.map { var v = $0; v.playing = false; return v },
                controls: t.map { t in
            .init(previous: { player.previous() }, toggle: { player.toggle() }, next: { player.next() },
                  menu: { if !model.path.isEmpty { model.path.removeLast() } },
                  select: {
                      if let album = model.albums.first(where: { $0.id == t.album.lowercased() }) { model.search = ""; model.path = [.album(album)] }
                  },
                  openArtist: { model.search = ""; model.pane = .artists; model.path = [.artist(t.artist)] },
                  seek: { player.seek($0 * player.length) },
                  position: player.length > 0 ? player.time / player.length : 0,
                  volume: player.volume, setVolume: { player.setVolume($0) })
        }, frogger: model.froggerSticker)
        .onChange(of: np) { _, v in if let v { last.value = v } }
        .onAppear { last.value = np }
    }
}

@MainActor
final class LastPlaying: ObservableObject { var value: IPodArt.NowPlaying? }

/// The real iPod as drawn: its name, sync state and sticker, never what Crate is playing.
struct PodPicture: View {
    @EnvironmentObject var model: Model
    var height: CGFloat
    var body: some View {
        IPodArt(mode: model.podArtMode, name: model.podName, height: height, frogger: model.froggerSticker)
    }
}

@MainActor
final class HoverState: ObservableObject { @Published var on = false }

/// The iPod in the sidebar card: small, grows on hover, bounces when a sync starts or ends.
struct SidebarIPod: View {
    @EnvironmentObject var model: Model
    @StateObject private var hover = HoverState()
    var body: some View {
        let big = hover.on || model.syncing || model.dropTarget == .ipod
        IPodArt(mode: model.podArtMode, name: model.podName, height: big ? 180 : 44, frogger: model.froggerSticker)
            .scaleEffect(model.dropTarget == .ipod ? 1.06 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.62), value: big)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.dropTarget == .ipod)
            .animation(.spring(response: 0.5, dampingFraction: 0.5), value: model.syncing)
            .onHover { h in hover.on = h }
            .frame(maxWidth: .infinity)
    }
}

/// A frog sticker, for an iPod running Frogger: a round little frog face, die-cut with a white border and a
/// soft shadow, stuck on at an angle.
struct FrogSticker: View {
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let b = sz.width * 0.07                       // the white border
            let iw = sz.width - 2 * b, ih = sz.height - 2 * b
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: b + x * iw, y: b + y * ih) }
            func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: b + x * iw, y: b + y * ih, width: w * iw, height: h * ih))
            }
            let green = Color(red: 0.46, green: 0.8, blue: 0.36), light = Color(red: 0.62, green: 0.9, blue: 0.46)
            let dark = Color(red: 0.18, green: 0.42, blue: 0.2)
            var frog = oval(0, 0.3, 1, 0.7)               // the head, and the two eye bumps on top
            frog.addPath(oval(0.06, 0.02, 0.4, 0.44))
            frog.addPath(oval(0.54, 0.02, 0.4, 0.44))
            ctx.stroke(frog, with: .color(.white), style: StrokeStyle(lineWidth: b * 2, lineJoin: .round))
            ctx.fill(frog, with: .color(.white))
            ctx.fill(frog, with: .linearGradient(Gradient(colors: [light, green]), startPoint: pt(0.5, 0), endPoint: pt(0.5, 1)))
            for x in [0.26, 0.74] {                       // eyes, with a shine
                ctx.fill(oval(x - 0.13, 0.08, 0.26, 0.3), with: .color(.white))
                ctx.fill(oval(x - 0.07, 0.15, 0.14, 0.17), with: .color(Color(white: 0.1)))
                ctx.fill(oval(x - 0.035, 0.16, 0.05, 0.06), with: .color(.white))
            }
            for x in [0.17, 0.83] { ctx.fill(oval(x - 0.08, 0.64, 0.16, 0.1), with: .color(.pink.opacity(0.6))) }
            var smile = Path()
            smile.move(to: pt(0.36, 0.66))
            smile.addQuadCurve(to: pt(0.64, 0.66), control: pt(0.5, 0.8))
            ctx.stroke(smile, with: .color(dark), style: StrokeStyle(lineWidth: max(1, sz.width * 0.035), lineCap: .round))
        }
        .frame(width: size, height: size * 0.85)
        .shadow(color: .black.opacity(0.25), radius: max(0.5, size * 0.04), y: size * 0.02)
        .rotationEffect(.degrees(-12))
        .help("This iPod runs Frogger")
    }
}
