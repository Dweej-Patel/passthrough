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
            PTColor.background.ignoresSafeArea()
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

/// The app icon as a rounded tile, from a full-resolution copy (`AppMark`, written by
/// scripts/make_icons.swift): the bundle's home-screen icon is at most 180 px and blurs when
/// shown larger.
struct AppIconView: View {
    var body: some View {
        GeometryReader { geometry in
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: geometry.size.width * 0.225, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
