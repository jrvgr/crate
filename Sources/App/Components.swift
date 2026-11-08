import SwiftUI
import AppKit

// Small pieces of UI used across the pages.

/// A page fades in when it opens, or when going back shows it again (the Mac's NavigationStack just swaps pages).
struct FadeIn: ViewModifier {
    var when = true
    @StateObject private var state = FadeState()

    func body(content: Content) -> some View {
        content
            .opacity(state.shown ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: state.shown)
            .onChange(of: when) { _, on in if on { state.shown = false } }
            .task(id: when) { await Task.yield(); state.shown = true }
    }
}

@MainActor
final class FadeState: ObservableObject { @Published var shown = false }

/// A menu in the same glass and height as the buttons beside it. SwiftUI's Menu doesn't take the glass
/// button style on the Mac, so this is a glass Button that pops the same menu (as an AppKit menu) under itself.
struct GlassMenu<Items: View, Label: View>: View {
    @EnvironmentObject var model: Model
    @ViewBuilder var items: () -> Items
    @ViewBuilder var label: () -> Label
    @StateObject private var anchor = MenuAnchor()

    var body: some View {
        Button { anchor.pop(NSHostingMenu(rootView: items().environmentObject(model))) } label: { label() }
            .background(MenuAnchor.Spot(anchor: anchor))
    }
}

/// ⋯ for a GlassMenu in a row of text buttons: as tall as their text, so the capsules match.
struct MoreLabel: View {
    var body: some View { Text(verbatim: "Mg").hidden().overlay(Image(systemName: "ellipsis")) }
}

@MainActor
final class MenuAnchor: ObservableObject {
    weak var view: NSView?
    func pop(_ menu: NSMenu) {
        guard let v = view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: v.isFlipped ? v.bounds.maxY + 6 : -6), in: v)
    }
    /// The button's spot in the window, for the menu to open under.
    struct Spot: NSViewRepresentable {
        let anchor: MenuAnchor
        func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
        func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
    }
}

struct Stat: View {
    var value, label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
