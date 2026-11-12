#if os(macOS)
import AppKit
import CoreGraphics
import PassthroughCore
import ScreenCaptureKit

/// Black over every display while a phone views the screen and asked for it
/// (`ScreenCapturer.setCurtain`): whoever is at the Mac sees nothing of what
/// the phone is doing, and the streams, told to leave these windows out, show
/// the screen as it is under them. A window of one colour per display: it
/// costs next to nothing. It is a screen for the eyes only: clicks pass
/// through it (the phone's go to what is under it) and the Mac's own keyboard
/// and trackpad still work, so it is no substitute for the lock.
///
/// One for the Mac, shared by every stream: each one leaves all of its windows
/// out, also a stream that didn't ask for it (another phone's view), and it
/// stays up while any of them wants it. Its changes run one after another.
@MainActor
final class ScreenCurtain {
    static let shared = ScreenCurtain()

    /// A stream on this Mac.
    struct Viewer {
        /// Leave these windows (all the curtain's) out of the stream; false if it couldn't.
        /// A stream not started yet starts with them; one that is over has nothing to show.
        let exclude: @Sendable ([SCWindow]) async -> Bool
        /// The curtain came down without being asked: it couldn't be put up again after the displays changed.
        let fell: @Sendable () -> Void
    }

    /// How often a curtain's new windows are looked for in what ScreenCaptureKit lists.
    private static let lookups = 4

    private var viewers: [UUID: Viewer] = [:]
    private var wanting: Set<UUID> = []
    private var windows: [NSWindow] = []
    /// The windows as ScreenCaptureKit knows them, which every stream leaves out.
    private var excluded: [SCWindow] = []
    private var raised = false
    private var observer: NSObjectProtocol?
    private var work: Task<Void, Never>?

    private init() {}

    /// A stream starts: the windows it leaves out from its first frame.
    func join(_ id: UUID, _ viewer: Viewer) async -> [SCWindow] {
        await queued { self.viewers[id] = viewer; return self.excluded }
    }

    /// A stream ends: the curtain comes down unless another wants it.
    func leave(_ id: UUID) async {
        await queued {
            guard self.viewers.removeValue(forKey: id) != nil else { return }
            self.wanting.remove(id)
            if self.wanting.isEmpty { await self.lower(reset: self.raised) }
        }
    }

    /// The stream `id` wants it up (`hidden`) or no longer does. Whether it is
    /// up for that stream now: false once it doesn't want it, though another
    /// stream may still keep it up.
    func want(_ id: UUID, _ hidden: Bool) async -> Bool {
        await queued {
            guard self.viewers[id] != nil else { return false }   // that stream is over
            guard hidden else {
                self.wanting.remove(id)
                if self.wanting.isEmpty { await self.lower(reset: self.raised) }
                return false
            }
            if !self.raised {
                guard await self.put() else { return false }
            }
            self.wanting.insert(id)
            return true
        }
    }

    /// After whatever change is under way.
    private func queued<T>(_ body: @escaping @MainActor () async -> T) async -> T {
        let before = work
        let task = Task { @MainActor in
            await before?.value
            return await body()
        }
        work = Task { _ = await task.value }
        return await task.value
    }

    /// New windows over every display, see-through until every stream leaves
    /// them out, then black; windows already up (displays that changed) stay
    /// until then, so neither the phone nor the Mac sees the change. False, and
    /// down for everyone, if it couldn't.
    private func put() async -> Bool {
        let fresh = NSScreen.screens.map(Self.window)
        let numbers = Set(fresh.map { CGWindowID($0.windowNumber) })
        var found: [SCWindow] = []
        for attempt in 0..<Self.lookups where !numbers.isEmpty {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            found = content?.windows.filter { numbers.contains($0.windowID) } ?? []
            if found.count == numbers.count { break }
        }
        var left = !numbers.isEmpty && found.count == numbers.count
        if left {
            let both = excluded + found
            for viewer in viewers.values {
                if !(await viewer.exclude(both)) { left = false }
            }
        }
        guard left else {
            ptLog(.warning, "screen: couldn't leave the curtain out of the stream")
            fresh.forEach { $0.close() }
            let lost = wanting
            wanting = []
            await lower(reset: true)
            lost.forEach { viewers[$0]?.fell() }
            return false
        }
        fresh.forEach { $0.alphaValue = 1 }
        windows.forEach { $0.close() }
        windows = fresh
        excluded = found
        raised = true
        for viewer in viewers.values { _ = await viewer.exclude(found) }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                              queue: .main) { _ in
                Task { @MainActor in await ScreenCurtain.shared.displaysChanged() }
            }
        }
        return true
    }

    /// Displays came, went or changed size: windows over them as they are now.
    private func displaysChanged() async {
        await queued { if self.raised { _ = await self.put() } }
    }

    /// `reset`: the streams leave nothing out again (they were told to leave something out).
    private func lower(reset: Bool) async {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        windows.forEach { $0.close() }
        windows = []
        excluded = []
        raised = false
        guard reset else { return }
        for viewer in viewers.values { _ = await viewer.exclude([]) }
    }

    /// See-through until `put` makes it black.
    private static func window(over screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.contentView = note(in: screen.frame.size)
        window.orderFrontRegardless()
        return window
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
