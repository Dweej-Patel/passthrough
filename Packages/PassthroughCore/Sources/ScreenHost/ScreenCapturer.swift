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
    private let wake = DisplayWake()

    func start(maxSide: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void,
               stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect) {
        wake.begin()
        do {
            return try await capture(maxSide: maxSide, queue: queue, frame: frame, stopped: stopped)
        } catch {
            wake.end()
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
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let alreadyStopped = lock.withLock { () -> Bool in
            if !self.stopped { self.stream = stream }
            return self.stopped
        }
        // `stop()` came while starting: it had nothing to stop yet.
        if alreadyStopped {
            stream.stopCapture { _ in }
            wake.end()
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
