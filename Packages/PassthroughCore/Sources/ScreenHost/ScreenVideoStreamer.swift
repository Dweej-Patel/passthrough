#if os(macOS)
import CoreMedia
import Foundation
import PassthroughCore
import ShellHost

/// The Mac's screen to one phone as H.264 (protocol/README.md, "Screen
/// video"). Latency comes from what waits, so nothing does: the phone acks
/// each frame it shows, and while `maxInFlight` frames are unacked the
/// newest captured frame waits alone (older ones are dropped before they
/// are encoded, never after). When the screen goes still, its last frame is
/// sent again a couple of times so the encoder can sharpen it.
///
/// Acks are the phone's word, so they are not all that paces it: a frame is
/// also only encoded while the stream has taken what was sent before it
/// (`Limits`), and a phone that acks without reading is dropped once what
/// waits for it passes a hard cap for a few seconds. Its input is bounded
/// too: payload caps in `ScreenVideoWire.Reader(from: .phone)`, and text
/// posted at a steady rate (`TypingPacer`).
public final class ScreenVideoStreamer: ScreenVideoSource, @unchecked Sendable {
    /// Frames sent but not yet on the phone's screen.
    static let maxInFlight = 2

    /// What the streamer lets wait in the stream (handed over, its send not
    /// yet complete): new frames are only encoded under `frames` and
    /// `softBytes`, and over `hardBytes` for `stallTimeout` the phone is
    /// dropped (the shell lines' own cap, `ShellConnection.sendBacklogLimit`).
    struct Limits {
        var frames = 2
        var softBytes = 4 << 20
        var hardBytes = 8 << 20
        var stallTimeout: TimeInterval = 5
        /// How long after its ⌘C a `copy` waits for the clipboard to change
        /// before answering `nothing`. Kept short: any change in that time is
        /// taken as the ⌘C's.
        var copyTimeout: TimeInterval = 1
    }
    /// How long the screen must be still before the last frame is sharpened.
    static let refineDelay: TimeInterval = 0.25
    static let refinePasses = 2

    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video", qos: .userInteractive)
    /// Reads the copied text: an app that provides its data lazily is asked
    /// for it then, which mustn't hold up frames and input on `queue`.
    private let clipboardQueue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video.clipboard", qos: .userInitiated)
    private let capture: FrameCapturing
    private let makeInput: (CGRect) -> InputSink
    private let limits: Limits

    // On `queue`.
    private var stream: (any ByteStream)?
    private var ended: (@Sendable () -> Void)?
    private var reader = ScreenVideoWire.Reader(from: .phone)
    /// Bytes handed to the stream whose send has not completed, and the frames among them.
    private var unsentBytes = 0
    private var unsentFrames = 0
    /// Since when (system uptime) `unsentBytes` has been over `limits.hardBytes`.
    private var overHardLimitSince: TimeInterval?
    private var typing = TypingPacer(now: ProcessInfo.processInfo.systemUptime)
    private var typingScheduled = false
    /// A `copy`'s ⌘C is out, and its answer not yet sent.
    private var copying = false
    private var stopped = false
    private var captureStarted = false
    private var encoder: VideoEncoder?
    private var encoderSettings: (width: Int, height: Int, bitRate: Int)?
    /// Encodes in a row that came back empty; the encoder is made again once, then the stream ends.
    private var failures = 0
    private var remadeEncoder = false
    private var input: InputSink?
    private var waiting: CVPixelBuffer?
    private var last: CVPixelBuffer?
    private var encoding = false
    private var sent: UInt32 = 0
    private var acked: UInt32 = 0
    private var needsKeyframe = true
    private var refinesLeft = 0
    /// Bumped by every captured frame, so a pending sharpen of an older one is dropped.
    private var captureCount = 0
    private let clock = CMClockGetHostTimeClock()

    /// The main display, with input injected as the Mac's own events.
    public convenience init() {
        self.init(capture: ScreenCapturer(), input: { InputInjector(display: $0) })
    }

    /// `limits` are smaller in tests.
    init(capture: FrameCapturing, input: @escaping (CGRect) -> InputSink, limits: Limits = Limits()) {
        self.capture = capture
        self.makeInput = input
        self.limits = limits
    }

