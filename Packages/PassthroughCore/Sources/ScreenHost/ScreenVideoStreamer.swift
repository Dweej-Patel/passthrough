#if os(macOS)
import CoreMedia
import Foundation
import PassthroughCore
import ShellHost

/// The Mac's screen to one phone as H.264 (protocol/README.md, "Screen
/// video"). Latency comes from what waits, so nothing does: the phone acks
/// each frame it shows, and while the pacer's window of frames is unacked the
/// newest captured frame waits alone (older ones are dropped before they
/// are encoded, never after). The window fits the round trip, and the
/// bitrate falls when acks start lagging behind it (`StreamPacer`). When the
/// screen goes still, its last frame is sent again a couple of times so the
/// encoder can sharpen it. The pointer isn't in the frames: where it is and
/// what it looks like go separately (`CursorSource`), and the phone draws it.
///
/// The phone's `hello` says what to show, and comes again when that changes:
/// the Mac's own display, or one made in the phone's shape (`DeviceDisplaying`).
/// Each change is a new capture; the old one goes on until the new one is up.
///
/// Acks are the phone's word, so they are not all that paces it: a frame is
/// also only encoded while the stream has taken what was sent before it
/// (`Limits`), and a phone that acks without reading is dropped once what
/// waits for it passes a hard cap for a few seconds. Its input is bounded
/// too: payload caps in `ScreenVideoWire.Reader(from: .phone)`, and text
/// posted at a steady rate (`TypingPacer`).
public final class ScreenVideoStreamer: ScreenVideoSource, @unchecked Sendable {
    /// How often the pointer's place is looked at, and (every `shapeEvery`th time) its shape.
    static let cursorInterval: TimeInterval = 1.0 / 60
    static let shapeEvery = 6
    /// The sides a display made for the phone may have, in pixels.
    static let maxDeviceSide = 4096
    static let minDeviceSide = 320

    /// What the streamer lets wait in the stream (handed over, its send not
    /// yet complete): new frames are only encoded under `frames` and
    /// `softBytes`, and over `hardBytes` for `stallTimeout` the phone is
    /// dropped (the shell lines' own cap, `ShellConnection.sendBacklogLimit`).
    struct Limits {
        var frames = StreamPacer.maxWindow
        var softBytes = 4 << 20
        var hardBytes = 8 << 20
        var stallTimeout: TimeInterval = 5
        /// How long after its ⌘C a `copy` waits for the clipboard to change
        /// before answering `nothing`. Kept short: any change in that time is
        /// taken as the ⌘C's.
        var copyTimeout: TimeInterval = 1
        /// How long a phone may say nothing, with frames it hasn't acknowledged,
        /// before its curtain comes down: put away or gone without a word, no one
        /// is watching, and the Mac shouldn't stay black for whoever is at it.
        var curtainSilence: TimeInterval = 20
        /// H.264 even for a phone that decodes HEVC (tests of the H.264 path).
        var h264Only = false
    }
    /// How long the screen must be still before the last frame is sharpened.
    static let refineDelay: TimeInterval = 0.25
    static let refinePasses = 2

    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video", qos: .userInteractive)
    /// Reads the copied text: an app that provides its data lazily is asked
    /// for it then, which mustn't hold up frames and input on `queue`.
    private let clipboardQueue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video.clipboard", qos: .userInitiated)
    private let makeCapture: () -> FrameCapturing
    private let makeInput: (CGRect) -> InputSink
    private let deviceDisplay: DeviceDisplaying?
    private let cursorSource: CursorSource?
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
    /// The capture showing now, and what it shows.
    private var capture: FrameCapturing?
    private var fit = ScreenVideoWire.Fit.mac
    /// Where the captured display is, in global coordinates (points).
    private var displayRect: CGRect?
    /// Bumped by every new capture: frames and endings of the ones before are ignored.
    private var captureGeneration = 0
    /// The generation of `capture`, which goes on showing while a newer one starts.
    private var shownGeneration = 0
    /// The newest frame of a capture still starting, encoded once it's up.
    private var startingFrame: CVPixelBuffer?
    /// What the phone last asked to see (`hello`), and what was last started for it.
    private var wanted: (width: Int, height: Int, fit: ScreenVideoWire.Fit)?
    private var applied: (width: Int, height: Int, fit: ScreenVideoWire.Fit, scale: Double)?
    /// The share of the full size to capture at: less while the link is slow (`StreamPacer.scale`).
    private var captureScale = 1.0
    /// What `applyWanted` would start now.
    private var target: (width: Int, height: Int, fit: ScreenVideoWire.Fit, scale: Double)? {
        wanted.map { ($0.width, $0.height, $0.fit, captureScale) }
    }
    /// A capture is starting (`applyWanted`); another change waits for it.
    private var starting = false
    /// Display changes and new captures, one after another.
    private var displayWork: Task<Void, Never>?
    private var cursorTimer: DispatchSourceTimer?
    private var cursorTicks = 0
    private var lastCursor: (x: UInt16, y: UInt16, visible: Bool)?
    private var lastShape: CursorImage?
    private var shapePending = false
    /// A `curtain` that came before capture was up.
    private var wantsCurtain: Bool?
    /// The Mac's displays are hidden for this phone (the Mac's last answer).
    private var curtainUp = false
    private var watchingSilence = false
    /// When the phone last sent anything (system uptime).
    private var heardAt = ProcessInfo.processInfo.systemUptime
    private var encoder: VideoEncoder?
    private var encoderSettings: (width: Int, height: Int, bitRate: Int)?
    /// What the phone decodes (its `hello`): HEVC when it can, H.264 otherwise.
    private var phoneCodecs: ScreenVideoWire.Codecs = .h264
    /// Encodes in a row that came back empty; the encoder is made again once, then the stream ends.
    private var failures = 0
    private var remadeEncoder = false
    private var input: InputSink?
    private var waiting: CVPixelBuffer?
    private var last: CVPixelBuffer?
    private var encoding = false
    private var sent: UInt32 = 0
    private var acked: UInt32 = 0
    private var pacer: StreamPacer?
    private var needsKeyframe = true
    private var refinesLeft = 0
    /// Bumped by every captured frame, so a pending sharpen of an older one is dropped.
    private var captureCount = 0
    private let clock = CMClockGetHostTimeClock()

