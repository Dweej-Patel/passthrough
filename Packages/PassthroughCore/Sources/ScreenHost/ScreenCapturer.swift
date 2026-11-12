#if os(macOS)
import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import PassthroughCore
import ScreenCaptureKit

/// Where the streamer gets the screen: `ScreenCapturer`, or frames a test makes.
protocol FrameCapturing: AnyObject {
    /// Starts delivering frames of at most `maxSide` pixels on their longer
    /// side, on `queue`: only when the screen changed. `stopped` runs if
    /// capture ends by itself. Returns the frames' size and the display's
    /// place in global coordinates (points), for input.
    func start(maxSide: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void,
               stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect)
    func stop()
    /// Hides what the Mac's displays show to whoever is at the Mac (`hidden`), while
    /// the frames go on showing it, or shows it again. `done` gets what they are
    /// now: false when it couldn't hide them. `stop()` always shows them again.
    func setCurtain(_ hidden: Bool, done: @escaping @Sendable (Bool) -> Void)
}

extension FrameCapturing {
    func setCurtain(_ hidden: Bool, done: @escaping @Sendable (Bool) -> Void) { done(false) }
}

/// The main display through ScreenCaptureKit, at its size in points (or
/// smaller), up to 60 frames a second, in the encoder's own 4:2:0 format,
/// with the pointer drawn in. While it captures, the display is kept on
/// (`DisplayWake`): a display that is off has nothing to capture.
final class ScreenCapturer: NSObject, FrameCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// How long a display that was off gets to come on before capture is given up.
    static let displayWait: TimeInterval = 5

    // Set from the starting task, used and cleared on the streamer's queue.
    private let lock = NSLock()
    private var stream: SCStream?
    private var onFrame: ((CVPixelBuffer) -> Void)?
    private var onStopped: ((Error?) -> Void)?
    private var stopped = false
    private var display: SCDisplay?
    /// This stream with the Mac's one curtain (`ScreenCurtain.shared`), which every stream leaves out.
    private let curtainID = UUID()
    /// The curtain's windows, as last told: what the stream leaves out.
    private var excluded: [SCWindow] = []
    /// Told what the curtain is when it falls without being asked (`setCurtain`'s `done`).
    private var curtainReport: (@Sendable (Bool) -> Void)?
    /// This stream's asks of the curtain, one after another: leaving it comes last.
    private var curtainWork: Task<Void, Never>?
    private let wake = DisplayWake()

    func start(maxSide: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void,
               stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect) {
        wake.begin()
        do {
            return try await capture(maxSide: maxSide, queue: queue, frame: frame, stopped: stopped)
        } catch {
            wake.end()
            leaveCurtain()
            throw error
        }
    }

    /// The display to capture, once there is one: while the display is off
    /// (asleep, or the Mac in dark wake with its lid closed) ScreenCaptureKit
    /// lists none, until `DisplayWake` has brought it on.
    private func mainDisplay() async throws -> SCDisplay {
        let deadline = Date().addingTimeInterval(Self.displayWait)
        while true {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let main = CGMainDisplayID()
            if let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first { return display }
            guard Date() < deadline, !lock.withLock({ self.stopped }) else { throw CocoaError(.featureUnsupported) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func capture(maxSide: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void,
                         stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect) {
        let display = try await mainDisplay()
        let scale = min(1, Double(max(maxSide, 320)) / Double(max(display.width, display.height)))
        // Even sizes: 4:2:0 halves both.
        let width = Int(Double(display.width) * scale) & ~1
        let height = Int(Double(display.height) * scale) & ~1

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false

        lock.withLock { onFrame = frame; onStopped = stopped }
        // Another view's curtain may be up: left out from the first frame.
        let viewer = ScreenCurtain.Viewer(exclude: { [weak self] windows in await self?.exclude(windows) ?? true },
                                          fell: { [weak self] in self?.lock.withLock { self?.curtainReport }?(false) })
        let leftOut = await ScreenCurtain.shared.join(curtainID, viewer)
        lock.withLock { excluded = leftOut }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: leftOut), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let (alreadyStopped, latest) = lock.withLock { () -> (Bool, [SCWindow]) in
            if !self.stopped { self.stream = stream; self.display = display }
            return (self.stopped, self.excluded)
        }
        // `stop()` came while starting: it had nothing to stop yet.
        if alreadyStopped {
            stream.stopCapture { _ in }
            wake.end()
            leaveCurtain()
        } else if latest.map(\.windowID) != leftOut.map(\.windowID) {
            // The curtain changed while this started.
            try? await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: latest))
        }
        return (width, height, CGDisplayBounds(display.displayID))
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            stopped = true
            onFrame = nil
            onStopped = nil
            defer { self.stream = nil }
            return self.stream
        }
        stream?.stopCapture { _ in }
        wake.end()
        leaveCurtain()
    }

    // MARK: Curtain

    func setCurtain(_ hidden: Bool, done: @escaping @Sendable (Bool) -> Void) {
        let id = curtainID
        lock.withLock {
            curtainReport = done
            let before = curtainWork
            curtainWork = Task {
                await before?.value
                done(await ScreenCurtain.shared.want(id, hidden))
            }
        }
    }

    /// After any ask still under way, so nothing can raise it for this stream once it is over.
    private func leaveCurtain() {
        let id = curtainID
        lock.withLock {
            curtainReport = nil
            let before = curtainWork
            curtainWork = Task {
                await before?.value
                await ScreenCurtain.shared.leave(id)
            }
        }
    }

    /// The curtain's windows, left out of this stream from now on.
    private func exclude(_ windows: [SCWindow]) async -> Bool {
        let (stream, display) = lock.withLock { () -> (SCStream?, SCDisplay?) in
            excluded = windows
            return (self.stream, self.display)
        }
        // Not started yet (it starts with them), or over.
        guard let stream, let display else { return true }
        do {
            try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: windows))
            return true
        } catch {
            return lock.withLock { self.stream == nil }   // over meanwhile: nothing left to show
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only frames with new pixels: idle ones (nothing changed) carry none.
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer else { return }
        lock.withLock { onFrame }?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped = lock.withLock { () -> ((Error?) -> Void)? in
            defer { onStopped = nil }
            return onStopped
        }
        wake.end()
        leaveCurtain()
        stopped?(error)
    }
}

