import SwiftUI

// A drawn 3rd gen iPod that shows what Crate is doing: its LCD lights up with the menu, says
// "Do not disconnect" with a progress bar while syncing, spins its wheel, and the whole thing
// grows and bounces when something happens (hover, a drop, a sync starting or finishing).

struct IPodArt: View {
    enum Mode: Equatable { case idle, syncing(Double), done, offline, dropping }
    var mode: Mode
    var name: String
    var height: CGFloat

    var body: some View {
        let w = height * 0.6
        TimelineView(.animation(paused: !(mode.isSyncing || mode == .dropping))) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                // body: white front with a soft chrome edge
                RoundedRectangle(cornerRadius: w * 0.16)
                    .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.16).strokeBorder(
                        LinearGradient(colors: [Color(white: 0.75), .white, Color(white: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: max(1, w * 0.025)))
                    .shadow(color: .black.opacity(0.3), radius: w * 0.08, y: w * 0.04)
                VStack(spacing: height * 0.035) {
                    screen(w: w, t: t)
                    buttons(w: w)
                    wheel(w: w, t: t)
                }
                .padding(.top, height * 0.07)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: w, height: height)
            .saturation(mode == .offline ? 0 : 1)
            .opacity(mode == .offline ? 0.6 : 1)
        }
    }

    // MARK: parts

    func screen(w: CGFloat, t: Double) -> some View {
        let sw = w * 0.78, sh = sw * 0.75
        let lit = mode != .offline
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: w * 0.025)
                .fill(lit ? LinearGradient(colors: [Color(red: 0.62, green: 0.74, blue: 0.82), Color(red: 0.5, green: 0.63, blue: 0.72)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color(white: 0.55), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
            if lit, height > 70 {
                VStack(alignment: .leading, spacing: 0) {
                    // title bar
                    HStack {
                        Text(title).font(.system(size: sh * 0.11, weight: .bold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "battery.75percent").font(.system(size: sh * 0.1))
                    }
                    .padding(.horizontal, sw * 0.04).padding(.vertical, sh * 0.025)
                    .overlay(alignment: .bottom) { Rectangle().frame(height: 0.7).opacity(0.6) }
                    content(sw: sw, sh: sh, t: t)
                        .padding(.horizontal, sw * 0.04).padding(.top, sh * 0.03)
                }
                .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.16))
                .transition(.opacity)
            }
        }
        .frame(width: sw, height: sh)
        .overlay(RoundedRectangle(cornerRadius: w * 0.025).strokeBorder(.black.opacity(0.25), lineWidth: 0.8))
        .animation(.easeInOut(duration: 0.3), value: mode)
    }

    var title: String {
        switch mode {
        case .syncing: return "Syncing"
        case .done: return "Synced"
        case .dropping: return "Add"
        default: return name
        }
    }

    @ViewBuilder func content(sw: CGFloat, sh: CGFloat, t: Double) -> some View {
        let fs = sh * 0.105
        switch mode {
        case .syncing(let p):
            VStack(alignment: .center, spacing: sh * 0.05) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: sh * 0.22, weight: .semibold))
                    .rotationEffect(.degrees(t * 120))
                Text("Do not disconnect.").font(.system(size: fs, weight: .semibold))
                ZStack(alignment: .leading) {
                    Capsule().strokeBorder(lineWidth: 0.8).frame(height: sh * 0.07)
                    Capsule().frame(width: max(sh * 0.07, (sw * 0.84) * p), height: sh * 0.07)
                }
                .frame(width: sw * 0.84)
            }
            .frame(maxWidth: .infinity)
        case .done:
            VStack(spacing: sh * 0.05) {
                Image(systemName: "checkmark.circle").font(.system(size: sh * 0.26, weight: .semibold))
                Text("OK to disconnect.").font(.system(size: fs, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        case .dropping:
            VStack(spacing: sh * 0.05) {
                Image(systemName: "arrow.down.circle").font(.system(size: sh * 0.26, weight: .semibold))
                    .offset(y: sin(t * 6) * sh * 0.03)
                Text("Drop to add").font(.system(size: fs, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        default:
            VStack(alignment: .leading, spacing: sh * 0.012) {
                ForEach(Array(["Playlists", "Browse", "Extras", "Settings"].enumerated()), id: \.offset) { i, item in
                    HStack {
                        Text(item).font(.system(size: fs))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: fs * 0.7, weight: .bold))
                    }
                    .padding(.horizontal, sw * 0.02)
                    .foregroundStyle(i == 1 ? Color(red: 0.62, green: 0.74, blue: 0.82) : Color(red: 0.08, green: 0.12, blue: 0.16))
                    .background(i == 1 ? Color(red: 0.08, green: 0.12, blue: 0.16) : .clear)
                }
            }
        }
    }

    /// The four touch buttons, glowing red like the 3rd gen's backlight while syncing.
    func buttons(w: CGFloat) -> some View {
        let glow = mode.isSyncing || mode == .dropping
        return HStack(spacing: w * 0.05) {
            ForEach(["backward.end.alt.fill", "line.3.horizontal", "playpause.fill", "forward.end.alt.fill"], id: \.self) { s in
                Circle().fill(Color(white: 0.93))
                    .overlay(Circle().strokeBorder(Color(white: 0.8), lineWidth: 0.6))
                    .overlay(Image(systemName: s).font(.system(size: w * 0.055, weight: .bold))
                        .foregroundStyle(glow ? Color(red: 1, green: 0.25, blue: 0.2) : Color(white: 0.55)))
                    .shadow(color: glow ? .red.opacity(0.6) : .clear, radius: w * 0.03)
                    .frame(width: w * 0.15, height: w * 0.15)
            }
        }
    }

    /// The touch wheel; a highlight goes round while syncing.
    func wheel(w: CGFloat, t: Double) -> some View {
        let d = w * 0.62
        return ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color(white: 0.78), lineWidth: 0.8))
            if mode.isSyncing {
                Circle().trim(from: 0, to: 0.18)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: d * 0.12, lineCap: .round))
                    .padding(d * 0.17)
                    .rotationEffect(.degrees(t * 200))
                    .blur(radius: 1.5)
            }
            Circle().fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.97)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color(white: 0.8), lineWidth: 0.6))
                .frame(width: d * 0.38, height: d * 0.38)
        }
        .frame(width: d, height: d)
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

@MainActor
final class HoverState: ObservableObject { @Published var on = false }

/// The iPod in the sidebar card: small, grows on hover, bounces when a sync starts or ends.
struct SidebarIPod: View {
    @EnvironmentObject var model: Model
    @StateObject private var hover = HoverState()
    var body: some View {
        let big = hover.on || model.syncing || model.dropTarget == .ipod
        IPodArt(mode: model.podArtMode, name: model.podName, height: big ? 180 : 44)
            .scaleEffect(model.dropTarget == .ipod ? 1.06 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.62), value: big)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.dropTarget == .ipod)
            .animation(.spring(response: 0.5, dampingFraction: 0.5), value: model.syncing)
            .onHover { h in hover.on = h }
            .frame(maxWidth: .infinity)
    }
}
