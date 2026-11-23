#if canImport(AppKit)
import AppKit
import PassthroughCore

/// Where received files are put, a folder per side; cleared when the app starts.
public enum ClipSyncStaging {
    public static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Passthrough/Received", isDirectory: true)
    }

    nonisolated(unsafe) private static var cleared = false
    private static let lock = NSLock()

    /// What earlier runs received (a quit or crash leaves it) is of no use now. Only the
    /// first call in a run clears it, so a later one can't take files a clipboard points at.
    public static func clearAtLaunch() {
        lock.lock(); defer { lock.unlock() }
        guard !cleared else { return }
        cleared = true
        try? FileManager.default.removeItem(at: root)
    }
}

/// A viewer window's side of clipboard sync with the computer it shows: this
/// Mac's copies go there, that computer's land here, and files dropped on the
/// window are sent to be dropped there. One per window, across reconnects
/// (its received files, the last 3 copies, span them). `onStatus` gets a line
/// to show for a while (nil clears it), on the main thread.
@MainActor
public final class ClipSyncViewer {
    private let hostName: String
    private let onStatus: (String?) -> Void
    private var session: ClipSyncSession?
    private var watch: UUID?
    private let staging: URL
    private var clipboardFolders: [URL] = []
    /// Drops on their way, by transfer: how many items, for what's said when they land.
    private var drops: [UInt32: Int] = [:]
    /// A large copy whose progress is on show, either way: its line is replaced when it ends.
    private var copyingOut: UInt32?
    private var copyingIn: UInt32?
    private var clearStatus: DispatchWorkItem?
    private var sessionNumber = 0

    public init(hostName: String, onStatus: @escaping (String?) -> Void) {
        self.hostName = hostName
        self.onStatus = onStatus
        staging = ClipSyncStaging.root.appendingPathComponent("viewer-\(UUID().uuidString)", isDirectory: true)
    }

    public var isActive: Bool { session != nil }

