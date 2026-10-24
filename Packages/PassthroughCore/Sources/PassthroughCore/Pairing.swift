import Foundation
import notify
import CryptoKit

/// The secret a phone issues each Mac it pairs with: 32 random bytes as
/// unpadded URL-safe base64. The phone keeps only its SHA-256.
public enum PairingToken {
    public static let length = 43

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256, the form the phone stores.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `token` has the shape `generate()` produces; anything else was not issued by a phone.
    public static func isWellFormed(_ token: String) -> Bool {
        token.count == length && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Where a Mac's shell listener is and which certificate it presents. The
/// key itself is kept apart, in the secret store.
public struct ShellGrant: Codable, Equatable, Sendable {
    public var certSHA256: String
    public var port: UInt16
    public var addresses: [String]
    public var macName: String
    /// The Mac's iroh endpoint id and home relay, when it offers the shell over iroh.
    /// The relay's token is kept apart, in the secret store.
    public var irohID: String?
    public var irohRelay: String?

    public init(certSHA256: String, port: UInt16, addresses: [String], macName: String,
                irohID: String? = nil, irohRelay: String? = nil) {
        self.certSHA256 = certSHA256; self.port = port; self.addresses = addresses; self.macName = macName
        self.irohID = irohID; self.irohRelay = irohRelay
    }
}

/// A Mac that has been granted access to this iPhone's proxy.
public struct PairedClient: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date?
    /// SHA-256 of the Mac's wireless-link certificate, once linked over the cable.
    public var linkCertificate: String?
    /// How to reach this Mac's shell listener, once it granted a shell key over the cable.
    public var shell: ShellGrant?

    public init(id: String, name: String, tokenHash: String, pairedAt: Date, lastSeen: Date? = nil) {
        self.id = id; self.name = name; self.tokenHash = tokenHash; self.pairedAt = pairedAt; self.lastSeen = lastSeen
    }
}

/// Stores paired Macs and the short-lived pairing code. Backed by the App Group
/// defaults so the tunnel extension and the app share one view of the world.
public final class PairingRegistry: @unchecked Sendable {
    public static let clientsKey = "pairing.clients"
    /// Posted (a Darwin notification, so across processes) whenever the list
    /// of paired or linked Macs changes: the app forgets a Mac while the
    /// tunnel extension's wireless link is running.
    public static let changedNotification = "\(PassthroughProtocol.identifier).pairings-changed"
    public static let codeKey = "pairing.code"
    public static let codeExpiryKey = "pairing.codeExpiry"
    /// Wrong guesses against the current code, over every connection. Kept
    /// with the code in the shared defaults, since the iOS app issues codes
    /// and the extension checks them.
    public static let failedAttemptsKey = "pairing.failedAttempts"
    /// Set when the last code was withdrawn for too many wrong guesses, so
    /// the app can say why it is gone; cleared by the next code.
    public static let codeWithdrawnKey = "pairing.codeWithdrawn"

    public static let phoneIDKey = "pairing.phoneID"

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let lock = NSLock()
    public var onChange: (@Sendable () -> Void)?

