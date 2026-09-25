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
