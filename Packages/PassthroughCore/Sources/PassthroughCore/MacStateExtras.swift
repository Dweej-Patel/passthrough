import Foundation

extension MacState {
    /// The VPN is on, on its way, or failed with its block in place: anything but off.
    public var vpnUp: Bool { vpn == MacState.vpnOn || vpn == MacState.vpnConnecting || vpn == MacState.vpnFailed }

    /// No battery: a desktop Mac, with no lid to close.
    public var hasLid: Bool { battery != nil }

    /// Minutes until Keep awake's battery limit (`floor`, in percent), from
    /// macOS's estimate to empty at `percent`; rounded to 5 so it doesn't
    /// churn. Nil once at or under the limit.
    public static func minutesLeft(percent: Int, toEmpty: Int, floor: Int) -> Int? {
        guard percent > floor, percent > 0 else { return nil }
        let toFloor = Double(toEmpty) * Double(percent - floor) / Double(percent)
        return Int((toFloor / 5).rounded()) * 5
    }
}

extension ShellSessionInfo {
    /// Running and quiet on a question: "needs you".
    public var isAsking: Bool { running && waiting != nil }
}

/// The Mac's numbers as the apps show them.
public enum MacFormat {
    /// "3 h 10 m", "45 m".
    public static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }

    /// A 0-to-1 level as a rounded percent: "82%".
    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}
