import Foundation
import Network
import PassthroughCore

/// How a watcher is doing, for the Mac UI.
public struct WatchStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case idle, notInstalled, starting, watching, unavailable }
    public var state: State
    /// Something the user must do on the phone (e.g. allow USB debugging).
    public var hint: String?
    public init(state: State = .idle, hint: String? = nil) { self.state = state; self.hint = hint }
}

/// Finds phones over one transport and reports the ones ready to use.
/// Restarts itself after failures until stopped.
@MainActor
public protocol DeviceWatcher: AnyObject {
    var transport: WatchTransport { get }
    var status: WatchStatus { get }
    /// Every usable phone this watcher sees, oldest first.
    var onDevicesChange: (([PhoneDevice]) -> Void)? { get set }
    var onStatusChange: ((WatchStatus) -> Void)? { get set }
    func start()
    /// Stops watching and reports an empty device list.
    func stop()
}

public enum WatchTransport: Sendable { case usbmux, adb, wireless }

/// Tracks every watcher's phones in attach order and reports each change.
@MainActor
public final class DeviceDirectory {
    public enum Change: Sendable { case attached(PhoneDevice), detached(PhoneDevice) }

    public private(set) var devices: [PhoneDevice] = []
    public var onChange: ((Change) -> Void)?
    public let watchers: [any DeviceWatcher]
    /// Which watcher reported each device.
    private var source: [String: WatchTransport] = [:]

    public init(watchers: [any DeviceWatcher]) {
        self.watchers = watchers
        for watcher in watchers {
            let transport = watcher.transport
            watcher.onDevicesChange = { [weak self] list in self?.update(transport, list) }
        }
    }

    public func watcher(for transport: WatchTransport) -> (any DeviceWatcher)? {
        watchers.first { $0.transport == transport }
    }

    /// Detaches first, then attaches, so a replugged phone reads as a fresh arrival.
    private func update(_ transport: WatchTransport, _ list: [PhoneDevice]) {
        let listed = Set(list.map(\.id))
        for gone in devices where source[gone.id] == transport && !listed.contains(gone.id) {
            devices.removeAll { $0.id == gone.id }
            source[gone.id] = nil
            onChange?(.detached(gone))
        }
        for new in list where !devices.contains(where: { $0.id == new.id }) {
            devices.append(new)
            source[new.id] = transport
            onChange?(.attached(new))
        }
    }
}

// MARK: iPhones

/// Watches usbmuxd for iPhones on the cable.
@MainActor
public final class USBMuxWatcher: DeviceWatcher {
    public let transport = WatchTransport.usbmux
    public private(set) var status = WatchStatus() { didSet { if status != oldValue { onStatusChange?(status) } } }
    public var onDevicesChange: (([PhoneDevice]) -> Void)?
    public var onStatusChange: ((WatchStatus) -> Void)?

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var restartTask: Task<Void, Never>?
    private var devices: [PhoneDevice] = []

    public init(queue: DispatchQueue = DispatchQueue(label: "dev.dpatel.passthrough.usbmux-watch")) {
        self.queue = queue
    }

    public func start() {
        connection?.cancel()
        connection = USBMux.listen(queue: queue) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    public func stop() {
        restartTask?.cancel(); restartTask = nil
        connection?.cancel(); connection = nil
        status = WatchStatus()
        publish([])
    }

    private func handle(_ event: USBMux.Event) {
        switch event {
        case .listening:
            status = WatchStatus(state: .watching)
            ptLog(.debug, "Watching usbmuxd for iPhones")
        case .attached(let d):
            guard d.isUSB, !devices.contains(where: { $0.id == "usbmux:\(d.id)" }) else { return }
            publish(devices + [.iPhone(deviceID: d.id, udid: d.udid)])
        case .detached(let id):
            publish(devices.filter { $0.id != "usbmux:\(id)" })
        case .failed(let error):
            // Coalesce: a connection can report waiting then failed; one restart only.
            guard restartTask == nil else { return }
            status = WatchStatus(state: .unavailable)
            ptLog(.error, "usbmuxd watch failed: \(error.localizedDescription); retrying")
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.restartTask = nil
                self.start()
            }
        }
    }

