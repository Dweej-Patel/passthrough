import Foundation
import Network
import PassthroughCore

/// Opens raw TCP streams to ports on a phone's loopback. Each way of reaching
/// a phone (usbmuxd for an iPhone, adb for an Android phone) is one link;
/// everything above it, pairing, SOCKS and the tunnel, is the same for all.
public protocol PhoneLink: Sendable {
    /// On success the connection carries the raw stream and the caller owns it.
    func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void)
}

/// An iPhone on the cable, through macOS's usbmuxd.
public struct USBMuxLink: PhoneLink {
    public let deviceID: Int
    public init(deviceID: Int) { self.deviceID = deviceID }
    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        USBMux.connect(deviceID: deviceID, port: port, queue: queue, completion: completion)
    }
}

/// An Android phone on the cable, through the local adb server.
public struct ADBLink: PhoneLink {
    public let serial: String
    public init(serial: String) { self.serial = serial }
    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        ADB.connect(serial: serial, port: port, queue: queue, completion: completion)
    }
}

/// A phone the Mac can reach, and the link to reach it.
public struct PhoneDevice: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case iPhone, android
        /// "iPhone" or "Android phone", for UI copy.
        public var name: String { self == .android ? "Android phone" : "iPhone" }
        /// The keychain slot every iPhone shares (the one used before Android support).
        public var defaultPairingSlot: String { "token" }
    }

    /// Unique among attached phones, e.g. "usbmux:3" or "adb:R58M…".
    public let id: String
    public let kind: Kind
    /// Short hardware label for logs ("00008110…", "Pixel 8").
    public let label: String
    /// Names the stored pairing token for this phone. Every iPhone shares the
    /// original slot; each Android phone gets its own, keyed by serial.
    public let pairingSlot: String
    public let link: any PhoneLink

    public init(id: String, kind: Kind, label: String, pairingSlot: String, link: any PhoneLink) {
        self.id = id; self.kind = kind; self.label = label; self.pairingSlot = pairingSlot; self.link = link
    }

    public static func iPhone(deviceID: Int, udid: String) -> PhoneDevice {
        PhoneDevice(id: "usbmux:\(deviceID)", kind: .iPhone, label: String(udid.prefix(8)) + "…",
                    pairingSlot: Kind.iPhone.defaultPairingSlot, link: USBMuxLink(deviceID: deviceID))
    }

    public static func android(serial: String, model: String?) -> PhoneDevice {
        let safe = serial.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return PhoneDevice(id: "adb:\(serial)", kind: .android, label: model ?? serial,
                           pairingSlot: "token.android." + safe, link: ADBLink(serial: serial))
    }

    /// "iPhone" or "Android phone", for UI copy.
    public var kindName: String { kind.name }

    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        link.connect(port: port, queue: queue, completion: completion)
    }

    public static func == (a: PhoneDevice, b: PhoneDevice) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
