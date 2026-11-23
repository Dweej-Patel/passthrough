#if canImport(AppKit)
import AppKit
import PassthroughCore

/// Where received files are put, a folder per side; cleared when the app starts.
public enum ClipSyncStaging {
    public static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Passthrough/Received", isDirectory: true)
    }

    private static let cleared = Locked(false)

    /// What earlier runs received (a quit or crash leaves it) is of no use now. Only the
    /// first call in a run clears it, so a later one can't take files a clipboard points
    /// at; the folder is moved aside at once and deleted off the main thread.
    public static func clearAtLaunch() {
        guard !cleared.get() else { return }
        cleared.set(true)
        let root = self.root
        let aside = root.deletingLastPathComponent().appendingPathComponent("Received-old-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.moveItem(at: root, to: aside)) != nil else { return }
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: aside) }
    }
}

/// A line clipboard sync shows at the top of a screen window, with buttons when it asks something.
public struct ClipStatus {
    public struct Action {
        public let title: String
        public let run: @MainActor () -> Void
    }

    public let text: String
    public let actions: [Action]
    /// Said again to VoiceOver as it appears.
    public let announce: Bool

    public init(_ text: String, actions: [Action] = [], announce: Bool = true) {
        self.text = text
        self.actions = actions
        self.announce = announce
    }
}

/// A viewer window's side of clipboard sync with the computer it shows: this
/// Mac's copies go there, that computer's land here, and files dropped on the
/// window are sent to be dropped there. One per window, across reconnects:
/// its received files (the last 3 copies) span them. `onStatus` gets a line
/// to show (nil clears it), on the main thread.
@MainActor
public final class ClipSyncViewer {
    /// Files copied here larger than this ask before they go; copies coming the other way
    /// this large can be stopped. Drops don't ask: dropping is asking.
    public static let askAbove: UInt64 = 50_000_000

    private let hostName: String
    private let onStatus: (ClipStatus?) -> Void
    private var session: ClipSyncSession?
    private var watch: UUID?
    private let staging: URL
    private var clipboardFolders: [URL] = []
    /// Drops on their way, by transfer: how many items, for what's said when they land.
    private var drops: [UInt32: Int] = [:]
    /// A large copy whose progress is on show, either way: its line is replaced when it ends.
    private var copyingOut: UInt32?
    private var copyingIn: UInt32?
    /// A large copy of files waiting for Send.
    private var waiting: ClipPayload?
    private var clearStatus: DispatchWorkItem?
    private var sessionNumber = 0

    public init(hostName: String, onStatus: @escaping (ClipStatus?) -> Void) {
        self.hostName = hostName
        self.onStatus = onStatus
        ClipSyncStaging.clearAtLaunch()
        staging = ClipSyncStaging.root.appendingPathComponent("viewer-\(UUID().uuidString)", isDirectory: true)
    }

    public var isActive: Bool { session != nil }

    /// Syncs over `stream` (after `clipSyncReady`) until the stream ends (`ended`) or
    /// `disconnect()`. Only what's copied from now on goes over: opening a window
    /// never changes the other computer's clipboard.
    public func start(stream: any ByteStream, initialBytes: Data, ended: @escaping () -> Void) {
        disconnect()
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
        watch = ClipboardWatcher.shared.watch { [weak self] snapshot in self?.copied(snapshot) }
    }

    /// Stops this connection's syncing (the view is reconnecting); what was received stays.
    public func disconnect() {
        session?.close()
        session = nil
        if let watch { ClipboardWatcher.shared.unwatch(watch) }
        watch = nil
        drops = [:]
        copyingOut = nil
        copyingIn = nil
        waiting = nil
    }

    /// Ends syncing for good: the window closed, or sync was turned off. Received files go,
    /// except a copy this Mac's clipboard still holds (it can still be pasted; it goes at the next launch).
    public func stop() {
        disconnect()
        status(nil)
        let kept = MacClipboard.folders(within: staging)
        for folder in clipboardFolders where !kept.contains(folder.standardizedFileURL) {
            try? FileManager.default.removeItem(at: folder)
        }
        clipboardFolders = clipboardFolders.filter { kept.contains($0.standardizedFileURL) }
    }

