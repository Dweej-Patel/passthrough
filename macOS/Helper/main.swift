import Foundation
import Security
import os

/// Privileged helper: creates the utun interface, runs the userspace TCP/IP
/// stack that converts packets into SOCKS5 streams, and installs routes/DNS.
/// It only ever talks to loopback and only accepts XPC from our own app.

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = CodeSigning.requirementForOwnTeam() {
            do {
                try connection.setCodeSigningRequirement(requirement)
            } catch {
                HelperLog.error("Could not apply code signing requirement: \(error)")
                return false
            }
        } else {
            HelperLog.warn("Helper is not signed with a team; accepting any local client (development only)")
        }
        connection.exportedInterface = NSXPCInterface(with: PassthroughHelperProtocol.self)
        connection.exportedObject = service
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [service] in
            service.clientGone(id)
        }
        service.clientArrived(id)
        connection.resume()
        return true
    }
}

enum CodeSigning {
    /// Builds a requirement that only accepts apps signed by the same team as this helper.
    static func requirementForOwnTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"dev.dpatel.passthrough.mac\""
    }
}

enum HelperLog {
    static let logger = Logger(subsystem: "dev.dpatel.passthrough", category: "helper")
    static func info(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func warn(_ s: String) { logger.warning("\(s, privacy: .public)") }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
}

guard getuid() == 0 else {
    HelperLog.error("must run as root (launched by launchd via SMAppService)")
    exit(1)
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
HelperLog.info("Passthrough helper \(HelperConstants.version) ready")
RunLoop.main.run()
