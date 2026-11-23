#if canImport(AppKit)
import AppKit
import PassthroughCore
import ShellHost

/// This Mac's side of clipboard sync with the computers viewing its screen:
/// one session per viewer while it views. A copy here goes to all of them; a
/// copy there lands on this clipboard (and goes on to the others); files a
/// viewer drops are dragged to where they were dropped here.
@MainActor
public final class ClipSyncHost {
    /// Off: `clipSync` requests are answered `clip_sync_off`, and sessions end.
    public static let enabledKey = "clipSyncWithComputers"

    /// Where a viewer's drop lands on this Mac (0…65535 across its stream), or nil when unknown.
    private let dropPoint: @Sendable (String, UInt16, UInt16) -> CGPoint?
    private let staging: URL
    private var sessions: [String: Entry] = [:]
    private var watch: UUID?
    /// Clipboard folders kept, newest last, so pasting a recent copy still finds its files.
    private var clipboardFolders: [URL] = []
    /// Dropped files kept, newest last, with their size: an app that took them by reference (an upload)
    /// may still be reading them. The last 5, up to 2 GB in all (the newest whatever its size); older
    /// ones go at once, and the kept ones at the next launch.
    private var dropFolders: [(url: URL, bytes: UInt64)] = []
    static let dropsKept = 5
    static let dropBytesKept: UInt64 = 2 << 30
    /// Viewers' names, by id, while they sync.
    private var labels: [String: String] = [:]
    /// A viewer is dropping files here (its name, how many, where; nil: they go to Downloads), for a notice.
    public var onDropNotice: ((String, Int, CGPoint?) -> Void)?
    /// Who syncs the clipboard now, by id, whenever that changes (for the panel's viewer rows).
    public var onSyncingChanged: ((Set<String>) -> Void)?
    /// What was at each drop's point when its offer came, by viewer and transfer: it's dropped only on that.
    private var dropTargets: [String: DropPerformer.Target?] = [:]
    /// Read on the listener's queue.
    private let state = Locked(State())

    struct State {
        var enabled = true
        var viewing: [String: Bool] = [:]
    }

    private struct Entry {
        let source: Source
        let session: ClipSyncSession
    }

    public init(dropPoint: @escaping @Sendable (String, UInt16, UInt16) -> CGPoint?) {
        self.dropPoint = dropPoint
        // Made with the app's shell controller, before any screen window: what earlier runs received goes.
        ClipSyncStaging.clearAtLaunch()
        staging = ClipSyncStaging.root.appendingPathComponent("host", isDirectory: true)
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        setEnabled(UserDefaults.standard.bool(forKey: Self.enabledKey))
    }

    public func setEnabled(_ on: Bool) {
        var s = state.get(); s.enabled = on; state.set(s)
        if !on { for id in Array(sessions.keys) { end(id) } }
    }

