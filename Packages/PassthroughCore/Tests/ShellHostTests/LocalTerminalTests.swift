#if os(macOS)
import Darwin
import Foundation
@testable import PassthroughCore
import XCTest
@testable import ShellHost

/// A terminal window on the Mac as a session: the app's socket server and the
/// tool's client, with a real shell and a pseudo-terminal standing in for the window.
final class LocalTerminalTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!
    private var manager: ShellSessionManager!
    private var server: LocalTerminalServer!
    private var socketPath: String!
    private let sharing = Locked(true)
    private var windows: [Window] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTerminalTests-\(UUID().uuidString)", isDirectory: true)
        store = try TranscriptStore(directory: directory)
        manager = ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"),
            endedRetention: 600,
            quietBeforeAsking: 0.2)
        // Short: a socket's path has little room.
        socketPath = "/tmp/pt-\(UUID().uuidString.prefix(8)).sock"
        let sharing = sharing
        server = LocalTerminalServer(path: socketPath, manager: manager) { mode in mode != .hook || sharing.get() }
        try server.start()
    }

    override func tearDown() {
        windows.forEach { $0.close() }
        server.stop()
        manager.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A terminal window: a pseudo-terminal whose far side the client reads
    /// keys from and draws on, and whose near side the test types into and reads.
    final class Window: @unchecked Sendable {
        let near: Int32
        let far: Int32
        private let lock = NSLock()
        private var data = Data()
        private var result: LocalTerminalClient.Outcome?
        private let stop = Locked(false)

        init(cols: UInt16 = 80, rows: UInt16 = 24) {
            var near: Int32 = -1, far: Int32 = -1
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            precondition(openpty(&near, &far, nil, nil, &size) == 0)
            self.near = near
            self.far = far
            // The reader owns both ends and closes them itself once told to:
            // closing a pseudo-terminal another thread is reading can hang.
            let stop = stop
            let thread = Thread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while !stop.get() {
                    var p = pollfd(fd: near, events: Int16(POLLIN), revents: 0)
                    guard poll(&p, 1, 20) > 0 else { continue }
                    let n = read(near, &buffer, buffer.count)
                    guard n > 0, let self else { break }
                    self.lock.lock(); self.data.append(contentsOf: buffer[0..<n]); self.lock.unlock()
                }
                Darwin.close(near)
                Darwin.close(far)
            }
            thread.start()
        }

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var bytes: Int { lock.lock(); defer { lock.unlock() }; return data.count }
        var outcome: LocalTerminalClient.Outcome? { lock.lock(); defer { lock.unlock() }; return result }

        func type(_ text: String) {
            let data = Data(text.utf8)
            _ = data.withUnsafeBytes { write(near, $0.baseAddress, data.count) }
        }

        func resize(cols: UInt16, rows: UInt16) {
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(near, TIOCSWINSZ, &size)
            // The kernel signals the terminal's own foreground group; the client here is this process.
            kill(getpid(), SIGWINCH)
        }

        /// Runs the client as the tool would in this window.
        func run(_ socket: String, _ mode: LocalTerminalWire.Mode, session: String? = nil,
                 environment: [String: String] = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "],
                 directory: String = "/tmp") {
            let far = far
            Thread { [weak self] in
                let outcome = LocalTerminalClient.run(.init(socketPath: socket, mode: mode, session: session, input: far, output: far,
                                                            environment: environment, directory: directory))
                guard let self else { return }
                self.lock.lock(); self.result = outcome; self.lock.unlock()
            }.start()
        }

        /// The window closes: the client's terminal is gone.
        func close() { stop.set(true) }
    }

    private func window(cols: UInt16 = 80, rows: UInt16 = 24) -> Window {
        let window = Window(cols: cols, rows: rows)
        windows.append(window)
        return window
    }

    private func wait(_ message: String, timeout: TimeInterval = 10, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(message)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private var running: [ShellSessionInfo] { manager.sessions.filter(\.running) }

    func testANewTerminalIsASessionAPhoneSeesAndTypesInto() throws {
        let mac = window()
        mac.run(socketPath, .hook)
        wait("the session exists") { self.running.count == 1 }
        let info = try XCTUnwrap(running.first)
        XCTAssertTrue(info.isOnMac)

        mac.type("echo mac-$((20+22))\r")
        wait("the window shows its own command's output") { mac.text.contains("mac-42") }

        let phone = SharedSessionTests.Client()
        try manager.attach(info.id, client: phone, cols: 80, rows: 24)
        wait("the phone is replayed what the window printed") { phone.text.contains("mac-42") }
        manager.input(info.id, Data("echo phone-$((30+3))\n".utf8), from: phone)
        wait("the window shows what the phone typed and its output") { mac.text.contains("phone-33") }
        XCTAssertTrue(try XCTUnwrap(manager.details.first).phoneAttached)
        XCTAssertEqual(manager.details.first?.macViewers, 1)

        mac.type("exit 7\r")
        wait("the window's client hears the shell's exit status") { mac.outcome == .ended(7) }
        wait("and so does the phone") { phone.exitStatus == 7 }
    }

    func testTheSessionStartsInTheWindowsFolderWithItsEnvironment() throws {
        let folder = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = window()
        mac.run(socketPath, .new, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "WINDOW_VAR": "kept"], directory: folder.path)
        wait("started") { self.running.count == 1 }
        mac.type("echo \"[$WINDOW_VAR|$(basename \"$(pwd)\")]\"\r")
        wait("the window's folder and environment") { mac.text.contains("[kept|project]") }
    }

    func testClosingTheWindowEndsTheSessionItStarted() {
        let mac = window()
        mac.run(socketPath, .hook)
        wait("started") { self.running.count == 1 }
        mac.close()
        wait("the session ends with its window") { self.running.isEmpty }
    }

    func testAWindowShowsAPhonesSessionAndLeavingItKeepsItRunning() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let phone = SharedSessionTests.Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.input(id, Data("echo before-$((4+4))\n".utf8), from: phone)
        wait("printed") { phone.text.contains("before-8") }

        let mac = window()
        mac.run(socketPath, .attach, session: String(id.prefix(8)))
        wait("the window is replayed the session") { mac.text.contains("before-8") }
        XCTAssertEqual(phone.detaches, 0, "the phone keeps the session")
        // Keys typed while the earlier output is drawn are dropped (the terminal's answers to old questions).
        Thread.sleep(forTimeInterval: LocalTerminalClient.settleAfterReplay + 0.2)
        mac.type("echo both-$((5+5))\r")
        wait("both see what the window typed") { mac.text.contains("both-10") && phone.text.contains("both-10") }

        mac.close()
        wait("the window's client stops") { mac.outcome == .detached }
        wait("the Mac no longer shows it") { self.manager.details.first?.macViewers == 0 }
        XCTAssertEqual(running.map(\.id), [id], "a session the window only showed carries on")
        manager.input(id, Data("echo after-$((6+6))\n".utf8), from: phone)
        wait("the phone still uses it") { phone.text.contains("after-12") }
    }

    func testCtrlBackslashTwiceLeavesASessionTheWindowOnlyShows() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let mac = window()
        mac.run(socketPath, .attach, session: id)
        wait("attached") { self.manager.details.first?.macViewers == 1 }
        Thread.sleep(forTimeInterval: LocalTerminalClient.settleAfterReplay + 0.2)
        mac.type("\u{1C}")
        Thread.sleep(forTimeInterval: 0.1)
        mac.type("\u{1C}")
        wait("left") { mac.outcome == .detached }
        XCTAssertEqual(running.map(\.id), [id])
    }

    func testTheWindowsSizeReachesTheShellWhenItChanges() {
        let mac = window(cols: 90, rows: 30)
        mac.run(socketPath, .hook)
        wait("started") { self.running.count == 1 }
        mac.type("echo a; stty size\r")
        wait("the window's size") { mac.text.contains("30 90") }
        mac.resize(cols: 132, rows: 43)
        Thread.sleep(forTimeInterval: 0.3)
        mac.type("echo b; stty size\r")
        wait("its new size") { mac.text.contains("43 132") }
    }

    func testTheHookIsRefusedWhileSharingIsOffButAskingByNameStillWorks() {
        sharing.set(false)
        let plain = window()
        plain.run(socketPath, .hook)
        wait("refused") { plain.outcome == .unavailable(LocalTerminalWire.Refused.notSharing) }
        XCTAssertTrue(running.isEmpty)
        let named = window()
        named.run(socketPath, .new)
        wait("started") { self.running.count == 1 }
    }

    func testWithoutTheAppTheTerminalCarriesOn() {
        server.stop()
        let mac = window()
        mac.run(socketPath, .hook)
        wait("nothing to connect to") { mac.outcome == .unavailable(LocalTerminalClient.notRunning) }
    }

    func testAnAppThatAcceptsButNeverAnswersDoesNotHoldTheTerminal() throws {
        server.stop()
        // Something else listening where the app's socket would be.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(socketPath) }
        var address = try XCTUnwrap(LocalTerminalServer.address(socketPath))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        let far = window().far
        let started = Date()
        let outcome = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .hook, input: far, output: far, answerTimeout: 0.5))
        XCTAssertEqual(outcome, .unavailable(LocalTerminalClient.noAnswer))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTheAppStoppingEndsTheSessionAndTellsTheWindow() {
        let mac = window()
        mac.run(socketPath, .hook)
        wait("started") { self.running.count == 1 }
        server.stop()
        wait("the window hears the app went away") { mac.outcome == .lost }
        wait("the session ended with its window's connection") { self.running.isEmpty }
    }

    func testListAndAnUnknownSession() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let far = window().far
        let listed = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .list, input: far, output: far))
        guard case .listed(let sessions) = listed else { return XCTFail("\(listed)") }
        XCTAssertEqual(sessions.map(\.id), [id])
        let missing = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .attach, session: "nope-nope", input: far, output: far))
        XCTAssertEqual(missing, .unavailable(LocalTerminalWire.Refused.noSuchSession))
    }

    func testTheSocketIsOnlyTheUsers() throws {
        var info = stat()
        XCTAssertEqual(stat(socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_uid, getuid())
    }

    func testAPathTooLongForASocketIsRefused() {
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertFalse(LocalTerminalServer.fits(long))
        XCTAssertThrowsError(try LocalTerminalServer(path: long, manager: manager).start())
    }

    /// A window that stops drawing does not make the Mac buffer the shell's
    /// output without end: the shell is held back until the window reads again.
    func testAWindowThatStopsReadingHoldsTheShellBack() throws {
        // A raw connection that says hello and then reads nothing.
        let fd = try XCTUnwrap(LocalTerminalClient.connect(socketPath))
        defer { close(fd) }
        let hello = LocalTerminalWire.Hello(mode: .new, cols: 80, rows: 24, directory: "/tmp",
                                            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "])
        XCTAssertTrue(LocalTerminalClient.writeAll(fd, LocalTerminalWire.encode(.hello, json: hello)))
        wait("started") { self.running.count == 1 }
        let id = try XCTUnwrap(running.first?.id)
        let phone = SharedSessionTests.Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)

        let total = 16 << 20
        manager.input(id, Data("head -c \(total) /dev/zero | tr '\\0' 'x'; echo; echo done-$((8+1))\n".utf8), from: phone)
        // Held back well short of the whole output (what fits in the socket, the queue's limit and the terminal).
        Thread.sleep(forTimeInterval: 1.5)
        let held = phone.bytes
        XCTAssertLessThan(held, total / 2, "the shell is not read while the window is behind")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(phone.bytes, held, "and stays held")

        // The window reads again: everything arrives, in order, nothing dropped.
        var parser = LocalTerminalWire.Parser()
        var received = 0
        var tail = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let deadline = Date().addingTimeInterval(30)
        while !String(decoding: tail, as: UTF8.self).contains("done-9"), Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { break }
            for frame in try parser.append(Data(buffer[0..<n])) where frame.kind == .output {
                received += frame.payload.count
                tail = (tail + frame.payload).suffix(64)
            }
        }
        XCTAssertTrue(String(decoding: tail, as: UTF8.self).contains("done-9"))
        XCTAssertGreaterThanOrEqual(received, total)
        wait("the phone got it all too") { phone.text.hasSuffix("$ ") && phone.bytes >= total }
    }
}
#endif
