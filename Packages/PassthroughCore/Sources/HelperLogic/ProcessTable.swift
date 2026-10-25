#if os(macOS)
import Darwin
import Foundation

/// What the kernel says about processes (libproc). Run as root it sees every
/// process; otherwise only the caller's own user's.
public enum ProcessTable {
    /// One process, as identified at the moment it was looked at.
    public struct Process: Equatable, Sendable {
        public var pid: pid_t
        public var uid: uid_t?
        public var path: String?
        public init(pid: pid_t, uid: uid_t?, path: String?) {
            self.pid = pid; self.uid = uid; self.path = path
        }
    }

    public static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// The executable's absolute path, nil once the process is gone.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// The real user ID it runs as.
    public static func uid(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
    }

    public static func describe(_ pid: pid_t) -> Process {
        Process(pid: pid, uid: uid(of: pid), path: executablePath(of: pid))
    }

    /// `path` with every symlink resolved, as the kernel reports executables
    /// (`/var/run/x` is `/private/var/run/x`); unchanged if it doesn't exist.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether the executable at `path` (as `executablePath` reports it) is directly inside `directory`.
    public static func isDirectlyInside(_ path: String, _ directory: String) -> Bool {
        (path as NSString).deletingLastPathComponent == realPath(directory)
    }

    /// Processes whose executable is directly inside `directory` (no trailing slash).
    public static func processes(executingIn directory: String, among pids: [pid_t]? = nil) -> [Process] {
        let directory = realPath(directory)
        return (pids ?? allPIDs()).compactMap { pid in
            guard let path = executablePath(of: pid), (path as NSString).deletingLastPathComponent == directory else { return nil }
            return Process(pid: pid, uid: uid(of: pid), path: path)
        }
    }

    /// Every process holding a TCP socket in LISTEN state on local `port`
    /// (any address, IPv4 or IPv6). A socket-activated launchd service has
    /// launchd (pid 1) among them, and the daemon once it has checked in.
    /// Processes that can't be inspected are left out, so call it as root.
    public static func tcpListeners(port: UInt16, among pids: [pid_t]? = nil) -> [Process] {
        (pids ?? allPIDs()).filter { holdsTCPListener(pid: $0, port: port) }.map(describe)
    }

    private static func holdsTCPListener(pid: pid_t, port: UInt16) -> Bool {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return false }
        for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            // The local port is kept in network byte order in an int.
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if tcp.tcpsi_state == Int32(TSI_S_LISTEN), local == port { return true }
        }
        return false
    }
}

/// Whether what listens on Screen Sharing's port (5900) is macOS's own
/// Screen Sharing. The Mac relays a phone's `screen` request there, and the
/// phone then sends the Mac account's password; any process of the user's
/// can listen on 5900 while Screen Sharing is off, so a listener alone
/// proves nothing. Screen Sharing is socket-activated: launchd (pid 1) owns
/// the listening socket, and screensharingd holds it too once it runs.
public enum ScreenSharingOwners {
    public enum Verdict: Int, Sendable {
        /// Nothing listens: Screen Sharing is off.
        case off = 0
        /// Only launchd and Apple's screensharingd (as root) hold the socket.
        case genuine = 1
        /// Something else listens there (as well).
        case impostor = 2
    }

    public static let daemonPath = "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd"

    public static func verdict(_ owners: [ProcessTable.Process]) -> Verdict {
        guard !owners.isEmpty else { return .off }
        let trusted = owners.allSatisfy { $0.pid == 1 || ($0.path == daemonPath && $0.uid == 0) }
        return trusted ? .genuine : .impostor
    }
}
#endif
