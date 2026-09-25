import Foundation
import Network

/// A reliable, ordered, two-way byte stream to a port on the phone: a TCP
/// connection over the cable, or one stream of the wireless link. Everything
/// above the transport (control channel, SOCKS forwarding) reads and writes
/// through this. Callbacks may arrive on any queue.
public protocol ByteStream: AnyObject, Sendable {
    /// Delivers the next bytes (at most `maximumLength`). `isComplete` means
    /// the far side will send nothing more.
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, Error?) -> Void)
    /// Sends `data`; with `isComplete` this side sends nothing more (half-close).
    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void)
    /// Tears the stream down in both directions.
    func cancel()
    /// Fires once when the stream fails or ends underneath us (not after `cancel()`).
    var onTerminated: (@Sendable (Error?) -> Void)? { get set }
}

/// A TCP connection as a `ByteStream`.
public final class ConnectionStream: ByteStream, @unchecked Sendable {
    public let connection: NWConnection
    private let lock = NSLock()
    private var terminated = false
    private var _onTerminated: (@Sendable (Error?) -> Void)?

    public var onTerminated: (@Sendable (Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onTerminated }
        set { lock.lock(); _onTerminated = newValue; lock.unlock() }
    }

    /// Wraps `connection`, starting it on `queue` if nobody has yet.
    public init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.terminate(error)
            case .cancelled: self?.terminate(nil)
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) }
    }

    public func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    public func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        if isComplete {
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { completion($0) })
        } else {
            connection.send(content: data, completion: .contentProcessed { completion($0) })
        }
    }

    public func cancel() {
        lock.lock(); terminated = true; lock.unlock()
        connection.cancel()
    }

    private func terminate(_ error: Error?) {
        lock.lock()
        let first = !terminated
        terminated = true
        let handler = _onTerminated
        lock.unlock()
        if first { handler?(error) }
    }
}
