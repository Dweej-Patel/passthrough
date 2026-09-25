import Foundation

/// Drives a bundled `openvpn` process from an ordinary .ovpn profile. The
/// profile is written to a root-only file for the process; the username and
/// password are handed over on stdin and never touch disk or the process list.
/// OpenVPN opens the utun itself; we do the ifconfig and routing so the layering
/// with the passthrough tunnel stays under one owner.
final class OpenVPNRunner: VPNRunner {
    var onEvent: ((VPNRunnerEvent) -> Void)?
    private(set) var endpoints: [(host: String, port: Int)] = []
    var endpointIPs: [String: String] = [:]

    private let configText: String
    private let username: String
    private let password: String
    private let queue: DispatchQueue
    private let configMTU: Int?
    private var process: Process?
    private var stdin: FileHandle?
    private var stopping = false
    private var interfaceName: String?
    private var pushedDNS: [String] = []
    private var pushedAddress: String?
    private var pushedPeerOrMask: String?
    private var pushedGateway: String?
    private var fatalReason: String?
    private var wasConnected = false
    private var lastStats: (Int, Int, Int?) = (0, 0, nil)
    private static let configPath = BundledEngines.stateDirectory + "/openvpn.conf"
    private static let statusPath = BundledEngines.stateDirectory + "/openvpn.status"

    init(configText: String, username: String, password: String, queue: DispatchQueue) throws {
        let profile = try OpenVPNProfile(text: configText)
        self.configText = profile.canonicalText
        self.username = username
        self.password = password
        self.queue = queue
        self.endpoints = profile.endpoints
        self.configMTU = profile.tunMTU
    }

