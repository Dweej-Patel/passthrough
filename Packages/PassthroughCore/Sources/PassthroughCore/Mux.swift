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
    static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func readUInt64(_ data: Data) -> UInt64? {
        data.count == 8 ? data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } : nil
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

/// A stream's position, exchanged when a link resumes.
public struct MuxStreamState: Codable, Equatable, Sendable {
    /// Stream ID.
    public var i: UInt32
    /// Bytes received on it so far.
    public var r: UInt64
    /// Whether its end-of-stream arrived.
    public var f: Bool
    public init(i: UInt32, r: UInt64, f: Bool) { self.i = i; self.r = r; self.f = f }
}

/// Carries many byte streams over one ordered, reliable connection. The Mac
/// opens streams (to the phone's SOCKS or control port); the phone accepts
/// them. Per-stream credit keeps one busy stream from flooding memory, and
/// pings every 10 s drop a connection that went quiet for 30 s.
///
/// A resumable mux survives its connection: when the transport fails the
/// streams wait (up to `suspendTimeout`), and `resume(on:peerStreams:)` on a
/// new transport carries on where it left off. Each stream keeps what it sent
/// but the peer hasn't consumed (at most one window), and after resuming
/// sends exactly the part the peer never received. All state lives on `queue`.
public final class Mux: @unchecked Sendable {
    public static let initialWindow = 256 * 1024
    static let windowUpdate = 64 * 1024
    public static var pingInterval: TimeInterval = 10
    public static var deadAfter: TimeInterval = 30
    /// How long a resumable mux holds its streams for the transport to come
    /// back. A locked iPhone's peer-to-peer Wi-Fi can vanish for 45 s or more.
    public static var suspendTimeout: TimeInterval = 120

    public let queue: DispatchQueue
    /// Identifies this mux across reconnects.
    public let sessionID: String
    /// Phone side: a stream the Mac opened to `port`, on `queue`.
    public var onOpen: ((UInt16, MuxStream) -> Void)?
    /// A resumable mux lost its transport and is waiting to resume, on `queue`.
    public var onSuspend: ((Error) -> Void)?
    /// Fires once, on `queue`, when the mux ends for good.
    public var onClose: ((Error?) -> Void)?

    private var transport: ByteStream?
    private let isOpener: Bool
    private let resumable: Bool
    private var streams: [UInt32: MuxStream] = [:]
    private var nextID: UInt32 = 1
    private var buffer = Data()
    private var closed = false
    private var epoch = 0
    private var lastHeard = Date()
    private var timer: DispatchSourceTimer?
    private var expiry: DispatchWorkItem?
    private let closedLock = NSLock()
    private var _isClosed = false
    /// True once the mux ended for good (safe from any thread).
    public var isClosed: Bool { closedLock.lock(); defer { closedLock.unlock() }; return _isClosed }

    /// `isOpener` is true on the Mac, false on the phone. `initialBytes` are
    /// frame bytes already read off the transport during the handshake.
    public init(transport: ByteStream, isOpener: Bool, queue: DispatchQueue, initialBytes: Data = Data(),
                sessionID: String = UUID().uuidString, resumable: Bool = false) {
        self.transport = transport
        self.isOpener = isOpener
        self.queue = queue
        self.buffer = initialBytes
        self.sessionID = sessionID
        self.resumable = resumable
    }

    public func start() {
        queue.async { [self] in attach(transport!, initialBytes: buffer) }
    }

    /// Mac side: a new stream to `port` on the phone, usable at once.
    public func open(port: UInt16) -> MuxStream {
        let stream = MuxStream(mux: self)
        queue.async { [self] in
            guard !closed else { stream.terminate(MuxError.linkClosed); return }
            stream.id = nextID
            stream.port = port
            nextID &+= 2
            streams[stream.id] = stream
            write(stream.openFrame)
            stream.linked()
        }
        return stream
    }

    public func close(_ error: Error? = nil) {
        queue.async { [self] in close(error ?? MuxError.linkClosed) }
    }

    /// Where every stream stands, for the resume handshake.
    public func streamStates(_ completion: @escaping @Sendable ([MuxStreamState]) -> Void) {
        queue.async { [self] in completion(streams.values.map(\.state)) }
    }

