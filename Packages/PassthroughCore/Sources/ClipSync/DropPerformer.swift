#if canImport(AppKit)
import AppKit

/// Drops files at a point on this Mac's screen as if someone had dragged them
/// there: a tiny window of Passthrough's own starts a real drag-and-drop with
/// the files, and the pointer is moved to the point and let go, so whatever is
/// there (a Finder window, the desktop, Mail, Slack) takes them its own way.
/// Only copying is offered, so the files stay where they were put. Posting the
/// pointer's events takes Accessibility, as the screen's input does.
@MainActor
public final class DropPerformer: NSObject, NSDraggingSource {
    public enum Outcome: Sendable { case dropped, notTaken }

    private var window: NSPanel?
    private var files: [URL] = []
    private var done: ((Outcome) -> Void)?
    private var timeout: DispatchWorkItem?
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
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = SourceView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.performer = self
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel

        let timeout = DispatchWorkItem { [weak self] in self?.finish(.notTaken) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit, execute: timeout)

        // The pointer's path, off the main thread: the drag runs on it meanwhile.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) {
            func post(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, start); usleep(30_000)
            post(.leftMouseDown, start); usleep(60_000)
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
        window?.orderOut(nil)
        window = nil
        done(outcome)
        Self.busy = false
        Self.active = nil
        if !Self.queued.isEmpty { Self.queued.removeFirst()() }
    }

    /// A screen's frame in CoreGraphics' global coordinates (y down from the main display's top).
    static func cgFrame(_ screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    /// Files that couldn't be dropped go to Downloads (under a free name) and are shown there.
    public static func saveToDownloads(_ files: [URL]) -> Bool {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return false }
        var moved: [URL] = []
        for url in files {
            var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path))?.map { $0.lowercased() } ?? [])
            let name = ClipPayload.unique(url.lastPathComponent, in: &taken)
            let target = downloads.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: url, to: target)
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