    private func publish(_ list: [PhoneDevice]) {
        devices = list
        onDevicesChange?(list)
    }
}

// MARK: Android phones

/// Watches the adb server for Android phones on the cable, starting the server
/// when platform-tools are installed but it isn't running.
@MainActor
public final class ADBWatcher: DeviceWatcher {
    public let transport = WatchTransport.adb
    public private(set) var status = WatchStatus() { didSet { if status != oldValue { onStatusChange?(status) } } }
    public var onDevicesChange: (([PhoneDevice]) -> Void)?
    public var onStatusChange: ((WatchStatus) -> Void)?

    private let queue: DispatchQueue
    /// Diagnostics only: also accept emulators and adb-over-Wi-Fi devices.
    private let includeNonUSB: Bool
    private var connection: NWConnection?
    private var restartTask: Task<Void, Never>?
    private var lastServerStart = Date.distantPast
    private var running = false

    public init(includeNonUSB: Bool = false, queue: DispatchQueue = DispatchQueue(label: "dev.dpatel.passthrough.adb-watch")) {
        self.includeNonUSB = includeNonUSB
        self.queue = queue
    }

    public func start() {
        running = true
        restartTask?.cancel(); restartTask = nil
        connection?.cancel()
        connection = ADB.track(queue: queue) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    public func stop() {
        running = false
        restartTask?.cancel(); restartTask = nil
        connection?.cancel(); connection = nil
        status = WatchStatus()
        onDevicesChange?([])
    }

    private func handle(_ event: ADB.Event) {
        guard running else { return }
        switch event {
        case .devices(let list):
            if status.state != .watching { ptLog(.debug, "Watching adb for Android phones") }
            let eligible = list.filter { $0.isUSB || includeNonUSB }
            onDevicesChange?(eligible.filter(\.isReady).map { .android(serial: $0.serial, model: $0.model) })
            status = WatchStatus(state: .watching, hint: Self.hint(for: eligible))
        case .failed(let error):
            onDevicesChange?([])
            status.hint = nil
            guard restartTask == nil else { return }
            let delay = recover(from: error)
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.restartTask = nil
                self.start()
            }
        }
    }

    /// Updates the status for a failed watch and returns how long to wait before retrying.
    private func recover(from error: Error) -> Duration {
        guard (error as? ADB.ADBError) == .serverUnavailable else {
            ptLog(.debug, "adb watch ended: \(error.localizedDescription); retrying")
            return .seconds(5)
        }
        guard let binary = ADB.findBinary() else {
            if status.state != .notInstalled { ptLog(.debug, "adb not found; Android phones need Android platform-tools") }
            status = WatchStatus(state: .notInstalled)
            return .seconds(30)
        }
        // Start the server ourselves, but not in a tight loop if it keeps dying.
        guard Date().timeIntervalSince(lastServerStart) > 60 else {
            status = WatchStatus(state: .unavailable)
            return .seconds(5)
        }
        lastServerStart = Date()
        status = WatchStatus(state: .starting)
        ptLog(.info, "Starting the adb server (\(binary))")
        Task.detached { ADB.startServer(binary: binary) }
        return .seconds(2)
    }

    nonisolated static func hint(for devices: [ADB.Device]) -> String? {
        if devices.contains(where: { $0.state == "unauthorized" }) {
            return "Unlock the Android phone and allow USB debugging for this Mac."
        }
        if devices.contains(where: { $0.state.contains("permission") }) {
            return "adb can't access the Android phone. Replug the cable and choose File Transfer if asked."
        }
        if devices.contains(where: { $0.state == "offline" }) {
            return "The Android phone is offline to adb. Replug the cable."
        }
        return nil
    }
}
