import Foundation

/// Joins two byte streams: whatever one receives the other sends, half-closes
/// pass through, and either side failing tears both down. The Mac's local
/// forwarder and the phone's end of the wireless link both use it.
public final class Splice: @unchecked Sendable {
    private let a: ByteStream
    private let b: ByteStream
    private let queue: DispatchQueue
    private let onBytes: ((_ aToB: Bool, _ count: Int) -> Void)?
    private let onClose: () -> Void
    private var closed = false
    private var halfClosures = 0

    /// `onBytes` counts traffic as it moves; `onClose` fires once, on `queue`.
    public init(_ a: ByteStream, _ b: ByteStream, queue: DispatchQueue,
                onBytes: ((_ aToB: Bool, _ count: Int) -> Void)? = nil, onClose: @escaping () -> Void) {
        self.a = a; self.b = b; self.queue = queue; self.onBytes = onBytes; self.onClose = onClose
    }

    public func start() {
        a.onTerminated = { [weak self] _ in self?.close() }
        b.onTerminated = { [weak self] _ in self?.close() }
        pump(from: a, to: b, aToB: true)
        pump(from: b, to: a, aToB: false)
    }

    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            a.onTerminated = nil
            b.onTerminated = nil
            a.cancel()
            b.cancel()
            onClose()
        }
    }

    private func pump(from source: ByteStream, to sink: ByteStream, aToB: Bool) {
        source.receive(maximumLength: 256 * 1024) { [weak self] data, isComplete, error in
            guard let self else { return }
            self.queue.async { self.moved(data, isComplete: isComplete, error: error, from: source, to: sink, aToB: aToB) }
        }
    }

    private func moved(_ data: Data?, isComplete: Bool, error: Error?, from source: ByteStream, to sink: ByteStream, aToB: Bool) {
        guard !closed else { return }
        if error != nil { close(); return }
        guard let data, !data.isEmpty else {
            isComplete ? halfClose(sink) : pump(from: source, to: sink, aToB: aToB)
            return
        }
        onBytes?(aToB, data.count)
        sink.send(data, isComplete: false) { [weak self] sendError in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if sendError != nil { self.close(); return }
                isComplete ? self.halfClose(sink) : self.pump(from: source, to: sink, aToB: aToB)
            }
        }
    }

    private func halfClose(_ sink: ByteStream) {
        sink.send(nil, isComplete: true) { _ in }
        halfClosures += 1
        if halfClosures >= 2 { close() }
    }
}
