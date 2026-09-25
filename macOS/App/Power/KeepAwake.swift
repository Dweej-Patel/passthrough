import Foundation
import SwiftUI
import PassthroughCore

/// Keeps the Mac from sleeping so long sessions survive: an idle-sleep
/// assertion in the app, plus lid-close sleep held by the root helper. Turns
/// itself off at a battery threshold when running on battery. Off by default.
@MainActor
final class KeepAwakeController: ObservableObject {
    @Published private(set) var isOn: Bool = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "keepAwake")
            power.apply(isOn)
            applyLidClose(isOn)
        }
    }
    /// True once the root helper has confirmed lid-close sleep is disabled.
    @Published private(set) var lidCloseHeld = false
    /// Auto-disable when the battery falls to the threshold (on battery power).
    @AppStorage("batteryAutoOff") var batteryAutoOff = true
    @AppStorage("batteryAutoOffThreshold") var batteryAutoOffThreshold = 20
    @Published private(set) var battery = BatteryReading(percent: -1, isOnAC: true, hasBattery: false)
    /// Set when keep-awake can't be turned on (or was auto-disabled) due to low battery.
    @Published private(set) var blockedReason: String?

    private let helper: HelperClient
    private let power = PowerManager()

    init(helper: HelperClient) {
        self.helper = helper
        power.apply(isOn)
    }

    /// Re-asserts lid-close sleep once the helper is known to be current.
    func resume() { applyLidClose(isOn) }

    /// Turn keep-awake on/off with a low-battery precheck. If the battery is at
    /// or below the configured limit (on battery power), it refuses to turn on
    /// and records a reason to show under the toggle.
    func set(_ on: Bool) {
        if on, batteryAutoOff {
            let r = BatteryMonitor.read()
            battery = r
            if r.hasBattery, !r.isOnAC, r.percent >= 0, r.percent <= batteryAutoOffThreshold {
                blockedReason = "Battery is \(r.percent)% — at or below your \(batteryAutoOffThreshold)% limit. Plug in, or lower the limit in Settings, to keep the Mac awake."
                if isOn { isOn = false }
                return
            }
        }
        blockedReason = nil
        isOn = on
    }

    /// Called periodically. If keep-awake is on and the battery hits the
    /// user's threshold while on battery power, turn keep-awake off so the Mac
    /// can sleep and stop draining, even with the lid closed.
    func checkBattery() {
        let reading = BatteryMonitor.read()
        battery = reading
        if blockedReason != nil, reading.isOnAC || reading.percent > batteryAutoOffThreshold {
            blockedReason = nil
        }
        guard isOn, batteryAutoOff, reading.hasBattery, !reading.isOnAC, reading.percent >= 0 else { return }
        if reading.percent <= batteryAutoOffThreshold {
            ptLog(.warning, "Battery \(reading.percent)% ≤ \(batteryAutoOffThreshold)% on battery: turning keep-awake off")
            blockedReason = "Turned off at \(reading.percent)% (your \(batteryAutoOffThreshold)% limit). Plug in to keep the Mac awake."
            isOn = false
        }
    }

    /// Hands lid-close sleep back before the app quits.
    func shutdown() async {
        if isOn { _ = await helper.setDisableSleep(false) }
    }

    /// Ask the root helper to disable/enable full (lid-close) sleep. The helper
    /// auto-reverts if this app disconnects, so the Mac can never get stuck awake.
    private func applyLidClose(_ on: Bool) {
        if on, helper.availability != .ready { _ = helper.register() }
        Task {
            let ok = await helper.setDisableSleep(on)
            lidCloseHeld = on && ok
            if on && !ok {
                ptLog(.warning, "Keep awake: idle sleep is held, but lid-close needs the helper approved.")
            }
        }
    }
}
