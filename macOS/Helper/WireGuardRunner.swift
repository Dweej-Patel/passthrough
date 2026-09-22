import Foundation

/// Drives a bundled `wireguard-go` process: parses a standard wg-quick style
/// .conf, lets the engine create its utun, then configures it over the UAPI
/// socket and brings the interface up. The private key only ever lives in
/// memory and on that root-only socket.
final class WireGuardRunner: VPNRunner {
    struct Peer {
        var publicKeyHex: String
        var presharedKeyHex: String?
        var endpointHost: String
        var endpointPort: Int
        var allowedIPs: [String]
        var keepalive: Int?
    }

    struct Parsed {
        var privateKeyHex = ""
        var addresses: [String] = []
        var dns: [String] = []
        var mtu: Int?
        var listenPort: Int?
        var peers: [Peer] = []
    }

    var onEvent: ((VPNRunnerEvent) -> Void)?
    var endpoints: [(host: String, port: Int)] { parsed.peers.map { ($0.endpointHost, $0.endpointPort) } }

    private let parsed: Parsed
    private let queue: DispatchQueue
    private var process: Process?
    private var interfaceName: String?
    private var pollTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var configured = false
    private var connected = false
    private var stopping = false
    private var startedAt = Date()
    private var lastStats: (Int, Int, Int?) = (0, 0, nil)
    private static let nameFile = BundledEngines.stateDirectory + "/wg.name"

    init(configText: String, queue: DispatchQueue) throws {
        parsed = try Self.parse(configText)
        self.queue = queue
    }

    // MARK: Parsing

    static func parse(_ text: String) throws -> Parsed {
        var result = Parsed()
        var section = ""
        var peer: Peer?
        func flushPeer() { if let p = peer { result.peers.append(p) }; peer = nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                flushPeer()
                section = line.lowercased()
                if section == "[peer]" { peer = Peer(publicKeyHex: "", endpointHost: "", endpointPort: 0, allowedIPs: []) }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            let list = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            switch (section, key) {
            case ("[interface]", "privatekey"): result.privateKeyHex = try keyHex(value, "PrivateKey")
            case ("[interface]", "address"): result.addresses += list
            case ("[interface]", "dns"): result.dns += list.filter { $0.first?.isNumber == true || $0.contains(":") }
            case ("[interface]", "mtu"): result.mtu = Int(value)
            case ("[interface]", "listenport"): result.listenPort = Int(value)
            case ("[peer]", "publickey"): peer?.publicKeyHex = try keyHex(value, "PublicKey")
            case ("[peer]", "presharedkey"): peer?.presharedKeyHex = try keyHex(value, "PresharedKey")
            case ("[peer]", "allowedips"): peer?.allowedIPs += list
            case ("[peer]", "persistentkeepalive"): peer?.keepalive = Int(value)
            case ("[peer]", "endpoint"):
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else {
                    throw VPNEngine.VPNError.badConfig("Endpoint must be host:port")
                }
                peer?.endpointHost = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                peer?.endpointPort = port
            default: break
            }
        }
        flushPeer()
        guard !result.privateKeyHex.isEmpty else { throw VPNEngine.VPNError.badConfig("missing PrivateKey") }
        guard !result.addresses.isEmpty else { throw VPNEngine.VPNError.badConfig("missing Address") }
        guard let first = result.peers.first, !first.publicKeyHex.isEmpty, !first.endpointHost.isEmpty else {
            throw VPNEngine.VPNError.badConfig("missing [Peer] with PublicKey and Endpoint")
        }
        return result
    }

