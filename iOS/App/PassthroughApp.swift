import SwiftUI

@main
struct PassthroughApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .preferredColorScheme(nil)
        }
    }
}
