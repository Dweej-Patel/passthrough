import AppKit
import SwiftUI

/// Passthrough is a menu bar (accessory) app, so macOS does not bring its
/// windows forward on its own: `openSettings()` alone leaves the Settings
/// window behind whatever app is in front. Activate first, then raise the
/// window once SwiftUI has created or reused it.
@MainActor
enum SettingsWindow {
    static func show(_ openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        // The window appears on the next run-loop turn; raise it then, and once
        // more shortly after in case the menu bar panel was still closing.
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { raise() }
        }
    }

    private static func raise() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" || ($0.title.hasSuffix("Settings") && $0.isVisible) }) else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