    /// Whether `id` views the screen now (the app's count of its views is above 0):
    /// sync lasts only while it does.
    public func viewer(_ id: String, viewing: Bool) {
        var s = state.get()
        s.viewing[id] = viewing ? true : nil
        state.set(s)
        if !viewing {
            // Within a second, as the protocol says, so a view that reconnects keeps its sync.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.state.get().viewing[id] == nil else { return }
                self.end(id)
            }
        }
    }

    /// The listeners stopped: nobody views, nobody syncs.
    public func endAll() {
        var s = state.get(); s.viewing = [:]; state.set(s)
        for id in Array(sessions.keys) { end(id) }
    }

    /// For both listeners' `clipSync`, on their queue.
    public nonisolated func source(for id: String, label: String) -> Result<any ClipSyncSource, ShellError> {
        let s = state.get()
        guard s.enabled else { return .failure(.clipSyncOff) }
        guard s.viewing[id] != nil else { return .failure(.noScreenView) }
        return .success(Source(host: self, id: id, label: label))
    }

    /// What the listener runs: hands the stream to the host on the main thread.
    final class Source: ClipSyncSource, @unchecked Sendable {
        private weak var host: ClipSyncHost?
        let id: String
        let label: String
        private let stopped = Locked(false)

        init(host: ClipSyncHost, id: String, label: String) {
            self.host = host
            self.id = id
            self.label = label
        }

        func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void) {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard !stopped.get(), let host else { stream.cancel(); return ended() }
                    host.began(self, stream: stream, initialBytes: initialBytes, ended: ended)
                }
            }
        }

        func stop() {
            stopped.set(true)
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { host?.stopped(self) }
            }
        }
    }

    private func began(_ source: Source, stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void) {
        // Asked on the listener's queue; by now the view may have ended or sync been turned off.
        let s = state.get()
        guard s.enabled, s.viewing[source.id] != nil else {
            stream.cancel()
            return ended()
        }
        // One per viewer: a new one replaces the old.
        end(source.id)
        let id = source.id
        let session = ClipSyncSession(stream: stream, initialBytes: initialBytes, staging: staging) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, from: id, source: source, ended: ended) }
        }
        sessions[id] = Entry(source: source, session: session)
        labels[id] = source.label
        onSyncingChanged?(Set(sessions.keys))
        session.start()
        ptLog(.info, "clipsync: \(source.label) syncs the clipboard")
        if watch == nil {
            watch = ClipboardWatcher.shared.watch { [weak self] snapshot in self?.copied(snapshot) }
        }
    }

    private func stopped(_ source: Source) {
        guard sessions[source.id]?.source === source else { return }
        end(source.id)
    }

    private func end(_ id: String) {
        guard let entry = sessions.removeValue(forKey: id) else { return }
        entry.session.close()
        onSyncingChanged?(Set(sessions.keys))
        if sessions.isEmpty, let watch {
            ClipboardWatcher.shared.unwatch(watch)
            self.watch = nil
        }
    }

    /// Something was copied on this Mac.
    private func copied(_ snapshot: MacClipboard.Snapshot) {
        // Too large: the viewer can't be told on its clipboard; it's simply not sent.
        guard case let .payload(payload) = snapshot else { return }
        for entry in sessions.values { entry.session.send(payload, kind: .clipboard) }
    }

    private func handle(_ event: ClipSyncSession.Event, from id: String, source: Source, ended: @escaping @Sendable () -> Void) {
        guard let entry = sessions[id], entry.source === source else {
            if case .closed = event { ended() }
            return
        }
        switch event {
        case let .received(transfer):
            switch transfer.kind {
            case .clipboard: paste(transfer, from: id, session: entry.session)
            case .drop: drop(transfer, from: id, session: entry.session)
            }
        case let .incoming(transfer, kind, _, x, y) where kind == .drop:
            // The drop goes where the user let go only if the same thing is still there when it's all here.
            dropTargets["\(id)#\(transfer)"] = dropPoint(id, x, y).map(DropPerformer.target(at:)) ?? nil
        case let .incomingEnded(transfer):
            dropTargets["\(id)#\(transfer)"] = nil
        case .closed:
            sessions[id] = nil
            onSyncingChanged?(Set(sessions.keys))
            dropTargets = dropTargets.filter { !$0.key.hasPrefix(id + "#") }
            if sessions.isEmpty, let watch {
                ClipboardWatcher.shared.unwatch(watch)
                self.watch = nil
            }
            ended()
        default:
            break
        }
    }

    private func paste(_ transfer: ReceivedTransfer, from id: String, session: ClipSyncSession) {
        ClipboardWatcher.shared.wrote(changeCount: MacClipboard.write(transfer))
        session.result(transfer.transfer, .placed)
        if let folder = transfer.folder { keep(folder) }
        // The other viewers see this Mac's clipboard change too.
        let others = sessions.filter { $0.key != id }.map(\.value.session)
        if !others.isEmpty {
            let payload = transfer.payload
            for other in others { other.send(payload, kind: .clipboard) }
        }
    }

    private func keep(_ folder: URL) {
        clipboardFolders.append(folder)
        while clipboardFolders.count > 3 {
            try? FileManager.default.removeItem(at: clipboardFolders.removeFirst())
        }
    }

    private func drop(_ transfer: ReceivedTransfer, from id: String, session: ClipSyncSession) {
        let files = transfer.topLevel
        let folder = transfer.folder
        let noted = dropTargets.removeValue(forKey: "\(id)#\(transfer.transfer)")
        func cleanUp() {
            guard let folder else { return }
            dropFolders.append((folder, transfer.total))
            while dropFolders.count > Self.dropsKept
                    || (dropFolders.count > 1 && dropFolders.reduce(0, { $0 + $1.bytes }) > Self.dropBytesKept) {
                try? FileManager.default.removeItem(at: dropFolders.removeFirst().url)
            }
        }
        func toDownloads(copy: Bool = false) {
            DropPerformer.saveToDownloads(files, copy: copy) { saved in
                session.result(transfer.transfer, saved ? .savedToDownloads : .failed)
                cleanUp()
            }
        }
        guard !files.isEmpty else {
            session.result(transfer.transfer, .failed)
            return cleanUp()
        }
        let viewer = labels[id] ?? "A computer"
        // Unknown point, or something else there now (another window came up while the files came): Downloads.
        guard let point = dropPoint(id, transfer.x, transfer.y), let noted, DropPerformer.target(at: point) == noted else {
            onDropNotice?(viewer, files.count, nil)
            return toDownloads()
        }
        onDropNotice?(viewer, files.count, point)
        DropPerformer.drop(files, at: point) { outcome in
            switch outcome {
            case .dropped:
                session.result(transfer.transfer, .placed)
                cleanUp()
            case .notTaken: toDownloads()
            // Whatever is there may still be taking them: a copy in Downloads, the originals left as they are.
            case .timedOut: toDownloads(copy: true)
            }
        }
    }
}
#endif
