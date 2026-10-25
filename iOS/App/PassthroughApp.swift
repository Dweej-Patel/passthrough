import SwiftUI
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