    /// Syncs over `stream` (after `clipSyncReady`) until the stream ends (`ended`) or
    /// `stop()`. `offerCurrent`: send what's on this Mac's clipboard now (unless it's
    /// files, an upload nobody asked for).
    public func start(stream: any ByteStream, initialBytes: Data, offerCurrent: Bool, ended: @escaping () -> Void) {
        endSession()
        // Its events carry its number: those of one ended since say nothing more.
        sessionNumber += 1
        let number = sessionNumber
        // The host never drops on its viewer: such an offer is declined at once.
        let session = ClipSyncSession(stream: stream, initialBytes: initialBytes, staging: staging, acceptsDrops: false) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.sessionNumber == number, self.session != nil else { return }
                self.handle(event, ended: ended)
            }
        }
        self.session = session
        session.start()
        watch = ClipboardWatcher.shared.watch { [weak self] snapshot in self?.copied(snapshot, announce: true) }
        guard offerCurrent else { return }
        ClipboardWatcher.shared.current { [weak self] snapshot in
            guard case let .payload(payload) = snapshot, !payload.hasFiles else { return }
            self?.copied(snapshot, announce: false)
        }
    }

    /// Ends syncing for good: the window closed, or sync was turned off. Received files go.
    public func stop() {
        endSession()
        try? FileManager.default.removeItem(at: staging)
        clipboardFolders = []
    }

    private func endSession() {
        session?.close()
        session = nil
        if let watch { ClipboardWatcher.shared.unwatch(watch) }
        watch = nil
        drops = [:]
        copyingOut = nil
        copyingIn = nil
    }

    /// Files dropped on the window at (`x`, `y`), each 0…65535 across the stream.
    public func drop(_ urls: [URL], x: UInt16, y: UInt16) {
        guard session != nil else { return status("Clipboard sync isn't on, so files can't go to \(hostName).") }
        status("Getting \(urls.count == 1 ? "it" : "them") ready…", hold: true)
        // A big folder takes a while to count: not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClipPayload.files(urls)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.send(drop: result, count: urls.count, x: x, y: y) }
            }
        }
    }

    private func send(drop result: Result<ClipPayload, ClipPayload.FilesError>, count: Int, x: UInt16, y: UInt16) {
        guard let session else { return status(nil) }
        switch result {
        case let .success(payload) where !payload.items.isEmpty:
            let id = session.send(payload, kind: .drop, x: x, y: y)
            drops[id] = count
            status("Sending \(Self.files(count, payload.total)) to \(hostName)…", hold: true)
        default:
            status("Those files couldn't be read.")
        }
    }

    private func copied(_ snapshot: MacClipboard.Snapshot, announce: Bool) {
        switch snapshot {
        case let .payload(payload):
            guard let id = session?.send(payload, kind: .clipboard) else { return }
            if announce, payload.total > 20 << 20 {
                copyingOut = id
                status("Copying \(Self.size(payload.total)) to \(hostName)…", hold: true)
            } else if copyingOut != nil {
                // The big copy was replaced by this one.
                copyingOut = nil
                status(nil)
            }
        case .tooLarge:
            if announce { status("Too large to sync (over 500 MB). Drag it onto the window instead.") }
        case .nothing:
            break
        }
    }

    private func handle(_ event: ClipSyncSession.Event, ended: @escaping () -> Void) {
        switch event {
        case let .received(transfer):
            switch transfer.kind {
            case .clipboard:
                ClipboardWatcher.shared.wrote(changeCount: MacClipboard.write(transfer))
                session?.result(transfer.transfer, .placed)
                let wasShown = copyingIn == transfer.transfer
                if wasShown { copyingIn = nil }
                if let folder = transfer.folder {
                    clipboardFolders.append(folder)
                    while clipboardFolders.count > 3 { try? FileManager.default.removeItem(at: clipboardFolders.removeFirst()) }
                    status("Copied \(Self.files(transfer.topLevel.count, nil)) from \(hostName).")
                } else if wasShown {
                    status("Copied from \(hostName).")
                }
            case .drop:
                // Declined at the offer (`acceptsDrops`); never here.
                if let folder = transfer.folder { try? FileManager.default.removeItem(at: folder) }
            }
        case let .incoming(transfer, kind, total, _, _) where kind == .clipboard && total > 20 << 20:
            copyingIn = transfer
            status("Copying \(Self.size(total)) from \(hostName)…", hold: true)
        case let .incomingEnded(transfer):
            if copyingIn == transfer {
                copyingIn = nil
                status(nil)
            }
        case let .sent(transfer):
            if let count = drops[transfer] { status("Dropping \(Self.files(count, nil)) on \(hostName)…", hold: true) }
            if copyingOut == transfer {
                copyingOut = nil
                status("Sent to \(hostName).")
            }
        case let .result(transfer, result):
            guard let count = drops.removeValue(forKey: transfer) else { return }
            switch result {
            case .placed: status("Dropped \(Self.files(count, nil)) on \(hostName).")
            case .savedToDownloads: status("\(count == 1 ? "It's" : "They're") in \(hostName)'s Downloads: nothing took \(count == 1 ? "it" : "them") at that spot, or something else was there by then.")
            case .failed: status("\(hostName) couldn't take \(count == 1 ? "that file" : "those files").")
            }
        case let .declined(transfer, reason):
            if copyingOut == transfer { copyingOut = nil }
            let what = drops.removeValue(forKey: transfer).map { Self.files($0, nil) } ?? "That copy"
            switch reason {
            case .tooLarge: status("\(what.prefix(1).uppercased() + what.dropFirst()) is too large for \(hostName).")
            case .noRoom: status("\(hostName) hasn't room for \(what.lowercased()).")
            case .syncOff: status("\(hostName) has clipboard sync turned off.")
            case .badOffer, .failed: status("\(what.prefix(1).uppercased() + what.dropFirst()) couldn't go to \(hostName).")
            }
        case .closed:
            session = nil
            if let watch { ClipboardWatcher.shared.unwatch(watch) }
            watch = nil
            drops = [:]
            copyingOut = nil
            copyingIn = nil
            status(nil)
            ended()
        default:
            break
        }
    }

    private func status(_ text: String?, hold: Bool = false) {
        clearStatus?.cancel()
        onStatus(text)
        guard !hold, text != nil else { return }
        let clear = DispatchWorkItem { [weak self] in self?.onStatus(nil) }
        clearStatus = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
    }

    static func files(_ count: Int, _ bytes: UInt64?) -> String {
        let n = count == 1 ? "1 item" : "\(count) items"
        guard let bytes, bytes > 0 else { return n }
        return "\(n) (\(size(bytes)))"
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
#endif
