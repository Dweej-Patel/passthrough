import SwiftUI
import PassthroughCore
import PassthroughUI

@main
struct PassthroughApp: App {
    @UIApplicationDelegateAdaptor(AppOrientation.self) private var orientation
    @StateObject private var model = AppModel()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LockGate { RootView() }
                // Here, not in RootView: that's built only after the first
                // unlock, and a cold launch from a widget would lose its link.
                .onOpenURL { PendingLinks.shared.open(AppLink(url: $0)) }
                .tint(PTColor.tintText)
                .environmentObject(model)
                .environmentObject(lock)
                .preferredColorScheme(nil)
                .onChange(of: scenePhase) { _, phase in lock.sceneChanged(to: phase) }
                .onChange(of: lock.isUnlocked) { _, _ in model.lock = lock; model.refreshShell() }
                .task { model.lock = lock }
        }
    }
}
