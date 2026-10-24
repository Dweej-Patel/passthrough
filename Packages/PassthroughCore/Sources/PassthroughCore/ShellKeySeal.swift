import CryptoKit
import Foundation

/// How a shell key a Mac grants over the cable waits for the app: sealed to
/// the app's sealing key, whose private half needs the user (the Secure
/// Enclave with user presence on iOS; inside the shell key vault on Android).
/// The tunnel extension (Android: the service) holds only the public half, so
/// what it stores is useless until the user unlocks the app. Mirrors
/// ShellKeySeal.kt; protocol/fixtures.json has a vector both must open.
///
/// ECIES over P-256: an ephemeral key agrees with the sealing key; HKDF-SHA256
/// (no salt, info = `infoLabel` ‖ ephemeral public key ‖ sealing public key,
/// both X9.63) gives a 256-bit AES-GCM key; the Mac's ID is the associated
/// data, so a sealed key can't pass for another Mac's.
///
/// `[version 1][ephemeral public key, X9.63, 65][nonce 12][ciphertext][tag 16]`
public enum ShellKeySeal {
    public static let version: UInt8 = 1
    static let infoLabel = Data("passthrough.shell.pending.v1".utf8)
    static let publicKeySize = 65
    static let overhead = 1 + publicKeySize + 12 + 16

    /// What a pending entry holds.
    public enum Format: Equatable, Sendable {
        case sealed
        /// A bare 32-byte key, as builds before sealing stored it: discarded, the Mac grants again.
        case plain
        case unknown
    }

    public static func format(of stored: Data) -> Format {
        if stored.count == 32 { return .plain }
        if stored.count > overhead, stored.first == version { return .sealed }
        return .unknown
    }

    public static func associatedData(clientID: String) -> Data {
        Data("passthrough.shell.key:".utf8) + Data(clientID.utf8)
    }

    public static func seal(_ key: Data, to recipient: P256.KeyAgreement.PublicKey, clientID: String) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let symmetric = derive(shared, ephemeral: ephemeral.publicKey, recipient: recipient)
        let box = try AES.GCM.seal(key, using: symmetric, authenticating: associatedData(clientID: clientID))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return Data([version]) + ephemeral.publicKey.x963Representation + combined
    }

    public enum OpenError: Error, Equatable {
        /// Not a sealed entry this build reads, or it was altered, or sealed to another key.
        case unreadable
        /// The sealing key refused (the user's presence isn't vouched for): try again after an unlock.
        case unavailable
    }

    /// `agree` runs the key agreement with the sealing key's private half (in
    /// the Secure Enclave, say); an error it throws means `.unavailable`.
    public static func open(_ sealed: Data, clientID: String, recipient: P256.KeyAgreement.PublicKey,
                            agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) -> Result<Data, OpenError> {
        guard format(of: sealed) == .sealed else { return .failure(.unreadable) }
        let bytes = [UInt8](sealed)
        guard let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: bytes[1..<(1 + publicKeySize)]) else {
            return .failure(.unreadable)
        }
        let shared: SharedSecret
        do { shared = try agree(ephemeral) } catch { return .failure(.unavailable) }
        let symmetric = derive(shared, ephemeral: ephemeral, recipient: recipient)
        guard let box = try? AES.GCM.SealedBox(combined: bytes[(1 + publicKeySize)...]),
              let key = try? AES.GCM.open(box, using: symmetric, authenticating: associatedData(clientID: clientID)) else {
            return .failure(.unreadable)
        }
        return .success(key)
    }

    /// What the app does with a pending entry at an unlock.
    public enum Adoption: Equatable, Sendable {
        /// Opened: into the vault with it, then delete the entry.
        case key(Data)
        /// An older build's bare key, or nothing this build can open: delete
        /// it; the Mac grants again on its next cable connection.
        case discard
        /// The sealing key wasn't available just now: leave it for the next unlock.
        case keep
    }

    public static func adopt(_ stored: Data, clientID: String, recipient: P256.KeyAgreement.PublicKey,
                             agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) -> Adoption {
        switch open(stored, clientID: clientID, recipient: recipient, agree: agree) {
        case let .success(key): return .key(key)
        case .failure(.unavailable): return .keep
        case .failure(.unreadable): return .discard
        }
    }

    private static func derive(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey, recipient: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                       sharedInfo: infoLabel + ephemeral.x963Representation + recipient.x963Representation,
                                       outputByteCount: 32)
    }
}
