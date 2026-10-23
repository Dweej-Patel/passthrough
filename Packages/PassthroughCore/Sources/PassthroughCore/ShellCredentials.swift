import Foundation
import Network

/// How the phone turns its paired Macs into `ShellCredential`s and picks a
/// Bonjour result for one of them. Pure, so the iOS app's model stays thin.
public enum ShellCredentials {
    /// One credential for every client that granted the shell and whose key
    /// `key` returns (nil: not in this phone's vault, or not readable now).
    /// `manualAddress` is a per-Mac address the user typed; it is dialed
    /// before the addresses the Mac sent.
    public static func build(clients: [PairedClient], phoneID: String,
                             key: (String) -> Data?, manualAddress: (String) -> String?,
                             relayToken: (String) -> String? = { _ in nil }) -> [ShellCredential] {
        clients.compactMap { client in
            guard let grant = client.shell, let shellKey = key(client.id) else { return nil }
            return ShellCredential(macID: client.id, macName: grant.macName, certSHA256: grant.certSHA256, shellKey: shellKey,
                                   phoneID: phoneID, port: grant.port,
                                   addresses: addresses(granted: grant.addresses, manual: manualAddress(client.id)),
                                   irohID: grant.irohID, irohRelay: grant.irohRelay,
                                   relayToken: grant.irohID == nil ? nil : relayToken(client.id))
        }
    }

    /// The manual address (trimmed; ignored when blank) first, then the
    /// granted ones, without repeats.
    public static func addresses(granted: [String], manual: String?) -> [String] {
        let typed = manual?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var seen = Set<String>()
        return ((typed.isEmpty ? [] : [typed]) + granted).filter { seen.insert($0).inserted }
    }

    /// The browse result to dial for `macName`: the service named after the
    /// Mac (the listener advertises under the computer name), else the only
    /// result when this phone has shell access to exactly one Mac and exactly
    /// one is advertising. Nil when it can't be tied to this Mac.
    public static func discovered(among results: [NWEndpoint], macName: String, shellMacCount: Int) -> NWEndpoint? {
        let services = results.filter { if case .service = $0 { return true } else { return false } }
        if let named = services.first(where: { if case let .service(name, _, _, _) = $0 { return name == macName } else { return false } }) {
            return named
        }
        return shellMacCount == 1 && services.count == 1 ? services[0] : nil
    }
}
