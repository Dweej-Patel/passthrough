import Foundation
import HelperLogic
import ObjectiveC
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
            // Without a Team ID there is no way to tell our app from any other
            // local process, and this helper runs as root. Refuse.
            HelperLog.error("Helper is not signed with a Team ID; refusing all clients. Set DEVELOPMENT_TEAM in Config/Signing.xcconfig.")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: PassthroughHelperProtocol.self)
        connection.exportedObject = service
        // A fresh ID per connection, never reused (an ObjectIdentifier can be,
        // once the connection object is freed), so ownership recorded for a
        // client that has gone can never pass to a later one.
        let id = UUID()
        ClientID.set(id, on: connection)
        connection.invalidationHandler = { [service] in
            service.clientGone(id)
        }
        service.clientArrived(id)
        connection.resume()
        return true
    }
}

/// The ID `ListenerDelegate` gave a connection, read by the XPC methods it calls.
enum ClientID {
    private static var key: UInt8 = 0

    static func set(_ id: UUID, on connection: NSXPCConnection) {
        objc_setAssociatedObject(connection, &key, id as NSUUID, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The calling client's ID; only inside an XPC method, before any hop off its thread.
    static func current() -> UUID? {
        (NSXPCConnection.current().flatMap { objc_getAssociatedObject($0, &key) } as? NSUUID) as UUID?
    }
}

enum CodeSigning {
    /// Builds a requirement that only accepts apps signed by the same team as
    /// this helper. A Release helper also refuses an app that carries
    /// get-task-allow (any development-signed build): code injected into it
    /// by a debugger, which needs no privileges for a debuggable app, would
    /// speak to this root helper as our app. A Debug helper accepts it so a
    /// Debug app can drive it.
    static func requirementForOwnTeam() -> String? {
        guard let team = ownTeamIdentifier() else { return nil }
        let id = HelperConstants.identifier
        // Checked where they are spliced in, so neither can loosen the requirement.
        precondition(HelperConstants.isValidIdentifier(id), "PassthroughID \"\(id)\" is not safe in a code-signing requirement")
        precondition(CodeRequirement.isValidTeam(team), "Team ID \"\(team)\" is not safe in a code-signing requirement")
        #if DEBUG
        let allowDebuggable = true
        #else
        let allowDebuggable = false
        #endif
        return CodeRequirement.client(team: team, identifier: id, allowDebuggable: allowDebuggable)
    }

    /// The Team ID this helper is signed with, or nil for unsigned dev builds.
    /// Read once, at launch: an app update replaces the bundle under a helper
    /// that keeps running, and reading its signature off the new files then
    /// fails, which refused every VPN engine until the helper restarted.
    static func ownTeamIdentifier() -> String? { launchTeam }

    private static let launchTeam: String? = readOwnTeamIdentifier()

    /// Reads it now; `main` calls this at launch so the lazy `launchTeam` is set before any update.
    @discardableResult
    static func cacheOwnTeam() -> String? { launchTeam }

    private static func readOwnTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }
}

enum HelperLog {
    static let logger = Logger(subsystem: HelperConstants.identifier, category: "helper")
    static func info(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func warn(_ s: String) { logger.warning("\(s, privacy: .public)") }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
}

// The tun2socks engine: this same binary, started by the helper (see EngineProcess).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == EngineProcess.flag { EngineProcess.run() }

guard getuid() == 0 else {
    HelperLog.error("must run as root (launched by launchd via SMAppService)")
    exit(1)
}

CodeSigning.cacheOwnTeam()
RecoverySweep.run()
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
HelperLog.info("Passthrough helper \(HelperConstants.version) ready")
RunLoop.main.run()
