import Combine
import SwiftUI
import UIKit
import PassthroughUI

/// A dedicated UIWindow above every sheet, full-screen cover and alert. It shows the lock screen
/// while locked and a privacy cover whenever the app is not active (app switcher snapshot), so any
/// presentation, present or future, is covered without per-view work.
@MainActor
final class LockOverlay {
    private let lock: AppLock
    private var window: UIWindow?
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(lock: AppLock) {
        self.lock = lock
        let nc = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(resigning: name == UIApplication.willResignActiveNotification) }
            })
        }
        // isUnlocked publishes in willSet; refresh on the next turn so it reads the new value.
        lock.$isUnlocked.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
        refresh(resigning: UIApplication.shared.applicationState != .active)
    }

    private func refresh(resigning: Bool? = nil) {
        let inactive = resigning ?? (UIApplication.shared.applicationState != .active)
        let visible = !lock.isUnlocked || inactive
        if visible {
            show()
            if !lock.isUnlocked { dismissPresentations() }
        } else {
            hide()
        }
    }

    private func show() {
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            let host = UIHostingController(rootView: OverlayView().environmentObject(lock))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.isHidden = false
    }

    private func hide() {
        window?.isHidden = true
    }

    /// Dismiss anything presented from the app's own windows (sheets, full-screen covers).
    private func dismissPresentations() {
        guard let scene = window?.windowScene else { return }
        for w in scene.windows where w !== window {
            if w.rootViewController?.presentedViewController != nil {
                w.rootViewController?.dismiss(animated: false)
            }
        }
    }
}

private struct OverlayView: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            PTBackground(glow: 0.45)
            VStack(spacing: 22) {
                AppIconView().frame(width: 96, height: 96)
                if !lock.isUnlocked {
                    Text("Passthrough").font(PTTheme.display(30))
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label("Unlock", systemImage: "lock.open.fill")
                            .font(.headline)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ignoresSafeArea()
    }
}
