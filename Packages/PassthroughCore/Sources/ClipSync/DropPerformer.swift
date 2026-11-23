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
    public static func drop(_ files: [URL], at point: CGPoint, done: @escaping (Outcome) -> Void) {
        let run = { DropPerformer().start(files, at: point, done: done) }
        if busy { queued.append(run) } else { run() }
    }

    private func start(_ files: [URL], at point: CGPoint, done: @escaping (Outcome) -> Void) {
        guard !files.isEmpty, CGPreflightPostEventAccess() else { return done(.notTaken) }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = SourceView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.performer = self
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel

        let timeout = DispatchWorkItem { [weak self] in self?.finish(.timedOut) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit, execute: timeout)
        // Viewers' own input waits meanwhile, so a move or click of theirs doesn't end the drag elsewhere.
        ScreenInputHold.set(true)

        // The pointer's path, off the main thread: the drag runs on it meanwhile.
        let pressed = self.pressed
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) {
            func post(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, start); usleep(30_000)
            post(.leftMouseDown, start)
            // The press must have reached our window. If it went to something else, let go where it was:
            // no drag, so nothing under it is moved.
            var waited = 0
            while !pressed.get(), waited < 250 { usleep(10_000); waited += 10 }
            guard pressed.get() else {
                post(.leftMouseUp, start)
                DispatchQueue.main.async { MainActor.assumeIsolated { DropPerformer.active?.finish(.notTaken) } }
                return
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
        }
    }

    fileprivate func begin(from view: NSView, event: NSEvent) {
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
        if !Self.queued.isEmpty { Self.queued.removeFirst()() }
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

    /// Files that couldn't be dropped go to Downloads (under a free name) and are shown there.
    /// `copy`: leave them where they are too (something may still be reading them).
    public static func saveToDownloads(_ files: [URL], copy: Bool = false) -> Bool {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return false }
        var moved: [URL] = []
        for url in files {
            var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path))?.map { $0.lowercased() } ?? [])
            let name = ClipPayload.unique(url.lastPathComponent, in: &taken)
            let target = downloads.appendingPathComponent(name)
            do {
                if copy { try FileManager.default.copyItem(at: url, to: target) } else { try FileManager.default.moveItem(at: url, to: target) }
                moved.append(target)
            } catch {
                continue
            }
        }
        guard !moved.isEmpty else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(moved)
        return true
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
