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
    /// Whether the phone's current network routes IPv6. Absent from older phones.
    public var ipv6: Bool?
    public var activeConnections: Int?
    public var rxBytes: Int64?
    public var txBytes: Int64?
    public var timestamp: Double?
    // Linking the wireless link (see protocol/README.md).
    public var linkKey: String?
    public var certSHA256: String?
    public var phoneID: String?
    public var network: String?
    public var passphrase: String?
    /// hello: how the Mac reaches the phone on this connection, "usb" or
    /// "wireless". A phone can have a wireless link up while the Mac uses the
    /// cable, so only the Mac knows which carries its traffic.
    public var via: String?

    public init(t: String) { self.t = t }

    public static let hello = "hello"
    public static let welcome = "welcome"
    public static let pair = "pair"
    public static let paired = "paired"
    public static let error = "error"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let status = "status"
    public static let link = "link"
    public static let linked = "linked"

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
    /// `WirelessLink.macTag` of the Macs whose link is up over the air.
    public var wirelessMacTags: [String]?
    /// What carries the wireless link: "Hotspot", "Peer-to-peer", "USB" or "Wi-Fi network".
    public var wirelessCarrier: String?
    public init(rx: Int64, tx: Int64, active: Int, totalConnections: Int, macs: [ConnectedMac], startedAt: Date?,
                wirelessMacTags: [String]? = nil, wirelessCarrier: String? = nil) {
        self.rx = rx; self.tx = tx; self.active = active; self.totalConnections = totalConnections; self.macs = macs; self.startedAt = startedAt
        self.wirelessMacTags = wirelessMacTags; self.wirelessCarrier = wirelessCarrier
    }

    /// Whether `mac` is connected over the wireless link rather than the cable:
    /// as the Mac said, or for a Mac too old to say, whether a link to it is up.
    public func isWireless(_ mac: ConnectedMac) -> Bool {
        mac.wireless ?? wirelessMacTags?.contains(WirelessLink.macTag(clientID: mac.id)) ?? false
    }
}

/// Keys the iOS app and extension share through the App Group defaults.
extension PassthroughProtocol {
    /// Shared log file in the App Group container, appended by the app and the extension.
    public static var sharedLogURL: URL? {
        // Under Library/ so `devicectl device copy from` can pull it for diagnostics.
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("Library", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("passthrough.log")
    }
}

public enum SharedKeys {
    public static let deviceName = "device.name"
    public static let radio = "device.radio"
    public static let carrier = "device.carrier"
    public static let battery = "device.battery"
    public static let cellularOnly = "settings.cellularOnly"
    public static let allowUDP = "settings.allowUDP"
    public static let socksPort = "settings.socksPort"
    public static let controlPort = "settings.controlPort"
    /// `Egress` raw value: which network "cellular only" is using right now.
    public static let egress = "state.egress"
    /// Dial linked Macs over the wireless link too.
    public static let wireless = "settings.wireless"
    /// Let the wireless link use Apple peer-to-peer Wi-Fi as well.
    public static let peerToPeer = "settings.peerToPeer"
    public static let usageMonthRx = "usage.month.rx"
    public static let usageMonthTx = "usage.month.tx"
    public static let usageMonthStart = "usage.month.start"
    public static let usageAllTimeRx = "usage.all.rx"
    public static let usageAllTimeTx = "usage.all.tx"
}
