#if os(macOS)
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

/// A terminal on the Mac and a phone looking at one session at once.
final class SharedSessionTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!
    private var manager: ShellSessionManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedSessionTests-\(UUID().uuidString)", isDirectory: true)
        store = try TranscriptStore(directory: directory)
        manager = ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"),
            endedRetention: 600,
            quietBeforeAsking: 0.2)
    }

    override func tearDown() {
        manager.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    final class Client: ShellAttachment, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var endStatus: Int32?
        private var detachCount = 0
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var bytes: Int { lock.lock(); defer { lock.unlock() }; return data.count }
        var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return endStatus }
        var detaches: Int { lock.lock(); defer { lock.unlock() }; return detachCount }
        func shellOutput(_ data: Data, session: String) { lock.lock(); self.data.append(data); lock.unlock() }
        func shellEnded(session: String, exitStatus: Int32) { lock.lock(); endStatus = exitStatus; lock.unlock() }
        func shellDetached(session: String, generation: UInt64) { lock.lock(); detachCount += 1; lock.unlock() }
    }

    private func wait(_ message: String, timeout: TimeInterval = 10, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(message)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func testAPhoneAndAMacTerminalBothSeeAndTypeIntoOneSession() throws {
        let id = try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac)
        let phone = Client(), mac = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.input(id, Data("echo from-$((1+1))-phone\n".utf8), from: phone)
        wait("both see the phone's line") { phone.text.contains("from-2-phone") && mac.text.contains("from-2-phone") }
        manager.input(id, Data("echo from-$((2+1))-mac\n".utf8), from: mac)
        wait("both see the Mac's line") { phone.text.contains("from-3-mac") && mac.text.contains("from-3-mac") }
        XCTAssertEqual(phone.detaches, 0)
        XCTAssertEqual(mac.detaches, 0, "a viewer is never taken over")
        manager.input(id, Data("exit 4\n".utf8))
        wait("both hear the end") { phone.exitStatus == 4 && mac.exitStatus == 4 }
    }

    func testASecondPhoneStillTakesOverTheFirstAndLeavesTheMacTerminal() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let first = Client(), second = Client(), mac = Client()
        try manager.attach(id, client: first, cols: 80, rows: 24)
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        XCTAssertEqual(first.detaches, 0, "a Mac terminal takes nothing over")
        try manager.attach(id, client: second, cols: 80, rows: 24)
        wait("the first phone is taken over") { first.detaches == 1 }
        let before = first.text
        manager.input(id, Data("echo to-$((40+2))\n".utf8), from: second)
        wait("the second phone and the Mac see it") { second.text.contains("to-42") && mac.text.contains("to-42") }
        XCTAssertEqual(first.text, before)
        XCTAssertEqual(mac.detaches, 0)
    }

    func testAViewerAttachingLaterIsReplayedWhatWasPrinted() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let phone = Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.input(id, Data("echo early-$((3+4))\n".utf8), from: phone)
        wait("printed") { phone.text.contains("early-7") }
        let mac = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        wait("replayed to the Mac terminal") { mac.text.contains("early-7") }
    }

    func testTheTerminalsSizeFollowsWhoeverTypedLast() throws {
        let id = try manager.open(phoneLabel: "This Mac", cols: 120, rows: 40, origin: .mac)
        let phone = Client(), mac = Client()
        try manager.attach(id, client: mac, cols: 120, rows: 40, shared: true)
        try manager.attach(id, client: phone, cols: 50, rows: 30)
        // The phone attached last: the terminal is its size.
        manager.input(id, Data("echo a; stty size\n".utf8), from: phone)
        wait("the phone's size") { phone.text.contains("30 50") }
        // The Mac's window changes size while the phone is the one typing: remembered, not applied.
        manager.resize(id, cols: 100, rows: 35, from: mac)
        manager.input(id, Data("echo b; stty size\n".utf8), from: phone)
        wait("still the phone's size") { phone.text.components(separatedBy: "30 50").count >= 3 }
        XCTAssertFalse(phone.text.contains("35 100"))
        // The Mac types: the terminal takes the size its window has now.
        manager.input(id, Data("echo c; stty size\n".utf8), from: mac)
        wait("the Mac's size") { mac.text.contains("35 100") }
        // And the phone's own resize applies again once it types.
        manager.resize(id, cols: 60, rows: 20, from: phone)
        manager.input(id, Data("echo d; stty size\n".utf8), from: phone)
        wait("the phone's new size") { phone.text.contains("20 60") }
    }

    func testAMacSessionStartsInTheTerminalsFolderWithItsEnvironmentAndSaysItIsOne() throws {
        let folder = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac,
                                  environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "FROM_WINDOW": "yes"],
                                  directory: folder)
        let mac = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        manager.input(id, Data("echo \"[$FROM_WINDOW|$\(RemoteShell.sessionVariable)|$(pwd -P)]\"\n".utf8), from: mac)
        // As the kernel names it (Foundation's own resolving leaves /private off).
        let real = try XCTUnwrap(realpath(folder.path, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) })
        let expected = "[yes|\(id)|\(real)]"
        wait("the window's environment and folder") { mac.text.contains(expected) }

        let info = try XCTUnwrap(manager.sessions.first { $0.id == id })
        XCTAssertTrue(info.isOnMac)
        let detail = try XCTUnwrap(manager.details.first { $0.id == id })
        XCTAssertEqual(detail.origin, .mac)
        XCTAssertEqual(detail.macViewers, 1)
        XCTAssertFalse(detail.phoneAttached)
    }

    func testAPhonesSessionAlsoSaysItIsOneAndIsNotMarkedAsTheMacs() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let phone = Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.input(id, Data("echo \"[$\(RemoteShell.sessionVariable)]\"\n".utf8), from: phone)
        wait("the session's id in its environment") { phone.text.contains("[\(id)]") }
        XCTAssertFalse(try XCTUnwrap(manager.sessions.first { $0.id == id }).isOnMac)
        XCTAssertTrue(try XCTUnwrap(manager.details.first { $0.id == id }).phoneAttached)
    }

    func testTheMacsTerminalsDoNotUseUpThePhonesSessions() throws {
        for _ in 0..<RemoteShell.maxSessions { _ = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24) }
        XCTAssertThrowsError(try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)) {
            XCTAssertEqual($0 as? ShellError, .tooManySessions)
        }
        XCTAssertNoThrow(try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac))
    }

    func testViewersChangeIsReportedWhenSomeoneStartsOrStopsLooking() throws {
        let changes = Locked(0)
        manager.onViewersChange = { changes.set(changes.get() + 1) }
        let id = try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac)
        let mac = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        wait("attach reported") { changes.get() == 1 }
        manager.detach(client: mac)
        wait("detach reported") { changes.get() == 2 }
        XCTAssertEqual(manager.details.first { $0.id == id }?.macViewers, 0)
    }

    /// A Mac terminal that can't keep up holds the shell's output back, for
    /// everyone, instead of it piling up; nothing is lost once it catches up.
    func testAPausedViewerHoldsOutputBackUntilItResumes() throws {
        let id = try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac)
        let mac = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        manager.input(id, Data("echo ready-$((1+1))\n".utf8), from: mac)
        wait("ready") { mac.text.contains("ready-2") }

        manager.setOutputPaused(id, true, by: mac)
        manager.input(id, Data("echo held-$((2+2))\n".utf8), from: mac)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(mac.text.contains("held-4"), "nothing is read from the shell while a viewer is paused")
        manager.setOutputPaused(id, false, by: mac)
        wait("delivered after resuming") { mac.text.contains("held-4") }
    }

    func testAPausedViewerThatLeavesNoLongerHoldsOutputBack() throws {
        let id = try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac)
        let mac = Client(), phone = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.setOutputPaused(id, true, by: mac)
        manager.input(id, Data("echo after-$((5+5))\n".utf8), from: phone)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(phone.text.contains("after-10"))
        manager.detach(client: mac)
        wait("the phone gets it once the Mac terminal is gone") { phone.text.contains("after-10") }
    }

    func testASessionEndsWhilePaused() throws {
        let id = try manager.open(phoneLabel: "This Mac", cols: 80, rows: 24, origin: .mac)
        let mac = Client()
        try manager.attach(id, client: mac, cols: 80, rows: 24, shared: true)
        manager.setOutputPaused(id, true, by: mac)
        manager.close(id)
        wait("ended") { mac.exitStatus != nil }
        XCTAssertEqual(manager.sessions.first { $0.id == id }?.running, false)
    }

    func testSomeoneWhoIsNotAViewerCannotPauseASession() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let phone = Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.setOutputPaused(id, true, by: phone)
        manager.input(id, Data("echo still-$((6+1))\n".utf8), from: phone)
        wait("output keeps coming") { phone.text.contains("still-7") }
    }
}
#endif
