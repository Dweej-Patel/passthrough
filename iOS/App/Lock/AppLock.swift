import LocalAuthentication
import os
import SwiftUI

/// Gate for the whole app UI. Face ID / Touch ID with passcode fallback (passcode alone when no
/// biometrics are enrolled). It locks the UI only; the packet tunnel keeps serving.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isUnlocked = false
    /// The last successfully evaluated context. The shell key vault reuses it to read a
    /// `.userPresence` Keychain item without a second prompt.
    private(set) var context = LAContext()

    static let relockAfter: TimeInterval = 60

    private static let log = Logger(subsystem: "app.passthrough", category: "AppLock")
    private var evaluating = false
    private var backgroundedAt: Date?
    /// True on cold launch and after each trip to the background; the gate consumes it to prompt
    /// once per activation, so cancelling the sheet does not re-prompt in a loop.
    private var autoPromptPending = true

    func unlock() async {
        guard !isUnlocked, !evaluating else { return }
        evaluating = true
        defer { evaluating = false }

        let ctx = LAContext()
        ctx.touchIDAuthenticationAllowableReuseDuration = 60
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error, LAError.Code(rawValue: error.code) == .passcodeNotSet {
                // No passcode at all: there is nothing to check, so don't strand the user.
                Self.log.notice("No device passcode set; unlocking without authentication")
                context = ctx
                isUnlocked = true
            } else {
                Self.log.error("Lock policy unavailable: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            return
        }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Passthrough")
            context = ctx
            isUnlocked = true
        } catch {
            Self.log.notice("Unlock not completed: \(error.localizedDescription, privacy: .public)")
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
        autoPromptPending = true
    }

    private func expireIfNeeded() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        let away = Date().timeIntervalSince(since)
        // A negative interval means the clock moved; treat that as expired.
        if away >= Self.relockAfter || away < 0 { lock() }
    }

    /// True once per activation; the gate uses it to decide whether to auto-prompt.
    func takeAutoPrompt() -> Bool {
        defer { autoPromptPending = false }
        return autoPromptPending
    }

    /// Ends the unlocked session so the gate prompts again: the one prompt comes from the lock.
    /// The shell model calls this when the vault can't read a key with `context`.
    func invalidateSession() { lock() }

    private func lock() {
        guard isUnlocked else { return }
        context.invalidate()
        context = LAContext()
        isUnlocked = false
        autoPromptPending = true
    }
}
