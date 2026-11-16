import Foundation
import Network

// Each device runs the same probe, in its tunnel extension ("ext") and/or in
// the app ("app"). A probe listens (TCP + UDP, advertised over Bonjour), dials
// every peer it finds (Bonjour and fixed addresses), and sends a heartbeat on
// every connection once a second. What each side hears, and when it stops
// hearing it, answers "who can reach whom" with the screen locked.

struct ProbeConfig: Codable {
    var role: String            // "phone" or "ipad"
    var host: String            // "ext" or "app"
    var fixedPeers: [String]    // addresses dialed without Bonjour
    var me: String { "\(role)-\(host)" }
}

struct PathStatus: Codable, Identifiable {
    var id: String
    var kind: String            // "tcp in", "tcp out", "udp in", "udp out"
    var peer: String            // the other probe's name once heard, else its address
    var remote: String
    var origin: String          // "listener", "bonjour", "fixed"
    var via: String             // interface
    var state: String
    var received: Int
    var lastHeardAgo: Double?
    var longestGap: Double
}

struct ProbeSnapshot: Codable {
    var me: String
    var running: Bool
    var updated: Date
    var paths: [PathStatus]
    var captured: Int
    var interfaces: String
}

enum ProbeFiles {
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "ProbeAppGroup") as? String ?? ""
    static var root: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    /// Library/, because `devicectl device copy from` may only read below it.
    static var dir: URL? { root?.appendingPathComponent("Library") }

    /// The first build wrote to the group's root; move those files into Library/.
    static func moveOldFiles() {
        guard let root, let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names where name.hasPrefix("probe-") || name.hasPrefix("status-") {
            let target = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: root.appendingPathComponent(name), to: target)
        }
    }
    static func log(_ me: String) -> URL? { dir?.appendingPathComponent("probe-\(me).log") }
    static func status(_ me: String) -> URL? { dir?.appendingPathComponent("status-\(me).json") }

    /// One line into a log without a running probe (tunnel start-up, the app's own events).
    static func append(_ me: String, _ text: String) {
        guard let url = log(me) else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) [\(me)] \(text)\n"
        NSLog("%@", line)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    }
}

enum ProbePorts {
    static func tcp(_ host: String) -> UInt16 { host == "ext" ? 47100 : 47200 }
    static func udp(_ host: String) -> UInt16 { tcp(host) + 1 }
}

private final class Link {
    enum Kind: String { case tcp, udp }
    let id = UUID().uuidString
    let kind: Kind
    let inbound: Bool
    let origin: String
    let connection: NWConnection
    let key: String?            // outbound: what to redial
    var peer = ""
    var state = "starting"
    var received = 0
    var seq = 0
    var lastRx: Date?
    var readyAt: Date?
    var longestGap: TimeInterval = 0
    var silentSince: Date?
    var warnedNothing = false
    var sendFailed = false
    var buffer = Data()
    var via = "?"
    var closed = false

    init(kind: Kind, inbound: Bool, origin: String, connection: NWConnection, key: String?) {
        self.kind = kind; self.inbound = inbound; self.origin = origin; self.connection = connection; self.key = key
    }

    var remote: String {
        if case .hostPort(let host, let port) = connection.endpoint { return "\(host):\(port)" }
        return "\(connection.endpoint)"
    }
    var row: String {
        "\(kind.rawValue) \(inbound ? "in ←" : "out →") \(peer.isEmpty ? remote : peer) [\(origin)]"
    }
}

final class Probe: @unchecked Sendable {
    let config: ProbeConfig
    private let queue = DispatchQueue(label: "probe")
    private var listeners: [NWListener] = []
    private var browsers: [NWBrowser] = []
    private var links: [String: Link] = [:]          // by id
    private var outbound: [String: Link] = [:]       // by key
    private var targets: [String: (NWEndpoint, Link.Kind, String)] = [:]
    private var timer: DispatchSourceTimer?
    private var monitor: NWPathMonitor?
    private var interfaces = ""
    private var logHandle: FileHandle?
    private var running = false
    private var ticks = 0
    private var captured = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    init(config: ProbeConfig) { self.config = config }

    private var me: String { config.me }

