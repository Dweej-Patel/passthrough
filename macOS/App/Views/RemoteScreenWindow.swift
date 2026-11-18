import AppKit
import AVFoundation
import CoreMedia
import Network
import SwiftUI
import IrohTransport
import LocalAuthentication
import PassthroughCore
import ScreenClient
import ShellHost

/// Another Mac's screen, seen and controlled from this one with a pass a
/// phone handed over (`ScreenPass`): the same stream the phone gets, through
/// the other Mac's remote shell, on its local network or over iroh from anywhere.
struct RemoteScreenWindow: View {
    static let id = "remote-screen"

    let macID: String
    @EnvironmentObject private var shell: RemoteShellController
    @StateObject private var model = RemoteScreenModel()
    /// Confirmed with Touch ID or this Mac's password, once per window: whoever
    /// is at this Mac can't take over the other one with a click.
    @State private var unlocked = false
    @State private var unlocking = false
    /// The window is open: a confirmation that comes back after it closed connects nothing.
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black
            RemoteScreenCanvas(model: model, live: model.phase == .live)
                .opacity(model.phase == .live ? 1 : 0)
            switch model.phase {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to \(model.macName)…").foregroundStyle(.secondary)
                }
            case .live:
                EmptyView()
            case let .failed(message):
                VStack(spacing: 14) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                    if model.canRetry {
                        Button("Try Again") { start() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(model.macName)
        .navigationSubtitle(model.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.sendClipboard() } label: { Label("Send Clipboard", systemImage: "doc.on.clipboard") }
                    .help("Put this Mac's clipboard text on \(model.macName)'s clipboard")
                    .disabled(model.phase != .live)
                Button { model.copyFromMac() } label: { Label("Copy from Mac", systemImage: "square.and.arrow.down.on.square") }
                    .help("Press ⌘C on \(model.macName) and put what it copied on this Mac's clipboard")
                    .disabled(model.phase != .live)
            }
        }
        .onAppear {
            shown = true
            start()
            NSApp.activate()
        }
        .onDisappear {
            shown = false
            model.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .passthroughScreenPassChanged)) { note in
            guard note.userInfo?["macID"] as? String == macID else { return }
            if shell.passStore.pass(for: macID) != nil {
                start()   // replaced: see it with the new pass
            } else {
                model.stop()
                model.end("This Mac no longer has a pass to \(model.macName)'s screen. Share it again from your phone.")
            }
        }
    }

    private func start() {
        guard let pass = shell.passStore.pass(for: macID) else {
            model.end("This Mac no longer has a pass to that screen. Share it again from your phone.")
            return
        }
        guard unlocked else { return unlock(pass) }
        model.start(pass)
    }

    private func unlock(_ pass: ReceivedScreenPass) {
        guard !unlocking else { return }
        unlocking = true
        model.locked(pass.macName)
        Task { @MainActor in
            // Shown as "Passthrough is trying to …".
            let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: "see and control \(pass.macName)'s screen")) ?? false
            unlocking = false
            guard ok, shown else { return }
            unlocked = true
            start()
        }
    }
}

// MARK: - Model

@MainActor
final class RemoteScreenModel: ObservableObject {
    enum Phase: Equatable {
        case connecting, live
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    /// False when there is nothing to try again with (the pass is gone).
    @Published private(set) var canRetry = true
    @Published private(set) var macName = "Screen"
    @Published private(set) var subtitle = ""
    /// The stream's size in pixels, once known.
    @Published private(set) var streamSize: CGSize = .zero
    /// The other Mac's pointer: its shape, size in stream pixels and tip.
    private(set) var cursor: (image: CGImage, size: CGSize, hotSpot: CGPoint)?
    /// Where the other Mac says its pointer is (0…1 across the stream), and whether it's on the streamed display.
    private(set) var remotePointer: (x: Double, y: Double, visible: Bool)?
    /// Set by the canvas: shows a frame, false when its display failed.
    var onFrame: ((CMSampleBuffer) -> Bool)?
    var onCursorChange: (() -> Void)?

    private var client: ShellClient?
    private var dialer: IrohShellDialer?
    private var video: ScreenVideoClient?
    private var browser: NWBrowser?
    private var generation = 0
    private var path: ShellPath?
    private var buttons: RFBClient.Buttons = []
    private var scrollRemainder = CGPoint.zero
    /// Someone can see the window; kept across reconnects.
    private var visible = true
    private var layout = RemoteScreenModel.fullLayout(visible: true)

