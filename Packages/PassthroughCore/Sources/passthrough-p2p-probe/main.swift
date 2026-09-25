import Foundation
import Network
import PassthroughCore

// Mac side of the peer-to-peer feasibility probe. Finds the phone's probe
// service over AWDL, keeps one connection pinging every 5 s, and opens a fresh
// connection every 30 s, logging the interface each one uses.
//   swift run passthrough-p2p-probe [minutes]

let minutes = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let queue = DispatchQueue(label: "probe")
let t0 = Date()
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("\(f.string(from: Date())) +\(Int(Date().timeIntervalSince(t0)))s \(s)")
    fflush(stdout)
}

/// The AWDL interface from the browse result: connections go over the
/// direct link only, never USB or a shared network.
var awdl: NWInterface?

func p2pParameters() -> NWParameters {
    let p = NWParameters.tcp
    p.includePeerToPeer = true
    if let awdl { p.requiredInterface = awdl }
    return p
}

var endpoint: NWEndpoint?
var persistent: NWConnection?
var sent: [Int: Date] = [:]
var seq = 0
var lastPong = Date.distantPast

func describe(_ c: NWConnection) -> String {
    let path = c.currentPath
    let ifaces = path?.availableInterfaces.map(\.name).joined(separator: ",") ?? "?"
    return "via \(ifaces) local=\(path?.localEndpoint.map { "\($0)" } ?? "?")"
}

func readLines(_ c: NWConnection, _ onLine: @escaping (String) -> Void) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
        if let data { String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { onLine(String($0)) } }
        if done || error != nil { return }
        readLines(c, onLine)
    }
}

func openPersistent() {
    guard let endpoint else { return }
    persistent?.cancel()
    let c = NWConnection(to: endpoint, using: p2pParameters())
    var became = false
    queue.asyncAfter(deadline: .now() + 15) {
        guard !became, persistent === c else { return }
        log("persistent: not ready after 15s (\(c.state)); retrying")
        openPersistent()
    }
    c.stateUpdateHandler = { state in
        switch state {
        case .ready: became = true; log("persistent: ready \(describe(c))")
        case .waiting(let e): log("persistent: waiting \(e)")
        case .failed(let e): log("persistent: FAILED \(e); reopening in 5s"); queue.asyncAfter(deadline: .now() + 5) { openPersistent() }
        case .cancelled: break
        default: break
        }
    }
    readLines(c) { line in
        let n = Int(line.split(separator: " ").dropFirst().first ?? "") ?? -1
        if let at = sent.removeValue(forKey: n) {
            lastPong = Date()
            if n % 6 == 0 { log("persistent: \(line) rtt=\(Int(Date().timeIntervalSince(at) * 1000))ms") }
        }
    }
    c.start(queue: queue)
    persistent = c
}

func freshConnectionTest() {
    guard let endpoint else { return }
    let c = NWConnection(to: endpoint, using: p2pParameters())
    let start = Date()
    var done = false
    c.stateUpdateHandler = { state in
        switch state {
        case .ready:
            c.send(content: Data("fresh\n".utf8), completion: .contentProcessed { _ in })
            readLines(c) { line in
                guard !done else { return }; done = true
                log("fresh: ok in \(Int(Date().timeIntervalSince(start) * 1000))ms \(describe(c)) [\(line)]")
                c.cancel()
            }
        case .failed(let e): if !done { done = true; log("fresh: FAILED \(e)") }
        default: break
        }
    }
    c.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 10) { if !done { done = true; log("fresh: TIMEOUT after 10s"); c.cancel() } }
}

let browser = NWBrowser(for: .bonjour(type: PeerProbeServer.serviceType, domain: nil), using: p2pParameters())
browser.stateUpdateHandler = { log("browser: \($0)") }
browser.browseResultsChangedHandler = { results, _ in
    log("browser: \(results.count) result(s) \(results.map { "\($0.endpoint) \($0.interfaces.map(\.name))" })")
    if endpoint == nil, let hit = results.first(where: { $0.interfaces.contains { $0.name.hasPrefix("awdl") } }) {
        endpoint = hit.endpoint
        awdl = hit.interfaces.first { $0.name.hasPrefix("awdl") }
        log("using \(hit.endpoint) over \(awdl?.name ?? "?")")
        openPersistent()
    }
}
browser.start(queue: queue)

let pinger = DispatchSource.makeTimerSource(queue: queue)
pinger.schedule(deadline: .now() + 5, repeating: 5)
pinger.setEventHandler {
    guard let c = persistent, c.state == .ready else { return }
    seq += 1; sent[seq] = Date()
    c.send(content: Data("\(seq)\n".utf8), completion: .contentProcessed { _ in })
    if lastPong != .distantPast, Date().timeIntervalSince(lastPong) > 20 {
        log("persistent: no pong for \(Int(Date().timeIntervalSince(lastPong)))s")
    }
}
pinger.resume()
let fresh = DispatchSource.makeTimerSource(queue: queue)
fresh.schedule(deadline: .now() + 30, repeating: 30)
fresh.setEventHandler { freshConnectionTest() }
fresh.resume()

queue.asyncAfter(deadline: .now() + minutes * 60) { log("done"); exit(0) }
dispatchMain()
