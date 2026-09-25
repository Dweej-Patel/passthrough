import Foundation
import Network
import PassthroughCore

/// Speaks the adb host protocol to the local adb server (127.0.0.1:5037) so the
/// Mac can open TCP streams to ports on a USB-attached Android phone, the
/// Android counterpart of `USBMux`. Needs Android's platform-tools installed
/// and USB debugging enabled on the phone.
public enum ADB {
    public static let serverPort: UInt16 = 5037

    public struct Device: Hashable, Sendable {
        public let serial: String
        /// "device" when usable; also "unauthorized", "offline", "no permissions"...
        public let state: String
        public let model: String?
        /// Attached over a USB cable (adb over Wi-Fi and emulators are not).
        public let isUSB: Bool
        public init(serial: String, state: String, model: String?, isUSB: Bool) {
            self.serial = serial; self.state = state; self.model = model; self.isUSB = isUSB
        }
        public var isReady: Bool { state == "device" }
    }

    public enum Event: Sendable {
        case devices([Device])
        case failed(Error)
    }

    public enum ADBError: LocalizedError, Equatable {
        case serverUnavailable
        case failed(String)
        case malformedResponse
        case timeout
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .serverUnavailable: return "The adb server is not running"
            case .failed(let message):
                let m = message.lowercased()
                if m.contains("closed") || m.contains("refused") || m.contains("connect") {
                    return "The phone refused the connection. Is Passthrough running on the phone?"
                }
                if m.contains("not found") { return "Android phone not found on USB" }
                if m.contains("unauthorized") { return "Allow USB debugging for this Mac on the phone" }
                return "adb: \(message)"
            case .malformedResponse: return "adb sent an unexpected reply"
            case .timeout: return "adb did not answer in time"
            case .cancelled: return "Cancelled"
            }
        }
    }

    // MARK: Framing

    /// A host request: four hex digits of length, then the payload.
    static func request(_ payload: String) -> Data {
        let body = Data(payload.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    /// Parses `host:track-devices-l` / `host:devices-l` output.
    public static func parseDevices(_ text: String) -> [Device] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            // States may be two words ("no permissions"); the key:value pairs follow.
            var stateWords: [String] = []
            var props: [String: String] = [:]
            var usb = false
            for field in fields.dropFirst() {
                if let colon = field.firstIndex(of: ":") {
                    let key = String(field[..<colon])
                    props[key] = String(field[field.index(after: colon)...])
                    if key == "usb" { usb = true }
                } else if props.isEmpty {
                    stateWords.append(field)
                }
            }
            let state = stateWords.joined(separator: " ")
            let model = props["model"].map { $0.replacingOccurrences(of: "_", with: " ") }
            return Device(serial: fields[0], state: state, model: model, isUSB: usb)
        }
    }

    static func makeConnection() -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: serverPort)!, using: NWParameters(tls: nil, tcp: tcp))
    }

    static func readExactly(_ connection: NWConnection, _ count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
            if let error { completion(.failure(error)); return }
            guard let data, data.count == count else {
                completion(.failure(isComplete ? ADBError.failed("closed") : ADBError.malformedResponse)); return
            }
            completion(.success(data))
        }
    }

    /// Reads a hex length and that many bytes.
    static func readLengthPrefixed(_ connection: NWConnection, completion: @escaping (Result<String, Error>) -> Void) {
        readExactly(connection, 4) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let hex):
                guard let length = Int(String(decoding: hex, as: UTF8.self), radix: 16), length < 1 << 20 else {
                    completion(.failure(ADBError.malformedResponse)); return
                }
                guard length > 0 else { completion(.success("")); return }
                readExactly(connection, length) { body in completion(body.map { String(decoding: $0, as: UTF8.self) }) }
            }
        }
    }

    /// Reads OKAY, or FAIL plus its message.
    static func readStatus(_ connection: NWConnection, completion: @escaping (Result<Void, Error>) -> Void) {
        readExactly(connection, 4) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let status):
                switch String(decoding: status, as: UTF8.self) {
                case "OKAY": completion(.success(()))
                case "FAIL":
                    readLengthPrefixed(connection) { message in
                        completion(.failure(ADBError.failed((try? message.get()) ?? "unknown error")))
                    }
                default: completion(.failure(ADBError.malformedResponse))
                }
            }
        }
    }

    static func send(_ connection: NWConnection, _ payload: String, completion: @escaping (Error?) -> Void) {
        connection.send(content: request(payload), completion: .contentProcessed { completion($0) })
    }

    /// A connection error that means nothing listens on 5037.
    static func isServerDown(_ error: Error) -> Bool {
        if let nw = error as? NWError, case .posix(let code) = nw { return code == .ECONNREFUSED }
        return false
    }

    // MARK: Watching devices

    /// Streams the device list whenever it changes. Cancel the returned connection to stop.
    public static func track(queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) -> NWConnection {
        let connection = makeConnection()
        let done = Locked(false)
        let fail: @Sendable (Error) -> Void = { error in
            guard done.exchange(true) == false else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            handler(.failed(error))
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                send(connection, "host:track-devices-l") { error in
                    if let error { fail(error); return }
                    readStatus(connection) { result in
                        if case .failure(let e) = result { fail(e); return }
                        readLoop(connection, handler: handler, fail: fail)
                    }
                }
            case .failed(let error):
                fail(isServerDown(error) ? ADBError.serverUnavailable : error)
            case .waiting(let error):
                fail(isServerDown(error) ? ADBError.serverUnavailable : error)
            case .cancelled:
                connection.stateUpdateHandler = nil
            default: break
            }
        }
        connection.start(queue: queue)
        return connection
    }

    private static func readLoop(_ connection: NWConnection, handler: @escaping @Sendable (Event) -> Void, fail: @escaping @Sendable (Error) -> Void) {
        readLengthPrefixed(connection) { result in
            switch result {
            case .failure(let error): fail(error)
            case .success(let text):
                handler(.devices(parseDevices(text)))
                readLoop(connection, handler: handler, fail: fail)
            }
        }
    }

    // MARK: Connecting to a device port

    /// Opens a TCP stream to `port` on the phone's loopback, through adbd. On
    /// success the returned connection carries the raw stream; the caller owns it.
    public static func connect(serial: String, port: UInt16, queue: DispatchQueue,
                               completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        let connection = makeConnection()
        let done = Locked(false)
        let finish: @Sendable (Result<NWConnection, Error>) -> Void = { result in
            guard done.exchange(true) == false else { return }
            if case .failure = result { connection.cancel() }
            connection.stateUpdateHandler = nil
            completion(result)
        }
        queue.asyncAfter(deadline: .now() + 10) { finish(.failure(ADBError.timeout)) }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                send(connection, "host:transport:\(serial)") { error in
                    if let error { finish(.failure(error)); return }
                    readStatus(connection) { result in
                        if case .failure(let e) = result { finish(.failure(e)); return }
                        send(connection, "tcp:\(port)") { error in
                            if let error { finish(.failure(error)); return }
                            readStatus(connection) { result in
                                switch result {
                                case .failure(let e): finish(.failure(e))
                                case .success: finish(.success(connection))
                                }
                            }
                        }
                    }
                }
            case .failed(let error), .waiting(let error):
                finish(.failure(isServerDown(error) ? ADBError.serverUnavailable : error))
            case .cancelled:
                finish(.failure(ADBError.cancelled))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: The adb binary

    /// Where platform-tools usually live. A menu bar app does not inherit the
    /// shell's PATH, so look in the usual places explicitly.
    public static func findBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var candidates: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key] { candidates.append("\(root)/platform-tools/adb") }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/opt/homebrew/Caskroom/android-platform-tools/latest/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `adb start-server` and waits for it (blocking; call off the main thread).
    @discardableResult
    public static func startServer(binary: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["start-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }
}
