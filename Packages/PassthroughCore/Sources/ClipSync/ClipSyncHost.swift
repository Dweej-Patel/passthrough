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
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        staging = caches.appendingPathComponent("Passthrough/Received/host", isDirectory: true)
        // What earlier runs received is of no use now.
        try? FileManager.default.removeItem(at: staging)
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
        // One per viewer: a new one replaces the old.
        end(source.id)
        let id = source.id
        let session = ClipSyncSession(stream: stream, initialBytes: initialBytes, staging: staging) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, from: id, source: source, ended: ended) }
        }
        sessions[id] = Entry(source: source, session: session)
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
        case .closed:
            sessions[id] = nil
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
        func cleanUp() {
            // Late enough for whatever took them to have copied them.
            guard let folder else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: folder) }
        }
        guard !files.isEmpty else {
            session.result(transfer.transfer, .failed)
            return cleanUp()
        }
        guard let point = dropPoint(id, transfer.x, transfer.y) else {
            session.result(transfer.transfer, DropPerformer.saveToDownloads(files) ? .savedToDownloads : .failed)
            return cleanUp()
        }
        DropPerformer.drop(files, at: point) { outcome in
            switch outcome {
            case .dropped: session.result(transfer.transfer, .placed)
            case .notTaken: session.result(transfer.transfer, DropPerformer.saveToDownloads(files) ? .savedToDownloads : .failed)
            }
            cleanUp()
        }
    }
}
#endif
