import Foundation
import SwiftUI
import PassthroughCore

/// Keeps the Mac from sleeping so long sessions survive: an idle-sleep
/// assertion in the app, plus lid-close sleep held by the root helper. Turns
/// itself off at a battery threshold when running on battery, and when the Mac
/// runs hot, so a closed laptop can sleep instead. Off by default.
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
    /// Auto-disable when macOS reports the Mac running hot.
    @AppStorage("thermalAutoOff") var thermalAutoOff = true
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    /// Set when keep-awake can't be turned on (or was auto-disabled) due to low battery or heat.
    @Published private(set) var blockedReason: String?
    private enum Cause { case battery, heat }
    /// What `blockedReason` is about, so each check clears only its own.
    private var blockedBy: Cause?
    private var thermalObserver: NSObjectProtocol?

    private let helper: HelperClient
    private let power = PowerManager()

    init(helper: HelperClient) {
        self.helper = helper
        power.apply(isOn)
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkThermal() }
        }
    }

    /// Re-asserts lid-close sleep once the helper is known to be current.
    func resume() { applyLidClose(isOn) }

    /// Turn keep-awake on/off with low-battery and heat prechecks. If either
    /// limit is already reached it refuses to turn on and records a reason to
    /// show under the toggle.
    func set(_ on: Bool) {
        if on, batteryAutoOff {
            let r = BatteryMonitor.read()
            battery = r
            if r.hasBattery, !r.isOnAC, r.percent >= 0, r.percent <= batteryAutoOffThreshold {
                block(.battery, "Battery is \(r.percent)% — at or below your \(batteryAutoOffThreshold)% limit. Plug in, or lower the limit in Settings, to keep the Mac awake.")
                return
            }
        }
        if on, thermalAutoOff {
            thermal = ProcessInfo.processInfo.thermalState
            if Self.isHot(thermal) {
                block(.heat, "The Mac is running \(Self.describe(thermal)). Let it cool down, or turn off the heat limit in Settings, to keep it awake.")
                return
            }
        }
        blockedReason = nil
        blockedBy = nil
        isOn = on
    }

    /// Keep-awake off (or refused) for `cause`, with the reason shown under the toggle.
    private func block(_ cause: Cause, _ reason: String) {
        blockedBy = cause
        blockedReason = reason
        if isOn { isOn = false }
    }

    private func clearBlock(_ cause: Cause) {
        guard blockedBy == cause else { return }
        blockedBy = nil
        blockedReason = nil
    }

    /// Serious is where macOS starts slowing the Mac down to cool it.
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool { state == .serious || state == .critical }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "cool"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "very hot"
        @unknown default: return "hot"
        }
    }

    /// Called periodically. If keep-awake is on and the battery hits the
    /// user's threshold while on battery power, turn keep-awake off so the Mac
    /// can sleep and stop draining, even with the lid closed.
    func checkBattery() {
        let reading = BatteryMonitor.read()
        battery = reading
        if reading.isOnAC || reading.percent > batteryAutoOffThreshold { clearBlock(.battery) }
        guard isOn, batteryAutoOff, reading.hasBattery, !reading.isOnAC, reading.percent >= 0 else { return }
        if reading.percent <= batteryAutoOffThreshold {
            ptLog(.warning, "Battery \(reading.percent)% ≤ \(batteryAutoOffThreshold)% on battery: turning keep-awake off")
            block(.battery, "Turned off at \(reading.percent)% (your \(batteryAutoOffThreshold)% limit). Plug in to keep the Mac awake.")
        }
    }

    /// On macOS's thermal-state change and periodically. If keep-awake is on
    /// and the Mac runs hot, turn keep-awake off so it can sleep and cool down,
    /// even with the lid closed.
    func checkThermal() {
        thermal = ProcessInfo.processInfo.thermalState
        if !Self.isHot(thermal) { clearBlock(.heat) }
        guard isOn, thermalAutoOff, Self.isHot(thermal) else { return }
        ptLog(.warning, "The Mac is running \(Self.describe(thermal)): turning keep-awake off so it can sleep and cool down")
        block(.heat, "Turned off because the Mac was running \(Self.describe(thermal)). It can sleep and cool down now.")
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