/// Keeps the display on while a phone watches it, as macOS's Screen Sharing
/// does: declaring user activity wakes a display that went off (the Mac
/// idle, or asleep with its lid closed) and brings the Mac to full wake;
/// renewed every `renewal`, it stays on, lid closed or not, until `end()`.
/// Then the Mac's own display-sleep and sleep settings apply again.
final class DisplayWake: @unchecked Sendable {
    /// Well inside the ~30 s after which a closed-lid Mac turns its display off again.
    static let renewal: TimeInterval = 10

    private let lock = NSLock()
    private var assertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var timer: DispatchSourceTimer?

    func begin() {
        lock.withLock {
            guard timer == nil else { return }
            declare()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + Self.renewal, repeating: Self.renewal)
            timer.setEventHandler { [weak self] in self?.lock.withLock { self?.declare() } }
            timer.resume()
            self.timer = timer
        }
    }

    func end() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            guard assertion != IOPMAssertionID(kIOPMNullAssertionID) else { return }
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    deinit { end() }

    /// Local, not remote: only local user activity turns the display on.
    /// With the same id it renews the one assertion. Under `lock`.
    private func declare() {
        let result = IOPMAssertionDeclareUserActivity("Passthrough: a phone is viewing this screen" as CFString, kIOPMUserActiveLocal, &assertion)
        if result != kIOReturnSuccess { ptLog(.warning, "screen: couldn't keep the display on (\(result))") }
    }
}
#endif
