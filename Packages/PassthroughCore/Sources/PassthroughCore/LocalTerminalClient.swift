#if os(macOS)
import Darwin
import Foundation

/// The terminal's side of `LocalTerminalWire`: what `passthrough-term` runs
/// inside a terminal window. It puts the window's terminal in raw mode and
/// carries bytes between it and a session in the Passthrough app, so the
/// window shows that session and so can a phone.
public enum LocalTerminalClient {
    public struct Options: Sendable {
        public var socketPath: String
        public var mode: LocalTerminalWire.Mode
        /// The session to show (`attach`).
        public var session: String?
        /// The terminal: where keys are read and output is written.
        public var input: Int32
        public var output: Int32
        public var environment: [String: String]
        public var directory: String
        /// How long the app has to answer before the terminal carries on without it.
        public var answerTimeout: TimeInterval
        /// How long the terminal has to say what its colours are, for a new
        /// session; 0 does not ask.
        public var coloursTimeout: TimeInterval

        public init(socketPath: String, mode: LocalTerminalWire.Mode, session: String? = nil,
                    input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    directory: String = FileManager.default.currentDirectoryPath,
                    answerTimeout: TimeInterval = 2, coloursTimeout: TimeInterval = 0) {
            self.socketPath = socketPath; self.mode = mode; self.session = session
            self.input = input; self.output = output
            self.environment = environment; self.directory = directory; self.answerTimeout = answerTimeout
            self.coloursTimeout = coloursTimeout
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The session's shell exited with this status.
        case ended(Int32)
        /// The window stopped showing a session that carries on (`attach`, on ctrl-\ twice or the window's end of input).
        case detached
        /// No session: the app isn't running, isn't sharing terminals, or said no (the reason).
        case unavailable(String)
        /// The app went away while the session was shown. The session is gone with it.
        case lost
        case listed([ShellSessionInfo])
    }

    /// Reasons for `unavailable` that the app did not give.
    public static let notRunning = "not_running"
    public static let noAnswer = "no_answer"

    /// How long keys are dropped after a running session's earlier output has
    /// been drawn: the terminal answers the questions programs asked in it
    /// (its colours, the cursor's place), and those answers are not keys.
    static let settleAfterReplay: TimeInterval = 0.3

    /// Leaves the alternate screen, mouse reporting and bracketed paste and
    /// shows the cursor: what a program in a session that is no longer shown
    /// may have left on.
    static let restoreTerminal = Data("\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?25h\u{1B}[0m\r\n".utf8)

