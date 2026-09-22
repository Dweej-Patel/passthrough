import Foundation
import Network
import PassthroughCore

/// Mac side of the control channel: says hello, pairs, keeps a heartbeat,
/// and relays the phone's live status.
public final class ControlClient: @unchecked Sendable {
    public struct Identity: Sendable {
        public var clientID: String
        public var name: String
        public var token: String?
        public init(clientID: String, name: String, token: String?) { self.clientID = clientID; self.name = name; self.token = token }
    }

    public enum Event: Sendable {
        case welcomed(paired: Bool, status: DeviceStatus, socksPort: UInt16)
        case paired(token: String)
        case pairingFailed(PairingFailure)
        case status(DeviceStatus, rx: Int64, tx: Int64, active: Int)
        case disconnected(Error?)
    }

    private let deviceID: Int
    private let port: UInt16
    private let identity: Identity
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.control-client")
    private var connection: NWConnection?
    private var buffer = Data()
    private var heartbeat: DispatchSourceTimer?
    private var lastPong = Date()
    private var closed = false
    private let handler: @Sendable (Event) -> Void

    public init(deviceID: Int, port: UInt16 = PassthroughProtocol.defaultControlPort, identity: Identity, handler: @escaping @Sendable (Event) -> Void) {
        self.deviceID = deviceID
        self.port = port
        self.identity = identity
        self.handler = handler
    }

    public func connect() {
        USBMux.connect(deviceID: deviceID, port: port, queue: queue) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    self.finish(error)
                case .success(let connection):
                    guard !self.closed else { connection.cancel(); return }
                    self.connection = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .failed(let error): self?.finish(error)
                        case .cancelled: self?.finish(nil)
                        default: break
                        }
                    }
                    var hello = ControlEnvelope(t: ControlEnvelope.hello)
                    hello.protocolVersion = PassthroughProtocol.version
                    hello.clientID = self.identity.clientID
                    hello.name = self.identity.name
                    hello.token = self.identity.token
                    self.send(hello)
                    self.receive()
                    self.startHeartbeat()
                }
            }
        }
    }

    public func pair(code: String) {
        queue.async {
            var m = ControlEnvelope(t: ControlEnvelope.pair)
            m.clientID = self.identity.clientID
            m.name = self.identity.name
            m.code = code
            self.send(m)
        }
    }

    public func close() {
        queue.async { self.finish(nil, silent: true) }
    }

    private func startHeartbeat() {
        lastPong = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPong) > 20 {
                self.finish(NSError(domain: "Passthrough", code: 1, userInfo: [NSLocalizedDescriptionKey: "The iPhone stopped responding"]))
                return
            }
            self.send(ControlEnvelope(t: ControlEnvelope.ping))
        }
        timer.resume()
        heartbeat = timer
    }

    private func send(_ message: ControlEnvelope) {
        guard let connection, let data = try? message.encodedLine() else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<newline)
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let message = try? ControlEnvelope.decode(line) { self.handle(message) }
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(nil); return }
            self.receive()
        }
    }

    private func handle(_ m: ControlEnvelope) {
        lastPong = Date()
        let status = DeviceStatus(deviceName: m.deviceName ?? "iPhone", radio: m.radio, carrier: m.carrier, battery: m.battery, hosting: m.hosting ?? "")
        switch m.t {
        case ControlEnvelope.welcome:
            handler(.welcomed(paired: m.paired ?? false, status: status, socksPort: UInt16(m.socksPort ?? Int(PassthroughProtocol.defaultSOCKSPort))))
        case ControlEnvelope.paired:
            if let token = m.token { handler(.paired(token: token)) }
        case ControlEnvelope.error:
            handler(.pairingFailed(PairingFailure(rawValue: m.reason ?? "") ?? .badCode))
        case ControlEnvelope.status:
            handler(.status(status, rx: m.rxBytes ?? 0, tx: m.txBytes ?? 0, active: m.activeConnections ?? 0))
        default: break
        }
    }

    private func finish(_ error: Error?, silent: Bool = false) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        connection?.cancel()
        connection = nil
        if !silent { handler(.disconnected(error)) }
    }
}
