import CoreGraphics
import Foundation

/// Where on this Mac each viewer's stream is (in CoreGraphics' global display
/// coordinates, as input is posted), by viewer id: a drop at a point across
/// the stream lands at the same point on this display. The latest stream's.
public enum ScreenStreamDisplays {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rects: [String: CGRect] = [:]

    static func set(_ rect: CGRect, for viewer: String) {
        lock.lock(); rects[viewer] = rect; lock.unlock()
    }

    public static func rect(for viewer: String) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return rects[viewer]
    }

    /// The point (`x`, `y`), each 0…65535 across `viewer`'s stream, on this Mac.
    public static func point(x: UInt16, y: UInt16, for viewer: String) -> CGPoint? {
        guard let rect = rect(for: viewer) else { return nil }
        return CGPoint(x: rect.minX + CGFloat(x) / 65535 * (rect.width - 1), y: rect.minY + CGFloat(y) / 65535 * (rect.height - 1))
    }
}