    /// How long to look for the other Mac on the local network before dialing without it.
    static let browseTime: TimeInterval = 0.8

    func start(_ pass: ReceivedScreenPass) {
        stop()
        generation += 1
        let gen = generation
        macName = pass.macName
        subtitle = ""
        canRetry = true
        phase = .connecting
        cursor = nil
        remotePointer = nil
        layout = Self.fullLayout(visible: visible)
        // The addresses in the pass are the ones the phone knew when it shared: find
        // the Mac by name on this network too, as the phone does, in case they changed.
        let browser = NWBrowser(for: .bonjour(type: RemoteShell.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // By name only (no count of Macs): never this Mac's own listener.
            guard let found = ShellCredentials.discovered(among: results.map(\.endpoint), macName: pass.macName, shellMacCount: 0) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dial(pass, discovered: found, generation: gen) } }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.browseTime) { [weak self] in
            self?.dial(pass, discovered: nil, generation: gen)
        }
    }

    /// Dials once per start: with the Bonjour result if it came first.
    private func dial(_ pass: ReceivedScreenPass, discovered: NWEndpoint?, generation gen: Int) {
        guard gen == generation, client == nil, video == nil else { return }
        browser?.cancel()
        browser = nil
        let credential = pass.credential
        let dialer = credential.irohID.map(IrohInfo.isValidID) == true ? IrohShellDialer() : nil
        self.dialer = dialer
        let client = ShellClient(credential: credential, queue: .main, iroh: dialer, mode: .automatic) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, generation: gen) }
        }
        self.client = client
        client.connect(discovered: discovered)
    }

    func stop() {
        generation += 1
        browser?.cancel()
        browser = nil
        client?.disconnect()
        client = nil
        video?.close()
        video = nil
        dialer?.shutdown()
        dialer = nil
        buttons = []
    }

    /// Waiting for Touch ID or the password before connecting to `macName`.
    func locked(_ name: String) {
        stop()
        macName = name
        subtitle = ""
        canRetry = true
        phase = .failed("Confirm it's you to see and control \(name)'s screen.")
    }

    /// Stops for good with `message`: nothing to try again with.
    func end(_ message: String) {
        stop()
        canRetry = false
        phase = .failed(message)
    }

    private func handle(_ event: ShellClient.Event, generation gen: Int) {
        guard gen == generation else {
            if case let .screen(stream, _) = event { stream.cancel() }
            return
        }
        switch event {
        case let .ready(path):
            self.path = path
            client?.requestScreen(video: true)
        case let .screen(stream, initialBytes):
            client = nil   // it let go of the stream; the dialer stays up for it
            let video = ScreenVideoClient(stream: stream, initialBytes: initialBytes, layout: layout) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
            self.video = video
            video.start()
        case let .failed(error, _):
            fail(Self.message(for: error, macName: macName))
        case .disconnected:
            fail("Couldn't reach \(macName). Check that it's awake and its Remote Shell is on.")
        default:
            break
        }
    }

    private func handle(_ event: ScreenVideoClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case let .size(width, height):
            streamSize = CGSize(width: width, height: height)
            phase = .live
            subtitle = switch path {
            case .relay?: "through a relay"
            case .direct?: "direct"
            case .local?: "local network"
            default: ""
            }
        case let .frame(sample, number):
            if onFrame?(sample) != true { video?.requestKeyframe() }
            video?.shown(number)
        case let .cursorShape(image, size, hotSpot):
            cursor = (image, size, hotSpot)
            onCursorChange?()
        case let .cursor(x, y, visible):
            remotePointer = (x, y, visible)
            onCursorChange?()
        case let .copied(result):
            switch result {
            case let .text(text) where !text.isEmpty:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            default:
                NSSound.beep()
            }
        case let .movedAway(name):
            fail("\(name) took over this view of \(macName)'s screen.")
        case let .closed(error):
            if error != nil { fail("The connection to \(macName) ended.") }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    /// The other Mac's own display at no more than this Mac's largest screen's
    /// pixels; as few frames as it sends (15 a second) while nobody can see the window.
    private static func fullLayout(visible: Bool) -> ScreenVideoClient.Layout {
        let largest = NSScreen.screens.map { $0.frame.size.width * $0.backingScaleFactor }.max() ?? 2560
        let side = Int(min(max(largest, 1280), 4096))
        return .init(width: side, height: side, fit: .mac, fps: visible ? 60 : 15, quality: .sharp)
    }

    /// Whether anyone can see the window (not minimized, hidden or covered).
    func setVisible(_ visible: Bool) {
        self.visible = visible
        let fps = visible ? 60 : 15
        guard layout.fps != fps else { return }
        layout.fps = fps
        video?.relayout(layout)
    }

    static func message(for error: ShellError, macName: String) -> String {
        switch error {
        case .notAuthorized, .screenNotAllowed:
            "\(macName) no longer accepts this pass. Share its screen with this Mac again from your phone."
        case .screenVideoUnavailable, .screenUnavailable:
            "\(macName) can't stream its screen yet. On \(macName), allow Passthrough Screen Recording and Accessibility in its Remote Shell settings."
        case .tooManyScreens:
            "\(macName) is already showing its screen as often as it allows. Close another view of it first."
        default:
            "\(macName) refused the connection (\(error.rawValue))."
        }
    }

    // MARK: Input

    /// The pointer at (`x`, `y`), each 0…1 across the stream.
    func pointer(x: Double, y: Double) {
        video?.pointer(x: x, y: y, buttons: buttons)
    }

    func button(_ button: RFBClient.Buttons, down: Bool, x: Double, y: Double) {
        if down { buttons.insert(button) } else { buttons.remove(button) }
        pointer(x: x, y: y)
    }

    var buttonsHeld: Bool { !buttons.isEmpty }

    /// Scrolls by (`dx`, `dy`) stream pixels; positive `dy` brings earlier content into view.
    func scroll(dx: CGFloat, dy: CGFloat) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let x = Int(scrollRemainder.x), y = Int(scrollRemainder.y)
        scrollRemainder.x -= CGFloat(x)
        scrollRemainder.y -= CGFloat(y)
        video?.scroll(dx: x, dy: y)
    }

    func scrollEnded() { scrollRemainder = .zero }

    func key(_ keysym: UInt32, modifiers: ScreenVideoWire.Modifiers) { video?.key(keysym, modifiers: modifiers) }
    func text(_ text: String) { video?.text(text) }

    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        video?.gesture(gesture, phase: phase, value: value)
    }

    func sendClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        if video?.clipboard(text) != true { NSSound.beep() }
    }

    func copyFromMac() { video?.copySelection() }
}

