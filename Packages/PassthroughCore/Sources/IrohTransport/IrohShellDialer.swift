import Foundation
import PassthroughCore

/// The phone's iroh dialer for `ShellClient`. Each `connect` binds a fresh
/// endpoint (an ephemeral key, never stored) using the Mac's relay from the
/// grant; `shutdown` closes every endpoint it bound, ending dials in progress
/// and their streams.
public final class IrohShellDialer: ShellIrohDialing, @unchecked Sendable {
    private let makeDialer: @Sendable (IrohRelayConfig) async throws -> IrohDialer
    private let lock = NSLock()
    /// Bumped by `shutdown`: a dial that binds its endpoint after that closes it at once.
    private var epoch = 0
    private var dialers: [IrohDialer] = []

    public convenience init() {
        self.init { try await IrohDialer(relay: $0) }
    }

    /// Tests bind endpoints with relays off.
    init(makeDialer: @escaping @Sendable (IrohRelayConfig) async throws -> IrohDialer) {
        self.makeDialer = makeDialer
    }

    public func connect(irohID: String, relayURL: String?, relayToken: String?, addresses: [String]) async throws -> any ByteStream {
        let started = lock.withLock { epoch }
        // The Mac's relay (a custom one with its token, or its n0 home relay)
        // is this endpoint's relay too; none known: n0's defaults.
        let dialer = try await makeDialer(IrohRelayConfig(url: relayURL, token: relayURL == nil ? nil : relayToken))
        let current: Bool = lock.withLock {
            guard epoch == started, !Task.isCancelled else { return false }
            dialers.append(dialer)
            return true
        }
        guard current else {
            await dialer.shutdown()
            throw IrohTransportError.endpointClosed
        }
        return try await dialer.connect(to: irohID, relayURL: relayURL, addresses: addresses, alpn: IrohShell.alpn)
    }

    public func path(of stream: any ByteStream) -> ShellPath {
        switch (stream as? IrohByteStream)?.pathKind {
        case .direct: .direct
        case .relay: .relay
        case .unknown, nil: .unknown
        }
    }

    public func shutdown() {
        let closing: [IrohDialer] = lock.withLock {
            epoch += 1
            defer { dialers = [] }
            return dialers
        }
        for dialer in closing { Task { await dialer.shutdown() } }
    }
}