    /// The main display or one made for the phone, with input injected as the Mac's own events.
    public convenience init() {
        self.init(capture: { ScreenCapturer() }, input: { InputInjector(display: $0) }, display: DeviceDisplay(), cursor: SystemCursor())
    }

    /// A new capture for each change of what's shown. `limits` are smaller in tests.
    init(capture: @escaping () -> FrameCapturing, input: @escaping (CGRect) -> InputSink, display: DeviceDisplaying? = nil,
         cursor: CursorSource? = nil, limits: Limits = Limits()) {
        self.makeCapture = capture
        self.makeInput = input
        self.deviceDisplay = display
        self.cursorSource = cursor
        self.limits = limits
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            self.stream = stream
            self.ended = ended
            received(initialBytes)
            receive()
            // A phone that never says hello still gets a picture.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if !stopped, wanted == nil { show(width: 0, height: 0, fit: .mac) }
            }
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
        heardAt = ProcessInfo.processInfo.systemUptime
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
        case let .hello(width, height, fit, codecs):
            phoneCodecs = codecs
            show(width: width, height: height, fit: fit)
        case let .ack(number):
            guard number <= sent, number > acked else { return }
            acked = number
            if pacer?.acked(number, at: uptime) == true, let pacer { encoder?.setBitRate(pacer.bitRate) }
            if let scale = pacer?.rescale(at: uptime) { rescale(to: scale) }
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
        case let .curtain(hidden): setCurtain(hidden)
        case .format, .frame, .copied, .curtained, .fitted, .cursor, .cursorShape:
            break
        }
    }

    /// Hides the Mac's displays from whoever is at the Mac (or shows them again), and
    /// tells the phone what they are now. Before capture is up there is nothing
    /// to leave the curtain out of: it waits for `captureReady`.
    private func setCurtain(_ hidden: Bool) {
        guard input != nil, let capture else { wantsCurtain = hidden; return }
        wantsCurtain = nil
        capture.setCurtain(hidden) { [weak self] nowHidden in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                if hidden != nowHidden { ptLog(.warning, "screen: couldn't hide the display for a phone") }
                self.curtainUp = nowHidden
                if nowHidden { self.watchSilence() }
                self.write(ScreenVideoWire.encode(.curtained(nowHidden)), frame: false)
            }
        }
    }

    /// While the curtain is up for this phone: down again once the phone has
    /// gone quiet with frames out (`limits.curtainSilence`). A still screen sends
    /// none, so it waits for the screen to change.
    private func watchSilence() {
        guard !watchingSilence else { return }
        watchingSilence = true
        queue.asyncAfter(deadline: .now() + min(5, limits.curtainSilence / 2)) { [weak self] in
            guard let self else { return }
            self.watchingSilence = false
            guard !self.stopped, self.curtainUp else { return }
            if self.sent != self.acked, ProcessInfo.processInfo.systemUptime - self.heardAt > self.limits.curtainSilence {
                ptLog(.info, "screen: the phone viewing the screen went quiet; its display shows again")
                self.curtainUp = false
                self.setCurtain(false)
            } else {
                self.watchSilence()
            }
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

    /// The phone wants to see this (`hello`): started now, or once the capture starting now is up.
    private func show(width: Int, height: Int, fit: ScreenVideoWire.Fit) {
        var fit = fit
        // A display the encoder couldn't take, or too small to use: the Mac's own.
        if fit == .device, max(width, height) > Self.maxDeviceSide || min(width, height) < Self.minDeviceSide {
            ptLog(.warning, "screen: a phone asked for a \(width)×\(height) display; showing the Mac's own")
            fit = .mac
        }
        wanted = (width, height, fit)
        captureStarted = true
        if !starting { applyWanted() }
    }

    /// Starts a capture of what the phone last asked for, unless that's showing
    /// already: on a display made in its shape (`device`; the Mac's own if that
    /// can't be made), or the main display fitted inside its size (`mac`).
    private func applyWanted() {
        guard !stopped, let wanted, let target else { return }
        if let applied, applied == target { return }
        // The Mac's own display at the phone's size: only its longer side matters.
        if wanted.fit == .mac, let applied, applied.fit == .mac, fit == .mac, applied.scale == captureScale,
           max(applied.width, applied.height) == max(wanted.width, wanted.height) {
            self.applied = target
            return
        }
        applied = target
        let scale = captureScale
        starting = true
        captureGeneration += 1
        let generation = captureGeneration
        // Frames of the capture before are another size: none of them is encoded from now.
        waiting = nil
        last = nil
        startingFrame = nil
        let device = deviceDisplay, queue = self.queue, capture = makeCapture()
        let before = displayWork
        displayWork = Task { [weak self] in
            await before?.value
            var fit = wanted.fit
            var source = CaptureSource.main(maxSide: wanted.width > 0 ? max(wanted.width, wanted.height) : 4096, scale: scale)
            if fit == .device, let device {
                do {
                    let id = try await device.show(width: wanted.width, height: wanted.height)
                    // The display keeps the phone's size; only the capture is smaller on a slow link.
                    source = .display(id, width: Int(Double(wanted.width) * scale) & ~1, height: Int(Double(wanted.height) * scale) & ~1)
                } catch {
                    ptLog(.warning, "screen: couldn't make a display for the phone (\(error)); showing the Mac's own")
                    fit = .mac
                }
            } else {
                fit = .mac
                await device?.close()
            }
            do {
                let info = try await capture.start(source, queue: queue, frame: { [weak self] buffer in
                    self?.captured(buffer, generation: generation)
                }, stopped: { [weak self] error in
                    queue.async { self?.captureStopped(generation: generation, error: error) }
                })
                queue.async { [weak self] in
                    // Gone meanwhile: nobody else will stop what just started.
                    guard let self else { return capture.stop() }
                    self.captureReady(capture, generation: generation, fit: fit, scale: scale, width: info.width, height: info.height,
                                      display: info.display)
                }
            } catch {
                queue.async { [weak self] in
                    guard let self else { return }
                    self.captureFailed(generation: generation, fit: fit, error: error)
                }
            }
        }
    }

    /// A capture ended by itself: the one showing, unless a newer one is about to take over.
    private func captureStopped(generation: Int, error: Error?) {
        guard !stopped, generation == shownGeneration, capture != nil else { return }
        ptLog(.warning, "screen: capture stopped: \(error.map { String(describing: $0) } ?? "no reason")")
        // The display it showed went away for the one starting (the phone's made, or removed).
        if starting { capture = nil; return }
        finish()
    }

    private func captureFailed(generation: Int, fit: ScreenVideoWire.Fit, error: Error) {
        guard !stopped, generation == captureGeneration else { return }
        starting = false
        // The phone's display was made but can't be captured: the Mac's own, then.
        if fit == .device, let wanted {
            ptLog(.warning, "screen: can't capture the phone's display: \(error); showing the Mac's own")
            self.wanted = (wanted.width, wanted.height, .mac)
            applied = nil
            return applyWanted()
        }
        // A capture already showing goes on (the phone asked for a change that didn't work).
        if capture != nil {
            ptLog(.warning, "screen: couldn't change the capture: \(error)")
            return applyWanted()
        }
        ptLog(.error, "screen: can't capture the screen: \(error)")
        finish()
    }

    private func captureReady(_ new: FrameCapturing, generation: Int, fit: ScreenVideoWire.Fit, scale: Double, width: Int, height: Int,
                              display: CGRect) {
        guard !stopped, generation == captureGeneration else { return new.stop() }
        starting = false
        let old = capture
        capture = new
        shownGeneration = generation
        self.fit = fit
        displayRect = display
        // About 4 bits per pixel each second at full size: 1728×1117 gets ~7.7 Mb/s.
        let fullPixels = Double(width * height) / (scale * scale)
        let maxBitRate = min(max(Int(fullPixels * 4), 2_000_000), 20_000_000)
        if pacer == nil { pacer = StreamPacer(maxBitRate: maxBitRate) } else { pacer?.setMaxBitRate(maxBitRate) }
        let bitRate = pacer?.bitRate ?? maxBitRate
        if encoderSettings.map({ $0.width != width || $0.height != height }) ?? true {
            let settings = (width: width, height: height, bitRate: bitRate)
            encoderSettings = settings
            encoder?.invalidate()
            encoder = makeEncoder(width: settings.width, height: settings.height, bitRate: settings.bitRate)
            guard encoder != nil else {
                ptLog(.error, "screen: no video encoder")
                old?.stop()
                return finish()
            }
            remadeEncoder = false
            failures = 0
        }
        needsKeyframe = true
        if let input = input as? InputInjector { input.display = display } else { input = makeInput(display) }
        ptLog(.info, "screen: streaming \(width)×\(height) \(encoder?.codec == .hevc ? "HEVC" : "H.264")\(fit == .device ? " on a display made for the phone" : "")")
        // The pointer again, in this stream's terms.
        lastCursor = nil
        lastShape = nil
        write(ScreenVideoWire.encode(.fitted(fit)), frame: false)
        // The curtain stays up across the change: this capture wants it before the old one leaves it.
        if let old {
            if curtainUp {
                new.setCurtain(true) { [weak self] nowHidden in
                    guard let self else { return old.stop() }
                    self.queue.async {
                        old.stop()
                        guard !self.stopped, !nowHidden, self.curtainUp else { return }
                        ptLog(.warning, "screen: couldn't keep the display hidden for a phone")
                        self.curtainUp = false
                        self.write(ScreenVideoWire.encode(.curtained(false)), frame: false)
                    }
                }
            } else {
                old.stop()
            }
        } else if let hidden = wantsCurtain {
            setCurtain(hidden)
        }
        waiting = startingFrame ?? waiting
        startingFrame = nil
        startCursor()
        pump()
        // The phone asked for something else meanwhile.
        if let target, let applied, target != applied { applyWanted() }
    }

    /// On `queue` (capture delivers there).
    private func captured(_ buffer: CVPixelBuffer, generation: Int) {
        guard !stopped, generation == captureGeneration else { return }
        // Before it's up the encoder is the old capture's, maybe another size.
        if starting { startingFrame = buffer; return }
        captureCount += 1
        waiting = buffer
        refinesLeft = Self.refinePasses
        pump()
    }

    /// Encodes the waiting frame if the phone has room for it, and the stream has taken what was sent before.
    private func pump() {
        guard !stopped, !encoding, let encoder, let buffer = waiting, sent &- acked < UInt32(pacer?.window ?? StreamPacer.minWindow),
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
                // The capture changed size meanwhile: this frame is the old encoder's.
                guard self.encoder === encoder else { return self.pump() }
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
              let fresh = makeEncoder(width: settings.width, height: settings.height, bitRate: settings.bitRate) else {
            ptLog(.error, "screen: the video encoder stopped working")
            return finish()
        }
        ptLog(.warning, "screen: the video encoder stopped working; made a new one")
        remadeEncoder = true
        failures = 0
        encoder?.invalidate()
        encoder = fresh
        if let pacer { fresh.setBitRate(pacer.bitRate) }
        needsKeyframe = true
        if waiting == nil { waiting = last }
    }

    /// The link is too slow for this size, or fast enough for a bigger one: captured at `scale` of the full size.
    private func rescale(to scale: Double) {
        guard scale != captureScale else { return }
        ptLog(.info, "screen: \(scale < captureScale ? "smaller" : "bigger") picture for the link: \(Int(scale * 100))% (\((pacer?.bitRate ?? 0) / 1000) kb/s)")
        captureScale = scale
        if !starting { applyWanted() }
    }

    /// HEVC if the phone decodes it and the Mac's hardware encodes it, else H.264; nil if neither.
    private func makeEncoder(width: Int, height: Int, bitRate: Int) -> VideoEncoder? {
        if phoneCodecs.contains(.hevc), !limits.h264Only,
           let hevc = try? VideoEncoder(codec: .hevc, width: width, height: height, bitRate: bitRate) {
            return hevc
        }
        return try? VideoEncoder(codec: .h264, width: width, height: height, bitRate: bitRate)
    }

    private func send(_ encoded: VideoEncoder.Encoded) {
        guard stream != nil, let encoder else { return }
        if encoded.keyframe {
            needsKeyframe = false
            if !encoded.parameterSets.isEmpty {
                write(ScreenVideoWire.encode(.format(codec: encoder.codec, width: encoder.width, height: encoder.height,
                                                     parameterSets: encoded.parameterSets)), frame: false)
            }
        }
        sent &+= 1
        pacer?.sent(sent, keyframe: encoded.keyframe, at: uptime)
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

    // MARK: Pointer

    /// Where the pointer is (when it moves) and what it looks like (when that
    /// changes), for the phone to draw: the frames leave it out.
    private func startCursor() {
        guard cursorTimer == nil, cursorSource != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.cursorInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.cursorTick() }
        timer.resume()
        cursorTimer = timer
    }

    private func cursorTick() {
        guard !stopped, let cursorSource, let rect = displayRect, rect.width > 1, rect.height > 1 else { return }
        cursorTicks += 1
        if let point = cursorSource.location() {
            let visible = point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
            let scale = { (v: CGFloat) in UInt16(clamping: Int((max(0, min(v, 1)) * 65535).rounded())) }
            let x = scale((point.x - rect.minX) / (rect.width - 1)), y = scale((point.y - rect.minY) / (rect.height - 1))
            if lastCursor.map({ $0.x != x || $0.y != y || $0.visible != visible }) ?? true {
                lastCursor = (x, y, visible)
                write(ScreenVideoWire.encode(.cursor(x: x, y: y, visible: visible)), frame: false)
            }
        }
        guard cursorTicks % Self.shapeEvery == 1, !shapePending else { return }
        shapePending = true
        DispatchQueue.main.async { [weak self, cursorSource] in
            let shape = MainActor.assumeIsolated { cursorSource.shape() }
            self?.queue.async { self?.sendShape(shape) }
        }
    }

    private func sendShape(_ shape: CursorImage?) {
        shapePending = false
        guard !stopped, let shape, shape != lastShape, let rect = displayRect, rect.width > 0, let encoder else { return }
        lastShape = shape
        // Points to this stream's pixels.
        let scale = CGFloat(encoder.width) / rect.width
        let px = { (v: CGFloat) in max(0, Int((v * scale).rounded())) }
        write(ScreenVideoWire.encode(.cursorShape(width: max(1, px(shape.size.width)), height: max(1, px(shape.size.height)),
                                                  hotX: px(shape.hotSpot.x), hotY: px(shape.hotSpot.y), png: shape.png)), frame: false)
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
        if let pacer, let rtt = pacer.minRTT {
            ptLog(.info, "screen: ended; shortest round trip \(Int(rtt * 1000)) ms, last bitrate \(pacer.bitRate / 1000) kb/s of \(pacer.maxBitRate / 1000)")
        }
        cursorTimer?.cancel()
        cursorTimer = nil
        capture?.stop()
        capture = nil
        startingFrame = nil
        // After any display change under way, so the phone's display can't outlive the stream.
        let device = deviceDisplay, before = displayWork
        displayWork = Task {
            await before?.value
            await device?.close()
        }
        encoder?.invalidate()
        encoder = nil
        input = nil
        waiting = nil
        last = nil
        stream = nil
    }
}
#endif
