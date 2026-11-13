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
    /// The app's own rules for what the socket lets in, sharing new terminals on.
    private let access = LocalTerminalAccess()

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
        access.isSharing = true
        let access = access
        server = LocalTerminalServer(path: socketPath, manager: manager) { access.admits($0) }
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
        /// What the window answers when asked for its colours; nil: nothing, as a bare pseudo-terminal.
        let coloursAnswer = Locked<Data?>(nil)
        /// How long the window takes to answer (past the tool's wait, its answer arrives late).
        let coloursDelay = Locked<TimeInterval>(0)
        /// What was typed into the window and left unread when its client ended.
        let unreadAtEnd = Locked(-1)
        /// A client thread is using the far side and closes it when it is done.
        private let clientRunning = Locked(false)

        init(cols: UInt16 = 80, rows: UInt16 = 24) {
            var near: Int32 = -1, far: Int32 = -1
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            precondition(openpty(&near, &far, nil, nil, &size) == 0)
            self.near = near
            self.far = far
            // The reader owns both ends and closes them itself once told to:
            // closing a pseudo-terminal another thread is reading can hang.
            let stop = stop, clientRunning = clientRunning
            let thread = Thread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while !stop.get() {
                    var p = pollfd(fd: near, events: Int16(POLLIN), revents: 0)
                    guard poll(&p, 1, 20) > 0 else { continue }
                    let n = read(near, &buffer, buffer.count)
                    guard n > 0, let self else { break }
                    self.lock.lock(); self.data.append(contentsOf: buffer[0..<n]); self.lock.unlock()
                    // A terminal that tells its colours when asked, as Terminal.app does.
                    if let answer = self.coloursAnswer.get(), Data(buffer[0..<n]).range(of: TerminalColors.question) != nil {
                        let delay = self.coloursDelay.get()
                        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                        _ = answer.withUnsafeBytes { write(near, $0.baseAddress, answer.count) }
                    }
                }
                // As a window closing: the near side goes, and the client finds
                // its terminal hung up. The far side is the client's to the end
                // (closing a descriptor another thread waits on wakes it on some
                // systems and not on others).
                Darwin.close(near)
                if !clientRunning.get() { Darwin.close(far) }
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
        func run(_ socket: String, _ mode: LocalTerminalWire.Mode, session: String? = nil, token: String? = nil,
                 environment: [String: String] = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "],
                 directory: String = "/tmp", coloursTimeout: TimeInterval = 0) {
            let far = far
            clientRunning.set(true)
            Thread { [weak self] in
                let outcome = LocalTerminalClient.run(.init(socketPath: socket, mode: mode, session: session, token: token, input: far, output: far,
                                                            environment: environment, directory: directory, coloursTimeout: coloursTimeout))
                var waiting: Int32 = 0
                _ = ioctl(far, LocalTerminalClient.fionread, &waiting)
                Darwin.close(far)
                guard let self else { return }
                self.unreadAtEnd.set(Int(waiting))
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

    static let coloursAnswer = Data("\u{1B}]10;rgb:e6ce/e6ce/e6ce\u{07}\u{1B}]11;rgb:213d/2743/33e7\u{07}\u{1B}[?1;2c".utf8)

    func testTheWindowsColoursGoWithItsSessionToPhones() throws {
        let mac = window()
        mac.coloursAnswer.set(Self.coloursAnswer)
        mac.run(socketPath, .hook, coloursTimeout: 2)
        wait("the session has the window's colours") { self.running.first?.theme == ShellTheme(foreground: "#e6e6e6", background: "#212734") }
        // The answer was read by the tool: none of it reaches the shell as typing.
        mac.type("echo clean-$((7+7))\r")
        wait("the shell works") { mac.text.contains("clean-14") }
        XCTAssertFalse(mac.text.contains("rgb:"), mac.text)
    }

    /// A terminal slower to answer than the tool waits: its answer, arriving
    /// once the session runs, is still kept from the shell.
    func testALateAnswerAboutColoursNeverReachesTheShell() {
        let mac = window()
        mac.coloursAnswer.set(Self.coloursAnswer)
        mac.coloursDelay.set(0.4)
        mac.run(socketPath, .hook, coloursTimeout: 0.1)
        wait("started") { self.running.count == 1 }
        Thread.sleep(forTimeInterval: 0.6)
        mac.type("echo clean-$((6+6))\r")
        wait("the shell works") { mac.text.contains("clean-12") }
        XCTAssertFalse(mac.text.contains("rgb:"), mac.text)
        XCTAssertFalse(mac.text.contains("1;2c"), mac.text)
    }

    /// A terminal that opens a window to run a command types it at once,
    /// before any shell reads: it must reach the session's shell, not be
    /// taken for the terminal's answer about its colours.
    func testWhatWasTypedBeforeTheSessionStartedStillReachesItsShell() {
        let mac = window()
        mac.coloursAnswer.set(Self.coloursAnswer)
        mac.type("echo ahead-$((2+3))\r")
        mac.run(socketPath, .hook, coloursTimeout: 2)
        wait("the typed-ahead command ran in the session") { mac.text.contains("ahead-5") }
        wait("and the colours were still read") { self.running.first?.theme != nil }
        XCTAssertFalse(mac.text.contains("rgb:"), mac.text)
    }

    /// The window "Open in Terminal" opens: its own shell is refused a
    /// session, and the command typed into it must still be there to run.
    func testAWindowRefusedASessionKeepsWhatWasTypedIntoIt() {
        access.isSharing = false
        let mac = window()
        mac.coloursAnswer.set(Self.coloursAnswer)
        let typed = "/path/to/Open.command ; exit;\n"
        mac.type(typed)
        mac.run(socketPath, .hook, coloursTimeout: 2)
        wait("refused") { mac.outcome == .unavailable(LocalTerminalWire.Refused.notSharing) }
        XCTAssertFalse(mac.text.contains("\u{1B}]11;?"), "the terminal was asked nothing")
        wait("the client ended") { mac.unreadAtEnd.get() >= 0 }
        XCTAssertEqual(mac.unreadAtEnd.get(), typed.utf8.count, "nothing typed was read")
    }

    func testAWindowThatDoesNotSayItsColoursStillStartsAfterAShortWait() {
        let mac = window()
        mac.run(socketPath, .hook, coloursTimeout: 0.2)
        wait("started") { self.running.count == 1 }
        XCTAssertNil(running.first?.theme)
        mac.type("echo fine-$((8+8))\r")
        wait("the shell works") { mac.text.contains("fine-16") }
    }

    func testAWindowOnlyShowingASessionDoesNotChangeItsColours() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let mac = window()
        mac.coloursAnswer.set(Self.coloursAnswer)
        mac.run(socketPath, .attach, session: id, token: access.grant(session: id, plain: false), coloursTimeout: 2)
        wait("attached") { self.manager.details.first?.macViewers == 1 }
        XCTAssertNil(running.first?.theme)
        XCTAssertFalse(mac.text.contains("\u{1B}]11;?"), "and is not asked")
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
        mac.run(socketPath, .attach, session: id, token: access.grant(session: id, plain: false))
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
        mac.run(socketPath, .attach, session: id, token: access.grant(session: id, plain: false))
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

    /// A session's shell runs inside Passthrough, with its privacy permissions:
    /// with sharing off, nothing on the socket starts one or lists them.
    func testWhileSharingIsOffNoNewSessionNorTheList() throws {
        access.isSharing = false
        let plain = window()
        plain.run(socketPath, .hook)
        wait("hook refused") { plain.outcome == .unavailable(LocalTerminalWire.Refused.notSharing) }
        let named = window()
        named.run(socketPath, .new)
        wait("new refused") { named.outcome == .unavailable(LocalTerminalWire.Refused.notSharing) }
        let far = window().far
        XCTAssertEqual(LocalTerminalClient.run(.init(socketPath: socketPath, mode: .list, input: far, output: far)),
                       .unavailable(LocalTerminalWire.Refused.notSharing))
        XCTAssertTrue(running.isEmpty)
        // "Open here" still works: the window it opens has its token.
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let shown = window()
        shown.run(socketPath, .attach, session: id, token: access.grant(session: id, plain: false))
        wait("attached") { self.manager.details.first?.macViewers == 1 }
    }

    /// Showing a running session (a phone's, with what it printed and what is
    /// typed into it) takes the token the app wrote for that window: once, for that session only.
    func testAttachingTakesAOneTimeTokenForThatSession() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let other = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        func attach(_ session: String, _ token: String?) -> LocalTerminalClient.Outcome {
            let far = window().far
            return LocalTerminalClient.run(.init(socketPath: socketPath, mode: .attach, session: session, token: token,
                                                 input: far, output: far, environment: [:]))
        }
        XCTAssertEqual(attach(id, nil), .unavailable(LocalTerminalWire.Refused.notAllowed), "no token")
        XCTAssertEqual(attach(id, "00" + String(repeating: "f", count: 62)), .unavailable(LocalTerminalWire.Refused.notAllowed), "a made-up one")
        let forOther = access.grant(session: other, plain: false)
        XCTAssertEqual(attach(id, forOther), .unavailable(LocalTerminalWire.Refused.notAllowed), "another session's")
        XCTAssertEqual(attach(String(id.prefix(8)), access.grant(session: id, plain: false)), .unavailable(LocalTerminalWire.Refused.notAllowed),
                       "a token is for the session's whole id")

        let token = access.grant(session: id, plain: false)
        let mac = window()
        mac.run(socketPath, .attach, session: id, token: token)
        wait("attached with its token") { self.manager.details.first { $0.id == id }?.macViewers == 1 }
        XCTAssertEqual(attach(id, token), .unavailable(LocalTerminalWire.Refused.notAllowed), "and only once")
    }

    /// The token came back after a window was let in with it: something else
    /// had it, so the owner hears of it (and the app takes the session off its windows).
    func testATokenUsedTwiceRaisesTheAlarm() throws {
        let contested = Locked<String?>(nil)
        access.onContested = { contested.set($0) }
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let token = access.grant(session: id, plain: false)
        let first = window()
        first.run(socketPath, .attach, session: id, token: token)
        wait("shown") { self.manager.details.first?.macViewers == 1 }
        let far = window().far
        let again = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .attach, session: id, token: token,
                                                  input: far, output: far, environment: [:]))
        XCTAssertEqual(again, .unavailable(LocalTerminalWire.Refused.notAllowed))
        XCTAssertEqual(contested.get(), id)
    }

    /// The Mac can take a phone's session off its windows at any time; it carries on for the phone.
    func testStopShowingHere() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let mac = window()
        mac.run(socketPath, .attach, session: id, token: access.grant(session: id, plain: false))
        wait("shown") { self.manager.details.first?.macViewers == 1 }
        server.stopShowing(id)
        wait("the window stops showing it") { mac.outcome == .detached }
        wait("the Mac no longer shows it") { self.manager.details.first?.macViewers == 0 }
        XCTAssertEqual(running.map(\.id), [id])
    }

    func testATokenRunsOutAndItsFileGoesWithIt() throws {
        var now = Date()
        let clock = Locked(now)
        let access = LocalTerminalAccess(now: { clock.get() })
        let file = directory.appendingPathComponent("Open.command")
        try Data("x".utf8).write(to: file)
        let token = access.grant(session: "S", file: file, plain: false)
        now += LocalTerminalAccess.lifetime + 1
        clock.set(now)
        XCTAssertFalse(access.admits(.init(mode: .attach, session: "S", cols: 80, rows: 24, token: token)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the expired command file is removed")

        let used = directory.appendingPathComponent("Used.command")
        try Data("x".utf8).write(to: used)
        let fresh = access.grant(session: "S", file: used, plain: false)
        let hello = LocalTerminalWire.Hello(mode: .attach, session: "S", cols: 80, rows: 24, token: fresh)
        XCTAssertTrue(access.admits(hello))
        // Kept for its minute: the window Passthrough opened must still find it,
        // so that one asking first in its place is found out.
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path))
        // The token again: never a second window, and the owner hears of it, once.
        let contested = Locked<[String]>([])
        access.onContested = { session in contested.set(contested.get() + [session]) }
        XCTAssertFalse(access.admits(hello))
        XCTAssertEqual(contested.get(), ["S"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: used.path), "gone once found out")
        XCTAssertFalse(access.admits(hello))
        XCTAssertEqual(contested.get(), ["S"], "told once")
        // A token is needed, and the session it was made for.
        XCTAssertFalse(access.admits(.init(mode: .attach, cols: 80, rows: 24)))
        XCTAssertFalse(access.admits(.init(mode: .attach, cols: 80, rows: 24, token: "nope")))
        let other = access.grant(session: "S", plain: false)
        XCTAssertFalse(access.admits(.init(mode: .attach, session: "T", cols: 80, rows: 24, token: other)))
        XCTAssertEqual(contested.get(), ["S"])
    }

    /// With the hook on, the window "Open here" opens must keep its own shell
    /// plain to run the command typed into it; it is the one with a line
    /// typed ahead. A new tab meanwhile still becomes a session.
    func testOnlyTheOpenedWindowStaysPlain() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        _ = access.grant(session: id, plain: true)

        let tab = window()
        tab.run(socketPath, .hook)
        wait("a new tab opened meanwhile is a session") { self.running.count == 2 }

        let opened = window()
        let typed = "'/path/Passthrough session.command' ; exit\n"
        opened.type(typed)
        opened.run(socketPath, .hook)
        wait("the opened window stays plain") { opened.outcome == .unavailable(LocalTerminalWire.Refused.notSharing) }
        wait("the client ended") { opened.unreadAtEnd.get() >= 0 }
        XCTAssertEqual(opened.unreadAtEnd.get(), typed.utf8.count, "its command is left for its shell")

        // Once: a later window with a line typed ahead is a session again.
        let later = window()
        later.type("echo ahead-$((1+1))\r")
        later.run(socketPath, .hook)
        wait("a later window is a session") { later.text.contains("ahead-2") }
    }

    /// A terminal shown inside itself would loop its own output back in.
    func testAWindowCannotShowTheSessionItIsIn() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let far = window().far
        let outcome = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .attach, session: id, token: access.grant(session: id, plain: false),
                                                    input: far, output: far, environment: [RemoteShell.sessionVariable: id]))
        XCTAssertEqual(outcome, .unavailable(LocalTerminalWire.Refused.ownSession))
        XCTAssertEqual(manager.details.first?.macViewers, 0)
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
        let missing = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .attach, session: "nope-nope",
                                                    token: access.grant(session: "nope-nope", plain: false), input: far, output: far))
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
        XCTAssertThrowsError(try LocalTerminalServer(path: long, manager: manager) { _ in true }.start())
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
