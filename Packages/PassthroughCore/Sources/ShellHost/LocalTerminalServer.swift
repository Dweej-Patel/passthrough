#if os(macOS)
import Darwin
import Foundation
import PassthroughCore

/// Lets terminal windows on this Mac be sessions: a Unix socket the
/// `passthrough-term` tool connects to from inside a terminal. The shell then
/// runs in a session of the manager's, the window shows it, and a phone can
/// attach to it at the same time (`LocalTerminalWire`).
///
/// Only this user's processes get in: the socket is `0600` in the user's own
/// folder, and every connection's user is checked. Such a process can already
/// start any shell as the user, so the socket gives it nothing new.
public final class LocalTerminalServer: @unchecked Sendable {
    public let path: String
    private let manager: ShellSessionManager
    private let label: String
    private let admit: @Sendable (LocalTerminalWire.Mode) -> Bool
    private let queue = DispatchQueue(label: "passthrough.terminals.accept")
    private var listening: Int32 = -1          // queue-confined
    private var source: DispatchSourceRead?    // queue-confined
    private var connections: [ObjectIdentifier: LocalTerminalConnection] = [:]   // queue-confined

    /// `admit` says whether a request is taken right now; it is asked for
    /// every `hello`, on a private queue. `label` names the Mac in the history.
    public init(path: String, manager: ShellSessionManager, label: String = "This Mac",
                admit: @escaping @Sendable (LocalTerminalWire.Mode) -> Bool = { _ in true }) {
        self.path = path
        self.manager = manager
        self.label = label
        self.admit = admit
    }

    deinit {
        // Not `stop()`: the last reference can go on the server's own queue,
        // where waiting on that queue would never return. Nothing else holds
        // the server now, so its state is this thread's.
        source?.cancel()
        if listening >= 0 { unlink(path) }
        connections.values.forEach { $0.close() }
    }

    public enum ServerError: LocalizedError {
        case pathTooLong, socket(Int32), bind(Int32), listen(Int32)
        public var errorDescription: String? {
            switch self {
            case .pathTooLong: return "The terminals socket's path is too long."
            case .socket(let e), .bind(let e), .listen(let e): return String(cString: strerror(e))
            }
        }
    }

    /// The socket's address, or nil when `path` does not fit in one.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Whether a socket at `path` can be bound (its address has room for it).
    public static func fits(_ path: String) -> Bool { address(path) != nil }

