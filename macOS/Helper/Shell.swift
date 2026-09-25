import Foundation
import SystemConfiguration

/// Small process helpers shared by the tunnel and VPN engines.
enum Shell {
    struct CommandFailed: LocalizedError {
        let command: String
        let status: Int32
        var errorDescription: String? { "\(command) failed with status \(status)" }
    }

    /// Runs a command, discarding output; throws on non-zero exit.
    static func run(_ path: String, _ arguments: [String], quiet: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = quiet ? FileHandle.nullDevice : FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailed(command: ([path] + arguments).joined(separator: " "), status: process.terminationStatus)
        }
    }

    /// Runs a command and returns its trimmed stdout (empty on failure).
    static func capture(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves a host name (or IP literal) to IP address strings, IPv4 first.
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var v4: [String] = [], v6: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if info.pointee.ai_family == AF_INET6 { if !v6.contains(ip) { v6.append(ip) } }
                else if !v4.contains(ip) { v4.append(ip) }
            }
            cursor = info.pointee.ai_next
        }
        return v4 + v6
    }

    static func isIPv6(_ ip: String) -> Bool { ip.contains(":") }
}

/// Exact-match queries against the kernel routing table, so a delete never
/// touches a route we didn't add (`route delete` on a missing prefix is not
/// something to rely on) and cleanup reports only what was really there.
enum RouteTable {
    /// netstat prints IPv4 prefixes classfully abbreviated: trailing zero
    /// octets dropped beyond the class's network part ("0.0.0.0/2" is "0/2",
    /// "128.0.0.0/3" is "128.0/3", "192.0.0.0/3" is "192.0.0/3").
    static func netstatName(_ prefix: String) -> String {
        let parts = prefix.split(separator: "/", maxSplits: 1)
        let octets = parts[0].split(separator: ".")
        guard parts.count == 2, octets.count == 4, let first = Int(octets[0]) else { return prefix }
        let keep = first < 128 ? 1 : first < 192 ? 2 : 3
        var shown = Array(octets)
        while shown.count > keep, shown.last == "0" { shown.removeLast() }
        return shown.joined(separator: ".") + "/" + parts[1]
    }

    static func present(v6: Bool) -> Set<String> {
        let table = Shell.capture("/usr/sbin/netstat", ["-rn", "-f", v6 ? "inet6" : "inet"])
        return Set(table.split(separator: "\n").compactMap { line -> String? in
            let first = line.split(separator: " ", maxSplits: 1).first.map(String.init)
            return first.flatMap { $0.contains("/") ? $0 : nil }
        })
    }

    /// The gateway column of `prefix`'s route, if it is in the table.
    static func gateway(of prefix: String, v6: Bool) -> String? {
        let name = netstatName(prefix)
        for line in Shell.capture("/usr/sbin/netstat", ["-rn", "-f", v6 ? "inet6" : "inet"]).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, fields[0] == name { return String(fields[1]) }
        }
        return nil
    }

    static func exists(_ prefix: String, v6: Bool, in table: Set<String>) -> Bool {
        table.contains(netstatName(prefix))
    }

    /// Whether `prefix` is one of our reject routes (gateway 127.0.0.1 or ::1).
    static func isReject(_ prefix: String, v6: Bool) -> Bool {
        gateway(of: prefix, v6: v6) == (v6 ? "::1" : "127.0.0.1")
    }

    /// Deletes `prefix` only if it is really in the table. Returns true if removed.
    @discardableResult
    static func deleteIfPresent(_ prefix: String, v6: Bool, table: Set<String>? = nil) -> Bool {
        let table = table ?? present(v6: v6)
        guard exists(prefix, v6: v6, in: table) else { return false }
        return (try? Shell.run("/sbin/route", ["-q", "-n", "delete", v6 ? "-inet6" : "-inet", prefix], quiet: true)) != nil
    }
}

