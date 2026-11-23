#if canImport(AppKit)
import AppKit
import PassthroughCore
import ScreenHost

/// Drops files at a point on this Mac's screen as if someone had dragged them
/// there: a tiny window of Passthrough's own starts a real drag-and-drop with
/// the files, and the pointer is moved to the point and let go, so whatever is
/// there (a Finder window, the desktop, Mail, Slack) takes them its own way.
/// Only copying is offered, so the files stay where they were put. Posting the
/// pointer's events takes Accessibility, as the screen's input does.
@MainActor
public final class DropPerformer: NSObject, NSDraggingSource {
    public enum Outcome: Sendable {
        case dropped
        /// The drag ended with nothing taking the files.
        case notTaken
        /// No answer in time: whatever is there may still be taking them, so they mustn't be moved.
        case timedOut
    }

    private var window: NSPanel?
    private var files: [URL] = []
    private var done: ((Outcome) -> Void)?
    private var timeout: DispatchWorkItem?
    /// Our window got the press (set on the main thread, read on the pointer's).
    fileprivate let pressed = Locked(false)
    /// One drop at a time: the pointer can only be in one place.
    private static var busy = false
    /// Holds the drop in progress (its window and view only point back weakly).
    private static var active: DropPerformer?
    private static var queued: [() -> Void] = []

    /// How far from the point the drag starts, in points.
    static let lead: CGFloat = 60
    static let limit: TimeInterval = 8

    /// Drops `files` at `point`, in global display coordinates (the top-left of
    /// the main display at 0, 0, as CoreGraphics' events use), then calls `done`.
    /// Only on `expected` (what was there when the drop was offered): checked again
    /// when its turn comes, as a drop may wait behind others.
    public static func drop(_ files: [URL], at point: CGPoint, expected: Target?, done: @escaping (Outcome) -> Void) {
        let run = { DropPerformer().start(files, at: point, expected: expected, done: done) }
        guard busy else { return run() }
        // A few may wait their turn; more aren't taken (so drops can't keep viewers' input held without end).
        guard queued.count < maxQueued else { return done(.notTaken) }
        queued.append(run)
    }

    static let maxQueued = 3

    /// The next waiting drop, once none is running.
    private static func next() {
        guard !busy, !queued.isEmpty else { return }
        queued.removeFirst()()
    }

