import Foundation
import IOKit.pwr_mgt

/// Holds a power assertion so the Mac won't idle-sleep while enabled. This keeps
/// long-running work alive (a Claude session, a download, the tunnel itself)
/// when you step away. It prevents *idle* system sleep while the lid is open;
/// closing the lid still sleeps the Mac unless it's on power with an external
/// display, which is normal macOS behavior we deliberately don't override.
final class PowerManager {
    private var assertionID: IOPMAssertionID = 0
    /// Keeps App Nap off while held: with the lid closed and no window open it
    /// would otherwise stretch the timer that runs the battery and heat checks.
    private var activity: NSObjectProtocol?
    private(set) var isActive = false

    func apply(_ keepAwake: Bool) {
        keepAwake ? enable() : disable()
    }

    private func enable() {
        guard !isActive else { return }
        let reason = "Passthrough is keeping this Mac awake" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID)
        isActive = (result == kIOReturnSuccess)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Keep awake checks battery and heat")
        }
    }

    private func disable() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    deinit { disable() }
}
