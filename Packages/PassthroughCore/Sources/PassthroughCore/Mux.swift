import Foundation

/// One frame of the wireless link's multiplexer (see protocol/README.md).
public struct MuxFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case open = 1, data, fin, reset, window, ping, pong }
    public static let maxPayload = 16384
    static let headerSize = 7

    public var kind: Kind
    public var stream: UInt32
    public var payload: Data

    public init(_ kind: Kind, stream: UInt32, payload: Data = Data()) {
        self.kind = kind; self.stream = stream; self.payload = payload
    }

    /// `[type:1][stream:4][length:2][payload]`, big-endian.
    public var encoded: Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(kind.rawValue)
        withUnsafeBytes(of: stream.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Removes and returns every whole frame at the front of `buffer`.
    public static func parse(_ buffer: inout Data) throws -> [MuxFrame] {
        var frames: [MuxFrame] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= headerSize {
            let type = buffer[offset]
            let stream = buffer[offset + 1 ..< offset + 5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = Int(buffer[offset + 5]) << 8 | Int(buffer[offset + 6])
            guard let kind = Kind(rawValue: type), length <= maxPayload else { throw MuxError.badFrame }
            guard buffer.endIndex - offset >= headerSize + length else { break }
            let start = offset + headerSize
            frames.append(MuxFrame(kind, stream: stream, payload: Data(buffer[start ..< start + length])))
            offset = start + length
        }
        buffer.removeSubrange(buffer.startIndex ..< offset)
        return frames
    }

    static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func readUInt32(_ data: Data) -> UInt32? {
        data.count == 4 ? data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : nil
    }
}

public enum MuxError: LocalizedError, Equatable {
    case badFrame, reset, linkClosed, timeout, protocolViolation(String)
    public var errorDescription: String? {
        switch self {
        case .badFrame: return "Malformed frame on the wireless link"
        case .reset: return "The phone closed the stream"
        case .linkClosed: return "The wireless link closed"
        case .timeout: return "The wireless link stopped responding"
        case .protocolViolation(let why): return "Wireless link protocol error: \(why)"
        }
    }
}

/// Carries many byte streams over one ordered, reliable connection. The Mac
/// opens streams (to the phone's SOCKS or control port); the phone accepts
/// them. Per-stream credit keeps one busy stream from flooding memory, and
/// pings every 10 s drop a connection that went quiet for 30 s. All state
/// lives on `queue`.
public final class Mux: @unchecked Sendable {
    public static let initialWindow = 256 * 1024
    static let windowUpdate = 64 * 1024
    public static var pingInterval: TimeInterval = 10
    public static var deadAfter: TimeInterval = 30

    public let queue: DispatchQueue
    /// Phone side: a stream the Mac opened to `port`, on `queue`.
    public var onOpen: ((UInt16, MuxStream) -> Void)?
    /// Fires once, on `queue`, when the link ends.
    public var onClose: ((Error?) -> Void)?

    private let transport: ByteStream
    private let isOpener: Bool
    private var streams: [UInt32: MuxStream] = [:]
    private var nextID: UInt32 = 1
    private var buffer = Data()
    private var closed = false
    private var lastHeard = Date()
    private var timer: DispatchSourceTimer?

    /// `isOpener` is true on the Mac, false on the phone. `initialBytes` are
    /// frame bytes already read off the transport during the handshake.
    public init(transport: ByteStream, isOpener: Bool, queue: DispatchQueue, initialBytes: Data = Data()) {
        self.transport = transport
        self.isOpener = isOpener
        self.queue = queue
        self.buffer = initialBytes
    }

    public func start() {
        transport.onTerminated = { [weak self] error in self?.queue.async { self?.close(error ?? MuxError.linkClosed) } }
        queue.async { [self] in
            lastHeard = Date()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
            timer.setEventHandler { [weak self] in self?.keepalive() }
            timer.resume()
            self.timer = timer
            if !buffer.isEmpty {
                do { for frame in try MuxFrame.parse(&buffer) { handle(frame); if closed { return } } } catch { close(error); return }
            }
            read()
        }
    }

    /// Mac side: a new stream to `port` on the phone, usable at once.
    public func open(port: UInt16) -> MuxStream {
        let stream = MuxStream(mux: self)
        queue.async { [self] in
            guard !closed else { stream.terminate(MuxError.linkClosed); return }
            stream.id = nextID
            nextID &+= 2
            streams[stream.id] = stream
            write(MuxFrame(.open, stream: stream.id, payload: withUnsafeBytes(of: port.bigEndian) { Data($0) }))
            stream.linked()
        }
        return stream
    }

    public func close(_ error: Error? = nil) {
        queue.async { [self] in close(error ?? MuxError.linkClosed) }
    }

    /// Streams currently open; on `queue`.
    public var streamCount: Int { streams.count }

    // MARK: Internals (on queue)

    fileprivate func write(_ frame: MuxFrame) {
        guard !closed else { return }
        transport.send(frame.encoded, isComplete: false) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async { self.close(error) }
        }
    }

    fileprivate func remove(_ id: UInt32) { streams[id] = nil }

    private func close(_ error: Error) {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        transport.onTerminated = nil
        transport.cancel()
        let open = streams.values
        streams.removeAll()
        open.forEach { $0.terminate(error) }
        onClose?(error)
    }

    private func keepalive() {
        guard !closed else { return }
        if Date().timeIntervalSince(lastHeard) > Self.deadAfter { close(MuxError.timeout); return }
        write(MuxFrame(.ping, stream: 0, payload: MuxFrame.uint32(UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))) + Data(count: 4)))
    }

    private func read() {
        transport.receive(maximumLength: 256 * 1024) { [weak self] data, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data {
                    self.buffer.append(data)
                    do {
                        for frame in try MuxFrame.parse(&self.buffer) { self.handle(frame); if self.closed { return } }
                    } catch { self.close(error); return }
                }
                if let error { self.close(error); return }
                if isComplete { self.close(MuxError.linkClosed); return }
                self.read()
            }
        }
    }

    private func handle(_ frame: MuxFrame) {
        lastHeard = Date()
        switch frame.kind {
        case .ping:
            write(MuxFrame(.pong, stream: 0, payload: frame.payload))
        case .pong:
            break
        case .open:
            guard !isOpener, frame.payload.count == 2, streams[frame.stream] == nil else {
                close(MuxError.protocolViolation("unexpected OPEN")); return
            }
            let port = UInt16(frame.payload[frame.payload.startIndex]) << 8 | UInt16(frame.payload[frame.payload.startIndex + 1])
            let stream = MuxStream(mux: self)
            stream.id = frame.stream
            streams[frame.stream] = stream
            stream.linked()
            if let onOpen { onOpen(port, stream) } else { stream.cancel() }
        case .data, .fin, .reset, .window:
            guard let stream = streams[frame.stream] else {
                // Late frames for a stream we already dropped.
                if frame.kind != .reset { write(MuxFrame(.reset, stream: frame.stream)) }
                return
            }
            stream.handle(frame)
        }
    }
}