    /// `secrets` holds the wireless link keys: the apps pass `KeychainSecrets`.
    public init(defaults: UserDefaults, secrets: SecretStore = InMemorySecrets()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    // MARK: Wireless link

    /// This phone's identity towards linked Macs: random, created once.
    public var phoneID: String {
        lock.lock(); defer { lock.unlock() }
        if let id = defaults.string(forKey: Self.phoneIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.phoneIDKey)
        return id
    }

    /// Records what a paired Mac sent over the cable to link wirelessly.
    /// False if the Mac isn't paired or its key could not be stored; the
    /// Mac is then not linked.
    @discardableResult
    public func link(clientID: String, certificateSHA256: String, linkKey: Data) -> Bool {
        lock.lock()
        var list = loadClients()
        guard let i = list.firstIndex(where: { $0.id == clientID }),
              secrets.write(linkKey, account: "link." + clientID) else { lock.unlock(); return false }
        list[i].linkCertificate = certificateSHA256
        save(list)
        lock.unlock()
        return true
    }

    /// Records the shell key a paired Mac sent over the cable. The key waits
    /// in the secret store, sealed to the app's sealing key (`ShellKeySeal`),
    /// until the app opens it and moves it to the shell client's own keychain
    /// item. False if the Mac isn't paired, the app hasn't published its
    /// sealing key yet (`shellSealingKey`: the key is then not kept at all),
    /// or the key could not be stored.
    @discardableResult
    public func grantShell(clientID: String, grant: ShellGrant, shellKey: Data, relayToken: String? = nil) -> Bool {
        guard let recipient = shellSealingKey,
              let sealed = try? ShellKeySeal.seal(shellKey, to: recipient, clientID: clientID) else { return false }
        lock.lock()
        var list = loadClients()
        guard let i = list.firstIndex(where: { $0.id == clientID }),
              secrets.write(sealed, account: Self.pendingShellAccount + clientID),
              storeRelayToken(relayToken, clientID: clientID) else { lock.unlock(); return false }
        list[i].shell = grant
        save(list)
        lock.unlock()
        return true
    }

    /// Applies a `macInfo` from a Mac this phone has a shell grant for. Valid
    /// addresses (capped at 16) always apply. The iroh details apply as a group
    /// only when valid: a valid id sets them (an absent token clears the stored
    /// one), an absent id clears them and the token (the Mac is the source of
    /// truth), invalid details leave the stored ones alone. Never touches the
    /// shell key or certificate. False if there is no grant.
    @discardableResult
    public func updateShellInfo(clientID: String, irohID: String?, irohRelay: String?, relayToken: String?, addresses: [String]?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var list = loadClients()
        guard let i = list.firstIndex(where: { $0.id == clientID }), var grant = list[i].shell else { return false }
        if let addresses { grant.addresses = Array(addresses.prefix(IrohInfo.maxAddresses)) }
        if irohID == nil {
            if storeRelayToken(nil, clientID: clientID) { grant.irohID = nil; grant.irohRelay = nil }
        } else if IrohInfo.areValid(id: irohID, relay: irohRelay, token: relayToken),
                  storeRelayToken(relayToken, clientID: clientID) {
            grant.irohID = irohID
            grant.irohRelay = irohRelay
        }
        list[i].shell = grant
        save(list)
        return true
    }

    /// The relay token a Mac's grant or `macInfo` carried.
    public func relayToken(clientID: String) -> String? {
        secrets.read(Self.relayTokenAccount + clientID).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func storeRelayToken(_ token: String?, clientID: String) -> Bool {
        guard let token, !token.isEmpty else { secrets.delete(Self.relayTokenAccount + clientID); return true }
        return secrets.write(Data(token.utf8), account: Self.relayTokenAccount + clientID)
    }

    private static let relayTokenAccount = "shell.relayToken."

    /// What waits for the app from `clientID`'s grant: sealed (`ShellKeySeal`),
    /// or a bare key an older build stored, which the app discards.
    public func sealedPendingShellKey(clientID: String) -> Data? {
        secrets.read(Self.pendingShellAccount + clientID)
    }

    /// The public half of the app's sealing key (X9.63), which the app
    /// publishes once it has one; nil until the app has been opened.
    public var shellSealingKey: P256.KeyAgreement.PublicKey? {
        defaults.data(forKey: Self.shellSealingKeyKey).flatMap { try? P256.KeyAgreement.PublicKey(x963Representation: $0) }
    }

    /// The app only: publishes (or, with nil, withdraws) its sealing key.
    public func publishShellSealingKey(_ key: P256.KeyAgreement.PublicKey?) {
        if let key { defaults.set(key.x963Representation, forKey: Self.shellSealingKeyKey) } else { defaults.removeObject(forKey: Self.shellSealingKeyKey) }
    }

    public static let shellSealingKeyKey = "shell.sealingKey"

    public func clearPendingShellKey(clientID: String) {
        secrets.delete(Self.pendingShellAccount + clientID)
    }

    private static let pendingShellAccount = "shell.pending."

    /// Everything the wireless dialer needs, for every linked Mac.
    public func linkCredentials() -> [LinkCredential] {
        let id = phoneID
        return clients.compactMap { client in
            guard let cert = client.linkCertificate, let key = secrets.read("link." + client.id) else { return nil }
            return LinkCredential(macTag: WirelessLink.macTag(clientID: client.id), certSHA256: cert, linkKey: key, phoneID: id)
        }
    }

    public var clients: [PairedClient] {
        lock.lock(); defer { lock.unlock() }
        return loadClients()
    }

    private func loadClients() -> [PairedClient] {
        guard let data = defaults.data(forKey: Self.clientsKey) else { return [] }
        return (try? JSONDecoder().decode([PairedClient].self, from: data)) ?? []
    }

    private func save(_ clients: [PairedClient]) {
        defaults.set(try? JSONEncoder().encode(clients), forKey: Self.clientsKey)
        onChange?()
        notify_post(Self.changedNotification)
    }

    // MARK: Pairing code

    /// Generates a fresh six digit code, valid for `PassthroughProtocol.pairingCodeLifetime`.
    @discardableResult
    public func issueCode() -> (code: String, expiry: Date) {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        let code = String(format: "%06d", value % 1_000_000)
        let expiry = Date().addingTimeInterval(PassthroughProtocol.pairingCodeLifetime)
        lock.lock()
        defaults.set(code, forKey: Self.codeKey)
        defaults.set(expiry.timeIntervalSince1970, forKey: Self.codeExpiryKey)
        defaults.set(0, forKey: Self.failedAttemptsKey)
        defaults.removeObject(forKey: Self.codeWithdrawnKey)
        lock.unlock()
        onChange?()
        return (code, expiry)
    }

    public func clearCode() {
        lock.lock()
        defaults.removeObject(forKey: Self.codeKey)
        defaults.removeObject(forKey: Self.codeExpiryKey)
        defaults.removeObject(forKey: Self.codeWithdrawnKey)
        lock.unlock()
        onChange?()
    }

    /// Whether the last code was withdrawn because too many wrong codes were
    /// tried against it (until a new code is issued or pairing is ended).
    public var codeWasWithdrawn: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: Self.codeWithdrawnKey)
    }

