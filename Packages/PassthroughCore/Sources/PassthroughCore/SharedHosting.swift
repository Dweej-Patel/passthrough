import Foundation

/// How the iOS app and its tunnel extension build and read the same service.
/// Settings and device facts live in the App Group defaults; either process
/// can host the service, and the app reads its stats either way.
extension PassthroughService.Options {
    private enum Key {
        static let cellularOnly = "cellularOnly"
        static let allowUDP = "allowUDP"
        static let socksPort = "socksPort"
        static let controlPort = "controlPort"
    }

    /// Reads the options the app stored in the tunnel's provider configuration.
    public init(providerConfiguration config: [String: Any]) {
        self.init()
        cellularOnly = config[Key.cellularOnly] as? Bool ?? false
        allowUDP = config[Key.allowUDP] as? Bool ?? true
        socksPort = UInt16(config[Key.socksPort] as? Int ?? Int(PassthroughProtocol.defaultSOCKSPort))
        controlPort = UInt16(config[Key.controlPort] as? Int ?? Int(PassthroughProtocol.defaultControlPort))
    }

    public var providerConfiguration: [String: Any] {
        [Key.cellularOnly: cellularOnly, Key.allowUDP: allowUDP,
         Key.socksPort: Int(socksPort), Key.controlPort: Int(controlPort)]
    }
}

extension PassthroughService {
    /// A service that reports the device facts the app keeps in `defaults`, and
    /// records there which network "cellular only" is using (see `Egress`).
    /// Pass the app's own `registry` when hosting in the app process.
    public static func sharing(_ store: UserDefaults, registry: PairingRegistry? = nil, options: Options, hosting: String) -> PassthroughService {
        nonisolated(unsafe) let defaults = store  // UserDefaults is thread-safe
        let registry = registry ?? PairingRegistry(defaults: defaults, secrets: KeychainSecrets(accessGroup: PassthroughProtocol.appGroup))
        let service = PassthroughService(registry: registry, options: options) {
            DeviceStatus(deviceName: defaults.string(forKey: SharedKeys.deviceName) ?? "iPhone",
                         radio: defaults.string(forKey: SharedKeys.radio),
                         battery: defaults.object(forKey: SharedKeys.battery) as? Double,
                         hosting: hosting)
        }
        service.onEgressChange = { egress in defaults.set(egress.rawValue, forKey: SharedKeys.egress) }
        defaults.set(Egress.cellular.rawValue, forKey: SharedKeys.egress)
        return service
    }

    /// Current counters, connected Macs and start time, in the shape the app shows.
    public func stats() -> ProviderStats {
        let snap = counter.snapshot()
        return ProviderStats(rx: snap.rx, tx: snap.tx, active: snap.active, totalConnections: snap.totalConnections,
                             macs: connectedMacs, startedAt: startedAt)
    }
}
