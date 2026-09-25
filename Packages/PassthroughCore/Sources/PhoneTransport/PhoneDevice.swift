import Foundation
import Network
import PassthroughCore

/// Opens byte streams to ports on a phone's loopback. Each way of reaching a
/// phone (usbmuxd for an iPhone, adb for an Android phone, the wireless link)
/// is one link; everything above it, pairing, SOCKS and the tunnel, is the
/// same for all.
public protocol PhoneLink: Sendable {
    /// On success the stream is open and the caller owns it.
    func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void)
}

extension Result where Success == NWConnection {
    /// A cable transport's connection, as a stream.
    func stream(on queue: DispatchQueue) -> Result<ByteStream, Error> {
        map { ConnectionStream($0, queue: queue) }.mapError { $0 as Error }
    }
}

/// An iPhone on the cable, through macOS's usbmuxd.
public struct USBMuxLink: PhoneLink {
    public let deviceID: Int
    public init(deviceID: Int) { self.deviceID = deviceID }
    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void) {
        USBMux.connect(deviceID: deviceID, port: port, queue: queue) { completion($0.stream(on: queue)) }
    }
}

/// An Android phone on the cable, through the local adb server.
public struct ADBLink: PhoneLink {
    public let serial: String
    public init(serial: String) { self.serial = serial }
    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void) {
        ADB.connect(serial: serial, port: port, queue: queue) { completion($0.stream(on: queue)) }
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

    /// How the Mac reaches the phone.
    public enum Medium: Sendable { case usb, wireless }

    /// Unique among attached phones, e.g. "usbmux:3", "adb:R58M…" or "wifi:<phoneID>".
    public let id: String
    public let kind: Kind
    public let medium: Medium
    /// Short hardware label for logs ("00008110…", "Pixel 8").
    public let label: String
    /// Names the stored pairing token for this phone. Every iPhone shares the
    /// original slot; each Android phone gets its own, keyed by serial.
    public let pairingSlot: String
    public let link: any PhoneLink

    public init(id: String, kind: Kind, medium: Medium = .usb, label: String, pairingSlot: String, link: any PhoneLink) {
        self.id = id; self.kind = kind; self.medium = medium; self.label = label; self.pairingSlot = pairingSlot; self.link = link
    }

    /// A phone that dialed in over the wireless link.
    public static func wireless(phoneID: String, kind: Kind, label: String, pairingSlot: String, link: any PhoneLink) -> PhoneDevice {
        PhoneDevice(id: "wifi:\(phoneID)", kind: kind, medium: .wireless, label: label, pairingSlot: pairingSlot, link: link)
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

    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void) {
        link.connect(port: port, queue: queue, completion: completion)
    }

    public static func == (a: PhoneDevice, b: PhoneDevice) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
