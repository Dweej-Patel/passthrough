import CoreGraphics
import Foundation
import PassthroughCore

/// A VNC (RFB 3.8, RFC 6143) viewer for macOS Screen Sharing, over a stream
/// the remote shell handed over after `screenReady` (protocol/README.md,
/// "Screen"). It logs in with Apple's method (account name and password)
/// only: a server offering no login at all is not the Mac's Screen Sharing,
/// which always asks for one. It asks for 32-bit pixels in ZRLE, Zlib, CopyRect or Raw, and keeps one
/// incremental update request outstanding, sent as each update starts so the
/// Mac prepares the next one while this one decodes. Everything runs on its
/// own queue; events arrive on the queue given to `init`, at most one frame
/// at a time (a frame that is still waiting there is replaced, not queued).
public final class RFBClient: @unchecked Sendable {
    public struct Login: Sendable {
        public var username: String
        public var password: String
        public init(username: String, password: String) { self.username = username; self.password = password }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Not an RFB server this client speaks to, or no login method it knows.
        case unsupportedServer
        /// It offered to connect with no login (RFB "None"), which the Mac's
        /// Screen Sharing never does: something else is answering.
        case noLoginOffered
        /// The Mac refused the name and password; its reason, if it gave one.
        case loginFailed(String?)
        case protocolError(String)
        case connectionLost
    }

    public enum Event: @unchecked Sendable {
        /// Logged in; the screen is `width`×`height` pixels.
        case connected(width: Int, height: Int, name: String)
        /// The screen after an update.
        case frame(CGImage)
        /// The Mac's clipboard changed (text only).
        case clipboard(String)
        case bell
        /// The connection is over: nil when `close()` ended it.
        case closed(Failure?)
    }

