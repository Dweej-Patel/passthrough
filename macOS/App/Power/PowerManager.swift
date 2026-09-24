import Foundation
import IOKit.pwr_mgt

/// Holds a power assertion so the Mac won't idle-sleep while enabled. This keeps
/// long-running work alive (a Claude session, a download, the tunnel itself)
/// when you step away. It prevents *idle* system sleep while the lid is open;
/// closing the lid still sleeps the Mac unless it's on power with an external
/// display, which is normal macOS behavior we deliberately don't override.
final class PowerManager {
    private var assertionID: IOPMAssertionID = 0
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
    }

    private func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    deinit { disable() }
}
