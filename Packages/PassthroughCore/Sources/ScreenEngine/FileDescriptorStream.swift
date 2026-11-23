import Foundation
import PassthroughCore

/// One end of a socket pair as a `ByteStream`: how a PC's Remote Desktop bytes
/// cross between the app (which holds the authenticated connection) and the
/// sandboxed engine helper (which is never given a network socket).
/// One receive and any number of sends at a time; sends complete in order.
public final class FileDescriptorStream: ByteStream, @unchecked Sendable {
    public struct Closed: Error {}

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).fd-stream")
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    private var readerRunning = false
    private var writerRunning = false
    private var receiving: (maximum: Int, completion: @Sendable (Data?, Bool, Error?) -> Void)?
    private var sends: [(data: Data, offset: Int, complete: Bool, completion: @Sendable (Error?) -> Void)] = []
    private var cancelled = false
    private var terminated = false
    private var handler: (@Sendable (Error?) -> Void)?
    private let handlerLock = NSLock()

    public var onTerminated: (@Sendable (Error?) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return handler }
        set { handlerLock.lock(); handler = newValue; handlerLock.unlock() }
    }

    /// Takes the descriptor: it is closed when the stream is cancelled or freed.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.readable() }
        writer.setEventHandler { [weak self] in self?.writable() }
        // The descriptor outlives both sources: closed when the second one is done with it.
        let group = DispatchGroup()
        group.enter(); group.enter()
        reader.setCancelHandler { group.leave() }
        writer.setCancelHandler { group.leave() }
        group.notify(queue: queue) { close(descriptor) }
    }

    deinit {
        // A source must be running to be cancelled.
        if !readerRunning { reader.resume() }
        if !writerRunning { writer.resume() }
        reader.cancel()
        writer.cancel()
    }

    /// A connected pair of stream sockets with room for a burst of pictures. Nil if the system has none to give.
    public static func socketPair() -> (Int32, Int32)? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        for descriptor in pair {
            var size: Int32 = 1 << 20
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        return (pair[0], pair[1])
    }

    public func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        queue.async { [self] in
            guard !cancelled else { return completion(nil, false, Closed()) }
            receiving = (max(1, maximumLength), completion)
            readable()
        }
    }

    public func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard !cancelled else { return completion(Closed()) }
            sends.append((data ?? Data(), 0, isComplete, completion))
            writable()
        }
    }

    public func cancel() {
        queue.async { [self] in shutDown(telling: false, error: nil) }
    }

    // MARK: On `queue`

    private func readable() {
        guard !cancelled, let wanted = receiving else { return pauseReader() }
        var buffer = [UInt8](repeating: 0, count: min(wanted.maximum, 256 * 1024))
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
            receiving = nil
            pauseReader()
            wanted.completion(Data(buffer[0..<count]), false, nil)
        } else if count == 0 {
            receiving = nil
            pauseReader()
            wanted.completion(nil, true, nil)
        } else if errno == EAGAIN || errno == EINTR {
            if !readerRunning { readerRunning = true; reader.resume() }
        } else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            receiving = nil
            wanted.completion(nil, false, error)
            shutDown(telling: true, error: error)
        }
    }

    private func writable() {
        while !cancelled, !sends.isEmpty {
            var first = sends[0]
            if first.offset < first.data.count {
                let wrote = first.data.withUnsafeBytes { raw in
                    write(descriptor, raw.baseAddress! + first.offset, first.data.count - first.offset)
                }
                if wrote < 0 {
                    if errno == EAGAIN || errno == EINTR {
                        if !writerRunning { writerRunning = true; writer.resume() }
                        return
                    }
                    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return shutDown(telling: true, error: error)
                }
                first.offset += wrote
                sends[0] = first
                if first.offset < first.data.count { continue }
            }
            sends.removeFirst()
            if first.complete { shutdown(descriptor, SHUT_WR) }
            first.completion(nil)
        }
        if writerRunning { writerRunning = false; writer.suspend() }
    }

    private func pauseReader() {
        if readerRunning { readerRunning = false; reader.suspend() }
    }

    private func shutDown(telling: Bool, error: Error?) {
        guard !cancelled else { return }
        cancelled = true
        shutdown(descriptor, SHUT_RDWR)
        let waiting = receiving, unsent = sends
        receiving = nil
        sends = []
        waiting?.completion(nil, false, error ?? Closed())
        unsent.forEach { $0.completion(error ?? Closed()) }
        if !readerRunning { readerRunning = true; reader.resume() }
        if !writerRunning { writerRunning = true; writer.resume() }
        reader.cancel()
        writer.cancel()
        guard telling, !terminated else { return }
        terminated = true
        onTerminated?(error)
    }
}

/// Carries bytes both ways between two streams until either ends: one read
/// at a time each way, each waiting for its write, so neither side queues
/// more than a read's worth (256 KiB) for the other.
public final class StreamSplice: @unchecked Sendable {
    private let a: any ByteStream
    private let b: any ByteStream
    private let lock = NSLock()
    private var ended = false
    private let onEnd: @Sendable (Error?) -> Void

    /// `initialBytes` came from `a` already and go to `b` first.
    public init(_ a: any ByteStream, initialBytes: Data = Data(), _ b: any ByteStream, onEnd: @escaping @Sendable (Error?) -> Void) {
        self.a = a
        self.b = b
        self.onEnd = onEnd
        a.onTerminated = { [weak self] error in self?.end(error) }
        b.onTerminated = { [weak self] error in self?.end(error) }
        if initialBytes.isEmpty {
            pump(from: a, to: b)
        } else {
            b.send(initialBytes, isComplete: false) { [weak self] error in
                guard let self else { return }
                if let error { return self.end(error) }
                self.pump(from: a, to: b)
            }
        }
        pump(from: b, to: a)
    }

    /// Ends both streams. `onEnd` is not called for this.
    public func cancel() {
        lock.lock()
        let already = ended
        ended = true
        lock.unlock()
        guard !already else { return }
        close()
    }

    private func pump(from: any ByteStream, to: any ByteStream) {
        from.receive(maximumLength: 256 * 1024) { [weak self] data, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(data, isComplete: false) { [weak self] sendError in
                    guard let self else { return }
                    if let sendError { return self.end(sendError) }
                    if complete || error != nil { return self.end(error) }
                    self.pump(from: from, to: to)
                }
            } else if complete || error != nil {
                self.end(error)
            } else {
                self.pump(from: from, to: to)
            }
        }
    }

    private func end(_ error: Error?) {
        lock.lock()
        let already = ended
        ended = true
        lock.unlock()
        guard !already else { return }
        close()
        onEnd(error)
    }

    private func close() {
        a.onTerminated = nil
        b.onTerminated = nil
        a.cancel()
        b.cancel()
    }
}
