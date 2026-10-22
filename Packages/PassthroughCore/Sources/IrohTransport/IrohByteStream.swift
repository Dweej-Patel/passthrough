import Foundation
import IrohLib
import PassthroughCore

/// How an iroh connection is currently carried.
public enum IrohPath: Sendable, Equatable {
    /// UDP straight to the peer (LAN, or a hole-punched path).
    case direct
    /// Through a relay server.
    case relay
    /// No path selected yet.
    case unknown
}

public enum IrohTransportError: Error, Equatable, Sendable {
    /// The stream was cancelled on this side.
    case cancelled
    /// The connection closed underneath the stream; the reason is iroh's.
    case connectionClosed(String)
    /// The endpoint was shut down.
    case endpointClosed
    /// Not a 32-byte secret key.
    case invalidSecretKey
    /// The peer negotiated a protocol other than the one asked for.
    case wrongALPN
}

/// One bidirectional QUIC stream of an iroh connection as a `ByteStream`.
/// The stream owns its connection: cancelling it (or dropping it) closes the
/// connection, gracefully: data already handed to `send` still reaches the
/// peer (bounded by `drainTimeout`). Async iroh calls run in Swift tasks chained per direction, so
/// sends (and receives) complete in the order they were issued; completions
/// and `onTerminated` are delivered on a private serial queue.
public final class IrohByteStream: ByteStream, @unchecked Sendable {
    let connection: Connection
    private let sendHalf: SendStream
    private let recvHalf: RecvStream
    /// Largest single read (each read allocates this much in Rust).
    static let maxReadLength = 65536
    /// How long `cancel()` waits for sent data to be acknowledged before closing.
    static let drainTimeout: UInt64 = 2_000_000_000
    private let queue = DispatchQueue(label: "iroh.stream")

    private let lock = NSLock()
    private var cancelled = false
    private var terminated = false
    private var _onTerminated: (@Sendable (Error?) -> Void)?
    private var sendTail: Task<Void, Never>?
    private var recvTail: Task<Void, Never>?

    public var onTerminated: (@Sendable (Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onTerminated }
        set { lock.lock(); _onTerminated = newValue; lock.unlock() }
    }

    init(connection: Connection, stream: BiStream) {
        self.connection = connection
        sendHalf = stream.send()
        recvHalf = stream.recv()
        Task { [weak self, connection] in
            let reason = await connection.closed()
            // A close with code 0 (ours or the peer's) is a clean end.
            self?.terminate(IrohPaths.isCleanClose(reason) ? nil : IrohTransportError.connectionClosed(reason))
        }
    }

    deinit {
        try? connection.close(errorCode: 0, reason: Data())
    }

    /// The peer's endpoint id.
    public var remoteID: String { connection.remoteId().description }

    /// The path currently selected for this connection.
    public var pathKind: IrohPath { IrohPaths.kind(connection.paths()) }

    /// The peer's IP address when the selected path is direct, else nil.
    public var remoteIP: String? { IrohPaths.remoteIP(connection.paths()) }

    public func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        let queue = self.queue
        lock.lock()
        if cancelled {
            lock.unlock()
            queue.async { completion(nil, true, IrohTransportError.cancelled) }
            return
        }
        let previous = recvTail
        let recv = recvHalf
        let limit = UInt32(clamping: min(max(1, maximumLength), Self.maxReadLength))
        recvTail = Task {
            await previous?.value
            do {
                let data = try await recv.read(sizeLimit: limit)
                // iroh returns an empty buffer once the peer has finished.
                queue.async { data.isEmpty ? completion(nil, true, nil) : completion(data, false, nil) }
            } catch {
                queue.async { completion(nil, true, error) }
            }
        }
        lock.unlock()
    }

    public func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        let queue = self.queue
        lock.lock()
        if cancelled {
            lock.unlock()
            queue.async { completion(IrohTransportError.cancelled) }
            return
        }
        let previous = sendTail
        let send = sendHalf
        sendTail = Task {
            await previous?.value
            do {
                if let data, !data.isEmpty { try await send.writeAll(buf: data) }
                if isComplete { try await send.finish() }
                queue.async { completion(nil) }
            } catch {
                queue.async { completion(error) }
            }
        }
        lock.unlock()
    }

    /// Stops new sends and receives at once, then finishes the send half and
    /// closes the connection once the peer has acknowledged everything already
    /// sent (or after `drainTimeout`), so `send(x) { cancel() }` delivers x
    /// as it does over TCP.
    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        terminated = true
        let tail = sendTail
        lock.unlock()
        guard first else { return }
        let close = CloseOnce(connection)
        Task {
            await tail?.value
            try? await self.sendHalf.finish()   // fails harmlessly if already finished
            _ = try? await self.sendHalf.stopped()
            close.fire()
        }
        Task {
            try? await Task.sleep(nanoseconds: Self.drainTimeout)
            close.fire()
        }
    }

    private func terminate(_ error: Error?) {
        lock.lock()
        let first = !terminated
        terminated = true
        let handler = _onTerminated
        lock.unlock()
        if first, let handler { queue.async { handler(error) } }
    }
}

/// Closes a connection (code 0) the first time it fires.
private final class CloseOnce: @unchecked Sendable {
    private let connection: Connection
    private let lock = NSLock()
    private var fired = false

    init(_ connection: Connection) { self.connection = connection }

    func fire() {
        let first: Bool = lock.withLock {
            defer { fired = true }
            return !fired
        }
        if first { try? connection.close(errorCode: 0, reason: Data()) }
    }
}

/// Reads iroh's path snapshots.
enum IrohPaths {
    static func selected(_ paths: [PathSnapshot]) -> PathSnapshot? {
        paths.first(where: \.isSelected)
    }

    static func kind(_ paths: [PathSnapshot]) -> IrohPath {
        guard let path = selected(paths) else { return .unknown }
        if path.isRelay { return .relay }
        if path.isIp { return .direct }
        return .unknown
    }

    static func remoteIP(_ paths: [PathSnapshot]) -> String? {
        guard let path = selected(paths), path.isIp, !path.isRelay else { return nil }
        return host(ofSocketAddress: path.remoteAddr)
    }

    /// True for iroh's close reasons that mean application code 0 or our own
    /// close: "closed" (local) and "closed by peer: 0".
    static func isCleanClose(_ reason: String) -> Bool {
        if reason == "closed" { return true }
        let prefix = "closed by peer: "
        guard reason.hasPrefix(prefix) else { return false }
        let code = reason.dropFirst(prefix.count).prefix(while: \.isNumber)
        return code == "0"
    }

    /// "1.2.3.4:5" → "1.2.3.4"; "[fe80::1%en0]:5" → "fe80::1%en0".
    static func host(ofSocketAddress address: String) -> String? {
        if address.hasPrefix("[") {
            guard let close = address.firstIndex(of: "]") else { return nil }
            return String(address[address.index(after: address.startIndex)..<close])
        }
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return String(address[..<colon])
    }
}
