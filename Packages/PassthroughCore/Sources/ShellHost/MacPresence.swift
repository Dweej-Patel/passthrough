#if os(macOS)
import CoreGraphics
import Foundation

/// Whether someone is at this Mac: a key, the mouse or the trackpad used
/// lately, and the screen not locked. A terminal window showing a session
/// is looked at only then, so a result that arrives while nobody is there
/// is still news for the phones.
public enum MacPresence {
    public static let activeWithin: TimeInterval = 120

    public static var userIsActive: Bool {
        guard let any = CGEventType(rawValue: UInt32.max) else { return false }   // kCGAnyInputEventType
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        guard idle < activeWithin else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
#endif
