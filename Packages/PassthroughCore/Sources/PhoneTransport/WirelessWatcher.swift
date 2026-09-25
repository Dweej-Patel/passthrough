import Foundation
import PassthroughCore

/// A phone the Mac linked with over the cable, as the wireless watcher needs it.
public struct WirelessPhone: Codable, Equatable, Sendable {
    public var phoneID: String
    public var linkKey: Data
    public var isAndroid: Bool
    public var label: String
    public var pairingSlot: String
    /// The Wi-Fi Direct network an Android phone hosts for the Mac to join.
    public var network: String?
    public var passphrase: String?

    public init(phoneID: String, linkKey: Data, isAndroid: Bool, label: String, pairingSlot: String, network: String? = nil, passphrase: String? = nil) {
        self.phoneID = phoneID; self.linkKey = linkKey; self.isAndroid = isAndroid; self.label = label
        self.pairingSlot = pairingSlot; self.network = network; self.passphrase = passphrase
    }
}

/// Reports linked phones that dialed in over the wireless link. Runs the
/// Mac's `WirelessListener` while started.
@MainActor
public final class WirelessWatcher: DeviceWatcher {
    public let transport = WatchTransport.wireless
    public private(set) var status = WatchStatus() { didSet { if status != oldValue { onStatusChange?(status) } } }
    public var onDevicesChange: (([PhoneDevice]) -> Void)?
    public var onStatusChange: ((WatchStatus) -> Void)?

    private let macTag: @Sendable () -> String
    private let identity: () throws -> MacIdentity
    private let phones: @Sendable () -> [WirelessPhone]
    private var listener: WirelessListener?
    private var links: [String: (mux: Mux, device: PhoneDevice)] = [:]   // by phoneID
    private var order: [String] = []

    /// `phones` must be safe to call from any thread (the listener asks for keys).
    public init(macTag: @escaping @Sendable () -> String, identity: @escaping () throws -> MacIdentity, phones: @escaping @Sendable () -> [WirelessPhone]) {
        self.macTag = macTag
        self.identity = identity
        self.phones = phones
    }

    public func start() {
        guard listener == nil else { return }
        do {
            let phones = self.phones
            let listener = WirelessListener(identity: try identity(), macTag: macTag()) { id in
                phones().first { $0.phoneID == id }?.linkKey
            }
            listener.onLink = { [weak self] link in Task { @MainActor in self?.linked(link) } }
            try listener.start()
            self.listener = listener
            status = WatchStatus(state: .watching)
        } catch {
            ptLog(.error, "wireless: could not start: \(error.localizedDescription)")
            status = WatchStatus(state: .unavailable, hint: error.localizedDescription)
        }
    }

    public func stop() {
        listener?.stop()
        listener = nil
        links.values.forEach { $0.mux.close() }
        links.removeAll()
        order.removeAll()
        status = WatchStatus()
        publish()
    }

    private func linked(_ link: WirelessListener.Link) {
        guard listener != nil, let phone = phones().first(where: { $0.phoneID == link.phoneID }) else { link.mux.close(); return }
        let id = link.phoneID
        // A phone that comes back with a new session (it restarted, or was
        // gone too long to resume) replaces its old link. Report that as the
        // old device leaving and a new one arriving: the device ID is the same,
        // so a silent swap would leave the Mac using the closed link.
        if let old = links.removeValue(forKey: id) {
            order.removeAll { $0 == id }
            publish()
            old.mux.close()
        }
        let mux = link.mux
        mux.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.links[id]?.mux === mux else { return }
                ptLog(.info, "wireless: \(phone.label) went out of reach (\(error?.localizedDescription ?? "closed"))")
                self.links[id] = nil
                self.order.removeAll { $0 == id }
                self.publish()
            }
        }
        mux.onSuspend = { error in
            ptLog(.info, "wireless: \(phone.label) dropped (\(error.localizedDescription)); waiting for it to redial")
        }
        let device = PhoneDevice.wireless(phoneID: id, kind: phone.isAndroid ? .android : .iPhone, label: phone.label,
                                          pairingSlot: phone.pairingSlot, link: MuxLink(mux: mux))
        links[id] = (mux, device)
        if !order.contains(id) { order.append(id) }
        mux.start()
        ptLog(.info, "wireless: \(phone.label) linked")
        publish()
    }

    private func publish() {
        onDevicesChange?(order.compactMap { links[$0]?.device })
    }
}
