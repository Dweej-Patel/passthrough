import Foundation
import PassthroughCore
import PhoneTransport

/// Phones linked for the wireless link, kept in the Keychain: each phone's
/// ID and how to treat it, and the link key sent to it (one per pairing slot,
/// so a phone that relinks gets the same key). Thread-safe: the wireless
/// listener looks keys up off the main thread.
final class LinkStore: @unchecked Sendable {
    private static let phonesAccount = "wireless.phones"
    private let lock = NSLock()
    private var cached: [WirelessPhone]

    init() {
        let json = Keychain.read(Self.phonesAccount).flatMap { $0.data(using: .utf8) }
        cached = json.flatMap { try? JSONDecoder().decode([WirelessPhone].self, from: $0) } ?? []
    }

    var phones: [WirelessPhone] { lock.lock(); defer { lock.unlock() }; return cached }

    /// The key for phones in `slot`, created on first use.
    func key(forSlot slot: String) -> Data {
        let account = "link." + slot
        if let stored = Keychain.read(account).flatMap({ Data(base64Encoded: $0) }), stored.count == 32 { return stored }
        let key = WirelessLink.randomBytes(32)
        _ = Keychain.write(key.base64EncodedString(), account: account)
        return key
    }

    /// A slot holds one phone's pairing, so a phone that relinks with a new
    /// ID (reinstalled) replaces the slot's old entry.
    func record(_ phone: WirelessPhone) {
        lock.lock()
        cached.removeAll { $0.phoneID == phone.phoneID || $0.pairingSlot == phone.pairingSlot }
        cached.append(phone)
        let list = cached
        lock.unlock()
        save(list)
    }

    /// Forgets every phone paired through `slot` and the key they used.
    func forget(slot: String) {
        lock.lock()
        cached.removeAll { $0.pairingSlot == slot }
        let list = cached
        lock.unlock()
        save(list)
        Keychain.delete("link." + slot)
    }

    private func save(_ list: [WirelessPhone]) {
        guard let data = try? JSONEncoder().encode(list), let text = String(data: data, encoding: .utf8) else { return }
        _ = Keychain.write(text, account: Self.phonesAccount)
    }
}
