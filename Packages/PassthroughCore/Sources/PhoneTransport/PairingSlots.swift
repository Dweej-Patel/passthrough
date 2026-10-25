import Foundation

/// Where the Mac keeps pairing tokens (the Keychain in the app), as text by slot.
public protocol PairingTokenStore {
    func read(_ slot: String) -> String?
    @discardableResult func write(_ token: String, slot: String) -> Bool
    func delete(_ slot: String)
}

/// Finds the token that proves a phone's pairing. Every iPhone once shared
/// one slot, so a token there may be any iPhone's: it is tried for an iPhone
/// whose own slot is empty, and moves into that slot once the phone has
/// proved it holds the same one. Paired iPhones so carry on without pairing again.
public enum PairingSlots {
    public struct Stored: Equatable, Sendable {
        public let token: String
        public let slot: String
        public init(token: String, slot: String) { self.token = token; self.slot = slot }
        /// From the shared iPhone slot: only a guess at this phone's pairing,
        /// so a phone that can't prove it counts as unpaired, not as an impostor.
        public var isShared: Bool { slot == PhoneDevice.sharediPhonePairingSlot }
    }

    public static func lookup(for device: PhoneDevice, in store: PairingTokenStore) -> Stored? {
        if let token = store.read(device.pairingSlot) { return Stored(token: token, slot: device.pairingSlot) }
        guard device.mayUseSharedSlot, let token = store.read(PhoneDevice.sharediPhonePairingSlot) else { return nil }
        return Stored(token: token, slot: PhoneDevice.sharediPhonePairingSlot)
    }

    /// The slots that hold `device`'s own pairing: its own slot when it has a
    /// token, and the shared iPhone slot only when the phone proved the token
    /// there on the open channel (`provedShared`: it stays there when moving
    /// it failed). A shared token not yet proved may be another iPhone's, so
    /// it neither makes this one count as paired nor goes when this one
    /// forgets its pairing; it moves once its owner proves it (`adopt`), and
    /// can be forgotten with no iPhone attached.
    public static func provenSlots(for device: PhoneDevice, provedShared: Bool, in store: PairingTokenStore) -> [String] {
        var slots: [String] = []
        if store.read(device.pairingSlot) != nil { slots.append(device.pairingSlot) }
        if provedShared, device.mayUseSharedSlot, store.read(PhoneDevice.sharediPhonePairingSlot) != nil {
            slots.append(PhoneDevice.sharediPhonePairingSlot)
        }
        return slots
    }

    /// `device` proved `stored`: a token from the shared slot is this phone's,
    /// so it moves to the phone's own slot. The shared copy is deleted only
    /// once the new one reads back. False if nothing moved.
    @discardableResult
    public static func adopt(_ stored: Stored, for device: PhoneDevice, in store: PairingTokenStore) -> Bool {
        guard stored.isShared, device.mayUseSharedSlot,
              store.write(stored.token, slot: device.pairingSlot), store.read(device.pairingSlot) == stored.token else { return false }
        store.delete(PhoneDevice.sharediPhonePairingSlot)
        return true
    }
}
