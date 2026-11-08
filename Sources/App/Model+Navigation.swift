import SwiftUI
import AppKit

// MARK: back and forward

extension Model {
    var place: Place { Place(pane: pane, path: path, search: search) }

    /// Called when the page or what's open on it changes; going back or forward isn't a new visit, and nor is typing a search.
    func visited(from old: Place) {
        if travelling { travelling = false; return }
        guard old.pane != pane || old.path != path else { return }
        back.append(old); if back.count > 100 { back.removeFirst() }
        forward = []
    }

    func goBack() { guard let p = back.popLast() else { return }; forward.append(place); travel(to: p) }
    func goForward() { guard let p = forward.popLast() else { return }; back.append(place); travel(to: p) }

    private func travel(to p: Place) {
        guard p != place else { return }
        travelling = true
        search = p.search; pane = p.pane; path = p.path
    }
}
