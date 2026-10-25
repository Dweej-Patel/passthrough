import AppIntents
import Foundation

/// A link or intent waiting for the app to unlock (and, for a change to the
/// Mac, for the Mac to be reachable). `RootView` carries it out.
@MainActor
final class PendingLinks: ObservableObject {
    static let shared = PendingLinks()
    @Published private(set) var pending: AppLink?
    /// Why the last one couldn't be done, shown on the Mac tab.
    @Published var note: String?
    private var giveUp: Task<Void, Never>?

    func open(_ link: AppLink?) {
        guard let link else { return }
        note = nil
        pending = link
        giveUp?.cancel()
        // A change to the Mac waits for it; not forever.
        giveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.pending == link else { return }
            self.pending = nil
            self.note = "Couldn't reach your Mac in time. Try again once it shows as reachable."
        }
    }

    func done() {
        pending = nil
        giveUp?.cancel()
    }
}

// MARK: - Shortcuts, Siri and the Action button

// Each opens Passthrough: only the app can reach the Mac, and its keys need
// Face ID. Turning the VPN off isn't offered: it lowers protection, so it's in-app only.

struct KeepMacAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac awake"
    static let description = IntentDescription("Opens Passthrough and turns on Keep awake on your Mac.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        PendingLinks.shared.open(.keepAwake)
        return .result()
    }
}

struct MacVPNOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn on Mac VPN"
    static let description = IntentDescription("Opens Passthrough and turns on your Mac's VPN.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        PendingLinks.shared.open(.vpnOn)
        return .result()
    }
}

struct StepAwayIntent: AppIntent {
    static let title: LocalizedStringResource = "Step away from Mac"
    static let description = IntentDescription("Opens Passthrough's checklist before you leave your Mac.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        PendingLinks.shared.open(.stepAway)
        return .result()
    }
}

struct PassthroughShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: KeepMacAwakeIntent(), phrases: ["Keep my Mac awake with \(.applicationName)"],
                    shortTitle: "Keep Mac awake", systemImageName: "cup.and.saucer.fill")
        AppShortcut(intent: MacVPNOnIntent(), phrases: ["Turn on my Mac's VPN with \(.applicationName)"],
                    shortTitle: "Mac VPN on", systemImageName: "lock.shield.fill")
        AppShortcut(intent: StepAwayIntent(), phrases: ["Step away from my Mac with \(.applicationName)"],
                    shortTitle: "Step away", systemImageName: "figure.walk")
    }
}