    public func start() throws {
        try queue.sync {
            guard listening < 0 else { return }
            guard var address = Self.address(path) else { throw ServerError.pathTooLong }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ServerError.socket(errno) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // One left behind by an app that did not get to remove it.
            unlink(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { let error = errno; close(fd); throw ServerError.bind(error) }
            chmod(path, 0o600)
            guard listen(fd, 16) == 0 else { let error = errno; close(fd); unlink(path); throw ServerError.listen(error) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            listening = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
    }

    /// Stops listening and closes every terminal's connection. A session a
    /// terminal started ends with its connection, as when its window closes.
    public func stop() {
        let open: [LocalTerminalConnection] = queue.sync {
            guard listening >= 0 else { return [] }
            listening = -1
            source?.cancel()
            source = nil
            unlink(path)
            let all = Array(connections.values)
            connections = [:]
            return all
        }
        open.forEach { $0.close() }
    }

    private func accept() {
        while listening >= 0 {
            let fd = Darwin.accept(listening, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                ptLog(.warning, "terminals: refused a connection from another user")
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = LocalTerminalConnection(fd: fd, manager: manager, label: label, admit: admit)
            let key = ObjectIdentifier(connection)
            connections[key] = connection
            connection.onClose = { [weak self] in self?.queue.async { self?.connections[key] = nil } }
            connection.start()
        }
    }
}

/// One terminal window's connection. It is a shared viewer of its session
/// (`ShellSessionManager.attach(shared:)`); all its state lives on its queue.
final class LocalTerminalConnection: ShellAttachment, @unchecked Sendable {
    /// Output waiting for the terminal to take it. Past the first the shell
    /// is no longer read, until it falls under the second.
    static let pauseAbove = 1 << 20
    static let resumeBelow = 1 << 18
    static let helloTimeout: TimeInterval = 5

    private let fd: Int32
    private let manager: ShellSessionManager
    private let label: String
    private let admit: @Sendable (LocalTerminalWire.Mode) -> Bool
    private let queue = DispatchQueue(label: "passthrough.terminals.connection")
    private let writes = DispatchQueue(label: "passthrough.terminals.write")
    private let descriptor = Descriptor()
    private var parser = LocalTerminalWire.Parser()
    private var reader: DispatchSourceRead?
    private var session: String?
    /// The session was started for this terminal: it ends when the terminal goes.
    private var owner = false
    private var greeted = false
    private var closed = false
    /// Bytes handed to `writes` and not yet taken by the terminal.
    private let pending = Counter()
    private var paused = false
    var onClose: (() -> Void)?

    init(fd: Int32, manager: ShellSessionManager, label: String, admit: @escaping @Sendable (LocalTerminalWire.Mode) -> Bool) {
        self.fd = fd
        self.manager = manager
        self.label = label
        self.admit = admit
    }

    func start() {
        queue.async { [self] in
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.read() }
            // The only place the descriptor is closed: libdispatch is done with it by then.
            let descriptor = descriptor, fd = fd
            reader.setCancelHandler { descriptor.close(fd) }
            reader.resume()
            self.reader = reader
            queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
                guard let self, !self.greeted else { return }
                self.close()
            }
        }
    }

    func close() {
        queue.async { [self] in closeNow() }
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        manager.detach(client: self)
        if owner, let session { manager.close(session) }
        // Wakes a write that waits on a terminal that stopped reading.
        descriptor.shutdown(fd)
        reader?.cancel()
        reader = nil
        onClose?()
        onClose = nil
    }

    // MARK: Reading

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !closed {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                guard let frames = try? parser.append(Data(buffer[0..<n])) else { return closeNow() }
                frames.forEach(handle)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            return closeNow()   // the terminal went away
        }
    }

    private func handle(_ frame: LocalTerminalWire.Frame) {
        guard !closed else { return }
        switch frame.kind {
        case .hello:
            guard !greeted, let hello = LocalTerminalWire.decode(LocalTerminalWire.Hello.self, from: frame) else { return refuse(LocalTerminalWire.Refused.badRequest) }
            greeted = true
            greet(hello)
        case .input:
            guard let session else { return }
            manager.input(session, frame.payload, from: self)
        case .resize:
            guard let session, let size = LocalTerminalWire.decodeResize(frame.payload) else { return }
            manager.resize(session, cols: size.cols, rows: size.rows, from: self)
        default:
            break   // the app's own kinds: nothing a terminal sends
        }
    }

    private func greet(_ hello: LocalTerminalWire.Hello) {
        guard admit(hello.mode) else { return refuse(LocalTerminalWire.Refused.notSharing) }
        switch hello.mode {
        case .list:
            send(LocalTerminalWire.encode(.sessions, json: manager.sessions))
            finish()
        case .attach:
            guard let id = hello.session else { return refuse(LocalTerminalWire.Refused.badRequest) }
            // By its id, or the first few characters of it (what `list` shows).
            let matches = manager.sessions.filter { $0.running && ($0.id == id || (id.count >= 4 && $0.id.lowercased().hasPrefix(id.lowercased()))) }
            guard matches.count == 1 else { return refuse(LocalTerminalWire.Refused.noSuchSession) }
            show(matches[0].id, hello)
        case .hook, .new:
            do {
                let directory = hello.directory.flatMap { path -> URL? in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                        ? URL(fileURLWithPath: path, isDirectory: true) : nil
                }
                let id = try manager.open(phoneLabel: label, cols: hello.cols, rows: hello.rows, origin: .mac,
                                          environment: hello.environment, directory: directory)
                owner = true
                show(id, hello)
            } catch let error as ShellError {
                refuse(error.rawValue)
            } catch {
                ptLog(.error, "terminals: could not start a shell: \(error.localizedDescription)")
                refuse(LocalTerminalWire.Refused.badRequest)
            }
        }
    }

    private func show(_ id: String, _ hello: LocalTerminalWire.Hello) {
        session = id
        send(LocalTerminalWire.encode(.started, json: LocalTerminalWire.Started(session: id)))
        do {
            try manager.attach(id, client: self, cols: hello.cols, rows: hello.rows, shared: true)
        } catch {
            session = nil
            refuse(LocalTerminalWire.Refused.noSuchSession)
        }
    }

    private func refuse(_ reason: String) {
        greeted = true
        send(LocalTerminalWire.encode(.refused, json: LocalTerminalWire.Refused(reason: reason)))
        finish()
    }

    // MARK: Writing

    /// Closes once everything queued has been written.
    private func finish() {
        writes.async { [weak self] in self?.close() }
    }

    private func send(_ frame: Data) {
        guard !closed else { return }
        let waiting = pending.add(frame.count)
        if !paused, waiting > Self.pauseAbove, let session {
            paused = true
            manager.setOutputPaused(session, true, by: self)
        }
        writes.async { [self] in
            write(frame)
            let left = pending.add(-frame.count)
            guard left < Self.resumeBelow else { return }
            queue.async { [self] in
                guard paused, pending.value < Self.resumeBelow, let session else { return }
                paused = false
                manager.setOutputPaused(session, false, by: self)
            }
        }
    }

    /// Writes all of `frame`, waiting for as long as the terminal isn't reading.
    private func write(_ frame: Data) {
        var offset = 0
        while offset < frame.count {
            let (n, error) = descriptor.write(fd, frame, from: offset)
            if n > 0 { offset += n; continue }
            guard n < 0, error == EAGAIN || error == EINTR else { return }   // closed, or the terminal is gone
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            poll(&p, 1, 100)
        }
    }

    // MARK: ShellAttachment (on the manager's callouts queue: hand off, never block)

    func shellOutput(_ data: Data, session: String) {
        queue.async { [self] in
            guard session == self.session else { return }
            var offset = 0
            while offset < data.count {
                let end = min(offset + LocalTerminalWire.outputChunk, data.count)
                send(LocalTerminalWire.encode(.output, data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))))
                offset = end
            }
        }
    }

    func shellReplayed(session: String) {
        queue.async { [self] in
            guard session == self.session else { return }
            send(LocalTerminalWire.encode(.replayed))
        }
    }

    func shellEnded(session: String, exitStatus: Int32) {
        queue.async { [self] in
            guard session == self.session else { return }
            self.session = nil
            owner = false
            send(LocalTerminalWire.encode(.ended, json: LocalTerminalWire.Ended(exitStatus: exitStatus)))
            finish()
        }
    }

    /// Viewers are never taken over.
    func shellDetached(session: String, generation: UInt64) {}

    /// The socket, shared with the read source's cancel handler: writes and
    /// the close exclude each other, so a write never lands on a descriptor
    /// number that was closed and handed to another file.
    private final class Descriptor: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false

        func write(_ fd: Int32, _ data: Data, from offset: Int) -> (Int, Int32) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return (-1, EBADF) }
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            return (n, errno)
        }

        func shutdown(_ fd: Int32) {
            lock.lock(); defer { lock.unlock() }
            if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
        }

        func close(_ fd: Int32) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}

/// A count shared between the connection's queue and its write queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add(_ amount: Int) -> Int { lock.lock(); defer { lock.unlock() }; count += amount; return count }
}
#endif
