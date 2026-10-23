#if os(macOS)
import CPTY
import Darwin
import Foundation
import PassthroughCore

/// The shell a session starts: the user's login shell, as a login shell, set
/// up as a new Terminal.app window is.
public enum LoginShell {
    public static func command() -> (executable: String, arguments: [String]) {
        (account().shell ?? "/bin/zsh", ["-l"])
    }

    /// What a new Terminal.app window starts from: the account's basics, a
    /// plain PATH (the login profile, via path_helper and the user's own
    /// files, builds the rest) and the terminal type. Nothing else in the
    /// app's environment is passed on, so whatever launched the app (a
    /// script, another Claude Code session…) doesn't reach the shell.
    public static func environment(inheriting inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { passedOn.contains($0.key) }
        let account = account()
        environment["HOME"] = account.home ?? inherited["HOME"] ?? NSHomeDirectory()
        environment["USER"] = account.name ?? inherited["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["USER"]
        environment["SHELL"] = command().executable
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "Passthrough"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    /// The per-login values launchd gives every app, Terminal.app included.
    static let passedOn: Set<String> = ["TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG"]

    private static func account() -> (name: String?, home: String?, shell: String?) {
        guard let entry = getpwuid(getuid()) else { return (nil, nil, nil) }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
            guard let pointer, pointer.pointee != 0 else { return nil }
            return String(cString: pointer)
        }
        return (string(entry.pointee.pw_name), string(entry.pointee.pw_dir), string(entry.pointee.pw_shell))
    }
}

/// A child process on a pseudo-terminal: its own session with the terminal as
/// controlling terminal, so job control and ctrl-C behave as in Terminal.app.
public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    /// Called on a private queue with what the process wrote.
    public var onOutput: (@Sendable (Data) -> Void)?
    /// Called once, after the last output: the exit code, or 128 + the signal that ended it.
    public var onExit: (@Sendable (Int32) -> Void)?

    private let master: Int32
    private let queue = DispatchQueue(label: "passthrough.shell.pty")
    private let writeQueue = DispatchQueue(label: "passthrough.shell.pty.write")
    private let state = MasterState()
    private var exited = false          // queue-confined
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    public init(executable: String, arguments: [String], directory: URL, environment: [String: String],
                cols: UInt16, rows: UInt16) throws {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw SpawnError.pty(errno) }
        defer { close(slave) }   // the child has its own copy

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let pid = pt_spawn_on_pty(executable, argv, envp, slave, directory.path)
        guard pid > 0 else { let error = errno; close(master); throw SpawnError.spawn(error) }

        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.master = master
        self.pid = pid
    }

    deinit {
        // Dropping the object ends the session: hang up, and reap the child
        // without a source that needs us. Once started, the read source's cancel
        // handler (which holds only the fd's state, not self) closes the master.
        readSource?.cancel()
        exitSource?.cancel()
        if readSource == nil { state.close(master) }
        guard !exited else { return }
        let pid = pid
        killpg(pid, SIGHUP)
        // SIGKILL only while the child is unreaped: until then neither its pid
        // nor its process group can be reused by another process.
        DispatchQueue.global().async {
            var status: Int32 = 0
            let deadline = Date() + 2
            while waitpid(pid, &status, WNOHANG) == 0 {
                guard Date() < deadline else { killpg(pid, SIGKILL); waitpid(pid, &status, 0); return }
                usleep(50_000)
            }
        }
    }

    /// Begins delivering output and watching for exit.
    public func start() {
        queue.async { [self] in
            guard readSource == nil else { return }
            let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            reader.setEventHandler { [weak self] in self?.drain() }
            // The fd must stay open until libdispatch is done with it, or the
            // teardown could hit a newer pty that reused the number. This is
            // the only place the master is closed once started (the handler holds
            // no reference to self, so dropping the object can tear down).
            let state = state, fd = master
            reader.setCancelHandler { state.close(fd) }
            reader.resume()
            readSource = reader

            let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            watcher.setEventHandler { [weak self] in self?.reap(blocking: true) }
            watcher.resume()
            exitSource = watcher
            reap(blocking: false)   // it may have exited before the source was armed, whose event then never comes
        }
    }

    /// Writes all of `data` in order, waiting for as long as the shell isn't
    /// reading (as a terminal does); only closing the master ends the wait.
    public func write(_ data: Data) {
        writeQueue.async { [self] in
            var offset = 0
            while offset < data.count {
                state.lock.lock()
                let n = state.closed ? -1 : data.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, data.count - offset) }
                let error = state.closed ? EBADF : errno
                state.lock.unlock()
                if n > 0 { offset += n; continue }
                guard n < 0, error == EAGAIN || error == EINTR else { return }   // closed
                var p = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
                poll(&p, 1, 100)
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        state.lock.lock(); defer { state.lock.unlock() }
        guard !state.closed else { return }
        _ = ioctl(master, TIOCSWINSZ, &size)   // the kernel signals the foreground group with SIGWINCH
    }

    /// Hangs up the shell's session, as closing a terminal window does; a
    /// process that ignores that is killed after two seconds.
    public func terminate() {
        killpg(pid, SIGHUP)
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            if !exited { killpg(pid, SIGKILL) }
        }
    }

    // MARK: Queue-confined

    private func drain() {
        // Cancelling the read source closes the master (in its cancel handler,
        // on this queue), after which the number may belong to another file.
        guard readSource != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n > 0 { onOutput?(Data(buffer[0..<n])); continue }
            if n < 0, errno == EINTR { continue }
            if n == 0 || (n < 0 && errno != EAGAIN) { readSource?.cancel(); readSource = nil }   // the slave side is gone
            return
        }
    }

    /// `blocking` once the exit event has fired: the status is then certain to come.
    private func reap(blocking: Bool) {
        guard !exited else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, blocking ? 0 : WNOHANG) == pid else { return }
        exited = true
        drain()   // whatever it wrote last
        exitSource?.cancel()
        exitSource = nil
        readSource?.cancel()
        readSource = nil
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        ptLog(.info, "shell: pid \(pid) exited (\(code))")
        onExit?(code)
    }

    /// Whether the master fd is still open, shared with the cancel handler.
    private final class MasterState: @unchecked Sendable {
        let lock = NSLock()
        var closed = false
        func close(_ fd: Int32) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    public enum SpawnError: LocalizedError {
        case pty(Int32), spawn(Int32)
        public var errorDescription: String? {
            switch self {
            case .pty(let e): return "Could not open a terminal: \(String(cString: strerror(e)))"
            case .spawn(let e): return "Could not start the shell: \(String(cString: strerror(e)))"
            }
        }
    }
}
#endif
