import SwiftUI
import PassthroughUI

/// Builds `content` only after the first unlock. Once built it stays alive (so its sheets can be
/// torn down on relock) but is non-interactive and hidden from accessibility while locked; the
/// `LockOverlay` window covers everything, including sheets, whenever locked or not active.
/// Nothing here starts authentication: the overlay's lock screen asks when the user taps it.
struct LockGate<Content: View>: View {
    @EnvironmentObject private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    @State private var overlay: LockOverlay?
    @State private var built = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            PTBackground(glow: 0.45)
            if built {
                content()
                    .allowsHitTesting(lock.isUnlocked)
                    .accessibilityHidden(!lock.isUnlocked)
            }
        }
        .onAppear {
            if overlay == nil { overlay = LockOverlay(lock: lock) }
            built = built || lock.isUnlocked
            if scenePhase == .active { lock.unlockIfNothingToCheck() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lock.unlockIfNothingToCheck() }
        }
        .onChange(of: lock.isUnlocked) { _, unlocked in
            if unlocked { built = true }
        }
    }
}

/// The home screen icon, read from the bundle's icon list (asset-catalog app icons can't be
/// loaded with `Image(_:)`).
private let appIconImage: UIImage? = {
    guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
          let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
          let files = primary["CFBundleIconFiles"] as? [String],
          let name = files.last else { return nil }
    return UIImage(named: name)
}()

struct AppIconView: View {
    var body: some View {
        if let image = appIconImage {
            Image(uiImage: image)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            Image(systemName: "lock.fill")
                .resizable().scaledToFit().padding(24)
                .foregroundStyle(PTTheme.accent)
        }
    }
}