    /// Files dropped on the window at (`x`, `y`), each 0…65535 across the stream.
    public func drop(_ urls: [URL], x: UInt16, y: UInt16) {
        guard session != nil else { return status("Clipboard sync isn't running, so files can't go to \(hostName).") }
        status(Self.preparing(urls.count), hold: true, announce: false)
        // A big folder takes a while to count: not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClipPayload.files(urls, maxItems: Int(ClipSyncSession.maxDropItems))
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
            status("Sending \(Self.items(count, payload.total)) to \(hostName)…", hold: true)
        case .failure(.tooLarge):
            status("That's too many files to drop at once (\(ClipSyncSession.maxDropItems.formatted()) at most). Try a few folders at a time.")
        default:
            status("Those files couldn't be read.")
        }
    }

    private func copied(_ snapshot: MacClipboard.Snapshot) {
        switch snapshot {
        case let .payload(payload) where payload.hasFiles && payload.total > Self.askAbove:
            // A big upload shouldn't start because of a ⌘C: ask, and send only on Send.
            waiting = payload
            let size = Self.size(payload.total)
            status("Send \(size) of files to \(hostName)?", hold: true, actions: [
                .init(title: "Send") { [weak self] in self?.sendWaiting() },
                .init(title: "Don't Send") { [weak self] in self?.waiting = nil; self?.status(nil) },
            ])
        case let .payload(payload):
            if waiting != nil { waiting = nil; status(nil) }
            send(clipboard: payload)
        case let .tooLarge(files):
            waiting = nil
            status(files
                ? "Too large to sync (files up to 500 MB). Drag them onto the window instead."
                : "Too large to sync (text up to 16 MB, images up to 64 MB). Save it as a file and drag that onto the window.")
        case .nothing:
            break
        }
    }

    private func sendWaiting() {
        guard let payload = waiting else { return status(nil) }
        waiting = nil
        send(clipboard: payload)
    }

    private func send(clipboard payload: ClipPayload) {
        guard let id = session?.send(payload, kind: .clipboard) else { return }
        if payload.total > 20 << 20 {
            copyingOut = id
            status("Copying \(Self.size(payload.total)) to \(hostName)…", hold: true, announce: false)
        } else if copyingOut != nil {
            // The big copy was replaced by this one.
            copyingOut = nil
            status(nil)
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
                    status("Ready to paste: \(Self.items(transfer.topLevel.count, nil)) from \(hostName).")
                } else if wasShown {
                    status("Ready to paste from \(hostName).")
                }
            case .drop:
                // Declined at the offer (`acceptsDrops`); never here.
                if let folder = transfer.folder { try? FileManager.default.removeItem(at: folder) }
            }
        case let .incoming(transfer, kind, total, _, _) where kind == .clipboard && total > 20 << 20:
            copyingIn = transfer
            let actions: [ClipStatus.Action] = total > Self.askAbove
                ? [.init(title: "Stop") { [weak self] in self?.stopIncoming(transfer) }]
                : []
            status("Copying \(Self.size(total)) from \(hostName)…", hold: true, actions: actions, announce: false)
        case let .incomingEnded(transfer):
            if copyingIn == transfer {
                copyingIn = nil
                status(nil)
            }
        case let .sent(transfer):
            if let count = drops[transfer] { status("Dropping \(Self.items(count, nil)) on \(hostName)…", hold: true, announce: false) }
            if copyingOut == transfer {
                copyingOut = nil
                status("Sent to \(hostName).")
            }
        case let .result(transfer, result):
            guard let count = drops.removeValue(forKey: transfer) else { return }
            let they = count == 1 ? "It" : "They"
            switch result {
            case .placed: status("Dropped \(Self.items(count, nil)) on \(hostName).")
            case .savedToDownloads:
                status("\(they) went to \(hostName)'s Downloads instead: nothing took \(count == 1 ? "it" : "them") at that spot, or another window came up there.",
                       linger: 8)
            case .failed: status("\(hostName) couldn't take \(count == 1 ? "that file" : "those files").")
            }
        case let .declined(transfer, reason):
            if copyingOut == transfer { copyingOut = nil }
            let count = drops.removeValue(forKey: transfer)
            let those = count.map { $0 == 1 ? "That file" : "Those \($0) items" } ?? "That copy"
            let are = count.map { $0 == 1 ? "is" : "are" } ?? "is"
            switch reason {
            case .tooLarge: status("\(those) \(are) too large for \(hostName).")
            case .noRoom: status("\(hostName) doesn't have room for \(those.prefix(1).lowercased() + those.dropFirst()) right now.")
            case .syncOff: status("\(hostName) has clipboard sync turned off.")
            case .badOffer, .failed: status("\(those) couldn't go to \(hostName).")
            }
        case .closed:
            session = nil
            if let watch { ClipboardWatcher.shared.unwatch(watch) }
            watch = nil
            drops = [:]
            copyingOut = nil
            copyingIn = nil
            waiting = nil
            status(nil)
            ended()
        default:
            break
        }
    }

    private func stopIncoming(_ transfer: UInt32) {
        session?.stopIncoming(transfer)
        if copyingIn == transfer { copyingIn = nil }
        status("Stopped. \(hostName)'s copy wasn't brought over.")
    }

    /// Shows `text`; `hold` keeps it until something replaces it, otherwise it goes after `linger` seconds.
    private func status(_ text: String?, hold: Bool = false, actions: [ClipStatus.Action] = [], announce: Bool = true,
                        linger: TimeInterval = 5) {
        clearStatus?.cancel()
        onStatus(text.map { ClipStatus($0, actions: actions, announce: announce) })
        guard !hold, text != nil else { return }
        let clear = DispatchWorkItem { [weak self] in self?.onStatus(nil) }
        clearStatus = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: clear)
    }

    static func preparing(_ count: Int) -> String { count == 1 ? "Preparing 1 item…" : "Preparing \(count) items…" }

    static func items(_ count: Int, _ bytes: UInt64?) -> String {
        let n = count == 1 ? "1 item" : "\(count) items"
        guard let bytes, bytes > 0 else { return n }
        return "\(n) (\(size(bytes)))"
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
#endif
