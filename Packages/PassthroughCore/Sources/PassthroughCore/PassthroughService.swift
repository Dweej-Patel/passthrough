import Foundation

/// Bundles the SOCKS5 server and the control channel behind one switch.
/// Hosted either inside the packet tunnel extension or the foreground app.
public final class PassthroughService: @unchecked Sendable {
    public struct Options: Sendable {
        public var socksPort: UInt16 = PassthroughProtocol.defaultSOCKSPort
        public var controlPort: UInt16 = PassthroughProtocol.defaultControlPort
        public var cellularOnly = false
        public var allowUDP = true
        public var disableAuth = false
        /// Dev servers on a Mac legitimately talk to loopback/LAN targets.
        public var refuseLocalDestinations = true
        public init() {}
    }

    public let registry: PairingRegistry
    public let options: Options
    /// Fires when "cellular only" moves new connections to another network, or back.
    public var onEgressChange: (@Sendable (Egress) -> Void)?
    public private(set) var socks: SOCKS5Server?
    public private(set) var control: ControlServer?
    public var counter: ByteCounter { socks?.counter ?? fallbackCounter }
    private let fallbackCounter = ByteCounter()
    private let statusProvider: @Sendable () -> DeviceStatus
    public var onClientsChanged: (@Sendable ([ConnectedMac]) -> Void)?
    public private(set) var startedAt: Date?

    public init(registry: PairingRegistry, options: Options = Options(), statusProvider: @escaping @Sendable () -> DeviceStatus) {
        self.registry = registry
        self.options = options
        self.statusProvider = statusProvider
    }

    public var isRunning: Bool { socks?.isRunning ?? false }

    public func start() throws {
        guard !isRunning else { return }
        Self.raiseFileDescriptorLimit()
        var config = SOCKS5Server.Configuration()
        config.port = options.socksPort
        config.cellularOnly = options.cellularOnly
        config.allowUDP = options.allowUDP
        config.refuseLocalDestinations = options.refuseLocalDestinations
        let registry = self.registry
        var authenticator: SOCKS5Server.Authenticator? = nil
        if !options.disableAuth {
            authenticator = { user, password in registry.verify(clientID: user, token: password) }
        }
        let socks = SOCKS5Server(configuration: config, authenticator: authenticator)
        socks.onEgressChange = { [weak self] egress in self?.onEgressChange?(egress) }
        let provider = statusProvider
        let control = ControlServer(port: options.controlPort, socksPort: options.socksPort, registry: registry,
                                    counter: socks.counter) { [weak socks] in
            var status = provider()
            status.ipv6 = socks?.egressSupportsIPv6
            return status
        }
        control.onClientsChanged = { [weak self] macs in self?.onClientsChanged?(macs) }
        try socks.start()
        do { try control.start() } catch { socks.stop(); throw error }
        self.socks = socks
        self.control = control
        startedAt = Date()
    }

    public func stop() {
        control?.stop()
        socks?.stop()
        control = nil
        socks = nil
        startedAt = nil
    }

    public var connectedMacs: [ConnectedMac] { control?.connectedMacs ?? [] }

    /// Every proxied connection costs two descriptors (the stream from the Mac
    /// and the one to the internet). iOS starts processes at 256, which a
    /// speed test or a busy browser exhausts; new connections then fail.
    static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let before = limit.rlim_cur
        limit.rlim_cur = min(rlim_t(OPEN_MAX), limit.rlim_max)
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            limit.rlim_cur = min(4096, limit.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
        _ = getrlimit(RLIMIT_NOFILE, &limit)
        ptLog(.info, "File descriptor limit: \(before) → \(limit.rlim_cur)")
    }
}