    public static func run(_ options: Options) -> Outcome {
        guard let socket = connect(options.socketPath) else { return .unavailable(notRunning) }
        defer { close(socket) }

        let starts = options.mode == .hook || options.mode == .new
        var size = windowSize(options.output)
        let hello = LocalTerminalWire.Hello(
            mode: options.mode, session: options.session, cols: size.cols, rows: size.rows,
            directory: starts ? options.directory : nil, environment: starts ? options.environment : nil)
        // The hello and its answer share one deadline: an app that accepts
        // and then neither reads nor answers must not hold the terminal.
        let deadline = Date().addingTimeInterval(options.answerTimeout)
        guard writeAll(socket, LocalTerminalWire.encode(.hello, json: hello), until: deadline) else { return .unavailable(noAnswer) }

        var parser = LocalTerminalWire.Parser()
        var waitingFrames: [LocalTerminalWire.Frame] = []
        // The answer: `started`, `refused` or `sessions`.
        answer: while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return .unavailable(noAnswer) }
            var p = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(max(1, left * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, let frames = readFrames(socket, &parser) else { return .unavailable(noAnswer) }
            for (index, frame) in frames.enumerated() {
                switch frame.kind {
                case .started:
                    waitingFrames = Array(frames[(index + 1)...])
                    break answer
                case .refused:
                    return .unavailable(LocalTerminalWire.decode(LocalTerminalWire.Refused.self, from: frame)?.reason ?? LocalTerminalWire.Refused.badRequest)
                case .sessions:
                    return .listed(LocalTerminalWire.decode([ShellSessionInfo].self, from: frame) ?? [])
                default:
                    continue
                }
            }
        }

        // Nothing is read from the terminal until here: a window that is not
        // to be a session keeps every key typed into it, for its own shell.
        // Raw: every key goes to the session's own terminal, which does the echo and the signals.
        var saved = termios()
        let isTerminal = tcgetattr(options.input, &saved) == 0
        if isTerminal {
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(options.input, TCSANOW, &raw)
        }
        defer { if isTerminal { tcsetattr(options.input, TCSANOW, &saved) } }

        // The window's colours, for the session it started; what was typed meanwhile goes to the shell.
        if starts, isTerminal {
            let asked = TerminalColors.ask(input: options.input, output: options.output, timeout: options.coloursTimeout)
            if let theme = asked.theme, !writeAll(socket, LocalTerminalWire.encode(.theme, json: theme)) { return lost(options) }
            if !asked.typed.isEmpty, !writeAll(socket, LocalTerminalWire.encode(.input, asked.typed)) { return lost(options) }
        }

        let resized = ResizeWatch()
        defer { resized.stop() }

        /// Keys are dropped until then (see `settleAfterReplay`); only when showing a session already running.
        var ignoreKeysUntil: Date? = options.mode == .attach ? .distantFuture : nil
        var keys = [UInt8](repeating: 0, count: 16_384)
        var lastQuit: Date?

        func handle(_ frames: [LocalTerminalWire.Frame]) -> Outcome? {
            for frame in frames {
                switch frame.kind {
                case .output:
                    guard writeAll(options.output, frame.payload) else { return .detached }   // the window is gone
                case .replayed:
                    if ignoreKeysUntil != nil { ignoreKeysUntil = Date().addingTimeInterval(settleAfterReplay) }
                case .ended:
                    return .ended(LocalTerminalWire.decode(LocalTerminalWire.Ended.self, from: frame)?.exitStatus ?? 0)
                default:
                    continue
                }
            }
            return nil
        }

        if let outcome = handle(waitingFrames) { return outcome }
        while true {
            var fds = [
                pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                pollfd(fd: options.input, events: Int16(POLLIN), revents: 0),
                pollfd(fd: resized.readEnd, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 3, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return .lost
            }
            if fds[2].revents != 0 {
                resized.drain()
                let now = windowSize(options.output)
                if now != size {
                    size = now
                    guard writeAll(socket, LocalTerminalWire.encodeResize(cols: now.cols, rows: now.rows)) else { return lost(options) }
                }
            }
            if fds[0].revents != 0 {
                guard let frames = readFrames(socket, &parser) else { return lost(options) }
                if let outcome = handle(frames) { return outcome }
            }
            if fds[1].revents != 0 {
                let n = read(options.input, &keys, keys.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                // The window closed. A session it started ends with the connection; one it only showed carries on.
                guard n > 0 else { return .detached }
                if let until = ignoreKeysUntil {
                    if Date() < until { continue }
                    ignoreKeysUntil = nil
                }
                // ctrl-\ twice within a second leaves a session this window only shows.
                if options.mode == .attach, n == 1, keys[0] == 0x1C {
                    if let last = lastQuit, Date().timeIntervalSince(last) < 1 {
                        _ = writeAll(options.output, restoreTerminal)
                        return .detached
                    }
                    lastQuit = Date()
                } else {
                    lastQuit = nil
                }
                guard writeAll(socket, LocalTerminalWire.encode(.input, Data(keys[0..<n]))) else { return lost(options) }
            }
        }
    }

    private static func lost(_ options: Options) -> Outcome {
        _ = writeAll(options.output, restoreTerminal)
        return .lost
    }

    // MARK: Plumbing

    public struct WindowSize: Equatable, Sendable {
        public var cols: Int
        public var rows: Int
    }

    static func windowSize(_ fd: Int32) -> WindowSize {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return WindowSize(cols: 80, rows: 24) }
        return WindowSize(cols: Int(size.ws_col), rows: Int(size.ws_row))
    }

    static func connect(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        // Non-blocking, so a write can give up (`writeAll(until:)`).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Writes all of `data`, waiting while the other side isn't reading: for
    /// as long as it takes, or until `deadline`. False once it is gone or the time is up.
    static func writeAll(_ fd: Int32, _ data: Data, until deadline: Date? = nil) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if let deadline, Date() >= deadline { return false }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                poll(&p, 1, 100)
                continue
            }
            return false
        }
        return true
    }

    /// What has arrived, as frames; nil once the app is gone or sent something that isn't one.
    private static func readFrames(_ fd: Int32, _ parser: inout LocalTerminalWire.Parser) -> [LocalTerminalWire.Frame]? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { return try? parser.append(Data(buffer[0..<n])) }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return [] }
            return nil
        }
    }

    /// Wakes the loop when the window changes size (SIGWINCH), through a pipe.
    private final class ResizeWatch {
        let readEnd: Int32
        private let writeEnd: Int32
        private let source: DispatchSourceSignal

        init() {
            var ends: [Int32] = [-1, -1]
            pipe(&ends)
            readEnd = ends[0]
            writeEnd = ends[1]
            for fd in ends {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
            // A dispatch source sees the signal only once its default action (ignore) is in place.
            signal(SIGWINCH, SIG_IGN)
            source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: DispatchQueue(label: "passthrough.terminal.resize"))
            let writeEnd = writeEnd
            source.setEventHandler {
                var byte: UInt8 = 1
                _ = write(writeEnd, &byte, 1)
            }
            source.resume()
        }

        func drain() {
            var buffer = [UInt8](repeating: 0, count: 64)
            while read(readEnd, &buffer, buffer.count) > 0 {}
        }

        func stop() {
            source.cancel()
            close(readEnd)
            close(writeEnd)
        }
    }
}
#endif