    // MARK: lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            openLog()
            log("── start \(me): tcp \(ProbePorts.tcp(config.host)), udp \(ProbePorts.udp(config.host)), fixed peers \(config.fixedPeers)")
            listen(.tcp)
            listen(.udp)
            browse(.tcp)
            browse(.udp)
            for ip in config.fixedPeers {
                for host in ["ext", "app"] {
                    let tcp = NWEndpoint.hostPort(host: .init(ip), port: .init(rawValue: ProbePorts.tcp(host))!)
                    let udp = NWEndpoint.hostPort(host: .init(ip), port: .init(rawValue: ProbePorts.udp(host))!)
                    addTarget("fixed tcp \(ip) \(host)", tcp, .tcp, "fixed")
                    addTarget("fixed udp \(ip) \(host)", udp, .udp, "fixed")
                }
            }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let text = "\(path.status) " + path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: " ")
                self.queue.async {
                    guard text != self.interfaces else { return }
                    self.interfaces = text
                    self.log("network: \(text)")
                }
            }
            monitor.start(queue: queue)
            self.monitor = monitor
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            timer?.cancel(); timer = nil
            monitor?.cancel(); monitor = nil
            listeners.forEach { $0.cancel() }; listeners = []
            browsers.forEach { $0.cancel() }; browsers = []
            targets = [:]
            for link in links.values { link.closed = true; link.connection.cancel() }
            links = [:]; outbound = [:]
            log("── stopped")
            writeStatus()
            try? logHandle?.close(); logHandle = nil
        }
    }

    /// Something worth a line in the timeline (screen lock, wake, captured packets).
    func note(_ text: String) { queue.async { [self] in log(text) } }

    func countCaptured(_ packets: [Data]) {
        queue.async { [self] in
            for packet in packets {
                captured += 1
                if captured <= 5, packet.count >= 20, packet[packet.startIndex] >> 4 == 4 {
                    let d = packet.dropFirst(16).prefix(4).map(String.init).joined(separator: ".")
                    log("tunnel captured a packet for \(d) (so the tunnel does carry this device's traffic)")
                }
            }
        }
    }

    // MARK: listening and finding peers

    private func parameters(_ kind: Link.Kind) -> NWParameters {
        let params: NWParameters = kind == .tcp ? .tcp : .udp
        params.includePeerToPeer = false        // hotspot only, like the real link
        params.allowLocalEndpointReuse = true
        return params
    }

    private func listen(_ kind: Link.Kind) {
        let port = kind == .tcp ? ProbePorts.tcp(config.host) : ProbePorts.udp(config.host)
        do {
            let listener = try NWListener(using: parameters(kind), on: .init(rawValue: port)!)
            listener.service = .init(name: me, type: "_ptprobe._\(kind.rawValue)")
            listener.stateUpdateHandler = { [weak self] state in self?.log("\(kind.rawValue) listener: \(state)") }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in self?.log("\(kind.rawValue) bonjour: \(change)") }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.adopt(connection, kind: kind, inbound: true, origin: "listener", key: nil)
            }
            listener.start(queue: queue)
            listeners.append(listener)
        } catch {
            log("✗ \(kind.rawValue) listener could not be made: \(error)")
        }
    }

    private func browse(_ kind: Link.Kind) {
        let browser = NWBrowser(for: .bonjour(type: "_ptprobe._\(kind.rawValue)", domain: nil), using: parameters(kind))
        browser.stateUpdateHandler = { [weak self] state in self?.log("\(kind.rawValue) browser: \(state)") }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      !name.hasPrefix(self.config.role + "-") else { continue }
                self.addTarget("bonjour \(kind.rawValue) \(name)", result.endpoint, kind, "bonjour")
            }
        }
        browser.start(queue: queue)
        browsers.append(browser)
    }

    private func addTarget(_ key: String, _ endpoint: NWEndpoint, _ kind: Link.Kind, _ origin: String) {
        guard running, targets[key] == nil else { return }
        log("found \(key)")
        targets[key] = (endpoint, kind, origin)
        dial(key)
    }

    private func dial(_ key: String) {
        guard running, outbound[key] == nil, let (endpoint, kind, origin) = targets[key] else { return }
        let connection = NWConnection(to: endpoint, using: parameters(kind))
        outbound[key] = adopt(connection, kind: kind, inbound: false, origin: origin, key: key)
    }

    // MARK: connections

    @discardableResult
    private func adopt(_ connection: NWConnection, kind: Link.Kind, inbound: Bool, origin: String, key: String?) -> Link {
        let link = Link(kind: kind, inbound: inbound, origin: origin, connection: connection, key: key)
        links[link.id] = link
        if inbound { log("incoming \(kind.rawValue) from \(link.remote)") }
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                link.state = "ready"
                link.readyAt = Date()
                link.via = connection.currentPath?.availableInterfaces.first?.name ?? "?"
                self.log("✓ \(link.row) connected via \(link.via)")
                self.receive(link)
            case .waiting(let error):
                if link.state != "waiting" { self.log("… \(link.row) waiting: \(error)") }
                link.state = "waiting"
                // Never ready: cancel so it is redialed instead of hanging.
                if !link.inbound, link.readyAt == nil {
                    self.queue.asyncAfter(deadline: .now() + 5) { if link.state == "waiting" { connection.cancel() } }
                }
            case .failed(let error):
                link.state = "failed"
                self.log("✗ \(link.row) failed: \(error)")
                self.close(link)
            case .cancelled:
                self.close(link)
            default: break
            }
        }
        connection.start(queue: queue)
        return link
    }

    private func receive(_ link: Link) {
        switch link.kind {
        case .tcp:
            link.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                guard let self, !link.closed else { return }
                if let data, !data.isEmpty {
                    link.buffer.append(data)
                    while let nl = link.buffer.firstIndex(of: 10) {
                        let line = String(decoding: link.buffer[link.buffer.startIndex..<nl], as: UTF8.self)
                        link.buffer = Data(link.buffer[(nl + 1)...])
                        self.heard(link, line)
                    }
                }
                if complete || error != nil {
                    self.log("✗ \(link.row) ended\(error.map { ": \($0)" } ?? " by the other side")")
                    link.connection.cancel()
                    return
                }
                self.receive(link)
            }
        case .udp:
            link.connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, !link.closed else { return }
                if let data { self.heard(link, String(decoding: data, as: UTF8.self)) }
                if let error {
                    self.log("✗ \(link.row) receive error: \(error)")
                    link.connection.cancel()
                    return
                }
                self.receive(link)
            }
        }
    }

    private func heard(_ link: Link, _ line: String) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 3, parts[0] == "hb" else { return }
        let now = Date()
        if link.peer.isEmpty {
            link.peer = String(parts[1])
            log("first heartbeat on \(link.row)")
        }
        link.received += 1
        if let last = link.lastRx { link.longestGap = max(link.longestGap, now.timeIntervalSince(last)) }
        if let since = link.silentSince {
            log("✓ \(link.row) heard again after \(Int(now.timeIntervalSince(since))) s of silence")
            link.silentSince = nil
        }
        link.lastRx = now
    }

    private func close(_ link: Link) {
        guard !link.closed else { return }
        link.closed = true
        links[link.id] = nil
        guard let key = link.key, outbound[key] === link else { return }
        outbound[key] = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dial(key) }
    }

    // MARK: heartbeats and status

    /// A file with complete protection can't be read while the device is
    /// locked (about 10 s after locking), so reading it tells lock state.
    private var lockState: Bool?
    private func checkLock() {
        guard let dir = ProbeFiles.dir else { return }
        let url = dir.appendingPathComponent("lock-canary-\(me)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("x".utf8).write(to: url, options: [.completeFileProtection])
        }
        let locked = (try? Data(contentsOf: url)) == nil
        guard locked != lockState else { return }
        if lockState != nil || locked { log(locked ? "🔒 device locked" : "🔓 device unlocked") }
        lockState = locked
    }

    private func tick() {
        guard running else { return }
        ticks += 1
        if ticks % 2 == 0 { checkLock() }
        let now = Date()
        for link in links.values where link.state == "ready" {
            link.seq += 1
            let message = Data("hb \(me) \(link.seq)\n".utf8)
            link.connection.send(content: message, completion: .contentProcessed { [weak self] error in
                guard let error, !link.sendFailed else { return }
                link.sendFailed = true
                self?.log("✗ \(link.row) send failed: \(error)")
            })
            if let last = link.lastRx, link.silentSince == nil, now.timeIntervalSince(last) > 5 {
                link.silentSince = last
                log("⚠︎ \(link.row) silent since \(stamp.string(from: last))")
            }
            if link.lastRx == nil, !link.warnedNothing, let ready = link.readyAt, now.timeIntervalSince(ready) > 10 {
                link.warnedNothing = true
                log("⚠︎ \(link.row) is connected but has heard nothing in 10 s")
            }
        }
        if ticks % 30 == 0 {
            let rows = links.values.sorted { $0.row < $1.row }.map { link -> String in
                let ago = link.lastRx.map { "\(Int(now.timeIntervalSince($0)))s ago" } ?? "never"
                return "  \(link.row): \(link.state), heard \(link.received), last \(ago), longest gap \(Int(link.longestGap))s"
            }
            log("summary (\(rows.count) paths):\n" + rows.joined(separator: "\n"))
        }
        writeStatus()
    }

    private func writeStatus() {
        let now = Date()
        let paths = links.values.map { link in
            PathStatus(id: link.id, kind: "\(link.kind.rawValue) \(link.inbound ? "in" : "out")",
                       peer: link.peer.isEmpty ? link.remote : link.peer, remote: link.remote, origin: link.origin,
                       via: link.via, state: link.state, received: link.received,
                       lastHeardAgo: link.lastRx.map { now.timeIntervalSince($0) }, longestGap: link.longestGap)
        }.sorted { ($0.kind, $0.peer) < ($1.kind, $1.peer) }
        let snapshot = ProbeSnapshot(me: me, running: running, updated: now, paths: paths, captured: captured, interfaces: interfaces)
        guard let url = ProbeFiles.status(me), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: log

    private func openLog() {
        guard let url = ProbeFiles.log(me) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: url)
        _ = try? logHandle?.seekToEnd()
    }

    /// Call on `queue` (or from Network callbacks, which run on it).
    private func log(_ text: String) {
        let line = "\(stamp.string(from: Date())) [\(me)] \(text)\n"
        NSLog("%@", line)
        try? logHandle?.write(contentsOf: Data(line.utf8))
    }
}
