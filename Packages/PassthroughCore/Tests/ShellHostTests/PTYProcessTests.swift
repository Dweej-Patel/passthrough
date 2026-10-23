#if os(macOS)
import XCTest
@testable import ShellHost

final class PTYProcessTests: XCTestCase {
    /// Collects a process's output and exit status.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var status: Int32?
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }
        func attach(to process: PTYProcess) {
            process.onOutput = { [self] in lock.lock(); data.append($0); lock.unlock() }
            process.onExit = { [self] in lock.lock(); status = $0; lock.unlock() }
        }
    }

    private func make(_ args: [String], shell: String = "/bin/sh", cols: UInt16 = 80, rows: UInt16 = 24) throws -> (PTYProcess, Probe) {
        let process = try PTYProcess(executable: shell, arguments: args, directory: URL(fileURLWithPath: "/tmp"),
                                     environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], cols: cols, rows: rows)
        let probe = Probe()
        probe.attach(to: process)
        process.start()
        return (process, probe)
    }

    /// Polls until `condition` holds, or fails after `timeout`.
    private func wait(_ message: String, timeout: TimeInterval = 10, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(message)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func testEchoRoundTrip() throws {
        let (process, probe) = try make([])
        defer { process.terminate() }
        // The tty echoes typed input, so wait for a result only the shell computes.
        process.write(Data("echo $((20+22))\n".utf8))
        wait("output contains 42") { probe.text.contains("42") }
    }

    func testExitStatus() throws {
        let (process, probe) = try make(["-c", "exit 3"])
        wait("exit status") { probe.exitStatus != nil }
        withExtendedLifetime(process) {}
        XCTAssertEqual(probe.exitStatus, 3)
    }

    func testHasControllingTerminal() throws {
        let (process, probe) = try make(["-c", "tty; ps -o tpgid= -p $$"])
        wait("exit") { probe.exitStatus != nil }
        withExtendedLifetime(process) {}
        XCTAssertTrue(probe.text.hasPrefix("/dev/ttys"), probe.text)
        // The tty has a foreground group only if it is the session's controlling terminal.
        let tpgid = probe.text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(tpgid, String(process.pid), probe.text)
    }

    func testInterruptReachesForegroundCommandInInteractiveShell() throws {
        // zsh (the default login shell) only puts commands in the tty's foreground
        // group when the tty is its controlling terminal; /bin/sh copes without.
        let (process, probe) = try make(["-f", "-i"], shell: "/bin/zsh")
        defer { process.terminate() }
        process.write(Data("cat\n".utf8))   // waits on the terminal, like `grep Python`
        Thread.sleep(forTimeInterval: 0.3)
        process.write(Data([0x03]))   // ctrl-C
        process.write(Data("echo AFTER_$((6*7))\n".utf8))
        wait("shell back after ctrl-C") { probe.text.contains("AFTER_42") }
    }

    func testResize() throws {
        let (process, probe) = try make([])
        defer { process.terminate() }
        process.resize(cols: 100, rows: 30)
        process.write(Data("stty size\n".utf8))
        wait("size reported") { probe.text.contains("30 100") }
    }

    func testInterruptWorks() throws {
        let (process, probe) = try make(["-c", "echo ready; sleep 30"])
        wait("shell running") { probe.text.contains("ready") }
        process.write(Data([0x03]))   // ctrl-C
        wait("exit") { probe.exitStatus != nil }
        withExtendedLifetime(process) {}
        XCTAssertEqual(probe.exitStatus, 128 + SIGINT)
    }

    func testTerminateEndsProcess() throws {
        let (process, probe) = try make([])
        process.terminate()
        wait("exit") { probe.exitStatus != nil }
        XCTAssertEqual(probe.exitStatus, 128 + SIGHUP)
    }

    func testDroppingTheProcessEndsTheChild() throws {
        let pid: pid_t = try {
            let (process, _) = try make(["-c", "exec cat"])
            return process.pid
        }()   // the only reference is gone
        wait("child gone") { kill(pid, 0) != 0 }
    }

    func testScrollbackKeepsTail() {
        var buffer = ScrollbackBuffer(capacity: 10)
        buffer.append(Data((0..<25).map { UInt8($0) }))
        XCTAssertEqual(buffer.contents, Data((15..<25).map { UInt8($0) }))
        buffer.append(Data([99]))
        XCTAssertEqual(buffer.contents, Data((16..<25).map { UInt8($0) } + [99]))
    }

    /// Until anything is cut off the replay is everything; after, it starts
    /// at a line, or failing that at a whole UTF-8 character.
    func testScrollbackReplayStartsAtALineOnceTrimmed() {
        var buffer = ScrollbackBuffer(capacity: 8)
        buffer.append(Data("ab\ncd".utf8))
        XCTAssertEqual(buffer.replay, Data("ab\ncd".utf8))
        buffer.append(Data("\u{1b}[31mxy\nz".utf8))
        XCTAssertEqual(buffer.contents, Data("[31mxy\nz".utf8))
        XCTAssertEqual(buffer.replay, Data("z".utf8), "not from inside the escape sequence")
        var wide = ScrollbackBuffer(capacity: 3)
        wide.append(Data("éé".utf8))   // four bytes, two per character
        XCTAssertEqual(wide.replay, Data("é".utf8), "not from the middle of a character")
    }

    func testLoginShellCommandAndEnvironment() {
        let command = LoginShell.command()
        XCTAssertEqual(command.arguments, ["-l"])
        XCTAssertFalse(command.executable.isEmpty)
        XCTAssertEqual(LoginShell.environment()["TERM"], "xterm-256color")
        XCTAssertNotNil(LoginShell.environment()["LANG"])
    }

    func testLoginShellEnvironmentStartsClean() {
        let launcher = [
            "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "PASSTHROUGH_DIRECT_SOCKS": "x",
            "PATH": "/opt/launcher/bin:/usr/bin", "HOME": "/elsewhere", "SHELL": "/bin/sh",
            "TMPDIR": "/tmp/t/", "SSH_AUTH_SOCK": "/tmp/agent", "LANG": "fr_FR.UTF-8",
        ]
        let environment = LoginShell.environment(inheriting: launcher)
        XCTAssertNil(environment["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertNil(environment["PASSTHROUGH_DIRECT_SOCKS"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["HOME"], NSHomeDirectory(), "the account's, not the launcher's")
        XCTAssertEqual(environment["SHELL"], LoginShell.command().executable)
        XCTAssertEqual(environment["LOGNAME"], environment["USER"])
        XCTAssertEqual(environment["TMPDIR"], "/tmp/t/")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/agent")
        XCTAssertEqual(environment["LANG"], "fr_FR.UTF-8")
        XCTAssertEqual(environment["TERM_PROGRAM"], "Passthrough")
        XCTAssertEqual(Set(environment.keys), ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TERM", "TERM_PROGRAM", "TMPDIR", "SSH_AUTH_SOCK", "LANG"])
    }

    func testShellGetsNoneOfTheLaunchersVariables() throws {
        let environment = LoginShell.environment(inheriting: ["CLAUDE_CODE_CHILD_SESSION": "1", "TMPDIR": "/tmp/"])
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["-c", "echo marker=${CLAUDE_CODE_CHILD_SESSION:-none} term=$TERM_PROGRAM"],
                                     directory: URL(fileURLWithPath: "/tmp"), environment: environment, cols: 80, rows: 24)
        let probe = Probe()
        probe.attach(to: process)
        process.start()
        wait("exit") { probe.exitStatus != nil }
        withExtendedLifetime(process) {}
        XCTAssertTrue(probe.text.contains("marker=none term=Passthrough"), probe.text)
    }
}
#endif
