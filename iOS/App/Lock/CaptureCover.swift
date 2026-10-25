import SwiftUI
import UIKit
import PassthroughUI

/// "Hide shell and Screen from screenshots and recordings": the terminal, the
/// session history and the Mac's screen are covered while this iPhone's
/// screen is recorded, mirrored or shared (iOS can't keep a screenshot from
/// being taken, but it says when the screen is being captured). On unless
/// the user turns it off in Settings.
enum CaptureProtection {
    static let key = "captureProtection"
    static let defaultOn = true
}

/// Whether any of the app's scenes is being recorded, mirrored or shared
/// (`UITraitCollection.sceneCaptureState`).
@MainActor
final class SceneCaptureWatch: ObservableObject {
    static let shared = SceneCaptureWatch()

    @Published private(set) var isCaptured = false
    private var watched: [ObjectIdentifier: UITraitChangeRegistration] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Scenes connect after launch: start watching each as it does.
        for name in [UIScene.didActivateNotification, UIScene.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        var captured = false
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let id = ObjectIdentifier(scene)
            if watched[id] == nil {
                watched[id] = scene.registerForTraitChanges([UITraitSceneCaptureState.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
            if scene.traitCollection.sceneCaptureState == .active { captured = true }
        }
        if captured != isCaptured { isCaptured = captured }
    }
}

private struct CaptureCover: ViewModifier {
    let onCovered: (Bool) -> Void
    @AppStorage(CaptureProtection.key) private var enabled = CaptureProtection.defaultOn
    @ObservedObject private var watch = SceneCaptureWatch.shared
    @Environment(\.dismiss) private var dismiss

    private var covered: Bool { enabled && watch.isCaptured }

    func body(content: Content) -> some View {
        content
            .overlay {
                if covered { cover.transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.2), value: covered)
            .onChange(of: covered, initial: true) { _, covered in onCovered(covered) }
    }

    /// The app switcher's privacy cover (LockOverlay), with a way out.
    private var cover: some View {
        ZStack {
            PTBackground(glow: 0.6)
            VStack(spacing: 18) {
                AppIconView().frame(width: 96, height: 96).accessibilityHidden(true)
                Text("Hidden while this iPhone's screen is recorded or shared.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Close") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(PTTheme.accentEnd)
            }
            .padding(32)
            .frame(maxWidth: 440)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
    }
}

extension View {
    /// Covers this presented view while the screen is being captured, if the
    /// user wants that (`CaptureProtection`). `onCovered` runs whenever that
    /// changes, e.g. to put the keyboard away so typing stops with the view hidden.
    func hiddenWhileCaptured(onCovered: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(CaptureCover(onCovered: onCovered))
    }
}
