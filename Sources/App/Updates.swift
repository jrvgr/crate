import SwiftUI
import Sparkle

// Updates with Sparkle. The feed (SUFeedURL in Info.plist) is the appcast.xml attached to the latest GitHub
// release; the release workflow signs each new version with Sparkle's EdDSA key (SUPublicEDKey), so updates
// are checked without an Apple Developer ID. Sparkle asks on the second launch whether to check automatically.

@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
    }

    func check() { controller.checkForUpdates(nil) }
}

/// Check for Updates…, under About in the app menu.
struct UpdateCommands: Commands {
    @ObservedObject var updates = Updates.shared
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
        }
    }
}
