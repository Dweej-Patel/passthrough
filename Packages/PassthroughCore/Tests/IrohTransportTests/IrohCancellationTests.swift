import XCTest
@testable import IrohTransport

/// Real iroh, no relays, nothing on the network: a dial that can't answer
/// runs to iroh's own 30 s limit unless its endpoint is closed.
final class IrohCancellationTests: XCTestCase {
    /// An endpoint id nobody is listening as.
    private func goneID() async throws -> String {
        let gone = try await IrohEndpointHost(secretKey: IrohEndpointHost.newSecretKey(), relayEnabled: false)
        let id = gone.endpointID
        await gone.shutdown()
        return id
    }

    /// A cancelled dial closes its endpoint, so it ends in seconds, not at 30 s.
    func testACancelledDialEndsSoon() async throws {
        let id = try await goneID()
        let dialer = IrohShellDialer { _ in try await IrohDialer(relayEnabled: false) }
        let started = Date()
        let dial = Task { try await dialer.connect(irohID: id, relayURL: nil, relayToken: nil, addresses: ["127.0.0.1:9"]) }
        try await Task.sleep(nanoseconds: 500_000_000)
        dial.cancel()
        _ = try? await dial.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        dialer.shutdown()
    }

    /// `answers` keeps to its timeout when the endpoint doesn't answer.
    func testAnswersKeepsToItsTimeout() async throws {
        let id = try await goneID()
        let started = Date()
        let answered = await IrohDialer.answers(id: id, relayURL: "https://127.0.0.1:9/", timeout: 1)
        XCTAssertFalse(answered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
