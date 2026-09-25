import Foundation
import Network

/// Feasibility probe for a wireless link (not the link itself): answers pings
/// over Apple peer-to-peer Wi-Fi (AWDL) so the Mac can measure whether the
/// phone stays reachable while it is locked and the proxy runs in the
/// background. Carries no traffic and has no access to the proxy.
public final class PeerProbeServer: @unchecked Sendable {
    public static let serviceType = "_ptprobe._tcp"
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.peer-probe")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let started = Date()

    public init() {}

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            do {
                let listener = try NWListener(using: params)
                listener.service = NWListener.Service(type: Self.serviceType)
                listener.stateUpdateHandler = { state in ptLog(.info, "peer probe listener: \(state)") }
                listener.serviceRegistrationUpdateHandler = { change in ptLog(.info, "peer probe service: \(change)") }
                listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                ptLog(.error, "peer probe listener failed: \(error)")
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let iface = c.currentPath?.availableInterfaces.first?.name ?? "?"
                ptLog(.info, "peer probe: connection from \(c.endpoint) on \(iface)")
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, buffer: LineBuffer(limit: 4096))
    }

    private func receive(_ c: NWConnection, buffer: LineBuffer) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            let lines = (try? buffer.append(data ?? Data())) ?? []
            for line in lines {
                let text = String(decoding: line, as: UTF8.self)
                let reply = "pong \(text) up=\(Int(Date().timeIntervalSince(self.started)))s\n"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            }
            if done || error != nil { c.cancel(); return }
            self.receive(c, buffer: buffer)
        }
    }
}

/// The other direction: the phone finds the Mac's probe service over
/// peer-to-peer Wi-Fi and dials out to it, pinging every 5 s and reconnecting
/// when the link drops. Tests whether the background extension can hold an
/// outgoing link while the phone is locked.
public final class PeerProbeDialer: @unchecked Sendable {
    public static let macServiceType = "_ptmac._tcp"
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.peer-dialer")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var timer: DispatchSourceTimer?
    private var seq = 0
    private var stopped = false

    public init() {}

    private static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }

    public func start() {
        queue.async { [self] in
            let browser = NWBrowser(for: .bonjour(type: Self.macServiceType, domain: nil), using: Self.parameters())
            browser.stateUpdateHandler = { ptLog(.info, "peer dialer browse: \($0)") }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                ptLog(.info, "peer dialer sees \(results.map { "\($0.endpoint) \($0.interfaces.map(\.name))" })")
                if let first = results.first, self.endpoint == nil {
                    self.endpoint = first.endpoint
                    self.dial()
                }
            }
            browser.start(queue: queue)
            self.browser = browser
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.ping() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            timer?.cancel(); timer = nil
            browser?.cancel(); browser = nil
            connection?.cancel(); connection = nil
        }
    }

    private func dial() {
        guard let endpoint, !stopped else { return }
        connection?.cancel()
        let c = NWConnection(to: endpoint, using: Self.parameters())
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ptLog(.info, "peer dialer connected via \(c.currentPath?.availableInterfaces.map(\.name) ?? [])")
            case .waiting(let e):
                ptLog(.info, "peer dialer waiting: \(e)")
            case .failed(let e):
                ptLog(.warning, "peer dialer failed: \(e); redialing in 5 s")
                self?.queue.asyncAfter(deadline: .now() + 5) { self?.dial() }
            default: break
            }
        }
        c.start(queue: queue)
        connection = c
        receive(c)
    }

    /// Answers the Mac: "echo <x>" comes straight back, "bulk <n>" returns n bytes.
    private func receive(_ c: NWConnection, buffer: LineBuffer = LineBuffer(limit: 4096)) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            var buffer = buffer
            for line in (try? buffer.append(data ?? Data())) ?? [] {
                let text = String(decoding: line, as: UTF8.self)
                if text.hasPrefix("echo ") {
                    c.send(content: Data("re\(text.dropFirst(4))\n".utf8), completion: .contentProcessed { _ in })
                } else if text.hasPrefix("bulk "), let n = Int(text.dropFirst(5)), n <= 16 << 20 {
                    var chunk = Data(repeating: 0x61, count: n)
                    chunk.append(0x0A)
                    c.send(content: chunk, completion: .contentProcessed { _ in })
                }
            }
            if done || error != nil { return }
            self?.receive(c, buffer: buffer)
        }
    }

    private func ping() {
        guard let c = connection, c.state == .ready else { return }
        seq += 1
        c.send(content: Data("ping \(seq) \(Date().timeIntervalSince1970)\n".utf8), completion: .contentProcessed { _ in })
    }
}
