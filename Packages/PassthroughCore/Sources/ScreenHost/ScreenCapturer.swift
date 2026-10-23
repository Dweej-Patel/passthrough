#if os(macOS)
import CoreGraphics
import CoreMedia
import Foundation
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
/// with the pointer drawn in.
final class ScreenCapturer: NSObject, FrameCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Set from the starting task, used and cleared on the streamer's queue.
    private let lock = NSLock()
    private var stream: SCStream?
    private var onFrame: ((CVPixelBuffer) -> Void)?
    private var onStopped: ((Error?) -> Void)?
    private var stopped = false

    func start(maxSide: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void,
               stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let main = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
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
        if alreadyStopped { stream.stopCapture { _ in } }
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
        stopped?(error)
    }
}
#endif
