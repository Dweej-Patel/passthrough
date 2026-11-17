#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the Mac's pointer looks like, in points.
struct CursorImage: Equatable, Sendable {
    var png: Data
    var size: CGSize
    var hotSpot: CGPoint
}

/// Where the Mac's pointer is and what it looks like: the stream leaves it
/// out, and the phone draws it where its own touches put it, without waiting
/// for a frame. `SystemCursor`, or a test's.
protocol CursorSource: AnyObject, Sendable {
    /// In global display coordinates (points, origin top left); nil if unknown. Any thread.
    func location() -> CGPoint?
    /// The cursor showing now; nil if unknown.
    @MainActor func shape() -> CursorImage?
}

/// The system's pointer, whichever app set it.
final class SystemCursor: CursorSource {
    func location() -> CGPoint? { CGEvent(source: nil)?.location }

    @MainActor func shape() -> CursorImage? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        // Retina: the phone shows it at least as sharp as the Mac does.
        var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * 2, height: image.size.height * 2))
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CursorImage(png: data as Data, size: image.size, hotSpot: cursor.hotSpot)
    }
}
#endif