    public var activeCode: (code: String, expiry: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let code = defaults.string(forKey: Self.codeKey) else { return nil }
        let expiry = Date(timeIntervalSince1970: defaults.double(forKey: Self.codeExpiryKey))
        guard expiry > Date() else { return nil }
        return (code, expiry)
    }

    /// Validates a code and registers the Mac; returns the token to hand back.
    ///
    /// Anything on the phone can reach the control port, and anything on the
    /// Mac through adb, so wrong guesses must not be able to lock the user
    /// out: a lockout in time, renewed by a few guesses every so often, would
    /// refuse even the right code for as long as the guesser liked. Instead
    /// each code takes `pairingMaxWrongCodesPerCode` wrong guesses in all,
    /// over every connection (each connection is also held to a few by
    /// `ControlServer`), and is then withdrawn: a new one must be shown, so
    /// guessing wins with odds of at most 10 in a million per code the user
    /// shows, and until then the right code always works. A guesser can still
    /// make the user's code vanish, but not silently: the phone says why.
    public func pair(code: String, clientID: String, name: String) -> Result<String, PairingFailure> {
        // Before the code is looked at, so a malformed request learns nothing and costs nothing.
        guard !clientID.isEmpty, clientID.count <= 64, name.count <= 64 else { return .failure(.badCode) }
        lock.lock()
        guard let stored = defaults.string(forKey: Self.codeKey) else { lock.unlock(); return .failure(.expired) }
        guard Date(timeIntervalSince1970: defaults.double(forKey: Self.codeExpiryKey)) > Date() else {
            lock.unlock()
            clearCode()
            return .failure(.expired)
        }
        guard constantTimeEquals(stored, code.trimmingCharacters(in: .whitespaces)) else {
            let n = defaults.integer(forKey: Self.failedAttemptsKey) + 1
            defaults.set(n, forKey: Self.failedAttemptsKey)
            let withdrawn = n >= PassthroughProtocol.pairingMaxWrongCodesPerCode
            if withdrawn {
                defaults.removeObject(forKey: Self.codeKey)
                defaults.removeObject(forKey: Self.codeExpiryKey)
                defaults.set(true, forKey: Self.codeWithdrawnKey)
            }
            lock.unlock()
            guard withdrawn else { return .failure(.badCode) }
            ptLog(.warning, "Withdrew the pairing code after \(n) wrong codes")
            onChange?()
            return .failure(.codeWithdrawn)
        }

        let token = PairingToken.generate()
        var list = loadClients().filter { $0.id != clientID }
        list.append(PairedClient(id: clientID, name: name, tokenHash: PairingToken.hash(token), pairedAt: Date(), lastSeen: Date()))
        save(list)
        defaults.removeObject(forKey: Self.codeKey)
        defaults.removeObject(forKey: Self.codeExpiryKey)
        lock.unlock()
        onChange?()
        ptLog(.info, "Paired Mac \(name)")
        return .success(token)
    }

    public func verify(clientID: String, token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let client = loadClients().first(where: { $0.id == clientID }) else { return false }
        return constantTimeEquals(client.tokenHash, PairingToken.hash(token))
    }

    /// K for a paired Mac (`ControlAuth`): what its proofs are checked against.
    public func pairingKey(clientID: String) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return loadClients().first(where: { $0.id == clientID }).flatMap { ControlAuth.key(tokenHash: $0.tokenHash) }
    }

    /// Whether `password` is the SOCKS5 password derived from this Mac's pairing.
    public func verifySOCKS(clientID: String, password: String) -> Bool {
        guard let key = pairingKey(clientID: clientID) else { return false }
        return constantTimeEquals(ControlAuth.socksPassword(key: key), password)
    }

    public func touch(clientID: String) {
        lock.lock(); defer { lock.unlock() }
        var list = loadClients()
        guard let i = list.firstIndex(where: { $0.id == clientID }) else { return }
        list[i].lastSeen = Date()
        save(list)
    }

    public func revoke(clientID: String) {
        lock.lock(); defer { lock.unlock() }
        secrets.delete("link." + clientID)
        secrets.delete(Self.pendingShellAccount + clientID)
        secrets.delete(Self.relayTokenAccount + clientID)
        save(loadClients().filter { $0.id != clientID })
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        loadClients().forEach {
            secrets.delete("link." + $0.id)
            secrets.delete(Self.pendingShellAccount + $0.id)
            secrets.delete(Self.relayTokenAccount + $0.id)
        }
        save([])
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
