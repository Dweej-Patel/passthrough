import Foundation
import SystemConfiguration

/// Notices when the network interface a VPN session runs over joins another
/// network (the Mac's Wi-Fi moving from a phone's hotspot to the home network,
/// say). The session's endpoint route still points at the old gateway, so the
/// VPN must start over; waiting for its own timeouts leaves the kill switch
/// blocking everything for a minute.
///
/// Watches the interface's IPv4 addresses in the dynamic store. A change counts
/// once the interface has addresses again and they differ from the ones it had
/// when the watch started: an interface between networks (no address) is left
/// alone until the new address arrives. Nothing the VPN itself does touches
/// this key, so a restart can't trigger another.
final class UnderlayWatch {
    private let queue: DispatchQueue
    private let read: (_ key: String) -> [String]
    private var store: SCDynamicStore?
    private var key: String?
    private var addresses: [String] = []
    private var onMove: (() -> Void)?

    /// `read` returns a key's IPv4 addresses; tests replace it.
    init(queue: DispatchQueue, read: ((String) -> [String])? = nil) {
        self.queue = queue
        self.read = read ?? { key in
            guard let store = SCDynamicStoreCreate(nil, "PassthroughUnderlayRead" as CFString, nil, nil) else { return [] }
            return Self.addresses(in: SCDynamicStoreCopyValue(store, key as CFString))
        }
    }

    /// Starts watching `interface`; `onMove` runs on the queue when it has moved.
    func start(interface: String, onMove: @escaping () -> Void) {
        stop()
        let key = "State:/Network/Interface/\(interface)/IPv4"
        self.key = key
        self.onMove = onMove
        addresses = read(key)
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "PassthroughUnderlay" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<UnderlayWatch>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context) else {
            HelperLog.warn("vpn: cannot watch \(interface) for network changes")
            return
        }
        SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        key = nil
        onMove = nil
    }

    /// On the queue: the key changed.
    func changed() {
        guard let key, onMove != nil else { return }
        let now = read(key)
        guard Self.moved(from: addresses, to: now) else { return }
        addresses = now
        onMove?()
    }

    static func moved(from old: [String], to new: [String]) -> Bool {
        !new.isEmpty && Set(new) != Set(old)
    }

    static func addresses(in value: CFPropertyList?) -> [String] {
        (value as? [String: Any])?[kSCPropNetIPv4Addresses as String] as? [String] ?? []
    }
}
