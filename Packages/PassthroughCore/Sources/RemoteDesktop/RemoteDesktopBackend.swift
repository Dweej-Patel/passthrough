#if canImport(FreeRDP)
import CoreGraphics
import Foundation
import FreeRDP
import PassthroughCore
import ScreenClient

/// A PC's screen through its own Remote Desktop, over the stream the app's
/// connection handed over after `rdpReady` (`ShellClient.Event.rdp`): FreeRDP
/// in the shim reads and writes two in-process byte queues, which this fills
/// from the stream and drains into it. No socket, no loopback.
///
/// The server must present the certificate whose SHA-256 the host announced;
/// anything else ends the view before the login leaves (`.identityMismatch`).
///
/// Threads: one engine thread per session makes every FreeRDP call; `io`
/// owns the stream's reads and writes; input comes from main and events go
/// to the queue given to `init` (main).
public final class RemoteDesktopBackend: ScreenBackend, @unchecked Sendable {
    public let capabilities: ScreenCapabilities = [.smoothScroll, .unicodeText, .resize, .drawsOwnPointer, .signIn, .windowsKeys]
    public var macStream: (any MacStreamControls)? { nil }

    /// The first shape asked of Windows.
    public struct Layout: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// Windows' scale factor in percent (100…500), and the device's (100, 140 or 180).
        public var desktopScale: Int
        public var deviceScale: Int
        public init(width: Int, height: Int, desktopScale: Int = 100, deviceScale: Int = 100) {
            // Even, within display control's limits.
            self.width = max(200, min(width, 8192)) & ~1
            self.height = max(200, min(height, 8192)) & ~1
            self.desktopScale = max(100, min(desktopScale, 500))
            self.deviceScale = [100, 140, 180].contains(deviceScale) ? deviceScale : 100
        }
    }

    private let stream: any ByteStream
    private let initialBytes: Data
    private let certSHA256: String
    private let login: ScreenLogin
    private let layout: Layout
    private let clientName: String
    private let callbackQueue: DispatchQueue
    private let onEvent: (ScreenBackendEvent) -> Void
    private let painter: (any RemoteDesktopPainter)?
    private let io = DispatchQueue(label: "\(PassthroughProtocol.identifier).rdp-io")

    /// Guards `rdp`, `started`, `closing`, `ended`.
    private let lock = NSLock()
    private var rdp: OpaquePointer?
    private var started = false
    private var closing = false
    private var ended = false

    // On `io`.
    private var receiving = false
    private var sending = false
    /// Over a relay, what the link did, logged every 5 s (io queue; frames under `pixelsLock`): to tell a slow
    /// network from a phone that holds its own sends back.
    private var stats = LinkStats()
    private var framesPainted = 0
    private struct LinkStats {
        var bytesOut = 0, bytesIn = 0, sends = 0
        var longestSend: TimeInterval = 0
        /// Outgoing data (input, frame acknowledgements) that had to wait for the send before it.
        var queuedSince: TimeInterval?
        var waited: TimeInterval = 0, longestWait: TimeInterval = 0
    }
    private var ioClosed = false

    /// The desktop's pixels as last painted (BGRA), guarded by `pixelsLock`.
    private let pixelsLock = NSLock()
    private var pixels: [UInt8] = []
    private var desktop = (width: 0, height: 0)
    private var imageScheduled = false

    // Main only: input state.
    private var scrollRemainder = CGPoint.zero
    private var buttons: ScreenButtons = []
    /// Over a relay, a drag's moves (the buttons unchanged) go at most this often, the newest position winning: each
    /// move makes Windows draw and send a frame, and through a relay those frames queue behind each other.
    static let relayMoveInterval: TimeInterval = 1.0 / 30
    private var heldMove: (x: UInt16, y: UInt16)?
    private var lastMoveSent: TimeInterval = 0
    private var moveFlushScheduled = false

    private let slowLink: Bool

    /// The clipboard's rules; on the callback queue only (copy, paste and the engine's clipboard callbacks all arrive there).
    private var clipboard = RDPClipboard()

    /// `certSHA256`: `rdpReady`'s, 64 lowercase hex. `clientName`: the device's kind ("iPhone"), never its own name.
    /// `slowLink`: the stream goes through a relay: a drag's moves are coalesced and Windows measures the link
    /// (network auto-detect) to fit its video to it.
    public init(stream: any ByteStream, initialBytes: Data = Data(), certSHA256: String, login: ScreenLogin, layout: Layout,
                clientName: String, slowLink: Bool = false, queue: DispatchQueue = .main, painter: (any RemoteDesktopPainter)? = nil,
                onEvent: @escaping (ScreenBackendEvent) -> Void) {
        self.slowLink = slowLink
        self.stream = stream
        self.initialBytes = initialBytes
        self.certSHA256 = certSHA256
        self.login = login
        self.layout = layout
        self.clientName = clientName
        self.callbackQueue = queue
        self.onEvent = onEvent
        self.painter = painter
    }

    deinit {
        // `run` frees the session; one never started is freed here.
        if let rdp, !started { pt_rdp_free(rdp) }
    }

    // MARK: Lifetime

    public func start() {
        lock.lock()
        guard !started, !closing else { lock.unlock(); return }
        started = true
        lock.unlock()
        guard RemoteDesktop.isEnabled, let rdp = makeSession() else {
            return finish(.unsupported("Remote Desktop"))
        }
        lock.lock()
        self.rdp = rdp
        let abortNow = closing
        lock.unlock()
        if abortNow { pt_rdp_abort(rdp) }

        io.async { [self] in
            stream.onTerminated = { [weak self] _ in self?.io.async { self?.networkClosed() } }
            if !initialBytes.isEmpty { feed(initialBytes) }
            receiveMore()
            if slowLink { logLink() }
        }
        let thread = Thread { [self] in run(rdp) }
        thread.name = "rdp"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        thread.start()
    }

    public func close() {
        lock.lock()
        let wasClosing = closing
        closing = true
        let started = self.started
        // Aborted under the lock: the engine thread frees the session only after taking it (pt_rdp_abort only signals).
        let aborted = !wasClosing && rdp.map { pt_rdp_abort($0); return true } == true
        lock.unlock()
        guard !wasClosing, !aborted, !started else { return }
        finish(.closedHere)
    }

    private func makeSession() -> OpaquePointer? {
        var callbacks = pt_rdp_callbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.verify_certificate = { user, pem, length in
            guard let user, let pem else { return 0 }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            let chain = Data(bytes: pem, count: length)
            return RDPCertificatePin.matches(pem: chain, sha256Hex: backend.certSHA256) ? 1 : 0
        }
        callbacks.phase = { user, phase in
            guard let user else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            let mapped: ScreenConnectPhase
            switch phase {
            case Int32(PT_PHASE_NEGOTIATING): mapped = .negotiating
            case Int32(PT_PHASE_IDENTITY_CHECKED): mapped = .identityChecked
            default: mapped = .signedIn
            }
            backend.emit(.phase(mapped))
        }
        callbacks.desktop = { user, width, height in
            guard let user else { return }
            Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue().desktopChanged(Int(width), Int(height))
        }
        callbacks.painted = { user, bgra, stride, width, height, dirty in
            guard let user, let bgra else { return }
            Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
                .painted(bgra, stride: Int(stride), width: Int(width), height: Int(height), dirty: dirty)
        }
        callbacks.pointer_shape = { user, bgra, width, height, hotX, hotY in
            guard let user, let bgra else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            guard let image = RemoteDesktopBackend.pointerImage(bgra, width: Int(width), height: Int(height)) else { return }
            backend.emit(.pointerShape(image, size: CGSize(width: Int(width), height: Int(height)),
                                       hotSpot: CGPoint(x: Int(hotX), y: Int(hotY))))
        }
        callbacks.pointer_system = { user, visible in
            guard let user, visible == 0 else { return }
            Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue().emit(.pointerHidden)
        }
        callbacks.pointer_moved = { user, x, y in
            guard let user else { return }
            Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
                .emit(.pointerPosition(CGPoint(x: Int(x), y: Int(y)), visible: true))
        }
        callbacks.clipboard_offered = { user, hasText in
            guard let user else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            backend.callbackQueue.async { backend.clipboardChanged(hasText: hasText != 0) }
        }
        callbacks.clipboard_announced = { user, _ in
            guard let user else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            backend.callbackQueue.async { backend.apply(backend.clipboard.pasteReady()) }
        }
        callbacks.clipboard_text = { user, utf16, units, result in
            guard let user else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            let answer: ScreenCopyResult
            switch result {
            case Int32(PT_CLIPBOARD_TEXT):
                let text = utf16.map { RDPClipboard.deviceText(Array(UnsafeBufferPointer(start: $0, count: units))) } ?? ""
                answer = text.isEmpty ? .nothing : .text(text)
            case Int32(PT_CLIPBOARD_TOO_LONG): answer = .tooLong
            default: answer = .nothing
            }
            backend.callbackQueue.async { backend.apply(backend.clipboard.fetched(answer, now: ProcessInfo.processInfo.systemUptime)) }
        }
        callbacks.outbox_ready = { user in
            guard let user else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            backend.io.async {
                if backend.sending, backend.stats.queuedSince == nil { backend.stats.queuedSince = ProcessInfo.processInfo.systemUptime }
                backend.pump()
            }
        }
        callbacks.inbox_space = { user in
            guard let user else { return }
            let backend = Unmanaged<RemoteDesktopBackend>.fromOpaque(user).takeUnretainedValue()
            backend.io.async { backend.receiveMore() }
        }

        let username = Self.account(login.username)
        return username.user.withCString { user in
            (username.domain ?? "").withCString { domain in
                login.password.withCString { password in
                    clientName.withCString { name in
                        var config = pt_rdp_config()
                        config.username = user
                        config.domain = domain
                        config.password = password
                        config.client_name = name
                        config.width = UInt32(layout.width)
                        config.height = UInt32(layout.height)
                        config.desktop_scale = UInt32(layout.desktopScale)
                        config.device_scale = UInt32(layout.deviceScale)
                        config.allow_h264 = 1
                        // Acknowledgements stay on, even over a relay: they're Windows' only brake. Measured with them
                        // suspended (60db5fc), the relay queued a drag's frames until its round trip reached 23 s.
                        config.suspend_frame_acks = 0
                        config.detect_network = slowLink ? 1 : 0
                        // Measured over the cellular relay: Windows held a drag to ~4 fps at 30–40 KB/s. 4:2:0 frames
                        // cost about half of 4:4:4's, so more of them fit.
                        config.avc420_only = slowLink ? 1 : 0
                        return pt_rdp_new(&config, &callbacks)
                    }
                }
            }
        }
    }

    /// `DOMAIN\user` → domain and user; `user@host`, `user` and `.\user` → that user, no domain.
    static func account(_ typed: String) -> (user: String, domain: String?) {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "\\") else { return (trimmed, nil) }
        let domain = String(trimmed[..<slash]), user = String(trimmed[trimmed.index(after: slash)...])
        return (user, domain.isEmpty || domain == "." ? nil : domain)
    }

    /// The engine thread: the whole session, then its teardown.
    private func run(_ rdp: OpaquePointer) {
        let end = pt_rdp_run(rdp)
        // No io call reaches the session from here on.
        io.sync { ioClosed = true }
        lock.lock()
        self.rdp = nil
        let closedHere = closing
        lock.unlock()
        pt_rdp_free(rdp)
        stream.onTerminated = nil
        stream.cancel()
        finish(closedHere && end.kind != PT_END_IDENTITY_MISMATCH ? .closedHere : Self.ending(end))
    }

    private func finish(_ end: ScreenEnd) {
        lock.lock()
        let already = ended
        ended = true
        lock.unlock()
        guard !already else { return }
        let onEvent = self.onEvent
        callbackQueue.async { onEvent(.ended(end)) }
    }

    static func ending(_ end: pt_rdp_end) -> ScreenEnd {
        switch end.kind {
        case PT_END_CLOSED_HERE: .closedHere
        case PT_END_IDENTITY_MISMATCH: .identityMismatch
        case PT_END_WRONG_PASSWORD: .signIn(.wrongPassword)
        case PT_END_PASSWORD_EXPIRED: .signIn(.passwordExpired)
        case PT_END_ACCOUNT_LOCKED: .signIn(.accountLocked)
        case PT_END_ACCOUNT_DISABLED: .signIn(.accountDisabled)
        case PT_END_NOT_ALLOWED_REMOTELY: .signIn(.notAllowedRemotely)
        case PT_END_NO_CREDENTIALS: .signIn(.other(nil))
        case PT_END_UNSUPPORTED: .unsupported("Remote Desktop")
        case PT_END_TAKEN_OVER: .takenOver
        case PT_END_SIGNED_OUT: .signedOut
        case PT_END_HOST_ENDED: .hostEnded("ended")
        case PT_END_NO_LICENCE: .hostEnded("licence")
        case PT_END_PROTOCOL_ERROR: .protocolError("Remote Desktop")
        default: .connectionLost
        }
    }

    private func emit(_ event: ScreenBackendEvent) {
        lock.lock()
        let over = ended
        lock.unlock()
        guard !over else { return }
        let onEvent = self.onEvent
        callbackQueue.async { onEvent(event) }
    }

    // MARK: The stream (on `io`)

    private func feed(_ data: Data) {
        guard !ioClosed, let rdp = currentSession() else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = pt_rdp_feed(rdp, base, raw.count)
        }
    }

    /// One receive at a time, never more than the inbox has room for: a full inbox
    /// pauses reading (the network slows the PC), and `inbox_space` resumes it.
    private func receiveMore() {
        guard !ioClosed, !receiving, let rdp = currentSession() else { return }
        let room = pt_rdp_inbox_free(rdp)
        guard room > 0 else { return }
        receiving = true
        stream.receive(maximumLength: min(256 * 1024, room)) { [weak self] data, complete, error in
            guard let self else { return }
            self.io.async {
                self.receiving = false
                if let data, !data.isEmpty { self.stats.bytesIn += data.count; self.feed(data) }
                if complete || error != nil { return self.networkClosed() }
                self.receiveMore()
            }
        }
    }

    /// One send at a time, at most 64 KiB, continued from each completion.
    private func pump() {
        guard !ioClosed, !sending, let rdp = currentSession() else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBufferPointer { pt_rdp_take(rdp, $0.baseAddress, $0.count) }
        guard count > 0 else { return }
        sending = true
        let started = ProcessInfo.processInfo.systemUptime
        if let since = stats.queuedSince {
            stats.waited += started - since
            stats.longestWait = max(stats.longestWait, started - since)
            stats.queuedSince = nil
        }
        stats.bytesOut += count
        stats.sends += 1
        stream.send(Data(buffer[0..<count]), isComplete: false) { [weak self] error in
            guard let self else { return }
            self.io.async {
                self.stats.longestSend = max(self.stats.longestSend, ProcessInfo.processInfo.systemUptime - started)
                self.sending = false
                if error != nil { return self.networkClosed() }
                self.pump()
            }
        }
    }

    /// Every 5 s while the session lasts (io queue).
    private func logLink() {
        io.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.ioClosed else { return }
            self.pixelsLock.lock()
            let frames = self.framesPainted
            self.framesPainted = 0
            self.pixelsLock.unlock()
            let s = self.stats
            ptLog(.info, "screen: relay 5 s: out \(s.bytesOut / 1024) KB in \(s.bytesIn / 1024) KB, \(s.sends) sends, longest send "
                + "\(Int(s.longestSend * 1000)) ms, waited \(Int(s.waited * 1000)) ms (longest \(Int(s.longestWait * 1000)) ms), \(frames) paints")
            self.stats = LinkStats(queuedSince: s.queuedSince)
            self.logLink()
        }
    }

    private func networkClosed() {
        guard !ioClosed, let rdp = currentSession() else { return }
        pt_rdp_feed_closed(rdp)
    }

    private func currentSession() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return rdp
    }

    // MARK: Pictures (engine thread, then the callback queue)

    private func desktopChanged(_ width: Int, _ height: Int) {
        if let painter {
            painter.desktop(width: width, height: height)
            pixelsLock.lock()
            desktop = (width, height)
            pixelsLock.unlock()
            return emit(.size(width: width, height: height))
        }
        // The PC chooses the size: one past the limits the Mac's helper keeps too is never drawn (a black view, not
        // gigabytes on the phone).
        let valid = width > 0 && height > 0 && width <= 16384 && height <= 16384 && width * height <= 50_000_000
        pixelsLock.lock()
        desktop = valid ? (width, height) : (0, 0)
        pixels = valid ? [UInt8](repeating: 0, count: width * height * 4) : []
        pixelsLock.unlock()
        guard valid else { return ptLog(.error, "screen: the PC's desktop size \(width)x\(height) is past the limits; not drawn") }
        emit(.size(width: width, height: height))
    }

    private func painted(_ bgra: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, dirty: pt_rect) {
        if let painter {
            return painter.painted(bgra, stride: stride, width: width, height: height,
                                   dirty: CGRect(x: Int(dirty.x), y: Int(dirty.y), width: Int(dirty.w), height: Int(dirty.h)))
        }
        pixelsLock.lock()
        framesPainted += 1
        guard desktop.width == width, desktop.height == height, pixels.count == width * height * 4 else {
            pixelsLock.unlock()
            return
        }
        let x0 = max(0, Int(dirty.x)), y0 = max(0, Int(dirty.y))
        let x1 = min(width, Int(dirty.x) + Int(dirty.w)), y1 = min(height, Int(dirty.y) + Int(dirty.h))
        if x1 > x0, y1 > y0 {
            pixels.withUnsafeMutableBytes { target in
                guard let base = target.baseAddress else { return }
                for row in y0..<y1 {
                    memcpy(base + row * width * 4 + x0 * 4, bgra + row * stride + x0 * 4, (x1 - x0) * 4)
                }
            }
        }
        // One picture waits on the callback queue at most; the newest pixels win.
        let schedule = !imageScheduled
        imageScheduled = true
        pixelsLock.unlock()
        guard schedule else { return }
        callbackQueue.async { [weak self] in
            guard let self, let image = self.makeImage() else { return }
            self.emit(.image(image))
        }
    }

    private func makeImage() -> CGImage? {
        pixelsLock.lock()
        imageScheduled = false
        let (width, height) = desktop
        let copy = Data(pixels)
        pixelsLock.unlock()
        guard width > 0, height > 0, let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A pointer shape: BGRA with straight alpha.
    private static func pointerImage(_ bgra: UnsafePointer<UInt8>, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let data = Data(bytes: bgra, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Input (main)

    /// Runs `body` with the session held: the engine thread can't free it meanwhile. The `pt_rdp_*` input calls only
    /// queue a command, so nothing waits under the lock.
    private func withSession(_ body: (OpaquePointer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let rdp else { return }
        body(rdp)
    }

    private func clamp(_ point: CGPoint) -> (UInt16, UInt16) {
        pixelsLock.lock()
        let (width, height) = desktop
        pixelsLock.unlock()
        let x = max(0, min(Int(point.x), max(width - 1, 0))), y = max(0, min(Int(point.y), max(height - 1, 0)))
        return (UInt16(clamping: x), UInt16(clamping: y))
    }

    public func pointer(at point: CGPoint, buttons: ScreenButtons) {
        let pressOrRelease = buttons != self.buttons
        self.buttons = buttons
        let (x, y) = clamp(point)
        let now = ProcessInfo.processInfo.systemUptime
        // A press or release always goes at once (with its position); so does every move off a relay.
        guard slowLink, !pressOrRelease, now - lastMoveSent < Self.relayMoveInterval else {
            heldMove = nil
            lastMoveSent = now
            withSession { pt_rdp_pointer($0, x, y, buttons.rawValue) }
            return
        }
        heldMove = (x, y)
        guard !moveFlushScheduled else { return }
        moveFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (lastMoveSent + Self.relayMoveInterval - now)) { [weak self] in
            guard let self else { return }
            self.moveFlushScheduled = false
            guard let move = self.heldMove else { return }
            self.heldMove = nil
            self.lastMoveSent = ProcessInfo.processInfo.systemUptime
            let held = self.buttons
            self.withSession { pt_rdp_pointer($0, move.x, move.y, held.rawValue) }
        }
    }

    /// 120 wheel units a notch, the remainder kept; vertical and horizontal apart, each at most ±255 an event.
    public func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat) {
        guard notch > 0 else { return }
        scrollRemainder.x += delta.x / notch * 120
        scrollRemainder.y += delta.y / notch * 120
        let (x, y) = clamp(point)
        // Fingers down bring earlier content in: positive rotation. Fingers left bring what is to the right: positive tilt.
        let vertical = Int(scrollRemainder.y), horizontal = Int(-scrollRemainder.x)
        scrollRemainder.y -= CGFloat(vertical)
        scrollRemainder.x += CGFloat(horizontal)
        withSession { rdp in
            for (amount, sideways) in [(vertical, false), (horizontal, true)] where amount != 0 {
                var left = amount
                while left != 0 {
                    let step = max(-255, min(255, left))
                    pt_rdp_wheel(rdp, x, y, Int16(step), sideways ? 1 : 0)
                    left -= step
                }
            }
        }
    }

    public func scrollEnded() { scrollRemainder = .zero }

    public func key(_ key: ScreenKey, modifiers: ScreenModifiers) {
        send(WindowsKeymap.strokes(for: key, modifiers: modifiers))
    }

    public func text(_ text: String) { send(WindowsKeymap.strokes(forText: text)) }

    /// Offers `text` to the PC's clipboard and presses Shift + Insert once the PC has taken the offer (or after a
    /// moment). The offer is withdrawn ten seconds later. False: too long, nothing is offered.
    public func paste(_ text: String) -> Bool {
        let units = RDPClipboard.windowsText(text)
        guard let offer = clipboard.pasteAsked(units: units.count) else { return false }
        withSession { rdp in units.withUnsafeBufferPointer { pt_rdp_clipboard_offer(rdp, $0.baseAddress, $0.count) } }
        callbackQueue.asyncAfter(deadline: .now() + RDPClipboard.pasteWait) { [weak self] in
            guard let self else { return }
            self.apply(self.clipboard.pasteReady())
        }
        callbackQueue.asyncAfter(deadline: .now() + RDPClipboard.offerLifetime) { [weak self] in
            guard let self else { return }
            self.apply(self.clipboard.offerExpired(offer))
        }
        return true
    }

    /// Presses Control + Insert, and takes the PC's clipboard if it changes to text within two seconds: `.copied` answers.
    public func copySelection() {
        clipboard.copyAsked(now: ProcessInfo.processInfo.systemUptime)
        send(WindowsShortcut.copy.strokes)
        callbackQueue.asyncAfter(deadline: .now() + RDPClipboard.copyWindow + 0.05) { [weak self] in
            guard let self else { return }
            self.apply(self.clipboard.copyDeadline(now: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func clipboardChanged(hasText: Bool) {
        apply(clipboard.changed(hasText: hasText, now: ProcessInfo.processInfo.systemUptime))
    }

    /// Does what the clipboard's rules decided (callback queue).
    private func apply(_ effect: RDPClipboard.Effect?) {
        switch effect {
        case .fetch:
            withSession { pt_rdp_clipboard_fetch($0) }
            callbackQueue.asyncAfter(deadline: .now() + RDPClipboard.fetchWait + 0.05) { [weak self] in
                guard let self else { return }
                self.apply(self.clipboard.fetchDeadline(now: ProcessInfo.processInfo.systemUptime))
            }
        case let .copied(result): emit(.copied(result))
        case .paste: send(WindowsShortcut.paste.strokes)
        case .withdraw: withSession { pt_rdp_clipboard_offer($0, nil, 0) }
        case nil: break
        }
    }

    public func presented(_ number: UInt32) {}
    public func needsKeyframe() {}

    /// Asks Windows for a desktop of this shape through display control. The size is clamped as the first one is.
    public func reshape(_ shape: ScreenShape) {
        let layout = Layout(width: shape.width, height: shape.height, desktopScale: shape.desktopScale, deviceScale: shape.deviceScale)
        var request = pt_rdp_layout_request()
        request.width = UInt32(layout.width)
        request.height = UInt32(layout.height)
        request.desktop_scale = UInt32(layout.desktopScale)
        request.device_scale = UInt32(layout.deviceScale)
        withSession { pt_rdp_layout($0, &request) }
    }

    /// Stops the PC's pictures while the app is away, and restarts them.
    public func setActive(_ active: Bool) {
        withSession { pt_rdp_suppress_output($0, active ? 0 : 1) }
    }

    private func send(_ strokes: [WindowsKeymap.Stroke]) {
        withSession { rdp in
            for stroke in strokes {
                switch stroke {
                case let .key(code, down): pt_rdp_key(rdp, code.code, code.extended ? 1 : 0, down ? 1 : 0)
                case let .unicode(unit, down): pt_rdp_unicode(rdp, unit, down ? 1 : 0)
                }
            }
        }
    }
}
#endif