// MARK: - Canvas

private struct RemoteScreenCanvas: NSViewRepresentable {
    let model: RemoteScreenModel
    /// A value of its own, so SwiftUI updates the view when the stream goes live or stops.
    let live: Bool

    func makeNSView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(model: model)
        model.onFrame = { [weak view] sample in view?.enqueue(sample) ?? false }
        model.onCursorChange = { [weak view] in view?.updateCursor() }
        return view
    }

    func updateNSView(_ view: RemoteScreenView, context: Context) {
        view.needsLayout = true
        view.liveChanged()
    }
}

/// Shows the stream, aspect-fitted, draws the other Mac's pointer (where this
/// Mac's is while it's over the picture, hiding this one's; where the other
/// Mac says otherwise), and sends the mouse, trackpad and keyboard over.
/// Typing goes through macOS text input, so input methods and dead keys
/// compose here and only finished text is sent.
final class RemoteScreenView: NSView, NSTextInputClient {
    private let model: RemoteScreenModel
    private let video = AVSampleBufferDisplayLayer()
    private let pointer = CALayer()
    private var tracking: NSTrackingArea?
    /// This Mac's pointer over the picture, in view points (nil: elsewhere).
    private var mouse: CGPoint?
    /// Text an input method is composing (not sent until it's committed), and
    /// its selection within it, as the input method last set them.
    private var marked = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var occlusionObserver: NSObjectProtocol?
    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(model: RemoteScreenModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        layer?.addSublayer(video)
        pointer.zPosition = 1
        pointer.isHidden = true
        pointer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(pointer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    private var isLive: Bool { model.phase == .live }

    override var acceptsFirstResponder: Bool { isLive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        model.setVisible(window.occlusionState.contains(.visible))
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.model.setVisible(window.occlusionState.contains(.visible))
            }
        }
    }

