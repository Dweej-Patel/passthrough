import Foundation
import HelperLogic
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

    /// Runs a command with `input` on its stdin; returns its status, stdout
    /// and stderr (status -1 when it could not start). For tools like pfctl
    /// that report on stderr.
    @discardableResult
    static func output(_ path: String, _ arguments: [String], input: String? = nil) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        guard (try? process.run()) != nil else { return (-1, "", "") }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // stderr on its own thread: either pipe filling up must not stall the other.
        let errors = Locked(Data())
        let readErrors = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errors.set(err.fileHandleForReading.readDataToEndOfFile())
            readErrors.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        readErrors.wait()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errors.get(), as: UTF8.self))
    }
}

/// Exact-match queries against the kernel routing table, so a delete never
/// touches a route we didn't add (`route delete` on a missing prefix is not
/// something to rely on) and cleanup reports only what was really there.
enum RouteTable {
    /// `prefix` as netstat prints it (`RouteNames.netstat`).
    static func netstatName(_ prefix: String) -> String { RouteNames.netstat(prefix) }

    /// Every route line of one family's table, from one netstat run.
    static func all(v6: Bool) -> [RouteEntry] {
        RouteEntry.parse(Shell.capture("/usr/sbin/netstat", ["-rn", "-f", v6 ? "inet6" : "inet"]))
    }

    /// Destination (as netstat prints it) → the unscoped route there.
    static func entries(v6: Bool) -> [String: RouteEntry] { RouteEntry.unscoped(all(v6: v6)) }

    static func present(v6: Bool) -> Set<String> {
        let table = Shell.capture("/usr/sbin/netstat", ["-rn", "-f", v6 ? "inet6" : "inet"])
        return Set(table.split(separator: "\n").compactMap { line -> String? in
            let first = line.split(separator: " ", maxSplits: 1).first.map(String.init)
            return first.flatMap { $0.contains("/") ? $0 : nil }
        })
    }

    static func exists(_ prefix: String, v6: Bool, in table: Set<String>) -> Bool {
        table.contains(netstatName(prefix))
    }

    /// Whether `prefix` is one of our reject routes (the reject flag, to
    /// 127.0.0.1 or ::1), in `table` when given (one snapshot for many prefixes).
    static func isReject(_ prefix: String, v6: Bool, in table: [String: RouteEntry]? = nil) -> Bool {
        RejectRoutes.isOurs((table ?? entries(v6: v6))[netstatName(prefix)], v6: v6)
    }

