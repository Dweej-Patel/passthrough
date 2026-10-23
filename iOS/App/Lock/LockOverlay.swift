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
        if let window {
            // Cancel a fade-out in progress: the cover must be fully up right away.
            window.layer.removeAllAnimations()
            window.alpha = 1
        }
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

    /// Fades the cover out; `show()` cancels the fade if the app locks or resigns meanwhile.
    private func hide() {
        guard let window, !window.isHidden else { return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            window.alpha = 0
        } completion: { finished in
            guard finished else { return }
            window.isHidden = true
            window.alpha = 1
        }
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
            PTBackground(glow: 0.6)
            if lock.isUnlocked {
                // Privacy cover for the app switcher: identity only, nothing from the app.
                AppIconView().frame(width: 96, height: 96)
            } else {
                LockScreen()
            }
        }
    }
}

/// The branded lock screen. Authentication starts only from its button.
private struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock
    @State private var method: AppLock.Method = .passcode

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    identity
                    Spacer(minLength: 32)
                    actions
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear { method = lock.method }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Enrolment can change in the Settings app while we're away.
            method = lock.method
        }
        .animation(.easeInOut(duration: 0.2), value: lock.failure)
        .animation(.easeInOut(duration: 0.2), value: lock.isEvaluating)
    }

    private var identity: some View {
        VStack(spacing: 18) {
            AppIconView()
                .frame(width: 96, height: 96)
                .shadow(color: PTTheme.accentEnd.opacity(0.3), radius: 22, y: 8)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Passthrough").font(PTTheme.display(32))
                PTPill("Locked", icon: "lock.fill", tint: .secondary)
            }
            Text("Your Mac stays online while Passthrough is locked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            if let notice = lock.notice {
                Label(notice, systemImage: "terminal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await lock.unlock() }
            } label: {
                HStack(spacing: 10) {
                    if lock.isEvaluating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: method.symbol).font(.title3.weight(.semibold))
                    }
                    Text("Unlock with \(method.title)")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(PTTheme.accentEnd)
            .disabled(lock.isEvaluating)
            if let failure = lock.failure {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PTTheme.danger)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }
}