    private func start(_ files: [URL], at point: CGPoint, expected: Target?, done: @escaping (Outcome) -> Void) {
        guard !files.isEmpty, CGPreflightPostEventAccess(), Self.target(at: point) == expected else {
            done(.notTaken)
            return Self.next()
        }
        Self.busy = true
        Self.active = self
        self.files = files
        self.done = done
        // Start beside the point, on the same display, so the drop target isn't under our window.
        let display = NSScreen.screens.first { Self.cgFrame($0).contains(point) } ?? NSScreen.main
        let bounds = display.map(Self.cgFrame) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        var start = CGPoint(x: point.x - Self.lead, y: point.y)
        if start.x < bounds.minX + 12 { start.x = point.x + Self.lead }
        start.x = min(max(start.x, bounds.minX + 12), bounds.maxX - 12)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let panel = NSPanel(contentRect: NSRect(x: start.x - 10, y: mainHeight - start.y - 10, width: 20, height: 20),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        // Not quite clear: a window takes no clicks where it's fully transparent, and then the press
        // would land on (and drag) whatever is under it.
        panel.backgroundColor = NSColor(white: 0.5, alpha: 0.02)
        panel.hasShadow = false
        // Over a full-screen app's space too, or the press would never find it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = SourceView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.performer = self
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel

        let timeout = DispatchWorkItem { [weak self] in
            // A drag still going after all this time (the button still down) is ended with Escape, so the next
            // pointer move doesn't carry the files on. Otherwise it's over: Escape would only answer whatever
            // the target is asking.
            if CGEventSource.buttonState(.combinedSessionState, button: .left) {
                for down in [true, false] {
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
                }
            }
            self?.finish(.timedOut)
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit, execute: timeout)
        // Viewers' own input is set aside while the pointer is ours (about half a second, until it's let go),
        // so a move or click of theirs doesn't end the drag elsewhere.
        ScreenInputHold.set(true)

        // The pointer's path, off the main thread: the drag runs on it meanwhile.
        let pressed = self.pressed
        let me = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) { [weak self] in
            func post(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            func end(_ outcome: Outcome) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(outcome) } }
            }
            // Someone's own drag or click on this Mac (a viewer's, through the screen) goes first: a press now
            // would do nothing, and the release after it would end their drag here. Up to 4 s, then not at all.
            var held = 0
            while Self.anyButtonDown(), held < 4000 { usleep(20_000); held += 20 }
            guard !Self.anyButtonDown() else { return end(.notTaken) }
            // Only press where our window is on top: otherwise the press would click whatever is there.
            guard Self.frontmostOwner(at: start) == me else { return end(.notTaken) }
            post(.mouseMoved, start); usleep(30_000)
            post(.leftMouseDown, start)
            // The press must have reached our window; if it somehow didn't, let go at once.
            var waited = 0
            while !pressed.get(), waited < 250 { usleep(10_000); waited += 10 }
            guard pressed.get() else {
                post(.leftMouseUp, start)
                return end(.notTaken)
            }
            usleep(40_000)
            let steps = 16
            for i in 1...steps {
                let f = CGFloat(i) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: start.x + (point.x - start.x) * f, y: point.y)); usleep(12_000)
            }
            // A moment over the target, as a hand would pause, so it accepts.
            post(.leftMouseDragged, point); usleep(120_000)
            post(.leftMouseUp, point)
            // Let go: viewers' input goes on at once, whatever the target takes to answer.
            DispatchQueue.main.async { ScreenInputHold.set(false) }
        }
    }

    /// Whether any mouse button is down on this Mac now, by anyone.
    nonisolated static func anyButtonDown() -> Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }

    /// The owner of the frontmost window at a point (Passthrough's own included).
    nonisolated static func frontmostOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point) else { continue }
            return info[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    fileprivate func begin(from view: NSView, event: NSEvent) {
        // A press that comes after the drop ended (it timed out) starts nothing.
        guard done != nil else { return }
        pressed.set(true)
        let items = files.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(view.bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finish(operation.isEmpty ? .notTaken : .dropped)
    }

    private func finish(_ outcome: Outcome) {
        guard let done else { return }
        self.done = nil
        timeout?.cancel()
        ScreenInputHold.set(false)
        window?.orderOut(nil)
        window = nil
        done(outcome)
        Self.busy = false
        Self.active = nil
        Self.next()
    }

    /// What's at a point on the screen: the frontmost window there (not Passthrough's own), by its
    /// number and owner; nil when it's the desktop.
    public struct Target: Equatable, Sendable {
        public let window: Int
        public let owner: pid_t
    }

    public static func target(at point: CGPoint) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let me = ProcessInfo.processInfo.processIdentifier
        // Front to back: the first that holds the point and can be seen.
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != me,
                  let number = info[kCGWindowNumber as String] as? Int,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point) else { continue }
            return Target(window: number, owner: owner)
        }
        return nil
    }

    /// A screen's frame in CoreGraphics' global coordinates (y down from the main display's top).
    static func cgFrame(_ screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    /// Files that couldn't be dropped go to Downloads (under a free name) and are shown there; `done`
    /// says whether any got there. `copy`: leave them where they are too (something may still be
    /// reading them). The moving or copying is done off the main thread: it can be gigabytes.
    public static func saveToDownloads(_ files: [URL], copy: Bool = false, done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let moved = save(files, copy: copy)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
                    done(!moved.isEmpty)
                }
            }
        }
    }

    nonisolated private static func save(_ files: [URL], copy: Bool) -> [URL] {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return [] }
        var moved: [URL] = []
        // Listed once: names taken there, and each one used here.
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path))?.map { $0.lowercased() } ?? [])
        for url in files {
            let name = ClipPayload.unique(url.lastPathComponent, in: &taken)
            let target = downloads.appendingPathComponent(name)
            do {
                if copy { try FileManager.default.copyItem(at: url, to: target) } else { try FileManager.default.moveItem(at: url, to: target) }
                moved.append(target)
            } catch {
                continue
            }
        }
        return moved
    }
}

private final class SourceView: NSView {
    weak var performer: DropPerformer?
    private var began = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !began, let performer else { return }
        began = true
        MainActor.assumeIsolated { performer.begin(from: self, event: event) }
    }
}
#endif