    /// Whether the route at `prefix` is ours to delete (`RejectRoutes.mayDelete`).
    static func isOurs(_ prefix: String, v6: Bool, in table: [String: RouteEntry]? = nil) -> Bool {
        RejectRoutes.mayDelete((table ?? entries(v6: v6))[netstatName(prefix)], v6: v6)
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
        // Engines left by a helper that died: the tun2socks engine quits by
        // itself once it notices, but its quit is what can spin forever; an
        // openvpn or wireguard-go would carry on running as root unmanaged.
        cleaned += EnginePIDs.killStrays()
        let v4 = RouteTable.present(v6: false), v6 = RouteTable.present(v6: true)
        for q in ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"] where RouteTable.deleteIfPresent(q, v6: false, table: v4) {
            cleaned.append(q)
        }
        for q in ["::/2", "4000::/2", "8000::/2", "c000::/2"] where RouteTable.deleteIfPresent(q, v6: true, table: v6) {
            cleaned.append(q)
        }
        // The tunnel's IPv6 halves, only when they are our reject routes
        // (interface routes vanished with their utun; anyone else's are not ours).
        let e4 = RouteTable.entries(v6: false), e6 = RouteTable.entries(v6: true)
        for q in TunnelEngine.ipv6Halves where RouteTable.isOurs(q, v6: true, in: e6) && RouteTable.deleteIfPresent(q, v6: true, table: v6) {
            cleaned.append(q)
        }
        // The kill switch: kept while the VPN was on when its app or the last
        // helper went away (`vpn-wanted`), so a crash never opens the Mac up;
        // the app reconnects it, or turning the VPN off lifts it. Else, gone.
        switch KillSwitchHold.helperStart(wanted: VPNEngine.stateStore.isWanted) {
        case .hold:
            HelperLog.warn("the VPN was on when Passthrough or its helper stopped: its kill switch stays engaged until the VPN reconnects or is turned off")
        case .lift:
            for q in VPNEngine.v6Eighths where RouteTable.isOurs(q, v6: true, in: e6) && RouteTable.deleteIfPresent(q, v6: true, table: v6) {
                cleaned.append(q)
            }
            for q in VPNEngine.v4Eighths where RouteTable.isOurs(q, v6: false, in: e4) && RouteTable.deleteIfPresent(q, v6: false, table: v4) {
                cleaned.append(q)
            }
            if PacketFilter.lift() { cleaned.append("kill switch packet filter") }
        }
        cleaned += HotspotGuard.removeAll()
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
            for service in ["\(HelperConstants.identifier).tunnel", "\(HelperConstants.identifier).vpn"] {
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

    /// Where staged engines are executed from; root only.
    static var binDirectory: String { stateDirectory + "/bin" }

    /// The app bundle lives in a user-writable place and this helper runs as
    /// root, so an engine is never executed from the bundle. Its bytes are
    /// copied into a new file in the root-only state directory, the *copy* is
    /// verified (strictly, and by identifier as well as Team ID) and the copy
    /// is what gets executed, so nothing can be swapped between check and exec.
    ///
    /// Only the bytes are copied, through descriptors: the source is opened
    /// without following a final symlink and must be a regular file, and the
    /// copy is created exclusively (never through a link). A file manager copy
    /// would copy a symlink planted in the bundle as a symlink, and the chmod,
    /// the signature check and the exec would all have followed it to a file
    /// its planter can swap at any moment.
    static func stagedEngine(_ url: URL, identifier: String? = nil) throws -> URL {
        let name = url.lastPathComponent
        let source = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else {
            throw errno == ENOENT ? EngineFileError.missing(name) : EngineFileError.notAFile(name)
        }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw EngineFileError.notAFile(name) }

        try prepareStateDirectory()
        try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var dir = stat()
        guard lstat(binDirectory, &dir) == 0, dir.st_mode & S_IFMT == S_IFDIR, dir.st_uid == 0 else { throw EngineFileError.notAFile(binDirectory) }
        let staged = binDirectory + "/" + name
        // Whatever is there (an old copy, or anything else) goes; a running
        // engine keeps its own inode.
        if unlink(staged) != 0, errno != ENOENT { try? FileManager.default.removeItem(atPath: staged) }
        let copy = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard copy >= 0 else { throw EngineFileError.copyFailed(name, errno) }
        do {
            defer { close(copy) }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(source, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw EngineFileError.copyFailed(name, errno) }
                if n == 0 { break }
                var written = 0
                while written < n {
                    let w = buffer[written..<n].withUnsafeBytes { write(copy, $0.baseAddress, $0.count) }
                    if w < 0, errno == EINTR { continue }
                    guard w > 0 else { throw EngineFileError.copyFailed(name, errno) }
                    written += w
                }
            }
            // The umask may have narrowed the mode; owner root whatever the directory's group.
            guard fchown(copy, 0, 0) == 0, fchmod(copy, 0o700) == 0, fsync(copy) == 0 else { throw EngineFileError.copyFailed(name, errno) }
        } catch {
            unlink(staged)
            throw error
        }
        let stagedURL = URL(fileURLWithPath: staged)
        try requireIntactCopy(stagedURL)
        try verifySignature(of: stagedURL, identifier: identifier ?? name)
        return stagedURL
    }

    /// The staged copy is still what `stagedEngine` made: a regular file (not
    /// a link), owned by root, mode 0700, with no other name. Checked before
    /// it is verified and again right before every exec, a cached copy
    /// included.
    static func isIntactCopy(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == 0
            && info.st_mode & 0o7777 == 0o700 && info.st_nlink == 1
            && (url.path as NSString).deletingLastPathComponent == binDirectory
    }

    static func requireIntactCopy(_ url: URL) throws {
        guard isIntactCopy(url) else { throw EngineFileError.notAFile(url.path) }
    }

    /// The environment an engine starts with: a fixed PATH and only `extra`,
    /// never the helper's own. The bundled openvpn links OpenSSL statically
    /// with OPENSSLDIR in Homebrew's prefix (user-writable): without these,
    /// a root openvpn would read an openssl.cnf, and load providers and
    /// engines, from there.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        let nowhere = "/var/empty/passthrough-none"   // /var/empty is root's and stays empty
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OPENSSL_CONF": "/dev/null",
            "OPENSSL_MODULES": nowhere,
            "OPENSSL_ENGINES": nowhere,
            "SSL_CERT_FILE": nowhere,
            "SSL_CERT_DIR": nowhere,
        ].merging(extra) { _, new in new }
    }

    /// `identifier`: the signing identifier the file must carry.
    static func verifySignature(of url: URL, identifier: String) throws {
        guard let team = CodeSigning.ownTeamIdentifier() else { throw EngineFileError.unsigned(url.lastPathComponent) }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw EngineFileError.unsigned(url.lastPathComponent)
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\"" as CFString
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
        case notAFile(String)
        case copyFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .missing(let name): return "The \(name) engine is not bundled with this build. Run scripts/build-vpn-engines.sh and rebuild."
            case .unsigned(let name): return "The \(name) engine is not signed by this app's team; refusing to run it as root."
            case .notAFile(let name): return "\(name) is not a plain file (a link, or changed after it was copied); refusing to run it as root."
            case .copyFailed(let name, let e): return "Could not copy the \(name) engine: \(String(cString: strerror(e)))"
            }
        }
    }
}

