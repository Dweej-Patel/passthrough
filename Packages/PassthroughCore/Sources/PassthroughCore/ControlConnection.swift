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
/// talk through it, whatever carries the bytes (see `ByteStream`).
public final class ControlConnection: @unchecked Sendable {
    /// Decoded messages, on the queue passed to `start`.
    public var onMessage: ((ControlEnvelope) -> Void)?
    /// Fires once, on that queue, when the stream ends by itself: nil for a
    /// clean close, else the error. Not called after `cancel()`.
    public var onClose: ((Error?) -> Void)?

    private let stream: ByteStream
    private var queue: DispatchQueue?
    private var lines = LineBuffer()
    private var closed = false

    public init(_ stream: ByteStream) {
        self.stream = stream
    }

    /// Wraps a TCP connection (starting it on `queue` if needed).
    public convenience init(_ connection: NWConnection, queue: DispatchQueue) {
        self.init(ConnectionStream(connection, queue: queue))
    }

    /// Starts reading; every callback is delivered on `queue`.
    public func start(queue: DispatchQueue) {
        self.queue = queue
        stream.onTerminated = { [weak self] error in queue.async { self?.finish(error) } }
        receive()
    }

    public func send(_ messages: [ControlEnvelope]) {
        guard !closed, !messages.isEmpty else { return }
        var payload = Data()
        for m in messages { if let line = try? m.encodedLine() { payload.append(line) } }
        stream.send(payload, isComplete: false) { [weak self] error in
            guard let error, let self, let queue = self.queue else { return }
            queue.async { self.finish(error) }
        }
    }

    public func send(_ message: ControlEnvelope) { send([message]) }

    /// Closes the stream without reporting it through `onClose`.
    public func cancel() {
        guard !closed else { return }
        closed = true
        stream.onTerminated = nil
        stream.cancel()
    }

    private func receive() {
        stream.receive(maximumLength: 64 * 1024) { [weak self] data, isComplete, error in
            guard let self, let queue = self.queue else { return }
            queue.async { self.received(data, isComplete: isComplete, error: error) }
        }
    }

    private func received(_ data: Data?, isComplete: Bool, error: Error?) {
        guard !closed else { return }
        do {
            for line in try lines.append(data ?? Data()) {
                guard !closed else { return }
                if let message = try? ControlEnvelope.decode(line) {
                    onMessage?(message)
                } else {
                    ptLog(.warning, "control: undecodable message")
                }
            }
        } catch {
            finish(NWError.posix(.EMSGSIZE)); return
        }
        if let error { finish(error); return }
        if isComplete { finish(nil); return }
        receive()
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        cancel()
        onClose?(error)
    }
}
