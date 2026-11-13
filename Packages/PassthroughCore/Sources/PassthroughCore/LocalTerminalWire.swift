import Foundation

/// What a terminal window on the Mac and the Passthrough app say to each
/// other over the app's Unix socket, so a shell in that window is one of the
/// app's sessions and phones can see it. It never leaves the Mac.
///
/// Frames: one byte of kind, a big-endian UInt32 length, then the payload.
/// `input` and `output` carry raw terminal bytes; the rest carry JSON, except
/// `resize` (two big-endian UInt16: columns, rows).
public enum LocalTerminalWire {
    /// Longest payload either side accepts.
    public static let maxPayload = 1 << 20
    /// Largest piece of output in one frame.
    public static let outputChunk = 65_536

    public enum Kind: UInt8, Sendable {
        // Terminal to app.
        case hello = 1, input = 2, resize = 3
        // App to terminal.
        case started = 16, output = 17, replayed = 18, ended = 19, refused = 20, sessions = 21
    }

    public struct Frame: Equatable, Sendable {
        public var kind: Kind
        public var payload: Data
        public init(_ kind: Kind, _ payload: Data = Data()) { self.kind = kind; self.payload = payload }
    }

    public enum Mode: String, Codable, Sendable {
        /// A new terminal's shell asking by itself (the startup hook): allowed
        /// only while the owner has turned sharing every terminal on.
        case hook
        /// A new session, asked for by name.
        case new
        /// Show a session that is already running.
        case attach
        /// Only list the sessions.
        case list
    }

    /// The first frame a terminal sends.
    public struct Hello: Codable, Equatable, Sendable {
        public var mode: Mode
        /// The session to show (`attach`).
        public var session: String?
        public var cols: Int
        public var rows: Int
        /// The terminal's folder and environment, so a new session's shell
        /// starts as the terminal's own would have.
        public var directory: String?
        public var environment: [String: String]?
        /// The window's colours, when its terminal told them.
        public var theme: ShellTheme?

        public init(mode: Mode, session: String? = nil, cols: Int, rows: Int, directory: String? = nil,
                    environment: [String: String]? = nil, theme: ShellTheme? = nil) {
            self.mode = mode; self.session = session; self.cols = cols; self.rows = rows
            self.directory = directory; self.environment = environment; self.theme = theme
        }
    }

    public struct Started: Codable, Equatable, Sendable {
        public var session: String
        public init(session: String) { self.session = session }
    }

    public struct Ended: Codable, Equatable, Sendable {
        public var exitStatus: Int32
        public init(exitStatus: Int32) { self.exitStatus = exitStatus }
    }

    public struct Refused: Codable, Equatable, Sendable {
        public var reason: String
        public init(reason: String) { self.reason = reason }

        /// Sharing every terminal is off, or this one was asked to stay plain.
        public static let notSharing = "not_sharing"
        public static let tooManySessions = ShellError.tooManySessions.rawValue
        public static let noSuchSession = ShellError.noSuchSession.rawValue
        public static let badRequest = ShellError.badRequest.rawValue
    }

    public enum WireError: Error, Equatable { case tooLong, malformed }

    public static func encode(_ kind: Kind, _ payload: Data = Data()) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func encode<T: Encodable>(_ kind: Kind, json value: T) -> Data {
        // These are plain structs of strings and numbers: encoding cannot fail.
        encode(kind, (try? JSONEncoder().encode(value)) ?? Data())
    }

    public static func encodeResize(cols: Int, rows: Int) -> Data {
        var payload = Data()
        for value in [cols, rows] {
            withUnsafeBytes(of: UInt16(clamping: max(1, value)).bigEndian) { payload.append(contentsOf: $0) }
        }
        return encode(.resize, payload)
    }

    public static func decodeResize(_ payload: Data) -> (cols: Int, rows: Int)? {
        guard payload.count == 4 else { return nil }
        let bytes = [UInt8](payload)
        return (Int(bytes[0]) << 8 | Int(bytes[1]), Int(bytes[2]) << 8 | Int(bytes[3]))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from frame: Frame) -> T? {
        try? JSONDecoder().decode(type, from: frame.payload)
    }

    /// Splits a byte stream into frames. A kind it does not know is skipped,
    /// so either side can learn new ones.
    public struct Parser: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func append(_ data: Data) throws -> [Frame] {
            buffer.append(data)
            var frames: [Frame] = []
            var offset = 0
            let bytes = [UInt8](buffer)
            while bytes.count - offset >= 5 {
                let length = Int(bytes[offset + 1]) << 24 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
                guard length <= LocalTerminalWire.maxPayload else { throw WireError.tooLong }
                guard bytes.count - offset >= 5 + length else { break }
                if let kind = Kind(rawValue: bytes[offset]) {
                    frames.append(Frame(kind, Data(bytes[(offset + 5)..<(offset + 5 + length)])))
                }
                offset += 5 + length
            }
            buffer = Data(bytes[offset...])
            return frames
        }
    }
}
