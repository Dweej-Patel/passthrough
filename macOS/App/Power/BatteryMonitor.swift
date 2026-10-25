import Foundation
import IOKit.ps

/// A point-in-time reading of the Mac's battery.
struct BatteryReading: Equatable {
    var percent: Int      // 0...100, or -1 if unknown (e.g. desktop Mac)
    var isOnAC: Bool
    var hasBattery: Bool
    /// macOS's estimate of minutes until empty, on battery; nil while it is still working it out.
    var minutesToEmpty: Int? = nil
}

/// Reads battery level and power source via IOKit power sources.
enum BatteryMonitor {
    static func read() -> BatteryReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryReading(percent: -1, isOnAC: true, hasBattery: false)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let current = desc[kIOPSCurrentCapacityKey as String] as? Int
            let capacity = desc[kIOPSMaxCapacityKey as String] as? Int
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            guard let current, let capacity, capacity > 0 else { continue }
            let raw = Int((Double(current) / Double(capacity) * 100).rounded())
            let pct = Swift.max(0, Swift.min(100, raw))
            // Treat anything not explicitly on AC as "on battery".
            let onAC = (state == (kIOPSACPowerValue as String))
            // -1 while macOS is still calculating.
            let toEmpty = (desc[kIOPSTimeToEmptyKey as String] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return BatteryReading(percent: pct, isOnAC: onAC, hasBattery: true, minutesToEmpty: onAC ? nil : toEmpty)
        }
        return BatteryReading(percent: -1, isOnAC: true, hasBattery: false)
    }
}
