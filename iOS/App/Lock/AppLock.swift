import LocalAuthentication
import os
import SwiftUI

/// Gate for the whole app UI. Face ID / Touch ID with passcode fallback (passcode alone when no
/// biometrics are enrolled). It locks the UI only; the packet tunnel keeps serving.
///
/// Authentication never starts by itself: the lock screen shows first and `unlock()` runs when
/// the user taps its button. The one exception is a device with no passcode at all, where there
/// is nothing to check (`unlockIfNothingToCheck()`).
@MainActor
final class AppLock: ObservableObject {
    /// How this device can unlock, for the lock screen's button and Settings.
    enum Method: Equatable {
        case faceID, touchID, opticID, passcode
        /// No passcode is set: there is nothing to check.
        case none

        var title: String {
            switch self {
            case .faceID: "Face ID"
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            case .passcode, .none: "Passcode"
            }
        }

        var symbol: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .passcode, .none: "lock.fill"
            }
        }
    }

    @Published private(set) var isUnlocked = false
    @Published private(set) var isEvaluating = false
    /// Why the last attempt didn't unlock, shown under the button; nil after a plain cancel.
    @Published private(set) var failure: String?
    /// Why the app locked itself while in use (not a timeout), shown on the lock screen.
    @Published private(set) var notice: String?
    /// The last successfully evaluated context. The shell key vault reuses it to read a
    /// `.userPresence` Keychain item without a second prompt.
    private(set) var context = LAContext()

    static let relockAfter: TimeInterval = 60

    private static let log = Logger(subsystem: "app.passthrough", category: "AppLock")
    private var backgroundedAt: Date?

    /// Reads the device's enrolled biometry without prompting.
    var method: Method {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch ctx.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: return .passcode
            }
        }
        var policyError: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) { return .passcode }
        if let policyError, LAError.Code(rawValue: policyError.code) == .passcodeNotSet { return .none }
        return .passcode
    }

    /// Asks for Face ID / Touch ID / the passcode. Only ever called from a user's tap.
    func unlock() async {
        guard !isUnlocked, !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        failure = nil

        let ctx = LAContext()
        ctx.touchIDAuthenticationAllowableReuseDuration = 60
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error, LAError.Code(rawValue: error.code) == .passcodeNotSet {
                // No passcode at all: there is nothing to check, so don't strand the user.
                Self.log.notice("No device passcode set; unlocking without authentication")
                open(with: ctx)
            } else {
                Self.log.error("Lock policy unavailable: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                failure = "This iPhone can't check it's you right now. Try again in a moment."
            }
            return
        }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Passthrough")
            open(with: ctx)
        } catch {
            Self.log.notice("Unlock not completed: \(error.localizedDescription, privacy: .public)")
            failure = Self.message(for: error, method: method)
        }
    }

    /// Unlocks without a prompt only when the device has no passcode (nothing to check).
    func unlockIfNothingToCheck() {
        guard !isUnlocked, method == .none else { return }
        Task { await unlock() }
    }

    private func open(with ctx: LAContext) {
        context = ctx
        failure = nil
        notice = nil
        isUnlocked = true
    }

    /// Copy for a failed evaluation; nil when the user (or the system) just cancelled.
    private static func message(for error: Error, method: Method) -> String? {
        guard let code = (error as? LAError)?.code else { return "Couldn't unlock. Try again." }
        switch code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return nil
        case .authenticationFailed:
            return "\(method.title) didn't recognise you. Try again."
        case .biometryLockout:
            return "\(method.title) is locked. Unlock with your passcode."
        case .passcodeNotSet:
            return "Set a passcode in the Settings app to lock Passthrough."
        default:
            return "Couldn't unlock. Try again."
        }
    }

    func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .background: markBackground()
        // The expiry decision runs as soon as we leave .background (the .inactive that precedes
        // .active), while the overlay is still up. .inactive alone (Face ID sheet) never counts.
        case .inactive, .active: expireIfNeeded()
        @unknown default: break
        }
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        // UIKit notifications fire synchronously and before the app becomes active, so the
        // expiry is decided before the overlay window can drop.
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.markBackground() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireIfNeeded() }
            },
        ]
    }

    private func markBackground() {
        if backgroundedAt == nil { backgroundedAt = Date() }
        // A message from before the trip away is stale by the time anyone sees the lock again.
        failure = nil
    }

    private func expireIfNeeded() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        let away = Date().timeIntervalSince(since)
        // A negative interval means the clock moved; treat that as expired.
        if away >= Self.relockAfter || away < 0 { lock() }
    }

    /// Ends the unlocked session so the lock screen asks again: the one prompt comes from the
    /// lock, when the user taps it. The shell model calls this when the vault can't read a key
    /// with `context`.
    func invalidateSession() {
        guard isUnlocked else { return }
        notice = "Unlock again to use Remote shell."
        lock()
    }

    private func lock() {
        guard isUnlocked else { return }
        context.invalidate()
        context = LAContext()
        failure = nil
        isUnlocked = false
    }
}