    func start() throws {
        let binary = try BundledEngines.stagedEngine(BundledEngines.openvpn)
        try configText.write(toFile: Self.configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configPath)
        try? FileManager.default.removeItem(atPath: Self.statusPath)

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--config", Self.configPath,
            "--dev", "utun", "--dev-type", "tun",
            "--ifconfig-noexec", "--route-noexec",
            "--pull-filter", "ignore", "route-ipv6",
            "--pull-filter", "ignore", "ifconfig-ipv6",
            "--pull-filter", "ignore", "block-outside-dns",
            // Crypto floor regardless of what the profile says (these come after
            // --config, so they win): AEAD or CBC only, TLS 1.2+, no compression.
            "--data-ciphers", "AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC",
            "--tls-version-min", "1.2",
            "--allow-compression", "asym",
            "--remote-cert-tls", "server",
            // Keepalives. We ping every 10 s whatever the server pushes (NordVPN:
            // ping 60), so carrier NAT never forgets the flow. The restart
            // timeout must outlast the *server's* ping interval, since OpenVPN
            // pings are one-way: an idle link hears from the server only that
            // often. A 25 s timeout against NordVPN's 60 s pings restarted every
            // idle half minute. So honour the server's ping-restart (NordVPN:
            // 180); network changes restart the session anyway (underlayChanged).
            "--pull-filter", "ignore", "ping",
            "--script-security", "0",
            "--nobind", "--persist-tun", "--persist-key",
            "--ping", "10",
            "--ping-restart", "120",
            "--connect-retry", "2", "10",
            "--auth-user-pass", "/dev/stdin",
            "--status", Self.statusPath, "1",
            "--verb", "3",
        ]
        let out = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = input
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let self { self.queue.async { self.handle(line: line) } }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.stopping else { return }
                self.cleanupFiles()
                self.onEvent?(.exited(fatal: self.fatalReason))
            }
        }
        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
        stdin?.write(Data((username + "\n" + password + "\n").utf8))
        try? stdin?.close()
        stdin = nil
    }

    func stop() {
        stopping = true
        guard let process else { cleanupFiles(); return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            // Don't block the helper's queue waiting; escalate to SIGKILL later if needed.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        self.process = nil
        cleanupFiles()
    }

    private func cleanupFiles() {
        try? FileManager.default.removeItem(atPath: Self.configPath)
        try? FileManager.default.removeItem(atPath: Self.statusPath)
    }

    // MARK: Log parsing

    private func handle(line rawLine: String) {
        // Strip the leading timestamp openvpn prints at verb 3.
        var line = rawLine
        if line.count > 20, line[line.index(line.startIndex, offsetBy: 4)] == "-" {
            line = String(line.dropFirst(20))
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }

        // Only anchored matches decide anything: log lines can echo server-
        // controlled text (certificate names, pushed options), and a matched
        // "fatal" must never be something a peer can forge.
        if line.hasPrefix("Opened utun device ") {
            let name = String(line.dropFirst("Opened utun device ".count)).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("utun"), name.dropFirst(4).allSatisfy(\.isNumber) { interfaceName = name }
        } else if line.hasPrefix("PUSH: Received control message: '") {
            let body = line.dropFirst("PUSH: Received control message: '".count).dropLast(line.hasSuffix("'") ? 1 : 0)
            parsePush(String(body))
        } else if line.hasPrefix("Initialization Sequence Completed") {
            bringUp()
        } else if line.hasPrefix("AUTH: Received control message: AUTH_FAILED") {
            fatalReason = "The VPN server rejected the username and password."
        } else if line.hasPrefix("Cannot allocate TUN/TAP dev") || line.hasPrefix("Cannot open utun") {
            fatalReason = "OpenVPN could not create a tunnel interface."
        } else if line.hasPrefix("VERIFY ERROR") || line.hasPrefix("OpenSSL: error") && line.contains("certificate verify failed") {
            fatalReason = "The VPN server's certificate did not verify."
        } else if line.hasPrefix("Options error") {
            fatalReason = "OpenVPN rejected the profile."
        } else if line.hasPrefix("Inactivity timeout") || line.hasPrefix("Connection reset") || line.hasPrefix("SIGUSR1[soft") || line.hasPrefix("[") && line.contains("Inactivity timeout") {
            if wasConnected { onEvent?(.reconnecting(line)) }
        }
        if !line.hasPrefix("VERIFY") && !line.hasPrefix("++") && !line.contains("Socket Buffers") {
            onEvent?(.log(line))
        }
    }

    /// Dotted-quad check for anything scraped from server-pushed text before it
    /// reaches ifconfig or the DNS configuration.
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in p.count <= 3 && !p.isEmpty && p.allSatisfy(\.isNumber) && Int(p)! <= 255 }
    }

    private func parsePush(_ body: String) {
        pushedDNS = []
        for option in body.split(separator: ",") {
            let parts = option.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let key = parts.first else { continue }
            switch key {
            case "dhcp-option" where parts.count >= 3 && parts[1].uppercased() == "DNS" && Self.isIPv4(parts[2]): pushedDNS.append(parts[2])
            case "ifconfig" where parts.count >= 3 && Self.isIPv4(parts[1]) && Self.isIPv4(parts[2]): pushedAddress = parts[1]; pushedPeerOrMask = parts[2]
            case "route-gateway" where parts.count >= 2 && Self.isIPv4(parts[1]): pushedGateway = parts[1]
            default: break
            }
        }
    }

    /// Configure the interface ourselves (ifconfig-noexec) and report connected.
    private func bringUp() {
        guard let name = interfaceName, let address = pushedAddress else {
            onEvent?(.log("connected but no interface/address was pushed; giving up"))
            fatalReason = "The VPN server did not push an address for this client."
            stop(); stopping = false
            onEvent?(.exited(fatal: fatalReason))
            return
        }
        let mask = pushedPeerOrMask
        let isMask = mask?.hasPrefix("255") == true
        let gateway = pushedGateway ?? (isMask ? WireGuardRunner.peerAddress(for: address) : (mask ?? WireGuardRunner.peerAddress(for: address)))
        var args = [name, "inet", address, gateway]
        if isMask, let mask { args += ["netmask", mask] } else { args += ["netmask", "255.255.255.255"] }
        args += ["mtu", "\(configMTU ?? 1500)", "up"]
        do {
            try Shell.run("/sbin/ifconfig", args)
        } catch {
            onEvent?(.log("ifconfig failed: \(error.localizedDescription)"))
            stop(); stopping = false
            onEvent?(.exited(fatal: nil))
            return
        }
        wasConnected = true
        onEvent?(.connected(interface: name, address: address, gateway: gateway, dns: pushedDNS, mtu: configMTU))
    }

    func stats() -> (Int, Int, Int?) {
        guard let text = try? String(contentsOfFile: Self.statusPath, encoding: .utf8) else { return lastStats }
        var rx = 0, tx = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ",")
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            if parts[0] == "TUN/TAP write bytes" { rx = v }
            if parts[0] == "TUN/TAP read bytes" { tx = v }
        }
        lastStats = (rx, tx, nil)
        return lastStats
    }
}