    /// Pointer buttons, as RFB numbers them.
    public struct Buttons: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left = Buttons(rawValue: 1)
        public static let middle = Buttons(rawValue: 2)
        public static let right = Buttons(rawValue: 4)
        public static let wheelUp = Buttons(rawValue: 8)
        public static let wheelDown = Buttons(rawValue: 16)
    }

    static let encodings: [Int32] = [16, 6, 1, 0, -223]   // ZRLE, Zlib, CopyRect, Raw, DesktopSize
    /// Longest refusal reason or screen name it reads: what a server says
    /// there is buffered whole before anything is checked.
    static let maxTextLength = 64 << 10

    private enum Stage {
        case version, securityTypes, appleParameters, securityResult, failureReason(login: Bool), serverInit, running
    }

    private let stream: any ByteStream
    private let login: Login
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).rfb")
    private let callbackQueue: DispatchQueue
    private let onEvent: (Event) -> Void

    // On `queue`.
    private var inbox: [UInt8] = []
    private var head = 0
    private var stage = Stage.version
    private var framebuffer = Framebuffer()
    private let zlib = Inflater()
    private let zrle = Inflater()
    private var rectsLeft = 0
    private var closed = false
    /// The frame waiting on the callback queue, if one is; guarded by `frameLock`.
    private var pendingFrame: CGImage?
    private let frameLock = NSLock()

    /// `initialBytes`: what arrived after `screenReady` with it.
    public init(stream: any ByteStream, initialBytes: Data = Data(), login: Login, queue: DispatchQueue = .main,
                onEvent: @escaping (Event) -> Void) {
        self.stream = stream
        self.login = login
        self.callbackQueue = queue
        self.onEvent = onEvent
        inbox = [UInt8](initialBytes)
    }

    public func start() {
        queue.async { [self] in
            stream.onTerminated = { [weak self] _ in self?.queue.async { self?.finish(.connectionLost) } }
            process()
            receive()
        }
    }

    public func close() {
        queue.async { [self] in finish(nil) }
    }

    // MARK: Input

    /// The pointer is at (`x`, `y`) in screen pixels with `buttons` held.
    public func pointer(x: Int, y: Int, buttons: Buttons) {
        queue.async { [self] in
            guard case .running = stage else { return }
            let x = UInt16(clamping: max(0, min(x, framebuffer.width - 1)))
            let y = UInt16(clamping: max(0, min(y, framebuffer.height - 1)))
            send([5, buttons.rawValue] + Self.bytes(x) + Self.bytes(y))
        }
    }

    /// A key, by X keysym (`RFBKeys`).
    public func key(_ keysym: UInt32, down: Bool) {
        queue.async { [self] in
            guard case .running = stage else { return }
            send([4, down ? 1 : 0, 0, 0] + Self.bytes(keysym))
        }
    }

    /// Puts text on the Mac's clipboard (Latin-1 only, as RFB allows).
    public func clipboard(_ text: String) {
        queue.async { [self] in
            guard case .running = stage, let latin1 = text.data(using: .isoLatin1) else { return }
            send([6, 0, 0, 0] + Self.bytes(UInt32(latin1.count)) + [UInt8](latin1))
        }
    }

    // MARK: Reading

    private func receive() {
        stream.receive(maximumLength: 256 * 1024) { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data, !data.isEmpty {
                    self.inbox.append(contentsOf: data)
                    self.process()
                }
                if complete || error != nil { return self.finish(.connectionLost) }
                if !self.closed { self.receive() }
            }
        }
    }

    private var available: Int { inbox.count - head }

    private func u8(_ at: Int = 0) -> UInt8 { inbox[head + at] }
    private func u16(_ at: Int = 0) -> Int { Int(inbox[head + at]) << 8 | Int(inbox[head + at + 1]) }
    private func u32(_ at: Int = 0) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(inbox[head + at + $1]) }
    }
    private func take(_ count: Int) -> ArraySlice<UInt8> {
        defer { head += count }
        return inbox[head..<(head + count)]
    }

    /// Handles everything complete in `inbox`, then drops what was used.
    private func process() {
        do {
            while !closed, try step() {}
        } catch let failure as Failure {
            return finish(failure)
        } catch {
            return finish(.protocolError(String(describing: error)))
        }
        if head > 0 && (head == inbox.count || head > 1 << 20) {
            inbox.removeFirst(head)
            head = 0
        }
    }

    /// One message (or part of an update) if it is all here; false to wait for more.
    private func step() throws -> Bool {
        switch stage {
        case .version:
            guard available >= 12 else { return false }
            let version = String(decoding: take(12), as: UTF8.self)
            guard version.hasPrefix("RFB 003."), let minor = Int(version.dropFirst(8).prefix(3)), minor >= 7 else {
                throw Failure.unsupportedServer
            }
            send(Array("RFB 003.008\n".utf8))
            stage = .securityTypes
        case .securityTypes:
            guard available >= 1 else { return false }
            let count = Int(u8())
            if count == 0 {
                head += 1
                stage = .failureReason(login: false)
                return true
            }
            guard available >= 1 + count else { return false }
            head += 1
            let offered = Set(take(count))
            if offered.contains(30) {
                send([30])
                stage = .appleParameters
            } else if offered.contains(1) {
                // Only None: chosen, it would see (and take) whatever the phone types.
                throw Failure.noLoginOffered
            } else {
                throw Failure.unsupportedServer
            }
        case .appleParameters:
            guard available >= 4 else { return false }
            let length = u16(2)
            guard available >= 4 + 2 * length else { return false }
            let generator = Array(take(2))
            head += 2
            let prime = Array(take(length)), peerKey = Array(take(length))
            do {
                send([UInt8](try AppleLogin.response(generator: generator, prime: prime, peerKey: peerKey,
                                                     username: login.username, password: login.password)))
            } catch {
                throw Failure.protocolError("login parameters")
            }
            stage = .securityResult
        case .securityResult:
            guard available >= 4 else { return false }
            if u32() == 0 {
                head += 4
                send([1])   // shared: leave other viewers connected
                stage = .serverInit
            } else {
                head += 4
                stage = .failureReason(login: true)
            }
        case .failureReason(let afterLogin):
            guard available >= 4 else { return false }
            let length = Int(u32())
            guard length <= Self.maxTextLength else { throw afterLogin ? Failure.loginFailed(nil) : Failure.unsupportedServer }
            guard available >= 4 + length else { return false }
            head += 4
            let reason = String(decoding: take(length), as: UTF8.self)
            throw afterLogin ? Failure.loginFailed(reason.isEmpty ? nil : reason) : Failure.unsupportedServer
        case .serverInit:
            guard available >= 24 else { return false }
            let nameLength = Int(u32(20))
            guard nameLength <= Self.maxTextLength else { throw Failure.protocolError("name too long") }
            guard available >= 24 + nameLength else { return false }
            let width = u16(), height = u16(2)
            head += 24
            let name = String(decoding: take(nameLength), as: UTF8.self)
            try framebuffer.resize(width: width, height: height)
            stage = .running
            // 32 bpp, depth 24, little-endian, true colour, 255 per channel, red at 16, green 8, blue 0.
            send([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            send([2, 0] + Self.bytes(UInt16(Self.encodings.count)) + Self.encodings.flatMap { Self.bytes(UInt32(bitPattern: $0)) })
            requestUpdate(incremental: false)
            emit(.connected(width: width, height: height, name: name))
        case .running:
            return try rectsLeft > 0 ? rect() : message()
        }
        return true
    }

    private func message() throws -> Bool {
        guard available >= 1 else { return false }
        switch u8() {
        case 0:   // FramebufferUpdate
            guard available >= 4 else { return false }
            rectsLeft = u16(2)
            head += 4
            requestUpdate(incremental: true)
            if rectsLeft == 0 { updateDone() }
        case 1:   // SetColourMapEntries: not used with true colour; skipped
            guard available >= 6 else { return false }
            let count = u16(4)
            guard available >= 6 + 6 * count else { return false }
            head += 6 + 6 * count
        case 2:
            head += 1
            emit(.bell)
        case 3:   // ServerCutText
            guard available >= 8 else { return false }
            let length = Int(u32(4))
            guard length <= 16 << 20 else { throw Failure.protocolError("clipboard too large") }
            guard available >= 8 + length else { return false }
            head += 8
            let text = String(data: Data(take(length)), encoding: .isoLatin1) ?? ""
            emit(.clipboard(text))
        case let type:
            throw Failure.protocolError("message \(type)")
        }
        return true
    }

    /// One rectangle of the update being read, if all of it is here.
    private func rect() throws -> Bool {
        guard available >= 12 else { return false }
        let x = u16(), y = u16(2), w = u16(4), h = u16(6)
        let encoding = Int32(bitPattern: u32(8))
        // Before waiting for its pixels: a rectangle off the screen would only be refused once all of it is buffered.
        guard encoding == -223 || framebuffer.contains(x: x, y: y, w: w, h: h) else {
            throw Failure.protocolError("rectangle outside the screen")
        }
        switch encoding {
        case 0:
            let size = w * h * 4
            guard available >= 12 + size else { return false }
            head += 12
            try inbox.withUnsafeBytes { try framebuffer.raw(x: x, y: y, w: w, h: h, UnsafeRawBufferPointer(rebasing: $0[head..<(head + size)])) }
            head += size
        case 1:
            guard available >= 16 else { return false }
            let fromX = u16(12), fromY = u16(14)
            head += 16
            try framebuffer.copy(fromX: fromX, fromY: fromY, x: x, y: y, w: w, h: h)
        case 6, 16:
            guard available >= 16 else { return false }
            let length = Int(u32(12))
            guard length <= 64 << 20 else { throw Failure.protocolError("rectangle too large") }
            guard available >= 16 + length else { return false }
            head += 16
            let compressed = Data(take(length))
            // Inflated no further than the rectangle can use, so a few
            // compressed bytes cannot become gigabytes on the phone.
            if encoding == 6 {
                let pixels = try zlib.inflated(compressed, limit: w * h * 4)
                try pixels.withUnsafeBytes { try framebuffer.raw(x: x, y: y, w: w, h: h, $0) }
            } else {
                try framebuffer.zrle(x: x, y: y, w: w, h: h, try zrle.inflated(compressed, limit: Framebuffer.zrleLimit(w: w, h: h)))
            }
        case -223:   // DesktopSize: the screen changed size
            head += 12
            try framebuffer.resize(width: w, height: h)
            requestUpdate(incremental: false)   // the request sent with this update had the old size
        default:
            throw Failure.protocolError("encoding \(encoding)")
        }
        rectsLeft -= 1
        if rectsLeft == 0 { updateDone() }
        return true
    }

    private func updateDone() {
        guard let image = framebuffer.image() else { return }
        frameLock.lock()
        let waiting = pendingFrame != nil
        pendingFrame = image
        frameLock.unlock()
        guard !waiting else { return }   // the delivery already queued takes this one
        let onEvent = self.onEvent
        callbackQueue.async { [self] in
            frameLock.lock()
            let image = pendingFrame
            pendingFrame = nil
            frameLock.unlock()
            if let image { onEvent(.frame(image)) }
        }
    }

    private func requestUpdate(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0] + Self.bytes(UInt16(clamping: framebuffer.width)) + Self.bytes(UInt16(clamping: framebuffer.height)))
    }

    // MARK: Plumbing

    private func send(_ bytes: [UInt8]) {
        guard !closed else { return }
        stream.send(Data(bytes), isComplete: false) { _ in }
    }

    private func finish(_ failure: Failure?) {
        guard !closed else { return }
        closed = true
        stream.onTerminated = nil
        stream.cancel()
        emit(.closed(failure))
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        callbackQueue.async { onEvent(event) }
    }

    static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    static func bytes(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
}