    public func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            self.stream = stream
            self.ended = ended
            received(initialBytes)
            receive()
            // A phone that never says hello still gets a picture.
            queue.asyncAfter(deadline: .now() + 1) { [self] in if !stopped, !captureStarted { startCapture(maxSide: 0) } }
        }
    }

    public func stop() {
        queue.async { [self] in shutDown() }
    }

    // MARK: Phone → Mac

    private func receive() {
        stream?.receive(maximumLength: 65536) { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                if let data, !data.isEmpty { self.received(data) }
                if complete || error != nil { return self.finish() }
                if !self.stopped { self.receive() }
            }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        let messages: [ScreenVideoWire.Message]
        do {
            messages = try reader.append(data)
        } catch {
            ptLog(.warning, "screen: a phone sent a malformed screen message; disconnected")
            return finish()
        }
        for message in messages {
            guard !stopped else { return }
            handle(message)
        }
    }

    private func handle(_ message: ScreenVideoWire.Message) {
        switch message {
        case let .hello(maxWidth, maxHeight):
            if !captureStarted { startCapture(maxSide: max(maxWidth, maxHeight)) }
        case let .ack(number):
            guard number <= sent else { return }
            acked = max(acked, number)
            pump()
        case .keyframeRequest:
            needsKeyframe = true
            if waiting == nil { waiting = last }
            pump()
        case let .pointer(x, y, buttons): input?.pointer(x: x, y: y, buttons: buttons)
        case let .scroll(dx, dy): input?.scroll(dx: dx, dy: dy)
        case let .key(keysym, modifiers): type(.key(keysym: keysym, modifiers: modifiers))
        case let .text(text): type(.text(text))
        case let .clipboard(text): input?.clipboard(text)
        case .copy: copySelection()
        case .format, .frame, .copied:
            break
        }
    }

    /// ⌘C, then what it copied. The ⌘C waits for text still being typed, the
    /// clipboard's change count is read just before it, and only a change in
    /// the `copyTimeout` after it counts; one from another device (Universal
    /// Clipboard) or a phone's paste doesn't. Every `copy` is answered once
    /// (one sent while another is unanswered gets `nothing` at once), so
    /// the phone's count of them stays right.
    private func copySelection() {
        guard !copying, input != nil else { return send(copied: .nothing) }
        copying = true
        postCopyWhenTyped()
    }

    private func postCopyWhenTyped() {
        guard !stopped, let input else { return }
        guard typing.isEmpty else {
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.postCopyWhenTyped() }
            return
        }
        let before = input.clipboardChangeCount
        input.key(keysym: 0x63, modifiers: ScreenVideoWire.Modifiers.command.rawValue)   // ⌘C
        awaitCopy(since: before, until: ProcessInfo.processInfo.systemUptime + limits.copyTimeout)
    }

    private func awaitCopy(since before: Int, until deadline: TimeInterval) {
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.stopped, let input = self.input else { return }
            guard input.clipboardChangeCount != before else {
                if ProcessInfo.processInfo.systemUptime < deadline { self.awaitCopy(since: before, until: deadline) } else { self.finishCopy(.nothing) }
                return
            }
            self.clipboardQueue.async {
                let result = Self.copyResult(input.clipboardContents())
                self.queue.async { self.finishCopy(result) }
            }
        }
    }

    private func finishCopy(_ result: ScreenVideoWire.CopyResult) {
        copying = false
        send(copied: result)
    }

    private func send(copied result: ScreenVideoWire.CopyResult) {
        guard !stopped else { return }
        write(ScreenVideoWire.encode(.copied(result)), frame: false)
    }

    /// What a changed clipboard answers a `copy` with.
    static func copyResult(_ contents: ClipboardContents) -> ScreenVideoWire.CopyResult {
        switch contents {
        case .elsewhere: return .nothing
        case .notText: return .notText
        case let .text(text):
            if text.isEmpty { return .nothing }
            return text.utf8.count <= ScreenVideoWire.maxClipboardPayload ? .text(text) : .tooLong
        }
    }

    /// Text and keys go through the pacer, so keys stay behind text still waiting.
    private func type(_ item: TypingPacer.Item) {
        guard input != nil else { return }
        if !typing.push(item) { ptLog(.warning, "screen: a phone sent text faster than it can be typed; dropped some") }
        typeWaiting()
    }

    private func typeWaiting() {
        guard !stopped, let input else { return }
        for item in typing.take(now: ProcessInfo.processInfo.systemUptime) {
            switch item {
            case let .text(text): input.text(text)
            case let .key(keysym, modifiers): input.key(keysym: keysym, modifiers: modifiers)
            }
        }
        guard !typingScheduled, let delay = typing.nextDelay else { return }
        typingScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.typingScheduled = false
            self.typeWaiting()
        }
    }

    // MARK: Capture and encoding

    /// `maxSide` 0: the display's own size in points.
    private func startCapture(maxSide: Int) {
        captureStarted = true
        let capture = self.capture, queue = self.queue
        Task {
            do {
                let info = try await capture.start(maxSide: maxSide > 0 ? maxSide : 4096, queue: queue, frame: { [weak self] buffer in
                    self?.captured(buffer)
                }, stopped: { [weak self] error in
                    queue.async {
                        ptLog(.warning, "screen: capture stopped: \(error.map { String(describing: $0) } ?? "no reason")")
                        self?.finish()
                    }
                })
                queue.async { [weak self] in
                    // Gone meanwhile: nobody else will stop what just started.
                    guard let self else { return capture.stop() }
                    self.captureReady(width: info.width, height: info.height, display: info.display)
                }
            } catch {
                queue.async { [weak self] in
                    ptLog(.error, "screen: can't capture the screen: \(error)")
                    self?.finish()
                }
            }
        }
    }

    private func captureReady(width: Int, height: Int, display: CGRect) {
        guard !stopped else { return capture.stop() }
        // About 4 bits per pixel each second: 1728×1117 gets ~7.7 Mb/s.
        let settings = (width: width, height: height, bitRate: min(max(width * height * 4, 2_000_000), 20_000_000))
        encoderSettings = settings
        do {
            encoder = try VideoEncoder(width: settings.width, height: settings.height, bitRate: settings.bitRate)
        } catch {
            ptLog(.error, "screen: no H.264 encoder: \(error)")
            return finish()
        }
        input = makeInput(display)
        ptLog(.info, "screen: streaming \(width)×\(height)")
        pump()
    }

    /// On `queue` (capture delivers there).
    private func captured(_ buffer: CVPixelBuffer) {
        guard !stopped else { return }
        captureCount += 1
        waiting = buffer
        refinesLeft = Self.refinePasses
        pump()
    }

    /// Encodes the waiting frame if the phone has room for it, and the stream has taken what was sent before.
    private func pump() {
        guard !stopped, !encoding, let encoder, let buffer = waiting, sent &- acked < UInt32(Self.maxInFlight),
              unsentFrames < limits.frames, unsentBytes < limits.softBytes else { return }
        waiting = nil
        last = buffer
        encoding = true
        let keyframe = needsKeyframe
        let count = captureCount
        encoder.encode(buffer, at: CMClockGetTime(clock), keyframe: keyframe) { [weak self] encoded in
            guard let self else { return }
            self.queue.async {
                self.encoding = false
                guard !self.stopped else { return }
                if let encoded {
                    self.failures = 0
                    self.send(encoded)
                } else {
                    self.encodeFailed()
                }
                self.scheduleRefine(after: count)
                self.pump()
            }
        }
    }

    /// An encode came back empty: dropped, or the encoder died (it can after sleep). A keyframe the phone
    /// waits for is tried again; a few empty ones in a row get the encoder made again, once.
    private func encodeFailed() {
        failures += 1
        if needsKeyframe, waiting == nil { waiting = last }
        guard failures >= 3 else { return }
        guard !remadeEncoder, let settings = encoderSettings,
              let fresh = try? VideoEncoder(width: settings.width, height: settings.height, bitRate: settings.bitRate) else {
            ptLog(.error, "screen: the H.264 encoder stopped working")
            return finish()
        }
        ptLog(.warning, "screen: the H.264 encoder stopped working; made a new one")
        remadeEncoder = true
        failures = 0
        encoder?.invalidate()
        encoder = fresh
        needsKeyframe = true
        if waiting == nil { waiting = last }
    }

    private func send(_ encoded: VideoEncoder.Encoded) {
        guard stream != nil, let encoder else { return }
        if encoded.keyframe {
            needsKeyframe = false
            if let sps = encoded.sps, let pps = encoded.pps {
                write(ScreenVideoWire.encode(.format(width: encoder.width, height: encoder.height, sps: sps, pps: pps)), frame: false)
            }
        }
        sent &+= 1
        write(ScreenVideoWire.encode(.frame(number: sent, keyframe: encoded.keyframe, data: encoded.data)), frame: true)
    }

    /// Hands `data` to the stream, counted as waiting until its send completes.
    private func write(_ data: Data, frame: Bool) {
        guard let stream else { return }
        let count = data.count
        unsentBytes += count
        if frame { unsentFrames += 1 }
        checkBacklog()
        stream.send(data, isComplete: false) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.unsentBytes -= count
                if frame { self.unsentFrames -= 1 }
                self.checkBacklog()
                self.pump()
            }
        }
    }

    /// Over the hard cap: the phone has `stallTimeout` to read before it is dropped.
    private func checkBacklog() {
        guard unsentBytes > limits.hardBytes else { overHardLimitSince = nil; return }
        guard overHardLimitSince == nil else { return }
        let since = ProcessInfo.processInfo.systemUptime
        overHardLimitSince = since
        queue.asyncAfter(deadline: .now() + limits.stallTimeout) { [weak self] in
            guard let self, !self.stopped, self.overHardLimitSince == since else { return }
            ptLog(.warning, "screen: a phone is not reading the screen stream; disconnected")
            self.finish()
        }
    }

    /// Sends the last frame again once the screen has been still a moment.
    private func scheduleRefine(after count: Int) {
        guard refinesLeft > 0 else { return }
        queue.asyncAfter(deadline: .now() + Self.refineDelay) { [weak self] in
            guard let self, !self.stopped, self.captureCount == count, self.waiting == nil, self.refinesLeft > 0, let last = self.last else { return }
            self.refinesLeft -= 1
            self.waiting = last
            self.pump()
        }
    }

    // MARK: Ending

    /// It can't go on: stop, and have the connection closed.
    private func finish() {
        guard !stopped else { return }
        let ended = self.ended
        shutDown()
        ended?()
    }

    private func shutDown() {
        guard !stopped else { return }
        stopped = true
        ended = nil
        capture.stop()
        encoder?.invalidate()
        encoder = nil
        input = nil
        waiting = nil
        last = nil
        stream = nil
    }
}
#endif
