import Foundation
import Network
import PassthroughCore

/// Listens on 127.0.0.1 and forwards each accepted stream over the phone's
/// link (see `PhoneLink`) to its SOCKS port. The tunnel helper talks to this
/// port; the phone does the real proxying. Counts bytes so the Mac UI can show live throughput.
public final class LocalForwarder: @unchecked Sendable {
    public let localPort: UInt16
    public let counter = ByteCounter()
    private let device: PhoneDevice
    private let remotePort: UInt16
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.forwarder", qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "dev.dpatel.passthrough.forwarder.state")
    private var listener: NWListener?
    private var pipes: [ObjectIdentifier: Pipe] = [:]
    public var onFailure: (@Sendable (Error) -> Void)?

    public init(device: PhoneDevice, remotePort: UInt16 = PassthroughProtocol.defaultSOCKSPort, localPort: UInt16 = PassthroughProtocol.defaultLocalSOCKSPort) {
        self.device = device
        self.remotePort = remotePort
        self.localPort = localPort
    }

    public func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: localPort)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { client.cancel(); return }
            let pipe = Pipe(forwarder: self, client: client)
            self.stateQueue.async { self.pipes[ObjectIdentifier(pipe)] = pipe }
            pipe.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                ptLog(.error, "Local forwarder failed: \(error)")
                self?.onFailure?(error)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        ptLog(.info, "Local SOCKS forwarder on 127.0.0.1:\(localPort) → \(device.kindName) \(device.label):\(remotePort)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let open: [Pipe] = stateQueue.sync { let p = Array(pipes.values); pipes.removeAll(); return p }
        open.forEach { $0.close() }
    }

    private var lastFailureLog = Date.distantPast
    fileprivate func logFailure(_ error: Error) {
        stateQueue.async {
            guard Date().timeIntervalSince(self.lastFailureLog) > 2 else { return }
            self.lastFailureLog = Date()
            ptLog(.warning, "USB connect to the phone failed: \(error.localizedDescription)")
        }
    }

    fileprivate func remove(_ pipe: Pipe) {
        stateQueue.async { self.pipes[ObjectIdentifier(pipe)] = nil }
    }

    fileprivate final class Pipe: @unchecked Sendable {
        private let forwarder: LocalForwarder
        private let client: NWConnection
        private var device: NWConnection?
        private let queue: DispatchQueue
        private var closed = false
        private var halfClosures = 0

        init(forwarder: LocalForwarder, client: NWConnection) {
            self.forwarder = forwarder
            self.client = client
            self.queue = DispatchQueue(label: "dev.dpatel.passthrough.pipe", target: forwarder.queue)
        }

        func start() {
            forwarder.counter.connectionOpened()
            client.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
            client.start(queue: queue)
            forwarder.device.connect(port: forwarder.remotePort, queue: queue) { [weak self] result in
                guard let self else { return }
                self.queue.async { self.opened(result) }
            }
        }

        private func opened(_ result: Result<NWConnection, Error>) {
            switch result {
            case .failure(let error):
                forwarder.logFailure(error)
                close()
            case .success(let device):
                guard !closed else { device.cancel(); return }
                self.device = device
                device.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.close() }
                    if case .cancelled = state { self?.close() }
                }
                pump(from: client, to: device, download: false)
                pump(from: device, to: client, download: true)
            }
        }

        private func pump(from source: NWConnection, to sink: NWConnection, download: Bool) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                if let data, !data.isEmpty {
                    if download { self.forwarder.counter.addRx(data.count) } else { self.forwarder.counter.addTx(data.count) }
                    sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if sendError != nil { self.close(); return }
                        if isComplete { self.halfClose(sink) } else { self.pump(from: source, to: sink, download: download) }
                    })
                } else if isComplete {
                    self.halfClose(sink)
                } else {
                    self.pump(from: source, to: sink, download: download)
                }
            }
        }

        private func halfClose(_ sink: NWConnection) {
            sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            halfClosures += 1
            if halfClosures >= 2 { close() }
        }

        func close() {
            queue.async { [self] in
                guard !closed else { return }
                closed = true
                client.cancel()
                device?.cancel()
                forwarder.counter.connectionClosed()
                forwarder.remove(self)
            }
        }
    }
}
