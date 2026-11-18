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
/// It also says how fast (the phone's frame rate) and what matters most when
/// the link can't carry it all (`Quality`, the pacer's `Profile`). While only
/// a sliver of the screen changes (a spinner, streaming text) and the phone
/// sends no input, frames go at `idleFPS`, back to full speed at its first touch.
///
/// Each view joins `ScreenViewers`, so it hears which other devices view the
/// screen, and its phone can take over ("Use Here"): the others are told who
/// and end.
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
    /// A frame where less than this share of the screen changed is a sliver (a spinner).
    static let smallChange = 0.03
    /// Slivers only, and nothing from the phone, for this long: `idleFPS`.
    static let idleAfter: TimeInterval = 1
    static let idleFPS = 15.0

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
    private let makeVoice: (() -> VoiceSink)?
    /// Starts and stops the voice's player, which can take a moment: not on `queue`, where frames wait.
    private let voiceQueue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video.voice", qos: .userInitiated)
    private let limits: Limits
    /// This view in `ScreenViewers`: its phone and that phone's name. Nil in tests that don't need it.
    private let viewer: (phoneID: String, name: String)?
    private let viewerID = UUID()
    /// A screen pass's view (another Mac's): it sees and controls the screen,
    /// but never hides the Mac's displays from whoever is at it, nor ends the
    /// other views (Use Here).
    private let restricted: Bool

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
    /// The capture showing now, and what it shows.
    private var capture: FrameCapturing?
    /// The capture showing before, which ended by itself while a new one starts:
    /// kept, so the new one takes the curtain over from it, then it's stopped.
    private var retiring: FrameCapturing?
    private var fit = ScreenVideoWire.Fit.mac
    /// Where the captured display is, in global coordinates (points).
    private var displayRect: CGRect?
    /// Bumped by every new capture: frames and endings of the ones before are ignored.
    private var captureGeneration = 0
    /// The generation of `capture`, which goes on showing while a newer one starts.
    private var shownGeneration = 0
    /// The newest frame of a capture still starting, encoded once it's up.
    private var startingFrame: CVPixelBuffer?
    /// What a capture is: a change in any of it is a new one.
    private struct CaptureKey: Equatable {
        var fit: ScreenVideoWire.Fit
        /// `mac`: the phone's longer side, both. `device`: the stream's size.
        var width: Int
        var height: Int
        var fps: Int
        var scale: Double
        var space: Int
    }
    /// What the phone last asked to see (`hello`), and what was last started for it.
    private var wanted: ScreenVideoWire.Hello?
    private var applied: CaptureKey?
    /// The share of the full size to capture at: less while the link is slow (`StreamPacer.scale`).
    private var captureScale = 1.0
    /// The full-size stream's pixels (the capture's, before `captureScale`), for the top bitrate.
    private var fullPixels: Double?
    /// What `applyWanted` would start now.
    private var target: CaptureKey? {
        guard let wanted else { return nil }
        guard wanted.fit == .device else {
            let side = wanted.width > 0 ? max(wanted.width, wanted.height) : 4096
            return CaptureKey(fit: .mac, width: side, height: side, fps: wanted.fps, scale: captureScale, space: 100)
        }
        return CaptureKey(fit: .device, width: wanted.width, height: wanted.height, fps: wanted.fps, scale: captureScale, space: wanted.space)
    }
    /// The idle slow-down: since when every frame has been a sliver, when the phone last
    /// sent input, when a frame was last encoded (system uptime).
    private var slivers: TimeInterval?
    private var inputAt: TimeInterval = 0
    private var encodedAt: TimeInterval = 0
    private var idlePumpScheduled = false
    /// The other devices viewing, as last sent.
    private var othersSent: [String]?
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
    private var encoderSettings: (width: Int, height: Int, bitRate: Int, fps: Int)?
    /// What the phone decodes (its `hello`): HEVC when it can, H.264 otherwise.
    private var phoneCodecs: ScreenVideoWire.Codecs = .h264
    /// Encodes in a row that came back empty; the encoder is made again once, then the stream ends.
    private var failures = 0
    private var remadeEncoder = false
    private var keyframeRetryScheduled = false
    private var input: InputSink?
    /// Where the phone's voice goes while it is this Mac's microphone, and whether it's on (`start` said so).
    private var voice: VoiceSink?
    private var voiceOn = false
    /// Bumped by every `microphone`: a start that finishes after a later one is ignored.
    private var voiceAsked = 0
    private var waiting: CVPixelBuffer?
    private var last: CVPixelBuffer?
    private var encoding = false
    private var sent: UInt32 = 0
    private var acked: UInt32 = 0
    private var pacer = StreamPacer(maxBitRate: 2_000_000)
    private var needsKeyframe = true
    private var refinesLeft = 0
    /// Bumped by every captured frame, so a pending sharpen of an older one is dropped.
    private var captureCount = 0
    private let clock = CMClockGetHostTimeClock()

    /// The main display or one made for the phone, with input injected as the Mac's own events.
    /// `phoneID` and `name` (the paired phone's): who this view is to the other views.
    /// `restricted` for a screen pass's view.
    public convenience init(phoneID: String, name: String, restricted: Bool = false) {
        _ = TypingKeys.shared   // the keyboard layout read while the stream starts, before the phone types
        self.init(capture: { ScreenCapturer() }, input: { InputInjector(display: $0) }, display: DeviceDisplay(), cursor: SystemCursor(),
                  voice: { PhoneVoicePlayer() }, viewer: (phoneID, name), restricted: restricted)
    }

    /// A new capture for each change of what's shown. `limits` are smaller in tests.
    init(capture: @escaping () -> FrameCapturing, input: @escaping (CGRect) -> InputSink, display: DeviceDisplaying? = nil,
         cursor: CursorSource? = nil, voice: (() -> VoiceSink)? = nil, viewer: (phoneID: String, name: String)? = nil,
         limits: Limits = Limits(), restricted: Bool = false) {
        self.restricted = restricted
        self.makeCapture = capture
        self.makeInput = input
        self.deviceDisplay = display
        self.cursorSource = cursor
        self.makeVoice = voice
        self.viewer = viewer
        self.limits = limits
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            self.stream = stream
            self.ended = ended
            if let viewer {
                ScreenViewers.shared.join(viewerID, .init(phoneID: viewer.phoneID, name: viewer.name, others: { [weak self] names in
                    self?.queue.async { self?.sendOthers(names) }
                }, movedAway: { [weak self] name in
                    self?.queue.async { self?.moveAway(to: name) }
                }))
            }
            received(initialBytes)
            receive()
            // A phone that never says hello still gets a picture.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if !stopped, wanted == nil { show(ScreenVideoWire.Hello(width: 0, height: 0)) }
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
        case let .hello(hello):
            show(hello)
        case let .ack(number):
            guard number <= sent, number > acked else { return }
            acked = number
            if pacer.acked(number, at: uptime) { encoder?.setBitRate(pacer.bitRate) }
            if let scale = pacer.rescale(at: uptime) { rescale(to: scale) }
            pump()
        case .keyframeRequest:
            needsKeyframe = true
            if waiting == nil { waiting = last }
            pump()
        case let .pointer(x, y, buttons): heardInput(); input?.pointer(x: x, y: y, buttons: buttons)
        case let .scroll(dx, dy): heardInput(); scroll(dx: dx, dy: dy)
        case let .key(keysym, modifiers): heardInput(); type(.key(keysym: keysym, modifiers: modifiers))
        case let .text(text): heardInput(); type(.text(text))
        case let .clipboard(text): type(.clipboard(text))
        case .copy: heardInput(); copySelection()
        case .useHere: if !restricted { useHere() }
        case let .gesture(gesture, phase, value): heardInput(); input?.gesture(gesture, phase: phase, value: value)
        case let .curtain(hidden):
            // Refused, and said so: the displays stay as they are.
            if restricted { write(ScreenVideoWire.encode(.curtained(false)), frame: false) } else { setCurtain(hidden) }
        // A screen pass's view is never this Mac's microphone.
        case let .microphone(on):
            if restricted { write(ScreenVideoWire.encode(.microphoneState(on ? .failed : .off)), frame: false) } else { setMicrophone(on) }
        case let .voice(samples): if voiceOn { voice?.play(samples) }
        case let .function(down): heardInput(); input?.function(down)
        case .format, .frame, .copied, .curtained, .fitted, .cursor, .cursorShape, .viewers, .movedAway, .microphoneState:
            break
        }
    }

    /// The phone is this Mac's microphone from now (its voice played to the "Passthrough
    /// Microphone" device), or no longer; it's told which, and sends voice only once it's `on`.
    private func setMicrophone(_ on: Bool) {
        voiceAsked += 1
        let asked = voiceAsked
        guard on, let makeVoice else {
            stopVoice()
            return write(ScreenVideoWire.encode(.microphoneState(on ? .failed : .off)), frame: false)
        }
        let sink = voice ?? makeVoice()
        voice = sink
        voiceQueue.async { [weak self] in
            let state = sink.start()
            guard let self else { return sink.stop() }
            self.queue.async {
                // Stopped, or asked for something else, while it started.
                guard !self.stopped, asked == self.voiceAsked else { return }
                self.voiceOn = state == .on
                if state == .on {
                    ptLog(.info, "screen: \(self.viewer?.name ?? "a phone") is this Mac's microphone")
                } else {
                    self.stopVoice()
                }
                self.write(ScreenVideoWire.encode(.microphoneState(state)), frame: false)
            }
        }
    }

    private func stopVoice() {
        voiceOn = false
        guard let sink = voice else { return }
        voice = nil
        voiceQueue.async { sink.stop() }
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

    /// Text, keys and clipboards go through the pacer, so each stays behind what came before it.
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
            case let .clipboard(text): input.clipboard(text)
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
    private func show(_ hello: ScreenVideoWire.Hello) {
        var hello = hello
        // A display the encoder couldn't take, or too small to use: the Mac's own.
        if hello.fit == .device, max(hello.width, hello.height) > Self.maxDeviceSide || min(hello.width, hello.height) < Self.minDeviceSide {
            ptLog(.warning, "screen: a phone asked for a \(hello.width)×\(hello.height) display; showing the Mac's own")
            hello.fit = .mac
        }
        phoneCodecs = hello.codecs
        if wanted.map({ $0.quality != hello.quality || $0.fps != hello.fps }) ?? true {
            pacer.setProfile(.of(hello.quality), fps: hello.fps)
            captureScale = pacer.scale
        }
        wanted = hello
        updateMaxBitRate()
        if !starting { applyWanted() }
    }

    /// Starts a capture of what the phone last asked for, unless that's showing
    /// already: on a display made in its shape (`device`; the Mac's own if that
    /// can't be made), or the main display fitted inside its size (`mac`).
    private func applyWanted() {
        guard !stopped, let key = target else { return }
        if let applied, applied == key { return }
        applied = key
        starting = true
        captureGeneration += 1
        let generation = captureGeneration
        // The capture showing goes on being encoded until the new one is up.
        startingFrame = nil
        let device = deviceDisplay, queue = self.queue, capture = makeCapture()
        let before = displayWork
        displayWork = Task { [weak self] in
            await before?.value
            var fit = key.fit
            var source = CaptureSource.main(maxSide: max(key.width, key.height), scale: key.scale)
            if fit == .device, let device {
                do {
                    let display = Self.displaySize(key)
                    let id = try await device.show(width: display.width, height: display.height, fps: key.fps)
                    // The stream is the phone's size (smaller on a slow link), whatever the display's.
                    source = .display(id, width: Int(Double(key.width) * key.scale) & ~1, height: Int(Double(key.height) * key.scale) & ~1)
                } catch {
                    ptLog(.warning, "screen: couldn't make a display for the phone (\(error)); showing the Mac's own")
                    fit = .mac
                }
            } else {
                fit = .mac
                await device?.close()
            }
            do {
                let info = try await capture.start(source, fps: key.fps, queue: queue, frame: { [weak self] buffer, changed in
                    self?.captured(buffer, changed: changed, generation: generation)
                }, stopped: { [weak self] error in
                    queue.async { self?.captureStopped(generation: generation, error: error) }
                })
                queue.async { [weak self] in
                    // Gone meanwhile: nobody else will stop what just started.
                    guard let self else { return capture.stop() }
                    self.captureReady(capture, generation: generation, fit: fit, scale: key.scale, fps: key.fps,
                                      width: info.width, height: info.height, display: info.display)
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
        if starting {
            retiring = capture
            capture = nil
            return
        }
        finish()
    }

    private func captureFailed(generation: Int, fit: ScreenVideoWire.Fit, error: Error) {
        guard !stopped, generation == captureGeneration else { return }
        starting = false
        // The phone's display was made but can't be captured: the Mac's own, then.
        if fit == .device, wanted != nil {
            ptLog(.warning, "screen: can't capture the phone's display: \(error); showing the Mac's own")
            wanted?.fit = .mac
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

    private func captureReady(_ new: FrameCapturing, generation: Int, fit: ScreenVideoWire.Fit, scale: Double, fps: Int,
                              width: Int, height: Int, display: CGRect) {
        guard !stopped, generation == captureGeneration else { return new.stop() }
        starting = false
        let old = capture ?? retiring
        retiring = nil
        capture = new
        shownGeneration = generation
        self.fit = fit
        displayRect = display
        fullPixels = Double(width * height) / (scale * scale)
        updateMaxBitRate()
        let bitRate = pacer.bitRate
        if encoderSettings.map({ $0.width != width || $0.height != height || $0.fps != fps }) ?? true {
            let settings = (width: width, height: height, bitRate: bitRate, fps: fps)
            encoderSettings = settings
            encoder?.invalidate()
            encoder = makeEncoder(width: settings.width, height: settings.height, bitRate: settings.bitRate, fps: fps)
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
        ptLog(.info, "screen: streaming \(width)×\(height) at up to \(fps) fps, \(encoder?.codec == .hevc ? "HEVC" : "H.264")\(fit == .device ? ", on a display made for the phone" : "")")
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
        // Frames of the capture before may be another size: none of them is encoded from now.
        waiting = startingFrame
        last = nil
        startingFrame = nil
        startCursor()
        pump()
        // The phone asked for something else meanwhile.
        if let target, let applied, target != applied { applyWanted() }
    }

    /// On `queue` (capture delivers there).
    private func captured(_ buffer: CVPixelBuffer, changed: Double, generation: Int) {
        guard !stopped else { return }
        if generation == captureGeneration {
            // Before it's up the encoder is the old capture's, maybe another size: kept for then.
            if starting { startingFrame = buffer; return }
        } else if !(starting && generation == shownGeneration) {
            return
        }
        if changed < Self.smallChange { slivers = slivers ?? uptime } else { slivers = nil }
        captureCount += 1
        waiting = buffer
        refinesLeft = Self.refinePasses
        pump()
    }

    /// Encodes the waiting frame if the phone has room for it, and the stream has taken what was sent before.
    private func pump() {
        guard !stopped, !encoding, let encoder, let buffer = waiting, sent &- acked < UInt32(pacer.window),
              unsentFrames < limits.frames, unsentBytes < limits.softBytes else { return }
        // Only a spinner moving, and no one touching: slower, until the next input or a real change.
        let now = uptime
        if let slivers, now - slivers >= Self.idleAfter, now - inputAt >= Self.idleAfter, !needsKeyframe,
           now - encodedAt < 1 / Self.idleFPS {
            guard !idlePumpScheduled else { return }
            idlePumpScheduled = true
            queue.asyncAfter(deadline: .now() + (encodedAt + 1 / Self.idleFPS - now)) { [weak self] in
                self?.idlePumpScheduled = false
                self?.pump()
            }
            return
        }
        encodedAt = now
        waiting = nil
        last = buffer
        encoding = true
        let keyframe = needsKeyframe
        let count = captureCount
        encoder.encode(buffer, at: CMClockGetTime(clock), keyframe: keyframe) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                self.encoding = false
                guard !self.stopped else { return }
                // The capture changed size meanwhile: this frame is the old encoder's.
                guard self.encoder === encoder else { return self.pump() }
                switch outcome {
                case let .encoded(encoded):
                    self.failures = 0
                    self.send(encoded)
                case .dropped:
                    self.encodeDropped()
                case .failed:
                    self.encodeFailed()
                }
                self.scheduleRefine(after: count)
                self.pump()
            }
        }
    }

    /// The encoder skipped the frame on purpose. A keyframe the phone waits for is
    /// tried again a moment later (not at once: it may skip that one too).
    private func encodeDropped() {
        guard needsKeyframe, !keyframeRetryScheduled else { return }
        keyframeRetryScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.stopped else { return }
            self.keyframeRetryScheduled = false
            if self.needsKeyframe, self.waiting == nil { self.waiting = self.last }
            self.pump()
        }
    }

    /// An encode failed with an error: the encoder may have died (it can after sleep). A keyframe the phone
    /// waits for is tried again; a few failures in a row get the encoder made again, once.
    private func encodeFailed() {
        failures += 1
        if needsKeyframe, waiting == nil { waiting = last }
        guard failures >= 3 else { return }
        guard !remadeEncoder, let settings = encoderSettings,
              let fresh = makeEncoder(width: settings.width, height: settings.height, bitRate: pacer.bitRate, fps: settings.fps) else {
            ptLog(.error, "screen: the video encoder stopped working")
            return finish()
        }
        ptLog(.warning, "screen: the video encoder stopped working; made a new one")
        remadeEncoder = true
        failures = 0
        encoder?.invalidate()
        encoder = fresh
        needsKeyframe = true
        if waiting == nil { waiting = last }
    }

    /// The link is too slow for this size, or fast enough for a bigger one: captured at `scale` of the full size.
    private func rescale(to scale: Double) {
        guard scale != captureScale else { return }
        ptLog(.info, "screen: \(scale < captureScale ? "smaller" : "bigger") picture for the link: \(Int(scale * 100))% (\(pacer.bitRate / 1000) kb/s)")
        captureScale = scale
        if !starting { applyWanted() }
    }

    /// HEVC if the phone decodes it and the Mac's hardware encodes it, else H.264; nil if neither.
    private func makeEncoder(width: Int, height: Int, bitRate: Int, fps: Int) -> VideoEncoder? {
        if phoneCodecs.contains(.hevc), !limits.h264Only,
           let hevc = try? VideoEncoder(codec: .hevc, width: width, height: height, bitRate: bitRate, fps: fps) {
            return hevc
        }
        return try? VideoEncoder(codec: .h264, width: width, height: height, bitRate: bitRate, fps: fps)
    }

    /// The display made for the phone: the stream's size times its `space`, within the encoder's limits.
    private static func displaySize(_ key: CaptureKey) -> (width: Int, height: Int) {
        var factor = Double(key.space) / 100
        factor = min(factor, Double(maxDeviceSide) / Double(max(key.width, key.height)))
        return (Int(Double(key.width) * factor) & ~1, Int(Double(key.height) * factor) & ~1)
    }

    /// The top bitrate for the full-size stream: about 4 bits per pixel each second
    /// (1728×1117 gets ~7.7 Mb/s), half again for more than 60 frames a second.
    private func updateMaxBitRate() {
        guard let fullPixels, let wanted else { return }
        let frames = wanted.fps > 60 && wanted.quality != .sharp ? 1.5 : 1
        let cap = wanted.quality == .sharp ? 20_000_000 : 30_000_000
        let before = pacer.bitRate
        pacer.setMaxBitRate(min(max(Int(fullPixels * 4 * frames), 2_000_000), cap))
        if pacer.bitRate != before { encoder?.setBitRate(pacer.bitRate) }
    }

    private func heardInput() { inputAt = uptime }

    /// The phone scrolls in the stream's pixels (what its fingers moved over); the Mac scrolls
    /// in points. They're the same only on the Mac's own display at full size: a display made
    /// for the phone has two pixels to the point (it scrolled twice as far as the fingers went),
    /// and a picture shrunk for a slow link has fewer. Fractions are carried over.
    private func scroll(dx: Int16, dy: Int16) {
        guard let input else { return }
        var factor = 1.0
        if let rect = displayRect, let width = encoderSettings?.width, width > 0, rect.width > 0 { factor = Double(rect.width) / Double(width) }
        scrollRest.x += Double(dx) * factor
        scrollRest.y += Double(dy) * factor
        let x = scrollRest.x.rounded(.towardZero), y = scrollRest.y.rounded(.towardZero)
        scrollRest.x -= x
        scrollRest.y -= y
        guard x != 0 || y != 0 else { return }
        input.scroll(dx: Int16(clamping: Int(x)), dy: Int16(clamping: Int(y)))
    }
    private var scrollRest = CGPoint.zero

    private func send(_ encoded: VideoEncoder.Encoded) {
        guard stream != nil, let encoder else { return }
        if encoded.keyframe {
            needsKeyframe = false
            if !encoded.parameterSets.isEmpty {
                write(ScreenVideoWire.encode(.format(codec: encoder.codec, width: encoder.width, height: encoder.height,
                                                     parameterSets: encoded.parameterSets)), frame: false)
                // The phone places the pointer only once it knows the size: where it is goes again after each format.
                lastCursor = nil
            }
        }
        sent &+= 1
        pacer.sent(sent, keyframe: encoded.keyframe, at: uptime)
        write(ScreenVideoWire.encode(.frame(number: sent, keyframe: encoded.keyframe, data: encoded.data)), frame: true)
    }

    /// Hands `data` to the stream, counted as waiting until its send completes (then `then`).
    private func write(_ data: Data, frame: Bool, then: (@Sendable () -> Void)? = nil) {
        guard let stream else { then?(); return }
        let count = data.count
        unsentBytes += count
        if frame { unsentFrames += 1 }
        checkBacklog()
        stream.send(data, isComplete: false) { [weak self] _ in
            then?()
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

    // MARK: Other viewers

    private func sendOthers(_ names: [String]) {
        guard !stopped, names != othersSent else { return }
        othersSent = names
        write(ScreenVideoWire.encode(.viewers(names)), frame: false)
    }

    /// This phone takes over: the other devices' views end. A display made for
    /// the phone that one of them had is free once it's gone, so it's tried again.
    private func useHere() {
        guard viewer != nil else { return }
        ScreenViewers.shared.takeOver(by: viewerID)
        // The other view lets go of the display once its own display work is done, which can take a moment.
        for delay in [1.0, 2.5, 5] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, !self.starting, self.wanted?.fit == .device, self.fit == .mac else { return }
                self.applied = nil
                self.applyWanted()
            }
        }
    }

    /// Another device took over: it's said, and this view ends.
    private func moveAway(to name: String) {
        guard !stopped else { return }
        ptLog(.info, "screen: \(viewer?.name ?? "a phone")'s view moved to \(name)")
        // Closed once it's sent (or after a couple of seconds): closing at once could drop it behind queued frames.
        let finished = Locked(false)
        let end: @Sendable () -> Void = { [weak self] in
            guard !finished.exchange(true) else { return }
            self?.queue.async { self?.finish() }
        }
        write(ScreenVideoWire.encode(.movedAway(to: name)), frame: false, then: end)
        queue.asyncAfter(deadline: .now() + 2) { end() }
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
        ScreenViewers.shared.leave(viewerID)
        if let rtt = pacer.minRTT {
            ptLog(.info, "screen: ended; shortest round trip \(Int(rtt * 1000)) ms, last bitrate \(pacer.bitRate / 1000) kb/s of \(pacer.maxBitRate / 1000)")
        }
        cursorTimer?.cancel()
        cursorTimer = nil
        capture?.stop()
        capture = nil
        retiring?.stop()
        retiring = nil
        startingFrame = nil
        // After any display change under way, so the phone's display can't outlive the stream.
        let device = deviceDisplay, before = displayWork
        displayWork = Task {
            await before?.value
            await device?.close()
        }
        encoder?.invalidate()
        encoder = nil
        // A button or gesture the phone still held (it went mid-drag) is let go, or the Mac
        // would think it's still held: a drag that never ends, and its own input ignored.
        input?.releaseAll()
        input = nil
        voiceAsked += 1
        stopVoice()
        waiting = nil
        last = nil
        stream = nil
    }
}
#endif
