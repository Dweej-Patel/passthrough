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

    /// A stream that showed `rect` ended: its entry goes, unless a newer stream of the viewer's set another.
    static func remove(_ rect: CGRect, for viewer: String) {
        lock.lock(); if rects[viewer] == rect { rects[viewer] = nil }; lock.unlock()
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

/// While a drop is being dragged into place on this Mac (clipboard sync's
/// drop), viewers' pointer, scroll, gesture, key and text input is dropped
/// (not delayed), so a click or a move from a viewer doesn't end the drag
/// somewhere else. Set from the press until the drag is let go (about half a
/// second); otherwise nothing is held.
public enum ScreenInputHold {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held = false

    public static var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    public static func set(_ on: Bool) {
        lock.lock(); held = on; lock.unlock()
    }
}
