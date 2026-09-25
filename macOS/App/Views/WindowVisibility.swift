import SwiftUI
import AppKit

/// Reports whether the hosting window is actually on screen. `MenuBarExtra`
/// keeps its panel content alive while closed, so `onAppear`/`onDisappear`
/// don't track visibility; the window's occlusion state does.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observed: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            observed = window
            guard let window else { onChange?(false); return }
            let report = { [weak self, weak window] in
                guard let self, let window else { return }
                self.onChange?(window.isVisible && window.occlusionState.contains(.visible))
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in report() })
            }
            report()
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
