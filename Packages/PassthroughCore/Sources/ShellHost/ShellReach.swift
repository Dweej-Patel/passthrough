#if os(macOS)
import Foundation
import IrohTransport
import PassthroughCore

/// What the Mac tells phones about reaching its shell: the iroh details in a
/// cable grant, and the `macInfo` sent after `ready` on every path. The app
/// keeps one current copy (cached values only: `macInfo` is built on a
/// listener's queue for every handshake).
public struct ShellReach: Equatable, Sendable {
    /// The "Reach this Mac from anywhere" setting.
    public var reachAnywhere: Bool
    /// The running endpoint's id; nil while it is not up.
    public var endpointID: String?
    /// The relay the running endpoint is reachable through, when known.
    public var homeRelay: String?
    public var relay: IrohRelayConfig
    /// Where phones can dial the TLS listener (`LocalAddresses.advertisable()`).
    public var addresses: [String]

    public init(reachAnywhere: Bool, endpointID: String? = nil, homeRelay: String? = nil,
                relay: IrohRelayConfig = IrohRelayConfig(), addresses: [String] = []) {
        self.reachAnywhere = reachAnywhere
        self.endpointID = endpointID
        self.homeRelay = homeRelay
        self.relay = relay
        self.addresses = addresses
    }

    public struct Iroh: Equatable, Sendable {
        public var id: String
        public var relay: String?
        public var token: String?
    }

    /// The iroh details to hand out, or nil while reaching from anywhere is off
    /// or the endpoint is not up. A custom relay is given with its token (when
    /// one is set); otherwise the endpoint's current home relay, without one,
    /// and nothing until that home relay is known.
    public var iroh: Iroh? {
        guard reachAnywhere, let endpointID else { return nil }
        if let url = relay.url {
            return Iroh(id: endpointID, relay: url, token: relay.token.flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let homeRelay else { return nil }
        return Iroh(id: endpointID, relay: homeRelay, token: nil)
    }

    /// The `macInfo` envelope. With reaching from anywhere off it has no iroh
    /// details, so phones drop theirs. While the endpoint is still starting
    /// (or, on n0's relays, has no home relay yet) there is none at all, so
    /// phones keep what they have.
    public func macInfo() -> ShellEnvelope? {
        if reachAnywhere && iroh == nil { return nil }
        var info = ShellEnvelope(t: ShellEnvelope.macInfo)
        info.addresses = addresses
        if let iroh {
            info.irohID = iroh.id
            info.irohRelay = iroh.relay
            info.relayToken = iroh.token
        }
        return info
    }
}
#endif
