import Darwin
import XCTest
@testable import HelperLogic

final class ProcessTableTests: XCTestCase {
    /// A TCP socket of ours listening on an ephemeral port (IPv4 or IPv6).
    private func listen(v6: Bool = false) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let bound: Int32
        if v6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = withUnsafePointer(to: &storage) { pointer -> UInt16 in
            v6 ? pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
               : pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        addTeardownBlock { close(fd) }
        return (fd, port)
    }

    func testFindsTheProcessListeningOnAPort() throws {
        for v6 in [false, true] {
            let (_, port) = try listen(v6: v6)
            let owners = ProcessTable.tcpListeners(port: port, among: [getpid()])
            XCTAssertEqual(owners.map(\.pid), [getpid()], "v6: \(v6)")
            XCTAssertEqual(owners.first?.uid, getuid())
            XCTAssertEqual(owners.first?.path, ProcessTable.executablePath(of: getpid()))
        }
    }

    /// The whole table too (what the helper does): this process is among
    /// the listeners, and a port nobody listens on has none.
    func testScansEveryProcess() throws {
        let (_, port) = try listen()
        XCTAssertTrue(ProcessTable.tcpListeners(port: port).contains { $0.pid == getpid() })
        let (fd, unused) = try listen()
        close(fd)
        XCTAssertEqual(ProcessTable.tcpListeners(port: unused, among: [getpid()]), [])
    }

    func testAConnectedSocketIsNotAListener() throws {
        let (_, port) = try listen()
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        // Our listener and our connected socket share the port number; only
        // one listens. (The client's local port differs; the listener counts once.)
        XCTAssertEqual(ProcessTable.tcpListeners(port: port, among: [getpid()]).count, 1)
    }

    func testExecutingIn() {
        let me = ProcessTable.executablePath(of: getpid())!
        let dir = (me as NSString).deletingLastPathComponent
        XCTAssertEqual(ProcessTable.processes(executingIn: dir, among: [getpid()]).map(\.pid), [getpid()])
        XCTAssertEqual(ProcessTable.processes(executingIn: dir + "/sub", among: [getpid()]), [])
        XCTAssertEqual(ProcessTable.processes(executingIn: (dir as NSString).deletingLastPathComponent, among: [getpid()]), [],
                       "only directly inside")
    }

    /// The kernel names executables by their real path: a staged engine in
    /// /var/run/passthrough/bin runs as /private/var/run/passthrough/bin/….
    func testDirectoriesAreComparedByRealPath() throws {
        let made = ProcessTable.realPath(NSTemporaryDirectory()) + "/pt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: made) }
        // The same directory through the /tmp or /var link.
        guard made.hasPrefix("/private/") else { throw XCTSkip("the temporary directory is not under /private") }
        let dir = String(made.dropFirst("/private".count))
        let real = ProcessTable.realPath(dir)
        XCTAssertEqual(real, made)
        XCTAssertTrue(ProcessTable.isDirectlyInside(real + "/openvpn", dir))
        XCTAssertFalse(ProcessTable.isDirectlyInside(real + "/sub/openvpn", dir))
        XCTAssertFalse(ProcessTable.isDirectlyInside("/tmp/openvpn", dir))
    }

    func testAllPIDsIncludesUsAndLaunchd() {
        let pids = ProcessTable.allPIDs()
        XCTAssertTrue(pids.contains(getpid()))
        XCTAssertTrue(pids.contains(1))
    }
}

final class ScreenSharingOwnersTests: XCTestCase {
    private let daemon = ScreenSharingOwners.daemonPath

    func testNothingListeningIsOff() {
        XCTAssertEqual(ScreenSharingOwners.verdict([]), .off)
    }

    func testLaunchdAloneOrWithScreensharingdIsGenuine() {
        XCTAssertEqual(ScreenSharingOwners.verdict([.init(pid: 1, uid: 0, path: "/sbin/launchd")]), .genuine)
        XCTAssertEqual(ScreenSharingOwners.verdict([.init(pid: 1, uid: 0, path: "/sbin/launchd"),
                                                    .init(pid: 812, uid: 0, path: daemon)]), .genuine)
    }

    func testAnyOtherOwnerIsAnImpostor() {
        let launchd = ProcessTable.Process(pid: 1, uid: 0, path: "/sbin/launchd")
        // A user's process bound 5900 while Screen Sharing is off.
        XCTAssertEqual(ScreenSharingOwners.verdict([.init(pid: 4242, uid: 501, path: "/Users/me/fake")]), .impostor)
        // Or alongside the real one (a more specific address on the same port).
        XCTAssertEqual(ScreenSharingOwners.verdict([launchd, .init(pid: 4242, uid: 501, path: "/tmp/x")]), .impostor)
        // screensharingd's path but not root: a copy run by the user.
        XCTAssertEqual(ScreenSharingOwners.verdict([launchd, .init(pid: 99, uid: 501, path: daemon)]), .impostor)
        // A process that could not be inspected proves nothing.
        XCTAssertEqual(ScreenSharingOwners.verdict([.init(pid: 99, uid: nil, path: nil)]), .impostor)
    }
}
