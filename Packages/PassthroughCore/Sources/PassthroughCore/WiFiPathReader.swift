import Foundation
import Network

/// The Wi-Fi interface's path, kept current (`WirelessLink.WiFiFacts`). A
/// monitor that requires Wi-Fi reports that interface itself, also inside a
/// tunnel that holds every route.
public final class WiFiPathReader: @unchecked Sendable {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).wifi-path")
    private let lock = NSLock()
    private var latest: WirelessLink.WiFiFacts?
    private var waiting: [@Sendable (WirelessLink.WiFiFacts?) -> Void] = []
    /// Each change, on the reader's queue. Given at init, so it's in place
    /// before the first report.
    private let onChange: (@Sendable (WirelessLink.WiFiFacts) -> Void)?

    public init(onChange: (@Sendable (WirelessLink.WiFiFacts) -> Void)? = nil) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let facts = WirelessLink.WiFiFacts(path: path)
            let callbacks = self.lock.withLock { () -> [@Sendable (WirelessLink.WiFiFacts?) -> Void] in
                self.latest = facts
                defer { self.waiting.removeAll() }
                return self.waiting
            }
            callbacks.forEach { $0(facts) }
            self.onChange?(facts)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public func cancel() {
        monitor.cancel()
        lock.withLock { waiting.removeAll() }
    }

    /// The latest facts, nil until the monitor has reported once.
    public var facts: WirelessLink.WiFiFacts? { lock.withLock { latest } }

    /// The facts once known (the first report comes almost at once), or nil after `timeout`.
    public func whenKnown(timeout: TimeInterval = 1, _ completion: @escaping @Sendable (WirelessLink.WiFiFacts?) -> Void) {
        let once = Locked(false)
        let finish: @Sendable (WirelessLink.WiFiFacts?) -> Void = { facts in
            guard !once.exchange(true) else { return }
            completion(facts)
        }
        let known: WirelessLink.WiFiFacts? = lock.withLock {
            if latest == nil { waiting.append(finish) }
            return latest
        }
        if let known { return finish(known) }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in finish(self?.facts) }
    }
}
