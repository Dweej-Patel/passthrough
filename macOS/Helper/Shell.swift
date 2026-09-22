import Foundation

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

    /// Refuses to launch an engine that isn't signed by our own team (when the
    /// helper itself is team-signed): the bundle lives in a user-writable place
    /// and this helper runs as root.
    static func verifySignature(of url: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw EngineFileError.missing(url.lastPathComponent)
        }
        guard let team = CodeSigning.ownTeamIdentifier() else { return }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw EngineFileError.unsigned(url.lastPathComponent)
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            throw EngineFileError.unsigned(url.lastPathComponent)
        }
        guard SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else {
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
