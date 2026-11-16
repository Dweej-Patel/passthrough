import Foundation
import Network
import PassthroughCore

/// An iPad's side of "Internet through iPhone": the Mac's role in the
/// wireless link, run inside the iPad's tunnel extension.
///
/// The iPad advertises on the iPhone's Personal Hotspot and the iPhone dials
/// it (an iOS extension gets no incoming connections from the iPad, but the
/// reverse works: Spikes/LinkProbe). Each link is proved both ways, then one
/// long-lived loopback SOCKS forwarder sends every stream over whichever link
/// is current, so the iPad's tun2socks never restarts when a link is replaced.
/// While there is no link, streams fail at once: with the tunnel holding every
/// route, the iPad is then offline on purpose rather than on hotspot data.
@MainActor
public final class HotspotClient {
    public var onStatusChange: ((HotspotStatus) -> Void)?
    public private(set) var status = HotspotStatus(phase: .waiting) {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public let localPort: UInt16
    /// The listener's port once it listens (tests dial it directly).
    public var listenerPort: UInt16? { watcher.listenerPort }

    private let clientID: String
    private let socksPort: UInt16
    private let controlPort: UInt16
    private let name: String
    private let upstream: @Sendable () -> UpstreamPhone?
    private let watcher: WirelessWatcher
    private let current = CurrentLink()
    private var forwarder: LocalForwarder?
    private var control: ControlClient?
    private var controlDevice: PhoneDevice?
    private var retry: Task<Void, Never>?

    /// `identity`: this iPad's TLS identity (the iPhone pins its certificate).
    /// `upstream` must be safe to call from any thread (the listener asks for the link key).
    public init(clientID: String, name: String, identity: @escaping () throws -> MacIdentity,
                upstream: @escaping @Sendable () -> UpstreamPhone?,
                provenAddresses: ProvenAddressStore = MemoryProvenAddressStore(),
                localPort: UInt16 = PassthroughProtocol.defaultLocalSOCKSPort,
                socksPort: UInt16 = PassthroughProtocol.defaultSOCKSPort,
                controlPort: UInt16 = PassthroughProtocol.defaultControlPort) {
        self.clientID = clientID
        self.socksPort = socksPort
        self.controlPort = controlPort
        self.name = name
        self.upstream = upstream
        self.localPort = localPort
        watcher = WirelessWatcher(macTag: { WirelessLink.macTag(clientID: clientID) }, identity: identity, phones: {
            guard let phone = upstream() else { return [] }
            return [WirelessPhone(phoneID: phone.phoneID, linkKey: phone.linkKey, isAndroid: false,
                                  label: phone.name, pairingSlot: "upstream")]
        }, provenAddresses: provenAddresses)
        watcher.peerToPeer = false   // the iPhone's hotspot only
    }

    /// Starts listening for the iPhone and serving the loopback SOCKS port.
    public func start() throws {
        guard forwarder == nil else { return }
        let device = PhoneDevice(id: "hotspot", kind: .iPhone, medium: .wireless, label: upstream()?.name ?? "iPhone",
                                 pairingSlot: "upstream", link: current)
        let forwarder = LocalForwarder(device: device, remotePort: socksPort, localPort: localPort)
        try forwarder.start()
        self.forwarder = forwarder
        watcher.onDevicesChange = { [weak self] devices in self?.linked(devices.first) }
        watcher.start()

        ptLog(.info, "hotspot: waiting for \(upstream()?.name ?? "the iPhone") to dial in")
    }

    public func stop() {
        retry?.cancel(); retry = nil
        control?.close(); control = nil
        controlDevice = nil
        current.device = nil
        watcher.onDevicesChange = nil
        watcher.stop()
        forwarder?.stop()
        forwarder = nil
        status = HotspotStatus(phase: .waiting)
    }

    /// The iPhone was forgotten or re-paired (perhaps with another iPhone):
    /// drop every link, so only the iPhone paired now links again, proving
    /// the new credentials.
    public func credentialsChanged() {
        watcher.linkedPhoneIDs.forEach(watcher.drop(phoneID:))
        linked(nil)
        status = HotspotStatus(phase: .waiting, phoneName: upstream()?.name, rx: counters.rx, tx: counters.tx)
    }

    /// Bytes this iPad sent through the iPhone, for the status.
    public var counters: ByteCounter.Snapshot { forwarder?.counter.snapshot() ?? .zero }

    private func linked(_ device: PhoneDevice?) {
        current.device = device
        guard device?.id != controlDevice?.id || device == nil else { return }
        retry?.cancel(); retry = nil
        control?.close(); control = nil
        controlDevice = device
        guard let device else {
            if status.phase == .online { ptLog(.info, "hotspot: \(status.phoneName ?? "the iPhone") went out of reach") }
            // A refusal, or the iPhone's goodbye, still explains why it's waiting.
            let keepMessage = status.phase == .refused || status.phase == .waiting
            status = HotspotStatus(phase: status.phase == .refused ? .refused : .waiting, phoneName: upstream()?.name,
                                   rx: counters.rx, tx: counters.tx, message: keepMessage ? status.message : nil)
            return
        }
        openControl(device)
    }

    /// The control channel proves the pairing both ways and brings the iPhone's
    /// status (its name, radio, battery, IPv6). It's what puts this iPad in the
    /// iPhone's "Sharing with" list.
    private func openControl(_ device: PhoneDevice) {
        guard let phone = upstream() else { return }
        let identity = ControlClient.Identity(clientID: clientID, name: name, token: phone.token)
        let client = ControlClient(device: device, port: controlPort, identity: identity) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: device) }
        }
        control = client
        client.connect()
    }

    private func handle(_ event: ControlClient.Event, from device: PhoneDevice) {
        guard controlDevice?.id == device.id else { return }
        let counters = self.counters
        switch event {
        case .welcomed(paired: true):
            ptLog(.info, "hotspot: \(upstream()?.name ?? "the iPhone") linked")
            status = HotspotStatus(phase: .online, phoneName: status.phoneName ?? upstream()?.name, radio: status.radio,
                                   battery: status.battery, ipv6: status.ipv6, since: status.since ?? Date(),
                                   rx: counters.rx, tx: counters.tx)
        case .welcomed(paired: false):
            ptLog(.warning, "hotspot: the iPhone doesn't know this iPad any more")
            status = HotspotStatus(phase: .refused, phoneName: upstream()?.name, rx: counters.rx, tx: counters.tx,
                                   message: "\(upstream()?.name ?? "The iPhone") no longer knows this iPad. Pair them again.")
        case let .status(device, _, _, _):
            guard status.phase == .online else { return }
            status.phoneName = device.deviceName
            status.radio = device.radio
            status.battery = device.battery
            status.ipv6 = device.ipv6
            status.rx = counters.rx
            status.tx = counters.tx
        case .disconnected(let error):
            control = nil
            switch error as? ControlClient.ControlError {
            case .proofFailed?:
                ptLog(.warning, "hotspot: the iPhone couldn't prove this iPad's pairing")
                status = HotspotStatus(phase: .refused, phoneName: upstream()?.name, rx: counters.rx, tx: counters.tx,
                                       message: "\(upstream()?.name ?? "The iPhone") no longer knows this iPad. Pair them again.")
                return
            case let .incompatible(_, phoneIsOlder)?:
                status = HotspotStatus(phase: .refused, phoneName: upstream()?.name, rx: counters.rx, tx: counters.tx,
                                       message: phoneIsOlder ? "Update Passthrough on \(upstream()?.name ?? "the iPhone")."
                                                             : "Update Passthrough on this iPad.")
                return
            case nil:
                break
            }
            if status.phase == .online {
                status.phase = .reconnecting
                ptLog(.info, "hotspot: control channel closed (\(error?.localizedDescription ?? "closed")); retrying")
            }
            // The link may still be up (the control stream alone closed): try again shortly.
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let device = self.current.device, device.id == self.controlDevice?.id else { return }
                self.openControl(device)
            }
        case .goodbye:
            // Turned off on purpose: say so now. (A link that merely dropped is
            // held for a while to resume, and says nothing until then.)
            let name = status.phoneName ?? upstream()?.name ?? "the iPhone"
            ptLog(.info, "hotspot: Passthrough was turned off on \(name)")
            status = HotspotStatus(phase: .waiting, phoneName: status.phoneName ?? upstream()?.name, rx: counters.rx, tx: counters.tx,
                                   message: "Passthrough was turned off on \(name).")
        case .paired, .pairingFailed, .linked, .shellGranted:
            break
        }
    }
}

/// The link streams go over: whichever wireless session is current. With
/// none, a stream fails at once (the guard: nothing waits, nothing leaks).
final class CurrentLink: PhoneLink, @unchecked Sendable {
    private let lock = NSLock()
    private var _device: PhoneDevice?
    var device: PhoneDevice? {
        get { lock.withLock { _device } }
        set { lock.withLock { _device = newValue } }
    }

    func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void) {
        guard let device else { completion(.failure(MuxError.linkClosed)); return }
        device.connect(port: port, queue: queue, completion: completion)
    }
}
