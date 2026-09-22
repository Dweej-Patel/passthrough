import Foundation

/// Constants shared by the iPhone server and the Mac client.
public enum PassthroughProtocol {
    /// Bump when the wire protocol changes incompatibly.
    public static let version = 1
    /// SOCKS5 port the iPhone listens on (loopback only, reached over usbmuxd).
    public static let defaultSOCKSPort: UInt16 = 7890
    /// Control channel port (pairing, heartbeat, device status).
    public static let defaultControlPort: UInt16 = 7891
    /// Loopback port the Mac exposes to its own tunnel helper.
    public static let defaultLocalSOCKSPort: UInt16 = 17890
    /// App Group shared between the iOS app and its tunnel extension.
    public static let appGroup = "group.dev.dpatel.passthrough"
    public static let pairingCodeLifetime: TimeInterval = 300
}

/// Newline-delimited JSON envelope used on the control channel.
/// Every message carries a type tag `t`; remaining fields are optional.
public struct ControlEnvelope: Codable, Equatable, Sendable {
    public var t: String
    public var protocolVersion: Int?
    public var clientID: String?
    public var name: String?
    public var code: String?
    public var token: String?
    public var reason: String?
    public var paired: Bool?
    public var socksPort: Int?
    public var deviceName: String?
    public var radio: String?
    public var carrier: String?
    public var battery: Double?
    public var hosting: String?
    public var activeConnections: Int?
    public var rxBytes: Int64?
    public var txBytes: Int64?
    public var timestamp: Double?

    public init(t: String) { self.t = t }

    public static let hello = "hello"
    public static let welcome = "welcome"
    public static let pair = "pair"
    public static let paired = "paired"
    public static let error = "error"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let status = "status"

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> ControlEnvelope {
        try JSONDecoder().decode(ControlEnvelope.self, from: line)
    }
}

/// Reasons a pairing attempt can fail, sent back over the control channel.
public enum PairingFailure: String, Sendable, Error {
    case badCode = "bad_code"
    case expired = "expired"
    case notAuthenticated = "not_authenticated"
    case unsupportedVersion = "unsupported_version"
}

/// Snapshot the tunnel extension hands the iOS app on request.
public struct ProviderStats: Codable, Sendable, Equatable {
    public var rx: Int64
    public var tx: Int64
    public var active: Int
    public var totalConnections: Int
    public var macs: [ConnectedMac]
    public var startedAt: Date?
    public init(rx: Int64, tx: Int64, active: Int, totalConnections: Int, macs: [ConnectedMac], startedAt: Date?) {
        self.rx = rx; self.tx = tx; self.active = active; self.totalConnections = totalConnections; self.macs = macs; self.startedAt = startedAt
    }
}

/// Keys the iOS app and extension share through the App Group defaults.
public enum SharedKeys {
    public static let deviceName = "device.name"
    public static let radio = "device.radio"
    public static let carrier = "device.carrier"
    public static let battery = "device.battery"
    public static let cellularOnly = "settings.cellularOnly"
    public static let allowUDP = "settings.allowUDP"
    public static let socksPort = "settings.socksPort"
    public static let controlPort = "settings.controlPort"
    public static let usageMonthRx = "usage.month.rx"
    public static let usageMonthTx = "usage.month.tx"
    public static let usageMonthStart = "usage.month.start"
    public static let usageAllTimeRx = "usage.all.rx"
    public static let usageAllTimeTx = "usage.all.tx"
}