    /// Continues on a new transport. `peerStreams` is what the other side
    /// holds; streams it lost are reset, and whatever it missed is resent.
    public func resume(on transport: ByteStream, peerStreams: [MuxStreamState], initialBytes: Data = Data()) {
        queue.async { [self] in
            guard !closed else { transport.cancel(); return }
            expiry?.cancel(); expiry = nil
            detachTransport()
            buffer = Data()
            let peer = Dictionary(peerStreams.map { ($0.i, $0) }, uniquingKeysWith: { a, _ in a })
            self.transport = transport
            for stream in Array(streams.values).sorted(by: { $0.id < $1.id }) {
                if let state = peer[stream.id] {
                    stream.resume(peer: state)
                } else if isOpener, stream.id % 2 == 1, !stream.peerSawOpen {
                    // The phone never got our OPEN: open again and send it all.
                    write(stream.openFrame)
                    stream.resume(peer: MuxStreamState(i: stream.id, r: 0, f: false))
                } else {
                    streams[stream.id] = nil
                    stream.terminate(MuxError.reset)
                }
            }
            // Streams the phone still has but the Mac dropped. Only the opener
            // knows: on the phone an unknown ID may be one the Mac opened during
            // the outage, whose OPEN is on its way.
            if isOpener { for id in peer.keys where streams[id] == nil { write(MuxFrame(.reset, stream: id)) } }
            ptLog(.info, "wireless: link resumed with \(streams.count) stream(s)")
            attach(transport, initialBytes: initialBytes)
        }
    }

    /// Tests: behave as if the connection just failed.
    func interruptForTesting() { queue.async { [self] in lost(MuxError.linkClosed, epoch: epoch) } }

    /// Streams currently open; on `queue`.
    public var streamCount: Int { streams.count }

    // MARK: Internals (on queue)

    private func attach(_ transport: ByteStream, initialBytes: Data) {
        epoch += 1
        let current = epoch
        transport.onTerminated = { [weak self] error in self?.queue.async { self?.lost(error ?? MuxError.linkClosed, epoch: current) } }
        lastHeard = Date()
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.keepalive() }
        timer.resume()
        self.timer = timer
        buffer = initialBytes
        if !buffer.isEmpty {
            do { for frame in try MuxFrame.parse(&buffer) { handle(frame); if closed { return } } } catch { lost(error, epoch: current); return }
        }
        read(epoch: current)
    }

    private func detachTransport() {
        timer?.cancel(); timer = nil
        transport?.onTerminated = nil
        transport?.cancel()
        transport = nil
    }

    /// The transport failed: wait for a resume if we can, else end.
    private func lost(_ error: Error, epoch lostEpoch: Int) {
        guard !closed, lostEpoch == epoch else { return }
        guard resumable else { close(error); return }
        detachTransport()
        guard expiry == nil else { return }
        ptLog(.info, "wireless: link interrupted (\(error.localizedDescription)); holding \(streams.count) stream(s)")
        let expiry = DispatchWorkItem { [weak self] in self?.close(MuxError.timeout) }
        queue.asyncAfter(deadline: .now() + Self.suspendTimeout, execute: expiry)
        self.expiry = expiry
        onSuspend?(error)
    }

    fileprivate func write(_ frame: MuxFrame) {
        guard !closed, let transport else { return }   // while suspended, resume() resends what matters
        let current = epoch
        transport.send(frame.encoded, isComplete: false) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async { self.lost(error, epoch: current) }
        }
    }

    fileprivate func remove(_ id: UInt32) { streams[id] = nil }

    private func close(_ error: Error) {
        guard !closed else { return }
        closed = true
        closedLock.lock(); _isClosed = true; closedLock.unlock()
        expiry?.cancel(); expiry = nil
        detachTransport()
        let open = streams.values
        streams.removeAll()
        open.forEach { $0.terminate(error) }
        onClose?(error)
    }

    private func keepalive() {
        guard !closed, transport != nil else { return }
        if Date().timeIntervalSince(lastHeard) > Self.deadAfter { lost(MuxError.timeout, epoch: epoch); return }
        write(MuxFrame(.ping, stream: 0, payload: MuxFrame.uint64(UInt64(Date().timeIntervalSince1970))))
    }

    private func read(epoch current: Int) {
        guard let transport else { return }
        transport.receive(maximumLength: 256 * 1024) { [weak self] data, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed, current == self.epoch else { return }
                if let data {
                    self.buffer.append(data)
                    do {
                        for frame in try MuxFrame.parse(&self.buffer) { self.handle(frame); if self.closed || current != self.epoch { return } }
                    } catch { self.lost(error, epoch: current); return }
                }
                if let error { self.lost(error, epoch: current); return }
                if isComplete { self.lost(MuxError.linkClosed, epoch: current); return }
                self.read(epoch: current)
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
            guard !isOpener, frame.payload.count == 2 else {
                close(MuxError.protocolViolation("unexpected OPEN")); return
            }
            if streams[frame.stream] != nil { return }   // a resent OPEN we already had
            let port = UInt16(frame.payload[frame.payload.startIndex]) << 8 | UInt16(frame.payload[frame.payload.startIndex + 1])
            let stream = MuxStream(mux: self)
            stream.id = frame.stream
            stream.port = port
            streams[frame.stream] = stream
            stream.linked()
            if let onOpen { onOpen(port, stream) } else { stream.cancel() }
        case .data, .fin, .reset, .window:
            guard let stream = streams[frame.stream] else {
                // Late frames for a stream we already dropped.
                if frame.kind != .reset { write(MuxFrame(.reset, stream: frame.stream)) }
                return
            }
            stream.peerSawOpen = true
            stream.handle(frame)
        }
    }
}

