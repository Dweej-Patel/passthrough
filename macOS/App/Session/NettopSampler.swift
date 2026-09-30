import AppKit
import Darwin
import PassthroughCore
import PhoneTransport

/// Per-app usage for the current session: runs `nettop` in bounded batches
/// (an unbounded `-L 0` run ignores `-s` and spins a core) and tallies each
/// app's growth on the tunnel's interface. See AppUsage.swift for what can
/// and cannot be attributed.
@MainActor
final class NettopSampler: ObservableObject {
    @Published private(set) var top: [AppUsageEntry] = []
    @Published private(set) var attributed: Int64 = 0
    /// nettop couldn't be run, or kept exiting: the numbers stopped updating.
    @Published private(set) var unavailable = false
    private var session: Date?
    private var interfaces: Set<String> = []
    private let engine = NettopEngine()

    init() {
        engine.onUpdate = { [weak self] session, top, attributed in
            Task { @MainActor in
                guard let self, self.session == session else { return }
                self.top = top
                self.attributed = attributed
            }
        }
        engine.onUnavailable = { [weak self] session in
            Task { @MainActor in
                guard let self, self.session == session else { return }
                self.unavailable = true
            }
        }
    }

    /// Called on every tick while connected: a new session starts a fresh
    /// tally; a changed interface set (VPN up or down) carries on counting.
    func sync(session: Date, interfaces: Set<String>) {
        if session != self.session {
            self.session = session
            self.interfaces = interfaces
            top = []; attributed = 0; unavailable = false
            engine.start(tracked: NettopInterface.names(interfaces), session: session)
        } else if interfaces != self.interfaces {
            self.interfaces = interfaces
            engine.track(NettopInterface.names(interfaces))
        }
    }

    func stop() {
        guard session != nil else { return }
        session = nil
        interfaces = []
        top = []; attributed = 0; unavailable = false
        engine.stop()
    }

    /// The top apps and "Other", fitted to the session total the card shows.
    func breakdown(sessionTotal: Int64) -> AppUsageBreakdown {
        AppUsageBreakdown(top: top, attributed: attributed, sessionTotal: sessionTotal)
    }

    /// Previews and snapshots.
    func debugApply(_ entries: [AppUsageEntry]) {
        top = entries
        attributed = entries.reduce(0) { $0 + $1.total }
    }
}

/// The off-main part. All state is confined to `queue`.
private final class NettopEngine: @unchecked Sendable {
    var onUpdate: ((Date, [AppUsageEntry], Int64) -> Void)?
    var onUnavailable: ((Date) -> Void)?
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.nettop", qos: .utility)
    private let resolver = RunningAppResolver()
    private var tally: AppUsageTally?
    private var parser = NettopParser()
    private var pending = Data()
    private var process: Process?
    private var generation = 0
    private var batch = 0
    /// The last batch whose end was handled (by end of file or the fallback).
    private var endedBatch = 0
    private var session = Date.distantPast
    private var policy = BatchRestartPolicy()
    private var lastPublish = Date.distantPast

    func start(tracked: Set<String>, session: Date) {
        queue.async { [self] in
            halt()
            self.session = session
            resolver.reset()
            tally = AppUsageTally(tracked: tracked, resolver: resolver)
            policy = BatchRestartPolicy()
            launch(generation)
        }
    }

    func track(_ tracked: Set<String>) {
        queue.async { [self] in tally?.tracked = tracked }
    }

    func stop() {
        queue.async { [self] in
            halt()
            tally = nil
        }
    }

    private func halt() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func launch(_ gen: Int) {
        guard gen == generation else { return }
        batch += 1
        let thisBatch = batch
        parser = NettopParser()
        pending = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NettopCommand.path)
        process.arguments = NettopCommand.arguments()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let started = Date()
        // The batch ends at end of file, not at exit: nettop's last sample is
        // flushed as it exits and can reach us after the termination handler.
        // The handler runs serially, so EOF is queued after every chunk.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.queue.async { self?.batchEnded(gen, thisBatch, ran: Date().timeIntervalSince(started)) }
                return
            }
            self?.queue.async { self?.consume(data, gen, thisBatch) }
        }
        // Fallback in case end of file never arrives; a no-op once it has.
        process.terminationHandler = { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 2) { self?.batchEnded(gen, thisBatch, ran: Date().timeIntervalSince(started)) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            ptLog(.warning, "Per-app usage unavailable: couldn't run nettop (\(error.localizedDescription))")
            onUnavailable?(session)
        }
    }

    private func consume(_ data: Data, _ gen: Int, _ thisBatch: Int) {
        guard gen == generation, thisBatch == batch, tally != nil else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            feed(line)
        }
    }

    private func feed(_ line: String) {
        switch parser.parse(line) {
        case .header:
            tally?.beginSample()
            publishIfDue()
        case .connection(let record):
            tally?.add(record)
        case .process, .skipped:
            break
        }
    }

    private func publishIfDue() {
        guard let tally, Date().timeIntervalSince(lastPublish) >= 1.5 else { return }
        lastPublish = Date()
        onUpdate?(session, tally.top(5), tally.attributed)
    }

    private func batchEnded(_ gen: Int, _ thisBatch: Int, ran: TimeInterval) {
        guard gen == generation, thisBatch == batch, thisBatch != endedBatch else { return }
        endedBatch = thisBatch
        process = nil
        if !pending.isEmpty { feed(String(decoding: pending, as: UTF8.self)) }
        pending = Data()
        tally?.endBatch()
        lastPublish = .distantPast
        publishIfDue()
        if policy.shouldRelaunch(afterRunOf: ran) {
            launch(gen)
        } else {
            ptLog(.warning, "Per-app usage stopped: nettop keeps exiting straight away")
            onUnavailable?(session)
        }
    }
}

/// pid → the app a person would recognise: the outermost .app around the
/// executable (so helpers count as their app), else the executable itself.
/// Called on the engine's queue only.
private final class RunningAppResolver: AppResolver, @unchecked Sendable {
    private var cache: [String: AppIdentity] = [:]

    /// A new session: pids from the last one may have been reused since.
    func reset() { cache = [:] }

    func identity(pid: Int32, processName: String) -> AppIdentity {
        let cacheKey = "\(pid)|\(processName)"
        if let hit = cache[cacheKey] { return hit }
        let identity: AppIdentity
        if let path = Self.executablePath(pid) {
            if let bundle = AppBundle.outermost(inExecutablePath: path) {
                let info = Bundle(path: bundle)?.infoDictionary
                let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
                    ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                identity = AppIdentity(key: bundle, name: name)
            } else {
                identity = AppIdentity(key: path, name: (path as NSString).lastPathComponent)
            }
        } else {
            identity = AppIdentity(key: "process:\(processName)", name: processName)
        }
        cache[cacheKey] = identity
        return identity
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Icons for `AppIdentity.key`s: a bundle or executable path gets its Finder
/// icon; anything else a generic one.
enum AppIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(forKey key: String) -> NSImage {
        if let hit = cache[key] { return hit }
        let image = key.hasPrefix("/") ? NSWorkspace.shared.icon(forFile: key)
            : NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[key] = image
        return image
    }
}
