import Foundation
import Network
import PassthroughCore

/// A phone on the USB cable, reached either through usbmuxd (iPhone) or adb
/// (Android). Everything above the transport, pairing, SOCKS and the tunnel,
/// is the same for both.
public struct PhoneDevice: Identifiable, Hashable, Sendable {
    public enum Transport: Hashable, Sendable {
        case usbmux(Int)
        case adb(String)
    }

    public enum Kind: Sendable { case iPhone, android }

    public let transport: Transport
    /// Short hardware label for logs ("00008110…", "Pixel 8").
    public let label: String

    public init(transport: Transport, label: String) {
        self.transport = transport
        self.label = label
    }

    public var id: String {
        switch transport {
        case .usbmux(let id): return "usbmux:\(id)"
        case .adb(let serial): return "adb:\(serial)"
        }
    }

    public var kind: Kind {
        if case .adb = transport { return .android }
        return .iPhone
    }

    /// "iPhone" or "Android phone", for UI copy.
    public var kindName: String { kind == .android ? "Android phone" : "iPhone" }

    /// Opens a raw TCP stream to `port` on the phone's loopback.
    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        switch transport {
        case .usbmux(let id): USBMux.connect(deviceID: id, port: port, queue: queue, completion: completion)
        case .adb(let serial): ADB.connect(serial: serial, port: port, queue: queue, completion: completion)
        }
    }
}