    /// The picture took or lost the keyboard: it has it only while live, so
    /// otherwise ⌘W, Return (Try Again) and the rest work as usual.
    func liveChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if self.isLive {
                if window.firstResponder !== self { window.makeFirstResponder(self) }
            } else if window.firstResponder === self {
                self.discardComposition()
                window.makeFirstResponder(nil)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
        updateCursor()
    }

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let renderer = video.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        renderer.enqueue(sample)
        return true
    }

    /// Where the picture is in the view: the stream aspect-fitted.
    private var pictureRect: CGRect {
        let size = model.streamSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// A point in the view as 0…1 across the stream (top left first), clamped.
    private func streamPoint(_ point: CGPoint) -> (x: Double, y: Double) {
        let rect = pictureRect
        let x = (point.x - rect.minX) / max(rect.width, 1)
        let y = 1 - (point.y - rect.minY) / max(rect.height, 1)   // AppKit counts up from the bottom
        return (Double(min(max(x, 0), 1)), Double(min(max(y, 0), 1)))
    }

    // MARK: Pointer

    func updateCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = pictureRect
        guard let cursor = model.cursor, model.streamSize.width > 0, model.remotePointer?.visible != false else {
            pointer.isHidden = true
            return
        }
        // Where this Mac's pointer is while it's over the picture (it leads the
        // echo); otherwise where the other Mac says its pointer is (someone there is using it).
        let tip: CGPoint
        if let mouse, rect.contains(mouse) {
            tip = mouse
        } else if let remote = model.remotePointer {
            tip = CGPoint(x: rect.minX + remote.x * rect.width, y: rect.maxY - remote.y * rect.height)
        } else {
            pointer.isHidden = true
            return
        }
        let scale = rect.width / model.streamSize.width
        let size = CGSize(width: cursor.size.width * scale, height: cursor.size.height * scale)
        pointer.contents = cursor.image
        pointer.bounds = CGRect(origin: .zero, size: size)
        pointer.anchorPoint = .zero
        // The tip at the point; the shape's y runs down from its top.
        pointer.position = CGPoint(x: tip.x - cursor.hotSpot.x * scale, y: tip.y - (size.height - cursor.hotSpot.y * scale))
        pointer.isHidden = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func setLocalCursor(at point: CGPoint?) {
        if isLive, model.cursor != nil, let point, pictureRect.contains(point) { Self.invisibleCursor.set() } else { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        setLocalCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        updateCursor()
        NSCursor.arrow.set()
    }

    private func moved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        updateCursor()
        setLocalCursor(at: point)
        // Off the picture (the black bars) the pointer stays put, unless a drag is under way.
        guard pictureRect.contains(point) || model.buttonsHeld else { return }
        let p = streamPoint(point)
        model.pointer(x: p.x, y: p.y)
    }

    private func pressed(_ event: NSEvent, _ button: RFBClient.Buttons, down: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        // A click in the black bars isn't a click on the Mac's screen edge.
        if down {
            guard isLive, pictureRect.contains(point) else { return }
            window?.makeFirstResponder(self)
        }
        mouse = point
        let p = streamPoint(point)
        model.button(button, down: down, x: p.x, y: p.y)
    }

    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }
    override func mouseDown(with event: NSEvent) {
        // Control-click is a right click, as on the Mac itself.
        pressed(event, event.modifierFlags.contains(.control) ? .right : .left, down: true)
    }
    override func mouseUp(with event: NSEvent) {
        pressed(event, .left, down: false)
        pressed(event, .right, down: false)
    }
    override func rightMouseDown(with event: NSEvent) { pressed(event, .right, down: true) }
    override func rightMouseUp(with event: NSEvent) { pressed(event, .right, down: false) }
    override func otherMouseDown(with event: NSEvent) { pressed(event, .middle, down: true) }
    override func otherMouseUp(with event: NSEvent) { pressed(event, .middle, down: false) }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isLive, pictureRect.contains(point) else { return }
        let p = streamPoint(point)
        model.pointer(x: p.x, y: p.y)
        // This Mac's points to the stream's pixels; a mouse wheel's lines to about ten points each.
        let perPoint = model.streamSize.width > 0 ? model.streamSize.width / max(pictureRect.width, 1) : 1
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        model.scroll(dx: event.scrollingDeltaX * lines * perPoint, dy: event.scrollingDeltaY * lines * perPoint)
        if event.phase == .ended || event.momentumPhase == .ended { model.scrollEnded() }
    }

    override func magnify(with event: NSEvent) {
        guard isLive, let phase = Self.phase(event.phase) else { return }
        model.gesture(.magnify, phase: phase, value: phase == .changed ? Double(event.magnification) : 0)
    }

    override func rotate(with event: NSEvent) {
        guard isLive, let phase = Self.phase(event.phase) else { return }
        model.gesture(.rotate, phase: phase, value: phase == .changed ? Double(event.rotation) : 0)
    }

    private static func phase(_ phase: NSEvent.Phase) -> ScreenVideoWire.GesturePhase? {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return nil
    }

    // MARK: Keyboard

    /// Shortcuts go to the other Mac, not this app's menus, while the picture is live and has the keyboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isLive, window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isLive else { return super.keyDown(with: event) }
        let modifiers = RemoteKeys.modifiers(event.modifierFlags)
        // An input method composing takes every key, Return and arrows included.
        if !hasMarkedText() {
            if let keysym = RemoteKeys.special[event.keyCode] {
                return model.key(keysym, modifiers: modifiers)
            }
            if modifiers.contains(.command) || modifiers.contains(.control) {
                // A shortcut: the key as it is without modifiers, with them held.
                guard let character = event.charactersIgnoringModifiers?.lowercased().first,
                      let keysym = RFBKeys.keysym(for: character) else { return }
                return model.key(keysym, modifiers: modifiers)
            }
        }
        // Text: through macOS text input, so input methods and dead keys compose here first.
        inputContext?.handleEvent(event)
    }

    // MARK: NSTextInputClient

    /// Committed text goes to the other Mac. Nothing here is a document, so
    /// `replacementRange` can only name the composition, which this replaces anyway.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        if !text.isEmpty { model.text(text) }
    }

    /// A key the text system turned into a command, not text: send its key.
    override func doCommand(by selector: Selector) {
        let keys: [Selector: UInt32] = [
            #selector(insertNewline(_:)): RFBKeys.returnKey, #selector(insertTab(_:)): RFBKeys.tab,
            #selector(deleteBackward(_:)): RFBKeys.backspace, #selector(cancelOperation(_:)): RFBKeys.escape,
        ]
        if let keysym = keys[selector] { model.key(keysym, modifiers: []) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            marked = NSMutableAttributedString(attributedString: attributed)
        } else {
            marked = NSMutableAttributedString(string: string as? String ?? "")
        }
        // Within the composition, as the input method says (clamped to it).
        let location = min(max(selectedRange.location == NSNotFound ? marked.length : selectedRange.location, 0), marked.length)
        markedSelection = NSRange(location: location, length: min(selectedRange.length, marked.length - location))
    }

    /// The input method accepts the composition as it stands: it's typed, as committed text is.
    func unmarkText() {
        let text = marked.string
        marked = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        if !text.isEmpty { model.text(text) }
    }

    /// Drops a composition without typing it (the view lost the keyboard).
    private func discardComposition() {
        guard hasMarkedText() else { return }
        marked = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        inputContext?.discardMarkedText()
    }

    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range
        return marked.attributedSubstring(from: range)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The input method's candidate window goes by the pointer on the picture (where the remote caret likely is).
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let anchor = mouse ?? CGPoint(x: pictureRect.midX, y: pictureRect.midY)
        let rect = NSRect(x: anchor.x, y: anchor.y - 20, width: 1, height: 20)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

/// macOS key codes for keys that aren't text, as X keysyms.
enum RemoteKeys {
    static let special: [UInt16: UInt32] = {
        var keys: [UInt16: UInt32] = [
            36: RFBKeys.returnKey, 76: RFBKeys.returnKey, 48: RFBKeys.tab, 51: RFBKeys.backspace, 117: RFBKeys.delete,
            53: RFBKeys.escape, 123: RFBKeys.left, 124: RFBKeys.right, 125: RFBKeys.down, 126: RFBKeys.up,
            115: RFBKeys.home, 119: RFBKeys.end, 116: RFBKeys.pageUp, 121: RFBKeys.pageDown,
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { keys[code] = RFBKeys.function(index + 1) }
        return keys
    }()

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ScreenVideoWire.Modifiers {
        var mask: ScreenVideoWire.Modifiers = []
        if flags.contains(.command) { mask.insert(.command) }
        if flags.contains(.shift) { mask.insert(.shift) }
        if flags.contains(.option) { mask.insert(.option) }
        if flags.contains(.control) { mask.insert(.control) }
        return mask
    }
}