/// One stream of a `Mux`, as a `ByteStream`.
public final class MuxStream: ByteStream, @unchecked Sendable {
    private let mux: Mux
    fileprivate var id: UInt32 = 0
    fileprivate var port: UInt16 = 0
    /// The peer has shown it knows this stream (sent anything on it).
    fileprivate var peerSawOpen = false
    private var registered = false
    private var queuedBeforeLink: [() -> Void] = []

    // Receiving
    private var received = Data()
    private var receivedTotal: UInt64 = 0
    private var consumed: UInt64 = 0
    private var advertised: UInt64 = 0
    private var remoteFinished = false
    private var pendingReceive: (max: Int, completion: @Sendable (Data?, Bool, Error?) -> Void)?

    // Sending. Credit comes from what the peer consumed; `unconfirmed` keeps
    // bytes [unconfirmedStart, sent) until the peer has them, for resending.
    private var sent: UInt64 = 0
    private var peerConsumed: UInt64 = 0
    private var unconfirmedStart: UInt64 = 0
    private var unconfirmed = Data()
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

    private func onQueue(_ work: @escaping () -> Void) {
        mux.queue.async { [self] in registered ? work() : queuedBeforeLink.append(work) }
    }

    fileprivate func linked() {
        registered = true
        let pending = queuedBeforeLink
        queuedBeforeLink = []
        pending.forEach { $0() }
    }

    fileprivate var openFrame: MuxFrame {
        MuxFrame(.open, stream: id, payload: withUnsafeBytes(of: port.bigEndian) { Data($0) })
    }

    fileprivate var state: MuxStreamState { MuxStreamState(i: id, r: receivedTotal, f: remoteFinished) }

    /// After a reconnect: forget what the peer has, resend the rest, and
    /// repeat our credit and end-of-stream in case those were lost.
    fileprivate func resume(peer: MuxStreamState) {
        confirm(upTo: peer.r)
        var offset = 0
        while offset < unconfirmed.count {
            let n = min(MuxFrame.maxPayload, unconfirmed.count - offset)
            mux.write(MuxFrame(.data, stream: id, payload: unconfirmed.subdata(in: unconfirmed.startIndex + offset ..< unconfirmed.startIndex + offset + n)))
            offset += n
        }
        if localFinished, !peer.f { mux.write(MuxFrame(.fin, stream: id)) }
        if !remoteFinished { mux.write(MuxFrame(.window, stream: id, payload: MuxFrame.uint64(consumed))) }
        advertised = consumed
        flush()
    }

    fileprivate func handle(_ frame: MuxFrame) {
        switch frame.kind {
        case .data:
            received.append(frame.payload)
            receivedTotal += UInt64(frame.payload.count)
            if received.count > Mux.initialWindow { mux.close(MuxError.protocolViolation("stream over its window")); return }
            deliver()
        case .fin:
            remoteFinished = true
            deliver()
        case .reset:
            mux.remove(id)
            terminate(MuxError.reset)
        case .window:
            guard let total = MuxFrame.readUInt64(frame.payload) else { mux.close(MuxError.badFrame); return }
            peerConsumed = max(peerConsumed, total)
            confirm(upTo: total)
            flush()
        default:
            break
        }
    }

    /// The peer holds everything before `offset`: stop keeping it.
    private func confirm(upTo offset: UInt64) {
        guard offset > unconfirmedStart else { return }
        let n = Int(min(offset - unconfirmedStart, UInt64(unconfirmed.count)))
        unconfirmed.removeFirst(n)
        unconfirmedStart += UInt64(n)
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
            consumed += UInt64(n)
            if consumed - advertised >= UInt64(Mux.windowUpdate), !remoteFinished {
                mux.write(MuxFrame(.window, stream: id, payload: MuxFrame.uint64(consumed)))
                advertised = consumed
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
                let credit = Int(peerConsumed + UInt64(Mux.initialWindow) - sent)
                let n = min(credit, item.data.count, MuxFrame.maxPayload)
                guard n > 0 else { sendQueue[0] = item; return }
                let chunk = item.data.prefix(n)
                mux.write(MuxFrame(.data, stream: id, payload: Data(chunk)))
                unconfirmed.append(chunk)
                sent += UInt64(n)
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