    private static func keyHex(_ base64: String, _ name: String) throws -> String {
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw VPNEngine.VPNError.badConfig("\(name) is not a valid 32-byte base64 key")
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Process

    func start() throws {
        let binary = BundledEngines.wireguardGo
        try BundledEngines.verifySignature(of: binary)
        try? FileManager.default.removeItem(atPath: Self.nameFile)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-f", "utun"]
        var env = ProcessInfo.processInfo.environment
        env["WG_TUN_NAME_FILE"] = Self.nameFile
        env["WG_PROCESS_FOREGROUND"] = "1"
        env["LOG_LEVEL"] = "error"
        process.environment = env
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        var buffer = Data()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty, let self { self.queue.async { self.onEvent?(.log(line)) } }
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                guard !self.stopping else { return }
                self.cancelTimers()
                self.onEvent?(.exited(fatal: nil))
            }
        }
        try process.run()
        self.process = process
        startedAt = Date()
        waitForInterface(attempt: 0)
    }

    func stop() {
        stopping = true
        cancelTimers()
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        self.process = nil
        try? FileManager.default.removeItem(atPath: Self.nameFile)
    }

    private func cancelTimers() {
        pollTimer?.cancel(); pollTimer = nil
        healthTimer?.cancel(); healthTimer = nil
    }

    /// wireguard-go writes the utun name it obtained to WG_TUN_NAME_FILE.
    private func waitForInterface(attempt: Int) {
        if let name = try? String(contentsOfFile: Self.nameFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           name.hasPrefix("utun"), FileManager.default.fileExists(atPath: "/var/run/wireguard/\(name).sock") {
            interfaceName = name
            do {
                try configure(name)
                waitForHandshake(attempt: 0)
            } catch {
                onEvent?(.log("configure failed: \(error.localizedDescription)"))
                stopAndReport()
            }
            return
        }
        guard attempt < 60 else { onEvent?(.log("engine never created its interface")); stopAndReport(); return }
        schedule(after: 0.1) { [weak self] in self?.waitForInterface(attempt: attempt + 1) }
    }

    private func stopAndReport() {
        stop()
        stopping = false
        onEvent?(.exited(fatal: nil))
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: block)
        timer.resume()
        pollTimer = timer
    }

    // MARK: Configuration

    private func configure(_ name: String) throws {
        var lines = ["set=1", "private_key=\(parsed.privateKeyHex)"]
        if let port = parsed.listenPort { lines.append("listen_port=\(port)") }
        lines.append("replace_peers=true")
        for peer in parsed.peers {
            lines.append("public_key=\(peer.publicKeyHex)")
            if let psk = peer.presharedKeyHex { lines.append("preshared_key=\(psk)") }
            if let ip = Shell.resolve(peer.endpointHost).first {
                lines.append("endpoint=\(Shell.isIPv6(ip) ? "[\(ip)]" : ip):\(peer.endpointPort)")
            }
            lines.append("persistent_keepalive_interval=\(peer.keepalive ?? 25)")
            lines.append("replace_allowed_ips=true")
            for allowed in peer.allowedIPs { lines.append("allowed_ip=\(allowed)") }
        }
        let reply = try uapi(lines.joined(separator: "\n") + "\n\n", socket: "/var/run/wireguard/\(name).sock")
        guard reply.contains("errno=0") else { throw VPNEngine.VPNError.badConfig("engine rejected the configuration (\(reply.trimmingCharacters(in: .whitespacesAndNewlines)))") }

        for address in parsed.addresses {
            if Shell.isIPv6(address) {
                try Shell.run("/sbin/ifconfig", [name, "inet6", address, "alias"])
            } else {
                let plain = address.split(separator: "/").first.map(String.init) ?? address
                try Shell.run("/sbin/ifconfig", [name, "inet", address.contains("/") ? address : address + "/32", Self.peerAddress(for: plain), "alias"])
            }
        }
        try Shell.run("/sbin/ifconfig", [name, "mtu", "\(parsed.mtu ?? 1420)", "up"])
        configured = true
    }

    /// A point-to-point "destination" that differs from our own address so the
    /// interface has a router configd can name; never used on the wire.
    static func peerAddress(for address: String) -> String {
        var octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return address }
        octets[3] = octets[3] == 1 ? 2 : 1
        return octets.map(String.init).joined(separator: ".")
    }

    private func waitForHandshake(attempt: Int) {
        let stats = readStats()
        lastStats = stats
        if let age = stats.2, age < 60 {
            connected = true
            let firstV4 = parsed.addresses.first { !Shell.isIPv6($0) }?.split(separator: "/").first.map(String.init)
            onEvent?(.connected(interface: interfaceName ?? "", address: firstV4, gateway: firstV4.map(Self.peerAddress(for:)), dns: parsed.dns, mtu: parsed.mtu))
            startHealthTimer()
            return
        }
        guard attempt < 40 else {
            onEvent?(.log("no handshake with \(parsed.peers.first?.endpointHost ?? "peer") after 20s"))
            stopAndReport()
            return
        }
        schedule(after: 0.5) { [weak self] in self?.waitForHandshake(attempt: attempt + 1) }
    }

    /// WireGuard has no session; a stale handshake is the only sign it's dead.
    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lastStats = self.readStats()
            if let age = self.lastStats.2, age > 180 {
                self.onEvent?(.log("no handshake for \(age)s; restarting"))
                self.cancelTimers()
                self.stopAndReport()
            }
        }
        timer.resume()
        healthTimer = timer
    }

    func stats() -> (Int, Int, Int?) { lastStats }

    private func readStats() -> (Int, Int, Int?) {
        guard let name = interfaceName, let reply = try? uapi("get=1\n\n", socket: "/var/run/wireguard/\(name).sock") else { return lastStats }
        var rx = 0, tx = 0, handshake: Int? = nil
        for line in reply.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            switch parts[0] {
            case "rx_bytes": rx += v
            case "tx_bytes": tx += v
            case "last_handshake_time_sec": if v > 0 { handshake = max(0, Int(Date().timeIntervalSince1970) - v) }
            default: break
            }
        }
        return (rx, tx, handshake)
    }

    // MARK: UAPI (unix socket, line protocol)

    private func uapi(_ request: String, socket path: String) throws -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNEngine.VPNError.badConfig("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in bytes.prefix(103).enumerated() { dst[i] = b }
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw VPNEngine.VPNError.badConfig("engine socket: \(String(cString: strerror(errno)))") }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let payload = Array(request.utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload[sent...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw VPNEngine.VPNError.badConfig("engine socket write failed") }
            sent += n
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            response.append(chunk, count: n)
            if response.count >= 2, response.suffix(2) == Data([0x0A, 0x0A]) { break }
        }
        return String(decoding: response, as: UTF8.self)
    }
}
