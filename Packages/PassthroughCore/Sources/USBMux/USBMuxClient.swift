import Foundation
import Network
import PassthroughCore

/// Speaks the usbmuxd protocol over its Unix socket so the Mac can open TCP
/// streams to ports on a USB-attached iPhone. No third party tooling required:
/// macOS ships usbmuxd and the socket is world-accessible.
public enum USBMux {
    public static let socketPath = "/var/run/usbmuxd"

    public struct Device: Identifiable, Hashable, Sendable {
        public let id: Int
        public let udid: String
        public let connectionType: String
        public let productID: Int
        public init(id: Int, udid: String, connectionType: String, productID: Int) {
            self.id = id; self.udid = udid; self.connectionType = connectionType; self.productID = productID
        }
        public var isUSB: Bool { connectionType.uppercased() == "USB" }
    }

    public enum Event: Sendable {
        case attached(Device)
        case detached(Int)
        case listening
        case failed(Error)
    }

    public enum MuxError: LocalizedError {
        case socketUnavailable
        case malformedResponse
        case result(Int)
        case cancelled
        case timeout

        public var errorDescription: String? {
            switch self {
            case .socketUnavailable: return "usbmuxd is not reachable"
            case .malformedResponse: return "usbmuxd sent an unexpected reply"
            case .result(let code):
                switch code {
                case 2: return "iPhone not found on USB"
                case 3: return "The iPhone refused the connection. Is Passthrough running on the phone?"
                case 6: return "usbmuxd version mismatch"
                default: return "usbmuxd error \(code)"
                }
            case .cancelled: return "Cancelled"
            case .timeout: return "usbmuxd did not answer in time"
            }
        }
    }

    // MARK: Framing

    static func packet(_ message: [String: Any], tag: UInt32) throws -> Data {
        var plist = message
        plist["ClientVersionString"] = "Passthrough"
        plist["ProgName"] = "Passthrough"
        plist["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var out = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        le32(UInt32(16 + body.count))
        le32(1)  // version
        le32(8)  // plist message
        le32(tag)
        out.append(body)
        return out
    }

    static func parseHeader(_ data: Data) -> (length: Int, tag: UInt32)? {
        guard data.count == 16 else { return nil }
        let length = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let tag = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }
        return (Int(length), tag)
    }

    static func makeConnection() -> NWConnection {
        NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    /// Reads one full plist response from the socket.
    static func readMessage(_ connection: NWConnection, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { header, _, _, error in
            if let error { completion(.failure(error)); return }
            guard let header, let (length, _) = parseHeader(header), length >= 16, length < 1 << 20 else {
                completion(.failure(MuxError.malformedResponse)); return
            }
            let bodyLength = length - 16
            connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, _, _, error in
                if let error { completion(.failure(error)); return }
                guard let body, body.count == bodyLength,
                      let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
                    completion(.failure(MuxError.malformedResponse)); return
                }
                completion(.success(plist))
            }
        }
    }

    // MARK: Listening for devices

    /// Subscribes to attach/detach events. Cancel the returned connection to stop.
    public static func listen(queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) -> NWConnection {
        let connection = makeConnection()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let packet = try? packet(["MessageType": "Listen"], tag: 1) else { return }
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error { handler(.failed(error)); connection.cancel(); return }
                    readLoop(connection, handler: handler)
                })
            case .failed(let error), .waiting(let error):
                // Terminal for our purposes: drop the handler (it captures the
                // connection) and cancel so nothing lingers; the caller restarts.
                connection.stateUpdateHandler = nil
                connection.cancel()
                handler(.failed(error))
            case .cancelled:
                connection.stateUpdateHandler = nil
            default: break
            }
        }
        connection.start(queue: queue)
        return connection
    }

    private static func readLoop(_ connection: NWConnection, handler: @escaping @Sendable (Event) -> Void) {
        readMessage(connection) { result in
            switch result {
            case .failure(let error):
                handler(.failed(error))
            case .success(let plist):
                switch plist["MessageType"] as? String {
                case "Result":
                    if let number = plist["Number"] as? Int, number != 0 { handler(.failed(MuxError.result(number))); return }
                    handler(.listening)
                case "Attached":
                    if let id = plist["DeviceID"] as? Int, let props = plist["Properties"] as? [String: Any] {
                        handler(.attached(Device(id: id,
                                                 udid: props["SerialNumber"] as? String ?? "",
                                                 connectionType: props["ConnectionType"] as? String ?? "",
                                                 productID: props["ProductID"] as? Int ?? 0)))
                    }
                case "Detached":
                    if let id = plist["DeviceID"] as? Int { handler(.detached(id)) }
                default: break
                }
                readLoop(connection, handler: handler)
            }
        }
    }

    // MARK: Connecting to a device port

    /// Opens a TCP stream to `port` on the device. On success the returned connection
    /// carries the raw stream; the caller owns it.
    public static func connect(deviceID: Int, port: UInt16, queue: DispatchQueue,
                               completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        let connection = makeConnection()
        let done = Locked(false)
        func finish(_ result: Result<NWConnection, Error>) {
            guard done.exchange(true) == false else { return }
            if case .failure = result { connection.cancel() }
            connection.stateUpdateHandler = nil
            completion(result)
        }
        // usbmuxd accepted the socket but never answers (wedged, device mid-reset).
        queue.asyncAfter(deadline: .now() + 10) { finish(.failure(MuxError.timeout)) }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let swapped = Int((port & 0xFF) << 8 | (port >> 8))
                guard let packet = try? packet(["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": swapped], tag: 2) else {
                    finish(.failure(MuxError.malformedResponse)); return
                }
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error { finish(.failure(error)); return }
                    readMessage(connection) { result in
                        switch result {
                        case .failure(let error): finish(.failure(error))
                        case .success(let plist):
                            let number = plist["Number"] as? Int ?? -1
                            number == 0 ? finish(.success(connection)) : finish(.failure(MuxError.result(number)))
                        }
                    }
                })
            case .failed(let error), .waiting(let error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(MuxError.cancelled))
            default: break
            }
        }
        connection.start(queue: queue)
    }
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func exchange(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}
