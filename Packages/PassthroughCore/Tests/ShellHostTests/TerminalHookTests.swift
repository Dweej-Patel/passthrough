#if os(macOS)
import Darwin
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

/// The lines put in the user's shell startup file, read by real shells.
final class TerminalHookTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: "/tmp/pt-hook-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private var script: URL { home.appendingPathComponent("Library/Application Support/passthrough.test/bin/passthrough-term") }

    private func wait(_ message: String, timeout: TimeInterval = 15, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(message)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: The text

    func testTheHookNamesTheScriptUnderHomeAndGoesFirst() throws {
        let text = try XCTUnwrap(TerminalHook.adding(to: "export EDITOR=vim\n", script: script.path, home: home.path))
        XCTAssertTrue(text.hasPrefix(TerminalHook.begin))
        XCTAssertTrue(text.hasSuffix("export EDITOR=vim\n"))
        XCTAssertTrue(text.contains("\"$HOME/Library/Application Support/passthrough.test/bin/passthrough-term\" hook"))
        XCTAssertFalse(text.contains(home.path), "no user name in the startup file")
        XCTAssertTrue(TerminalHook.isInstalled(in: text))
    }

    func testAddingTwiceLeavesOneHookAndRemovingGivesTheFileBack() throws {
        let original = "# mine\nexport EDITOR=vim\nalias ll='ls -l'\n"
        let once = try XCTUnwrap(TerminalHook.adding(to: original, script: script.path, home: home.path))
        let twice = try XCTUnwrap(TerminalHook.adding(to: once, script: script.path, home: home.path))
        XCTAssertEqual(once, twice)
        XCTAssertEqual(TerminalHook.removing(from: twice), original)
        XCTAssertEqual(TerminalHook.removing(from: original), original)
        XCTAssertEqual(TerminalHook.removing(from: try XCTUnwrap(TerminalHook.adding(to: "", script: script.path, home: home.path))), "")
    }

    func testAHookSomeoneMovedDownTheFileIsStillFoundAndRemoved() throws {
        let block = try XCTUnwrap(TerminalHook.block(script: script.path, home: home.path))
        let moved = "export A=1\n" + block + "export B=2\n"
        XCTAssertEqual(TerminalHook.removing(from: moved), "export A=1\nexport B=2\n")
    }

    func testAPathAShellWouldNotReadBackIsRefused() {
        for bad in ["/Users/a\"b/tool", "/Users/a$b/tool", "/Users/a`b/tool", "/Users/a\\b/tool"] {
            XCTAssertNil(TerminalHook.block(script: bad, home: "/Users/x"), bad)
        }
        XCTAssertNotNil(TerminalHook.block(script: "/opt/it's fine/tool", home: "/Users/x"))
    }

    func testWhichStartupFile() {
        XCTAssertEqual(TerminalHook.startupFile(shell: "/bin/zsh", home: home)?.lastPathComponent, ".zshrc")
        XCTAssertEqual(TerminalHook.startupFile(shell: "/opt/homebrew/bin/zsh", home: home)?.lastPathComponent, ".zshrc")
        XCTAssertNil(TerminalHook.startupFile(shell: "/opt/homebrew/bin/fish", home: home))
        // bash reads only the first of its three that exists: never make one that hides another.
        XCTAssertEqual(TerminalHook.startupFile(shell: "/bin/bash", home: home, exists: { _ in false })?.lastPathComponent, ".bash_profile")
        XCTAssertEqual(TerminalHook.startupFile(shell: "/bin/bash", home: home, exists: { $0.lastPathComponent == ".profile" })?.lastPathComponent, ".profile")
    }

    // MARK: The file

    func testInstallKeepsPermissionsFollowsASymlinkAndRemoveUndoesIt() throws {
        let real = home.appendingPathComponent("dotfiles/zshrc")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "export EDITOR=vim\n"
        try Data(original.utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = home.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try TerminalHook.install(in: link, script: script.path, home: home.path)
        XCTAssertTrue(TerminalHook.isInstalled(in: link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "still a link")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)

        try TerminalHook.remove(from: link)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)
    }

    func testInstallMakesTheFileWhenThereIsNoneAndRemoveLeavesAMissingOneAlone() throws {
        let file = home.appendingPathComponent(".zshrc")
        try TerminalHook.remove(from: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try TerminalHook.install(in: file, script: script.path, home: home.path)
        XCTAssertTrue(TerminalHook.isInstalled(in: file))
    }

    func testAFileThatIsNotTextIsLeftAlone() throws {
        let file = home.appendingPathComponent(".zshrc")
        let bytes = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28])
        try bytes.write(to: file)
        XCTAssertThrowsError(try TerminalHook.install(in: file, script: script.path, home: home.path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    // MARK: Real shells

    /// Starts `shell` as a terminal's login shell would be, in a home whose
    /// startup file holds the hook and then prints a marker.
    private func start(_ shell: String, tool: String?, environment extra: [String: String] = [:]) throws -> (PTYProcess, Output) {
        if let tool {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(tool.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let file = try XCTUnwrap(TerminalHook.startupFile(shell: shell, home: home))
        try Data("echo rest-of-startup-$((3+4))\n".utf8).write(to: file)
        try TerminalHook.install(in: file, script: script.path, home: home.path)
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "]
        environment.merge(extra) { $1 }
        let process = try PTYProcess(executable: shell, arguments: ["-l"], directory: home, environment: environment, cols: 80, rows: 24)
        let output = Output()
        process.onOutput = { output.append($0) }
        process.onExit = { output.exited($0) }
        process.start()
        return (process, output)
    }

    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var status: Int32?
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        func exited(_ code: Int32) { lock.lock(); status = code; lock.unlock() }
    }

    private let shells = ["/bin/zsh", "/bin/bash"]

    func testWhenASessionRanAndEndedTheTerminalsShellExitsWithItsStatus() throws {
        for shell in shells {
            let (process, output) = try start(shell, tool: "#!/bin/sh\necho in-session-$((1+1))\necho ended:5 >&3\n")
            wait("\(shell) exits") { output.exitStatus != nil }
            withExtendedLifetime(process) {}
            XCTAssertEqual(output.exitStatus, 5, shell)
            XCTAssertTrue(output.text.contains("in-session-2"), "the tool draws on the terminal: \(output.text)")
            XCTAssertFalse(output.text.contains("rest-of-startup-7"), "\(shell) gave the terminal up before the rest of its startup")
        }
    }

    func testWhenTheToolSaysNothingTheTerminalCarriesOnWithItsOwnShell() throws {
        // Refused, Passthrough not running, the app gone mid-session, a crash: all say nothing on descriptor 3.
        for tool in ["#!/bin/sh\nexit 0\n", "#!/bin/sh\nexit 139\n", "#!/bin/sh\nkill -SEGV $$\n", "#!/bin/sh\necho gibberish >&3\n"] {
            for shell in shells {
                let (process, output) = try start(shell, tool: tool)
                defer { process.terminate() }
                wait("\(shell) runs the rest of its startup after: \(tool)") { output.text.contains("rest-of-startup-7") }
                process.write(Data("echo alive-$((20+2))\n".utf8))
                wait("\(shell) is a working shell") { output.text.contains("alive-22") }
                XCTAssertNil(output.exitStatus)
            }
        }
    }

    func testWithoutTheScriptTheTerminalStartsAsUsual() throws {
        for shell in shells {
            let (process, output) = try start(shell, tool: nil)
            defer { process.terminate() }
            wait("\(shell) starts") { output.text.contains("rest-of-startup-7") }
        }
    }

    func testAShellAlreadyInASessionDoesNotAskForAnother() throws {
        for shell in shells {
            let (process, output) = try start(shell, tool: "#!/bin/sh\necho ASKED-AGAIN\necho ended:9 >&3\n",
                                              environment: [RemoteShell.sessionVariable: "A-SESSION"])
            defer { process.terminate() }
            wait("\(shell) starts") { output.text.contains("rest-of-startup-7") }
            XCTAssertFalse(output.text.contains("ASKED-AGAIN"), shell)
        }
    }

    func testAShellThatIsNotInteractiveDoesNotAsk() throws {
        try Data("#!/bin/sh\necho ASKED >&2\necho ended:9 >&3\n".utf8).write(to: {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            return script
        }())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = home.appendingPathComponent(".zshrc")
        try TerminalHook.install(in: file, script: script.path, home: home.path)
        // A script sourcing the file on a terminal (what a tool that runs `zsh -c` after loading it does).
        let process = try PTYProcess(executable: "/bin/zsh", arguments: ["-c", "source ~/.zshrc; echo ran-$((2+3))"], directory: home,
                                     environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], cols: 80, rows: 24)
        let output = Output()
        process.onOutput = { output.append($0) }
        process.onExit = { output.exited($0) }
        process.start()
        wait("the script ran") { output.exitStatus != nil }
        withExtendedLifetime(process) {}
        XCTAssertTrue(output.text.contains("ran-5"), output.text)
        XCTAssertFalse(output.text.contains("ASKED"), output.text)
    }

    // MARK: The whole path: a terminal's zsh, the hook, the real tool, the app's server, a session

    /// The tool as SwiftPM built it beside the tests, if it did.
    private var builtTool: URL? {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let tool = products.appendingPathComponent("passthrough-term")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    func testANewTerminalBecomesASharedSessionEndToEnd() throws {
        let tool = try XCTUnwrap(builtTool, "passthrough-term was not built beside the tests")
        for shell in shells {
            let transcripts = try TranscriptStore(directory: home.appendingPathComponent("history-\(UUID().uuidString.prefix(6))", isDirectory: true))
            let manager = ShellSessionManager(transcripts: transcripts, command: { (shell, ["-l"]) },
                                              environment: { [:] }, directory: home)
            defer { manager.closeAll() }
            let socket = "/tmp/pt-\(UUID().uuidString.prefix(8)).sock"
            let server = LocalTerminalServer(path: socket, manager: manager)
            try server.start()
            defer { server.stop() }

            // What the app writes at launch, and the hook in the startup file.
            try TerminalHook.writeScript(at: script, tool: tool.path, socket: socket)
            let file = try XCTUnwrap(TerminalHook.startupFile(shell: shell, home: home))
            try Data("PS1='> '\necho startup-$((3+4))-in-${\(RemoteShell.sessionVariable):+session}\n".utf8).write(to: file)
            try TerminalHook.install(in: file, script: script.path, home: home.path)

            // The terminal window's own shell, as Terminal.app starts it.
            let window = try PTYProcess(executable: shell, arguments: ["-l"], directory: home,
                                        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "FROM_TERMINAL": "yes"],
                                        cols: 100, rows: 30)
            let screen = Output()
            window.onOutput = { screen.append($0) }
            window.onExit = { screen.exited($0) }
            window.start()

            wait("\(shell): the session's shell runs the startup file, inside a session") { screen.text.contains("startup-7-in-session") }
            let info = try XCTUnwrap(manager.sessions.first { $0.running })
            XCTAssertTrue(info.isOnMac)
            XCTAssertEqual(screen.text.components(separatedBy: "startup-7").count, 2, "\(shell): the startup file ran once, in the session: \(screen.text)")

            window.write(Data("echo \"[$FROM_TERMINAL|$(stty size)]\"\r".utf8))
            wait("\(shell): the window's environment and size reached the session") { screen.text.contains("[yes|30 100]") }

            // A phone attaches to the same terminal.
            let phone = SharedSessionTests.Client()
            try manager.attach(info.id, client: phone, cols: 100, rows: 30)
            wait("\(shell): the phone sees what the window printed") { phone.text.contains("[yes|30 100]") }
            manager.input(info.id, Data("echo phone-$((40+2))\r".utf8), from: phone)
            wait("\(shell): the window shows what the phone typed") { screen.text.contains("phone-42") }

            window.write(Data("exit 6\r".utf8))
            wait("\(shell): the terminal's own shell exits with the session's status") { screen.exitStatus != nil }
            XCTAssertEqual(screen.exitStatus, 6, shell)
            wait("\(shell): the phone hears it too") { phone.exitStatus == 6 }
            try FileManager.default.removeItem(at: file)
        }
    }

    func testTheAppQuittingLeavesTheTerminalWithAWorkingShell() throws {
        let tool = try XCTUnwrap(builtTool, "passthrough-term was not built beside the tests")
        let transcripts = try TranscriptStore(directory: home.appendingPathComponent("history", isDirectory: true))
        let manager = ShellSessionManager(transcripts: transcripts, command: { ("/bin/zsh", ["-l"]) }, environment: { [:] }, directory: home)
        let socket = "/tmp/pt-\(UUID().uuidString.prefix(8)).sock"
        let server = LocalTerminalServer(path: socket, manager: manager)
        try server.start()
        try TerminalHook.writeScript(at: script, tool: tool.path, socket: socket)
        let file = home.appendingPathComponent(".zshrc")
        try Data("PS1='%% '\necho startup-$((3+4))-in-${\(RemoteShell.sessionVariable):-plain}\n".utf8).write(to: file)
        try TerminalHook.install(in: file, script: script.path, home: home.path)

        let window = try PTYProcess(executable: "/bin/zsh", arguments: ["-l"], directory: home,
                                    environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], cols: 80, rows: 24)
        defer { window.terminate() }
        let screen = Output()
        window.onOutput = { screen.append($0) }
        window.onExit = { screen.exited($0) }
        window.start()
        wait("in a session") { manager.sessions.contains { $0.running } }

        // Passthrough quits.
        server.stop()
        manager.closeAll()
        wait("the terminal says so and starts its own shell") { screen.text.contains("Passthrough stopped") && screen.text.contains("startup-7-in-plain") }
        window.write(Data("echo still-$((50+5))\r".utf8))
        wait("which works") { screen.text.contains("still-55") }
        XCTAssertNil(screen.exitStatus)
    }
}
#endif