/// One stream of a `Mux`, as a `ByteStream`.
public final class MuxStream: ByteStream, @unchecked Sendable {
    private let mux: Mux
    fileprivate var id: UInt32 = 0
    private var registered = false
    private var queuedBeforeLink: [() -> Void] = []

    private var received = Data()
    private var remoteFinished = false
    private var consumedSinceUpdate = 0
    private var pendingReceive: (max: Int, completion: @Sendable (Data?, Bool, Error?) -> Void)?

    private var credit = Mux.initialWindow
    private var sendQueue: [(data: Data, isComplete: Bool, completion: @Sendable (Error?) -> Void)] = []
    private var localFinished = false

    private var failure: Error?
    private var cancelled = false
    private let handlerLock = NSLock()
    private var _onTerminated: (@Sendable (Error?) -> Void)?

    fileprivate init(mux: Mux) { self.mux = mux }

    public var onTerminated: (@Sendable (Error?) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return _onTerminated }
        set { handlerLock.lock(); _onTerminated = newValue; handlerLock.unlock() }
    }

    public func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        onQueue { [self] in
            pendingReceive = (maximumLength, completion)
            deliver()
        }
    }

    public func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        onQueue { [self] in
            if let failure { completion(failure); return }
            if cancelled || localFinished { completion(MuxError.linkClosed); return }
            sendQueue.append((data ?? Data(), isComplete, completion))
            flush()
        }
    }

    public func cancel() {
        onQueue { [self] in
            guard !cancelled else { return }
            cancelled = true
            if failure == nil, !(localFinished && remoteFinished) { mux.write(MuxFrame(.reset, stream: id)) }
            mux.remove(id)
            fail(MuxError.linkClosed, notify: false)
        }
    }

    // MARK: On the mux queue

    /// Operations issued before the stream got its ID run once it has one.
    private func onQueue(_ work: @escaping () -> Void) {
        mux.queue.async { [self] in registered ? work() : queuedBeforeLink.append(work) }
    }

    fileprivate func linked() {
        registered = true
        let pending = queuedBeforeLink
        queuedBeforeLink = []
        pending.forEach { $0() }
    }

    fileprivate func handle(_ frame: MuxFrame) {
        switch frame.kind {
        case .data:
            received.append(frame.payload)
            if received.count > Mux.initialWindow { mux.close(MuxError.protocolViolation("stream over its window")); return }
            deliver()
        case .fin:
            remoteFinished = true
            deliver()
        case .reset:
            mux.remove(id)
            terminate(MuxError.reset)
        case .window:
            guard let more = MuxFrame.readUInt32(frame.payload) else { mux.close(MuxError.badFrame); return }
            credit += Int(more)
            flush()
        default:
            break
        }
    }

    fileprivate func terminate(_ error: Error) {
        guard failure == nil, !cancelled else { return }
        fail(error, notify: true)
    }

    private func fail(_ error: Error, notify: Bool) {
        if failure == nil { failure = error }
        if let pending = pendingReceive {
            pendingReceive = nil
            pending.completion(nil, true, cancelled ? nil : error)
        }
        let sends = sendQueue
        sendQueue = []
        sends.forEach { $0.completion(error) }
        if notify { let handler = onTerminated; onTerminated = nil; handler?(error) }
    }

    private func deliver() {
        guard let pending = pendingReceive else { return }
        if !received.isEmpty {
            let n = min(pending.max, received.count)
            let chunk = received.prefix(n)
            received.removeFirst(n)
            consumedSinceUpdate += n
            if consumedSinceUpdate >= Mux.windowUpdate, !remoteFinished {
                mux.write(MuxFrame(.window, stream: id, payload: MuxFrame.uint32(UInt32(consumedSinceUpdate))))
                consumedSinceUpdate = 0
            }
            pendingReceive = nil
            pending.completion(Data(chunk), false, nil)
        } else if remoteFinished {
            pendingReceive = nil
            pending.completion(nil, true, nil)
        } else if let failure {
            pendingReceive = nil
            pending.completion(nil, true, failure)
        }
    }

    private func flush() {
        while var item = sendQueue.first, failure == nil {
            while !item.data.isEmpty {
                let n = min(credit, item.data.count, MuxFrame.maxPayload)
                guard n > 0 else { sendQueue[0] = item; return }
                mux.write(MuxFrame(.data, stream: id, payload: item.data.prefix(n)))
                credit -= n
                item.data.removeFirst(n)
            }
            sendQueue.removeFirst()
            if item.isComplete {
                localFinished = true
                mux.write(MuxFrame(.fin, stream: id))
            }
            item.completion(nil)
        }
    }
}