/// Undo anything a previous helper instance may have left in the kernel or
/// system settings if it crashed: reject/VPN routes, keepalive interfaces,
/// disabled sleep, stale network-service keys, engine state files. Run once at
/// startup before accepting clients.
enum RecoverySweep {
    static func run() {
        var cleaned: [String] = []
        let v4 = RouteTable.present(v6: false), v6 = RouteTable.present(v6: true)
        for q in ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"] where RouteTable.deleteIfPresent(q, v6: false, table: v4) {
            cleaned.append(q)
        }
        for q in ["::/2", "4000::/2", "8000::/2", "c000::/2"] where RouteTable.deleteIfPresent(q, v6: true, table: v6) {
            cleaned.append(q)
        }
        // The tunnel's IPv6 halves and the kill switch's eighths, only when they
        // are our reject routes (interface routes vanished with their utun;
        // anyone else's are not ours).
        for q in TunnelEngine.ipv6Halves + VPNEngine.v6Eighths where RouteTable.isReject(q, v6: true) && RouteTable.deleteIfPresent(q, v6: true, table: v6) {
            cleaned.append(q)
        }
        for q in VPNEngine.v4Eighths where RouteTable.isReject(q, v6: false) && RouteTable.deleteIfPresent(q, v6: false, table: v4) {
            cleaned.append(q)
        }
        for name in Shell.capture("/sbin/ifconfig", ["-l"]).split(separator: " ").map(String.init) where name.hasPrefix("feth") {
            if Shell.capture("/sbin/ifconfig", [name]).contains("10.83.0.1"), (try? Shell.run("/sbin/ifconfig", [name, "destroy"], quiet: true)) != nil {
                cleaned.append(name)
            }
        }
        if Shell.capture("/usr/bin/pmset", ["-g"]).contains("SleepDisabled\t\t1") || Shell.capture("/usr/bin/pmset", ["-g"]).contains("SleepDisabled 1") {
            _ = try? Shell.run("/usr/bin/pmset", ["-a", "disablesleep", "0"], quiet: true)
            cleaned.append("disablesleep")
        }
        if let store = SCDynamicStoreCreate(nil, "PassthroughSweep" as CFString, nil, nil) {
            for service in ["dev.dpatel.passthrough.tunnel", "dev.dpatel.passthrough.vpn"] {
                for suffix in ["", "/IPv4", "/IPv6", "/DNS"] {
                    let key = "State:/Network/Service/\(service)\(suffix)" as CFString
                    if SCDynamicStoreCopyValue(store, key) != nil, SCDynamicStoreRemoveValue(store, key) { cleaned.append(String(key)) }
                }
            }
        }
        for file in ["openvpn.conf", "openvpn.status", "wg.name"] {
            try? FileManager.default.removeItem(atPath: BundledEngines.stateDirectory + "/" + file)
        }
        if !cleaned.isEmpty { HelperLog.warn("recovered leftovers from a previous run: \(cleaned.joined(separator: ", "))") }
    }
}

/// Where the bundled engines live: next to the helper inside Passthrough.app.
enum BundledEngines {
    static var directory: URL {
        Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/nonexistent")
    }
    static var wireguardGo: URL { directory.appendingPathComponent("wireguard-go") }
    static var openvpn: URL { directory.appendingPathComponent("openvpn") }

    /// Runtime state the engines need (config files, status files). Root only.
    static let stateDirectory = "/var/run/passthrough"

    static func prepareStateDirectory() throws {
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory)
    }

    /// The app bundle lives in a user-writable place and this helper runs as
    /// root, so an engine is never executed from the bundle. It is copied into
    /// the root-only state directory, the *copy* is verified (strictly, and by
    /// identifier as well as Team ID) and the copy is what gets executed, so
    /// nothing can be swapped between check and exec.
    static func stagedEngine(_ url: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw EngineFileError.missing(url.lastPathComponent) }
        try prepareStateDirectory()
        let binDir = URL(fileURLWithPath: stateDirectory).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = binDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: url, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        try verifySignature(of: staged)
        return staged
    }

    static func verifySignature(of url: URL) throws {
        guard let team = CodeSigning.ownTeamIdentifier() else { throw EngineFileError.unsigned(url.lastPathComponent) }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw EngineFileError.unsigned(url.lastPathComponent)
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(url.lastPathComponent)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            throw EngineFileError.unsigned(url.lastPathComponent)
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw EngineFileError.unsigned(url.lastPathComponent)
        }
    }

    enum EngineFileError: LocalizedError {
        case missing(String)
        case unsigned(String)
        var errorDescription: String? {
            switch self {
            case .missing(let name): return "The \(name) engine is not bundled with this build. Run scripts/build-vpn-engines.sh and rebuild."
            case .unsigned(let name): return "The \(name) engine is not signed by this app's team; refusing to run it as root."
            }
        }
    }
}
