#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics

/// What the Mac's own screen stream needs: Screen Recording to see the
/// screen, Accessibility to post a phone's pointer and keys.
public enum ScreenVideoPermissions {
    /// macOS may only report a new Screen Recording grant once the app restarts.
    public static var canCapture: Bool { CGPreflightScreenCaptureAccess() }
    public static var canControl: Bool { AXIsProcessTrusted() }
    public static var isReady: Bool { canCapture && canControl }

    /// Asks once (macOS shows its own prompt the first time, and adds the app to the list).
    public static func requestCapture() { _ = CGRequestScreenCaptureAccess() }

    public static func requestControl() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Privacy & Security › Screen Recording or › Accessibility in System Settings.
    public static func openSettings(capture: Bool) {
        let pane = capture ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        for address in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
#endif
