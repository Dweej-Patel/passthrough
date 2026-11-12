#if os(macOS)
import AppKit
import CoreGraphics

/// Black over every display while a phone views the screen and asked for it
/// (`ScreenCapturer.setCurtain`): whoever is at the Mac sees nothing of what
/// the phone is doing, and the stream, told to leave these windows out, shows
/// the screen as it is under them. A window of one colour per display: it
/// costs next to nothing. It is a screen for the eyes only: clicks pass
/// through it (the phone's go to what is under it) and the Mac's own keyboard
/// and trackpad still work, so it is no substitute for the lock.
@MainActor
final class ScreenCurtain {
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?
    private var raised = false

    nonisolated init() {}

    /// Puts a window over every display, see-through for now (`raise()` makes
    /// them black), and returns their numbers. `displaysChanged` runs when
    /// displays come, go or change size while it is up: the caller does it again.
    func prepare(displaysChanged: @escaping @Sendable () -> Void) -> Set<CGWindowID> {
        close()
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.alphaValue = raised ? 1 : 0
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)
            window.contentView = Self.note(in: screen.frame.size)
            window.orderFrontRegardless()
            return window
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                              queue: .main) { _ in displaysChanged() }
        }
        return Set(windows.map { CGWindowID($0.windowNumber) })
    }

    func raise() {
        raised = true
        windows.forEach { $0.alphaValue = 1 }
    }

    func lower() {
        raised = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        close()
    }

    private func close() {
        windows.forEach { $0.close() }
        windows = []
    }

    /// A dim line at the bottom, so the Mac's owner coming back knows why the screen is black.
    private static func note(in size: CGSize) -> NSView {
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: "Passthrough is hiding this display while a phone views it. Close the phone's screen view to show it again.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(white: 1, alpha: 0.28)
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(x: (size.width - label.frame.width) / 2, y: 28))
        label.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        view.addSubview(label)
        return view
    }
}
#endif
