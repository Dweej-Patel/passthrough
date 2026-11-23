import CoreGraphics
import Foundation
import PassthroughCore
import ScreenClient

/// What crosses between the app and the engine helper as plain numbers and
/// strings, and the limits the app holds the helper to. The helper runs a
/// parser of whatever a PC's Remote Desktop sends: the app treats everything
/// it says as untrusted.
public enum ScreenEngineCodes {
    // MARK: Limits

    /// The most a desktop may be, a side and in all (as the Screen Sharing client's limits).
    public static let maxSide = 16384
    public static let maxPixels = 50_000_000
    /// The largest pointer shape, a side (the protocol's large-pointer limit).
    public static let maxPointerSide = 384
    /// The most text taken from the helper (a copy from the PC): 1 MiB of UTF-16.
    public static let maxTextUnits = (1 << 20) / 2

    public static func validSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide && width * height <= maxPixels
    }

    /// `rect` within a `width` x `height` desktop; nil when nothing of it is.
    public static func clipped(x: Int, y: Int, width w: Int, height h: Int, in size: (width: Int, height: Int)) -> CGRect? {
        guard w > 0, h > 0, x < size.width, y < size.height else { return nil }
        let x0 = max(0, x), y0 = max(0, y)
        // No overflow: the sums are bounded before they are made.
        let x1 = min(size.width, x0 + min(w, size.width)), y1 = min(size.height, y0 + min(h, size.height))
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// A pointer shape's bytes are exactly its BGRA pixels, and it is no larger than a pointer may be.
    public static func validPointer(bytes: Int, width: Int, height: Int, hotX: Int, hotY: Int) -> Bool {
        width > 0 && height > 0 && width <= maxPointerSide && height <= maxPointerSide && bytes == width * height * 4
            && hotX >= 0 && hotY >= 0 && hotX <= width && hotY <= height
    }

    // MARK: Phases

    public static func code(_ phase: ScreenConnectPhase) -> Int {
        switch phase {
        case .negotiating: 1
        case .identityChecked: 2
        case .signedIn: 3
        }
    }

    public static func phase(_ code: Int) -> ScreenConnectPhase? {
        switch code {
        case 1: .negotiating
        case 2: .identityChecked
        case 3: .signedIn
        default: nil
        }
    }

    // MARK: Endings

    public static func code(_ end: ScreenEnd) -> (code: Int, detail: String?) {
        switch end {
        case .closedHere: (0, nil)
        case .connectionLost: (1, nil)
        case .identityMismatch: (2, nil)
        case .signIn(.wrongPassword): (3, nil)
        case .signIn(.passwordExpired): (4, nil)
        case .signIn(.accountLocked): (5, nil)
        case .signIn(.accountDisabled): (6, nil)
        case .signIn(.notAllowedRemotely): (7, nil)
        case let .signIn(.other(detail)): (8, detail)
        case let .unsupported(detail): (9, detail)
        case .takenOver: (10, nil)
        case .signedOut: (11, nil)
        case let .hostEnded(detail): (12, detail)
        case let .protocolError(detail): (13, detail)
        }
    }

    /// A code this build doesn't know is a lost connection. `detail` is kept only where an ending carries one, and short.
    public static func end(_ code: Int, detail: String?) -> ScreenEnd {
        let detail = detail.map { String($0.prefix(64)) }
        switch code {
        case 0: return .closedHere
        case 2: return .identityMismatch
        case 3: return .signIn(.wrongPassword)
        case 4: return .signIn(.passwordExpired)
        case 5: return .signIn(.accountLocked)
        case 6: return .signIn(.accountDisabled)
        case 7: return .signIn(.notAllowedRemotely)
        case 8: return .signIn(.other(detail))
        case 9: return .unsupported(detail ?? "Remote Desktop")
        case 10: return .takenOver
        case 11: return .signedOut
        case 12: return .hostEnded(detail ?? "ended")
        case 13: return .protocolError(detail ?? "Remote Desktop")
        default: return .connectionLost
        }
    }

    // MARK: Copies

    public static func code(_ result: ScreenCopyResult) -> (code: Int, text: String?) {
        switch result {
        case let .text(text): (0, text)
        case .nothing: (1, nil)
        case .tooLong: (2, nil)
        case .notText: (3, nil)
        }
    }

    /// Text past the cap is "too long"; a code this build doesn't know is "nothing".
    public static func copyResult(_ code: Int, text: String?) -> ScreenCopyResult {
        switch code {
        case 0:
            guard let text, !text.isEmpty else { return .nothing }
            return text.utf16.count <= maxTextUnits ? .text(text) : .tooLong
        case 2: return .tooLong
        case 3: return .notText
        default: return .nothing
        }
    }
}
