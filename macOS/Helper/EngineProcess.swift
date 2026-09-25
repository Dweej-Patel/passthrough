import Foundation
import HevSocks5Tunnel

/// The tun2socks engine runs in a child process: the helper's own binary,
/// relaunched with `flag`. The engine's own shutdown is unreliable: it waits
/// for a packet on the utun that stops coming once the routes are gone, and
/// lwIP has been seen spinning in it (tcp_fasttmr over a corrupted connection
/// list). A process needs none of it: SIGTERM ends it at once, the kernel
/// closes its sockets and releases the utun, and the helper tidies the rest.
///
/// The child gets the utun on fd 3 and the engine config on stdin (it holds
/// the SOCKS password, so never the command line). It writes a stats line to
/// stdout every second and the engine's own log to stderr; when the helper
/// goes away those writes fail and the child exits.
enum EngineProcess {
    static let flag = "--tun2socks"
    static let tunFD: Int32 = 3

    /// Child side: runs the engine until SIGTERM or the helper goes away.
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in _exit(0) }
        let config = Array(FileHandle.standardInput.readDataToEndOfFile())
        let done = DispatchSemaphore(value: 0)
        let result = Locked(Int32(0))
        // A named thread, so a sample of a stuck engine shows it as "tun2socks".
        let engine = Thread {
            result.set(config.withUnsafeBufferPointer { hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), tunFD) })
            done.signal()
        }
        engine.name = "tun2socks"
        engine.stackSize = 4 << 20
        engine.start()
        Thread.detachNewThread {
            while true {
                sleep(1)
                var tx = 0, txb = 0, rx = 0, rxb = 0
                hev_socks5_tunnel_stats(&tx, &txb, &rx, &rxb)
                let line = Array("stats \(tx) \(txb) \(rx) \(rxb)\n".utf8)
                if write(1, line, line.count) != line.count { _exit(2) }   // the helper is gone
            }
        }
        done.wait()
        exit(result.get() == 0 ? 0 : 1)
    }
}

/// Helper side: one running engine process.
final class EngineChild: @unchecked Sendable {
    struct Stats { var txPackets = 0, txBytes = 0, rxPackets = 0, rxBytes = 0 }

    let pid: pid_t
    private let lock = NSLock()
    private var _alive = true
    private var _stats = Stats()
    private let exited = DispatchSemaphore(value: 0)
    private var exitSource: DispatchSourceProcess?
    private var readers: [DispatchSourceRead] = []

    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return _alive }
    var stats: Stats { lock.lock(); defer { lock.unlock() }; return _stats }

    private init(pid: pid_t) { self.pid = pid }

    /// Starts `executable` (a verified copy of this helper) as the engine on `tunFD`.
    static func spawn(executable: URL, config: String, tunFD: Int32) throws -> EngineChild {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else { throw SpawnError.pipe(errno) }
        defer { [input[0], output[1], errors[1]].forEach { close($0) } }   // the child's ends

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Sources are dup'ed above the targets first, so no dup2 overwrites
        // another's source.
        let sources = [input[0], output[1], errors[1], tunFD].map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
        defer { sources.forEach { close($0) } }
        for (target, source) in sources.enumerated() { posix_spawn_file_actions_adddup2(&actions, source, Int32(target)) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only fds 0-3 reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let argv = [strdup(executable.path), strdup(EngineProcess.flag), nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard status == 0 else {
            [input[1], output[0], errors[0]].forEach { close($0) }
            throw SpawnError.spawn(status)
        }

        let child = EngineChild(pid: pid)
        let bytes = Array(config.utf8)
        _ = bytes.withUnsafeBufferPointer { write(input[1], $0.baseAddress, $0.count) }
        close(input[1])
        child.watch(output: output[0], errors: errors[0])
        return child
    }

    private func watch(output: Int32, errors: Int32) {
        let queue = DispatchQueue(label: "dev.dpatel.passthrough.engine-child")
        readers = [
            lines(from: output, on: queue) { [weak self] line in self?.parseStats(line) },
            lines(from: errors, on: queue) { line in HelperLog.warn("engine: \(line)") },
        ]
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            if waitpid(self.pid, &status, 0) == self.pid { self.markExited(status) }
        }
        source.resume()
        exitSource = source
        // It may have exited before the source was armed, whose event then never comes.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { markExited(status) }
    }

    /// Once, whichever of the exit event and the check above sees it first.
    private func markExited(_ status: Int32) {
        lock.lock(); let wasAlive = _alive; _alive = false; lock.unlock()
        guard wasAlive else { return }
        HelperLog.info("engine exited (status \(status))")
        exitSource?.cancel()
        exited.signal()
    }

    private func lines(from fd: Int32, on queue: DispatchQueue, _ handle: @escaping (String) -> Void) -> DispatchSourceRead {
        var pending = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { source.cancel(); return }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { handle(line) }
            }
            if pending.count > 16384 { pending.removeAll() }   // a runaway line
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func parseStats(_ line: String) {
        let fields = line.split(separator: " ")
        guard fields.count == 5, fields[0] == "stats" else { return }
        let n = fields.dropFirst().map { Int($0) ?? 0 }
        lock.lock(); _stats = Stats(txPackets: n[0], txBytes: n[1], rxPackets: n[2], rxBytes: n[3]); lock.unlock()
    }

    /// True once the process has exited (within `timeout`).
    func waitForExit(timeout: TimeInterval) -> Bool {
        guard isAlive else { return true }
        guard exited.wait(timeout: .now() + timeout) == .success else { return false }
        exited.signal()   // later waits see it too
        return true
    }

    /// Ends the engine (SIGTERM exits it at once); true if it was gone within `timeout`.
    func stop(timeout: TimeInterval) -> Bool {
        guard isAlive else { return true }
        Darwin.kill(pid, SIGTERM)
        return waitForExit(timeout: timeout)
    }

    /// Ends it regardless; the kernel frees its sockets and its utun reference.
    func kill() {
        guard isAlive else { return }
        Darwin.kill(pid, SIGKILL)
        _ = waitForExit(timeout: 2)
    }

    enum SpawnError: LocalizedError {
        case pipe(Int32), spawn(Int32)
        var errorDescription: String? {
            switch self {
            case .pipe(let e): return "Could not create the engine's pipes: \(String(cString: strerror(e)))"
            case .spawn(let e): return "Could not start the engine: \(String(cString: strerror(e)))"
            }
        }
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