/// Pid files for the engines the helper starts, in the root-only state
/// directory, so a helper started after a crash can end the ones its
/// predecessor left running (`RecoverySweep`).
enum EnginePIDs {
    static func path(_ name: String) -> String { BundledEngines.stateDirectory + "/\(name).pid" }

    static func record(_ pid: pid_t, for name: String) {
        do {
            try BundledEngines.prepareStateDirectory()
            try "\(pid)\n".write(toFile: path(name), atomically: true, encoding: .utf8)
        } catch {
            HelperLog.warn("could not record the \(name) engine's pid: \(error.localizedDescription)")
        }
    }

    static func clear(_ name: String) { unlink(path(name)) }

    /// Ends every process executing a staged engine: those in pid files, then
    /// any other (one that started before its pid was written, say). A pid is
    /// only signalled while its executable is in the staged directory: a pid
    /// file outlives its process and the number may belong to another by now.
    /// Returns what it ended.
    static func killStrays() -> [String] {
        var ended: [String] = []
        func end(_ pid: pid_t, _ label: String) {
            guard pid > 1, pid != getpid(),
                  let exe = ProcessTable.executablePath(of: pid), ProcessTable.isDirectlyInside(exe, BundledEngines.binDirectory) else { return }
            if kill(pid, SIGKILL) == 0 { ended.append("\(label) (pid \(pid))") }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: BundledEngines.stateDirectory)) ?? []
        for file in files where file.hasSuffix(".pid") {
            let name = String(file.dropLast(4))
            if let text = try? String(contentsOfFile: path(name), encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                end(pid, name)
            }
            clear(name)
        }
        for process in ProcessTable.processes(executingIn: BundledEngines.binDirectory) {
            end(process.pid, ((process.path ?? "engine") as NSString).lastPathComponent)
        }
        return ended
    }
}
