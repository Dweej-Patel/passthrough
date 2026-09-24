import Foundation
import Network

/// Splits a byte stream into newline-terminated lines: the control channel's framing.
public struct LineBuffer: Sendable {
    public struct Overflow: Error {}
    public static let defaultLimit = 256 * 1024

    private var pending = Data()
    private let limit: Int

    public init(limit: Int = LineBuffer.defaultLimit) { self.limit = limit }

    /// Appends bytes and returns every complete, non-empty line. Throws when
    /// more than `limit` bytes arrive without a newline.
    public mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        if pending.count > limit { throw Overflow() }
        return lines
    }
}

/// One control-channel stream: newline-delimited JSON envelopes in both
/// directions. The phone's `ControlServer` and the Mac's `ControlClient` both
/// talk through it, whatever carries the bytes (usbmuxd, adb, a network link).
public final class ControlConnection: @unchecked Sendable {
    /// Decoded messages, on the connection's queue.
    public var onMessage: ((ControlEnvelope) -> Void)?
    /// Fires once when the stream ends by itself: nil for a clean close, else
    /// the error. Not called after `cancel()`.
    public var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private var lines = LineBuffer()
    private var closed = false

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts reading. A connection that a transport already opened keeps the
    /// queue it was started on; a fresh one is started on `queue`.
    public func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) }
        receive()
    }

    public func send(_ messages: [ControlEnvelope]) {
        guard !closed, !messages.isEmpty else { return }
        var payload = Data()
        for m in messages { if let line = try? m.encodedLine() { payload.append(line) } }
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    public func send(_ message: ControlEnvelope) { send([message]) }

    /// Closes the stream without reporting it through `onClose`.
    public func cancel() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            do {
                for line in try self.lines.append(data ?? Data()) {
                    guard !self.closed else { return }
                    if let message = try? ControlEnvelope.decode(line) {
                        self.onMessage?(message)
                    } else {
                        ptLog(.warning, "control: undecodable message")
                    }
                }
            } catch {
                self.finish(NWError.posix(.EMSGSIZE)); return
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(nil); return }
            self.receive()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        cancel()
        onClose?(error)
    }
}
