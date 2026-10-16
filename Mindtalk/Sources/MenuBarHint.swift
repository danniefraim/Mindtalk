import AppKit
import SwiftUI

// MARK: - "Mindtalk finns kvar här"
//
// The first time the main window is closed, a small bubble from the menu-bar icon
// says where Mindtalk went. Once.

enum MenuBarHint {
    /// Shows the bubble under the status item, the first time only.
    @MainActor static func showOnce(from button: NSStatusBarButton?) {
        // Placeholder — built in its own change.
    }
}
