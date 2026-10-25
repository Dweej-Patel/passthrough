import Foundation

/// Where you are, rather than which switches to flip: each moment is a set of
/// Internet, Keep awake and VPN. It's read off the switches as they are, so a
/// change made on the Mac shows up here too; any other mix is `custom`. Away
/// leaves the VPN as it is, so stepping away never asks for Face ID.
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

    public var caption: String {
        switch self {
        case .desk: "Online through this iPhone over the cable. The Mac sleeps as usual."
        case .away: "The Mac stays awake on its own Wi-Fi, reachable from anywhere. The VPN stays as it is."
        case .public: "Online through this iPhone, with everything going through the VPN."
        case .custom: "Your own mix of the switches below."
        }
    }

    /// Internet through this iPhone, Keep awake, VPN (nil: left as it is).
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
}

extension MacState {
    /// The VPN is on, on its way, or failed with its block in place: anything but off.
    public var vpnUp: Bool { vpn == MacState.vpnOn || vpn == MacState.vpnConnecting || vpn == MacState.vpnFailed }
}
