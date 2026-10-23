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
public final class ScreenVideoStreamer: ScreenVideoSource, @unchecked Sendable {
    /// Frames sent but not yet on the phone's screen.
    static let maxInFlight = 2
    /// How long the screen must be still before the last frame is sharpened.
    static let refineDelay: TimeInterval = 0.25
    static let refinePasses = 2

    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video", qos: .userInteractive)
    private let capture: FrameCapturing
    private let makeInput: (CGRect) -> InputSink

    // On `queue`.
    private var stream: (any ByteStream)?
    private var ended: (@Sendable () -> Void)?
    private var reader = ScreenVideoWire.Reader()
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

    init(capture: FrameCapturing, input: @escaping (CGRect) -> InputSink) {
        self.capture = capture
        self.makeInput = input
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
        case let .key(keysym, modifiers): input?.key(keysym: keysym, modifiers: modifiers)
        case let .text(text): input?.text(text)
        case let .clipboard(text): input?.clipboard(text)
        case .format, .frame:
            break
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

    /// Encodes the waiting frame if the phone has room for it.
    private func pump() {
        guard !stopped, !encoding, let encoder, let buffer = waiting, sent &- acked < UInt32(Self.maxInFlight) else { return }
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
        guard let stream, let encoder else { return }
        if encoded.keyframe {
            needsKeyframe = false
            if let sps = encoded.sps, let pps = encoded.pps {
                stream.send(ScreenVideoWire.encode(.format(width: encoder.width, height: encoder.height, sps: sps, pps: pps)),
                            isComplete: false) { _ in }
            }
        }
        sent &+= 1
        stream.send(ScreenVideoWire.encode(.frame(number: sent, keyframe: encoded.keyframe, data: encoded.data)), isComplete: false) { _ in }
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
