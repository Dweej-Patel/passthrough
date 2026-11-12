import Foundation
import CoreGraphics
import Combine

/// Whether this Mac's screen is locked, and locking it.
///
/// Locking is what the Apple menu's Lock Screen does: the login window
/// covers the screen and asks for the password, and nothing else changes. The
/// Mac doesn't sleep, so shells, downloads and the passthrough carry on.
@MainActor
final class ScreenLock: ObservableObject {
    static let shared = ScreenLock()

    @Published private(set) var isLocked: Bool
    private var observers: [NSObjectProtocol] = []

    private init() {
        // The session's own record, for a launch while already locked.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        isLocked = (session?["CGSSessionScreenIsLocked"] as? Bool) == true
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLocked = locked }
            })
        }
    }

    /// Locks the screen now. False when macOS's lock call can't be found.
    ///
    /// macOS has no public call for this. `SACLockScreenImmediate`, in the
    /// system's login framework, is the one the Apple menu's Lock Screen
    /// reaches; it is looked up by name so a macOS without it fails here
    /// rather than at launch.
    func lock() -> Bool {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(framework, "SACLockScreenImmediate") else { return false }
        typealias LockNow = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: LockNow.self)() == 0
    }
}
