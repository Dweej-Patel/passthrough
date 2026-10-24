#if os(macOS)
import Foundation
import Network
import XCTest
import PassthroughCore
import PhoneTransport
import TestSupport

/// What Network.framework tells about a connection a TLS `NWListener` has
/// just accepted, before it is started: `ShellListener` checks the Mac's
/// address it arrived on right there, before TLS.
@available(macOS 15, *)
final class AcceptedPathTests: XCTestCase {
    /// An accepted connection knows its path, and the Mac's address on it,
    /// before it is started and before TLS (the client here never speaks
    /// TLS), over IPv4 and IPv6 alike. If this ever stops holding,
    /// `ShellListener` waits for the path instead (`awaitArrival`).
    func testAnAcceptedConnectionKnowsItsLocalAddressBeforeItStarts() throws {
        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        for loopback in ["127.0.0.1", "::1"] {
            let queue = DispatchQueue(label: "accepted-path")
            let seen = Locked<(state: String, local: String?, interface: String?)?>(nil)
            let listener = try NWListener(using: try identity.tlsListenerParameters())
            let ready = expectation(description: "listening")
            let accepted = expectation(description: "accepted")
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { connection in
                let path = connection.currentPath
                seen.set(("\(connection.state)", path?.localEndpoint.map(PeerAddress.host(of:)),
                          path?.availableInterfaces.first?.name))
                connection.cancel()
                accepted.fulfill()
            }
            listener.start(queue: queue)
            wait(for: [ready], timeout: 5)
            let client = NWConnection(host: NWEndpoint.Host(loopback), port: listener.port!, using: .tcp)
            client.start(queue: DispatchQueue(label: "accepted-path-client"))
            wait(for: [accepted], timeout: 5)
            client.cancel(); listener.cancel()
            let result = try XCTUnwrap(seen.get())
            XCTAssertEqual(result.state, "setup", "not started yet")
            XCTAssertEqual(result.local, loopback)
            XCTAssertEqual(result.interface, "lo0")
        }
    }
}
#endif
