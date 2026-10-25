import Foundation

/// Where you are, rather than which switches to flip: each moment is a set of
/// Internet, Keep awake and VPN. It's read off the switches as they are, so a
/// change made on the Mac shows up here too; any other mix is `custom`. Away
/// leaves the VPN as it is, so stepping away never asks for Face ID.
///
/// "Internet" is the Mac being online through a phone (or on its way there),
/// read the same on the Mac and on every phone (`MacState.internet`).
public enum Moment: String, CaseIterable, Identifiable, Sendable {
    case desk, away, `public`, custom

    public var id: String { rawValue }
    public static let choices: [Moment] = [.desk, .away, .public]

    public var title: String {
        switch self {
        case .desk: "Desk"
        case .away: "Away"
        case .public: "Public"
        case .custom: "Custom"
        }
    }

    /// `phone` names the phone as the reader knows it ("this iPhone", "the
    /// phone"); `fromAnywhere`: the Mac's shell is reachable off its network.
    public func caption(phone: String, fromAnywhere: Bool = true) -> String {
        switch self {
        case .desk: "Online through \(phone) over the cable. The Mac sleeps as usual."
        case .away:
            "The Mac stays awake on its own Wi-Fi, reachable \(fromAnywhere ? "from anywhere" : "on its network"). The VPN stays as it is."
        case .public: "Online through \(phone), with everything going through the VPN."
        case .custom: "Your own mix of the switches below."
        }
    }

    /// Internet through the phone, Keep awake, VPN (nil: left as it is).
    public var switches: (internet: Bool, awake: Bool, vpn: Bool?)? {
        switch self {
        case .desk: (true, false, false)
        case .away: (false, true, nil)
        case .public: (true, false, true)
        case .custom: nil
        }
    }

    public static func current(internet: Bool, awake: Bool, vpn: Bool) -> Moment {
        choices.first { moment in
            guard let s = moment.switches else { return false }
            return s.internet == internet && s.awake == awake && (s.vpn ?? vpn) == vpn
        } ?? .custom
    }

    /// What picking this moment changes from the switches as they are; nil
    /// for `custom`. Every app applies a moment through this, so they agree.
    public func plan(internet: Bool, awake: Bool, vpn: Bool) -> MomentPlan? {
        guard let s = switches else { return nil }
        return MomentPlan(internet: s.internet == internet ? nil : s.internet,
                          awake: s.awake == awake ? nil : s.awake,
                          vpn: s.vpn.flatMap { $0 == vpn ? nil : $0 })
    }
}

/// The switches a moment changes; nil where one is already right or left alone.
public struct MomentPlan: Equatable, Sendable {
    public var internet: Bool?
    public var awake: Bool?
    public var vpn: Bool?

    public init(internet: Bool? = nil, awake: Bool? = nil, vpn: Bool? = nil) {
        self.internet = internet; self.awake = awake; self.vpn = vpn
    }

    /// Turns the VPN off: asks for Face ID first.
    public var lowersVPN: Bool { vpn == false }
    /// Lets the Mac sleep: warns first when shells are running.
    public var letsSleep: Bool { awake == false }
    public var needsVPN: Bool { vpn == true }
    public var isEmpty: Bool { internet == nil && awake == nil && vpn == nil }
}

extension MacState {
    /// The VPN is on, on its way, or failed with its block in place: anything but off.
    public var vpnUp: Bool { vpn == MacState.vpnOn || vpn == MacState.vpnConnecting || vpn == MacState.vpnFailed }

    /// The moment the Mac is in. `phoneSharing` stands in for `internet` on a
    /// Mac that doesn't send it (an older build).
    public func moment(phoneSharing: Bool) -> Moment {
        Moment.current(internet: internet ?? phoneSharing, awake: awake == true, vpn: vpnUp)
    }

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
