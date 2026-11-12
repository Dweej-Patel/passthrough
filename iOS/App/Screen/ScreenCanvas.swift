import AVFoundation
import SwiftUI
import UIKit
import PassthroughCore
import PassthroughUI
import ScreenClient

/// How touches drive the Mac's pointer.
enum ScreenTouchMode: String, CaseIterable {
    /// Like a laptop's trackpad: drag moves the pointer, tap clicks where it is.
    case trackpad
    /// Tap where you want to click; drag pans a zoomed-in screen.
    case direct
}

/// The Mac's screen on the phone: pinch to zoom, and touches turned into
/// pointer events in screen pixels. Tap clicks, two-finger tap right-clicks,
/// two-finger drag scrolls, press-and-hold then drag drags, and three-finger
/// swipes move between desktops (left and right) or open Mission Control
/// (up) and the app's windows (down), as on a Mac's trackpad. It is also the
/// keyboard's text input while the keyboard is up.
final class ScreenCanvasView: UIView, UIScrollViewDelegate, UIKeyInput, UIGestureRecognizerDelegate {
    var onPointer: ((CGPoint, RFBClient.Buttons) -> Void)?
    var onClick: ((CGPoint, RFBClient.Buttons) -> Void)?
    /// Two fingers moved by a delta (screen pixels) with the pointer at a point; then the
    /// screen pixels a wheel notch is worth, for Screen Sharing.
    var onScroll: ((CGPoint, CGPoint, CGFloat) -> Void)?
    var onScrollEnded: (() -> Void)?
    /// The video display needs a keyframe to carry on (it was in the background).
    var onNeedsKeyframe: (() -> Void)?
    var onKey: ((UInt32, [UInt32]) -> Void)?
    var onText: ((String, [UInt32]) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSpace: ((ScreenModel.SpaceAction) -> Void)?

    var mode = ScreenTouchMode.trackpad {
        didSet { applyMode() }
    }

    private let scroll = UIScrollView()
    private let content = UIView()
    private let cursor = UIView()
    /// The Mac's own stream, decoded in hardware; Screen Sharing's frames are `content`'s image instead.
    private let video = AVSampleBufferDisplayLayer()
    private var screenSize = CGSize.zero
    /// Where the Mac's pointer is, in screen pixels.
    private var cursorPoint = CGPoint.zero
    private var lastDragLocation = CGPoint.zero
    private lazy var keyRow = ScreenKeyRow(canvas: self)
    /// Modifiers the key row holds for the next key.
    var heldModifiers: [UInt32] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.maximumNumberOfTouches = 1
        addSubview(scroll)
        scroll.addSubview(content)
        content.layer.magnificationFilter = .trilinear
        content.layer.minificationFilter = .trilinear
        video.videoGravity = .resize
        content.layer.addSublayer(video)
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.video.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
                self?.onNeedsKeyframe?()
            }
        }

        cursor.isUserInteractionEnabled = false
        cursor.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        cursor.layer.cornerRadius = 11
        cursor.layer.borderWidth = 2
        cursor.layer.borderColor = UIColor(PTTheme.accentStart).cgColor
        cursor.backgroundColor = UIColor(PTTheme.accentStart).withAlphaComponent(0.15)
        addSubview(cursor)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let move = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
        move.maximumNumberOfTouches = 1
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        wheel.delegate = self
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        move.require(toFail: hold)
        for recognizer in [tap, twoFingerTap, move, wheel, hold] { addGestureRecognizer(recognizer) }
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.numberOfTouchesRequired = 3
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
        self.move = move
        self.wheel = wheel
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    private weak var move: UIPanGestureRecognizer?
    private weak var wheel: UIPanGestureRecognizer?
    /// Where the fingers now down first touched, to tell a pinch from a two-finger scroll.
    private var touchStarts: [(touch: UITouch, start: CGPoint)] = []
    private var foregroundObserver: NSObjectProtocol?

    private func applyMode() {
        // Trackpad: one finger moves the pointer, and a zoomed view follows it.
        scroll.panGestureRecognizer.isEnabled = mode == .direct
        move?.isEnabled = mode == .trackpad
        cursor.isHidden = mode == .direct || screenSize == .zero
        updateCursor()
    }

    // MARK: Image and layout

    func show(_ image: CGImage?, size: CGSize) {
        if size != screenSize {
            let place = zoomedPlace()
            // The pointer keeps its place on a screen whose size in pixels changed (Screen Sharing to the stream).
            if screenSize.width > 0, size.width > 0 {
                cursorPoint = CGPoint(x: cursorPoint.x / screenSize.width * size.width, y: cursorPoint.y / screenSize.height * size.height)
            }
            screenSize = size
            if cursorPoint == .zero { cursorPoint = CGPoint(x: size.width / 2, y: size.height / 2) }
            layoutContent(keeping: place)
            applyMode()
        }
        content.layer.contents = image
    }

    /// One frame of the Mac's stream; false if the display couldn't take it (it needs a keyframe).
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let renderer = video.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        renderer.enqueue(sample)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroll.frame != bounds {
            let place = zoomedPlace()
            scroll.frame = bounds
            layoutContent(keeping: place)
        }
    }

    /// While zoomed in: how wide the whole screen is drawn (points) and which part
    /// of it is at the view's centre (0…1 across it), to come back to after the
    /// view changes shape. Nil at zoom 1.
    private func zoomedPlace() -> (width: CGFloat, centre: CGPoint)? {
        guard scroll.zoomScale > 1.01, screenSize.width > 0, content.bounds.width > 0, content.bounds.height > 0 else { return nil }
        let centre = content.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), from: scroll)
        return (content.frame.width,
                CGPoint(x: centre.x / content.bounds.width, y: centre.y / content.bounds.height))
    }

    /// Fits the screen to the view at zoom 1; zooming goes up to one Mac pixel per phone pixel (at least 3×).
    /// `place` (`zoomedPlace()`, from before the change): the zoom and the part in view are kept, so the
    /// keyboard coming up or the phone turning doesn't zoom back out.
    private func layoutContent(keeping place: (width: CGFloat, centre: CGPoint)? = nil) {
        guard screenSize.width > 0, bounds.width > 0 else { return }
        scroll.zoomScale = 1
        let fit = min(bounds.width / screenSize.width, bounds.height / screenSize.height)
        content.frame = CGRect(origin: .zero, size: CGSize(width: screenSize.width * fit, height: screenSize.height * fit))
        scroll.contentSize = content.frame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = content.bounds
        CATransaction.commit()
        let onePixel = 1 / (fit * max(window?.screen.scale ?? 3, 1))
        scroll.maximumZoomScale = max(3, onePixel)
        if let place {
            scroll.zoomScale = min(max(place.width / content.frame.width, 1), scroll.maximumZoomScale)
        }
        centerContent()
        if let place, scroll.zoomScale > 1 {
            let inset = scroll.contentInset
            let low = CGPoint(x: -inset.left, y: -inset.top)
            let high = CGPoint(x: max(low.x, scroll.contentSize.width - scroll.bounds.width + inset.right),
                               y: max(low.y, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
            scroll.contentOffset = CGPoint(x: (place.centre.x * scroll.contentSize.width - scroll.bounds.width / 2).clamped(low.x, high.x),
                                           y: (place.centre.y * scroll.contentSize.height - scroll.bounds.height / 2).clamped(low.y, high.y))
            // Trackpad: the pointer matters more than the centre (the keyboard just took half the view).
            if mode == .trackpad { follow() }
        }
        updateCursor()
    }

    private func centerContent() {
        let x = max(0, (scroll.bounds.width - content.frame.width) / 2)
        let y = max(0, (scroll.bounds.height - content.frame.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent(); updateCursor() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateCursor() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { bringPointerIntoView() }

    /// The part of the Mac's screen in view, in screen pixels.
    private var visibleScreen: CGRect {
        guard content.bounds.width > 0, content.bounds.height > 0 else { return .zero }
        let visible = content.convert(scroll.bounds, from: scroll).intersection(content.bounds)
        guard !visible.isNull else { return .zero }
        let x = screenSize.width / content.bounds.width, y = screenSize.height / content.bounds.height
        return CGRect(x: visible.minX * x, y: visible.minY * y, width: visible.width * x, height: visible.height * y)
    }

    /// Trackpad: a pinch can leave the pointer outside what's in view, where a tap would
    /// click unseen and the next drag would pull the view away to it. The pointer comes
    /// to the middle of what the pinch chose instead.
    private func bringPointerIntoView() {
        guard mode == .trackpad, screenSize.width > 0 else { return }
        let visible = visibleScreen
        guard visible.width > 1, visible.height > 1, !visible.contains(cursorPoint) else { return }
        cursorPoint = CGPoint(x: visible.midX.rounded(), y: visible.midY.rounded())
        onPointer?(cursorPoint, [])
        updateCursor()
    }

    /// Screen pixels for a point in this view.
    private func screenPoint(_ location: CGPoint) -> CGPoint {
        let local = content.convert(location, from: self)
        guard content.bounds.width > 0 else { return .zero }
        return CGPoint(x: (local.x / content.bounds.width * screenSize.width).clamped(0, screenSize.width - 1),
                       y: (local.y / content.bounds.height * screenSize.height).clamped(0, screenSize.height - 1))
    }

    /// This view's point for screen pixels.
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        guard screenSize.width > 0 else { return .zero }
        let local = CGPoint(x: point.x / screenSize.width * content.bounds.width, y: point.y / screenSize.height * content.bounds.height)
        return convert(local, from: content)
    }

    private func updateCursor() {
        cursor.center = viewPoint(cursorPoint)
    }

    /// Keeps the pointer in view while zoomed in.
    private func follow() {
        let point = content.convert(viewPoint(cursorPoint), from: self)
        let margin: CGFloat = 40 / scroll.zoomScale
        scroll.scrollRectToVisible(content.convert(CGRect(x: point.x - margin, y: point.y - margin, width: 2 * margin, height: 2 * margin),
                                                   to: scroll), animated: false)
    }

    // MARK: Touches

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if mode == .direct { cursorPoint = screenPoint(recognizer.location(in: self)); updateCursor() }
        onClick?(cursorPoint, .left)
    }

    @objc private func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
        if mode == .direct { cursorPoint = screenPoint(recognizer.location(in: self)); updateCursor() }
        onClick?(cursorPoint, .right)
    }

    /// Trackpad: the finger's travel moves the pointer, a little faster than 1:1.
    @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { bringPointerIntoView() }
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        movePointer(by: translation, buttons: [])
    }

    private func movePointer(by translation: CGPoint, buttons: RFBClient.Buttons) {
        guard content.frame.width > 0 else { return }
        let pixelsPerPoint = screenSize.width / content.frame.width
        let speed: CGFloat = 1.6
        cursorPoint = CGPoint(x: (cursorPoint.x + translation.x * pixelsPerPoint * speed).clamped(0, screenSize.width - 1),
                              y: (cursorPoint.y + translation.y * pixelsPerPoint * speed).clamped(0, screenSize.height - 1))
        onPointer?(cursorPoint, buttons)
        follow()
        updateCursor()
    }

    /// Press-and-hold, then drag: the left button stays down until the finger lifts.
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if mode == .direct { cursorPoint = screenPoint(location) }
            lastDragLocation = location
            onPointer?(cursorPoint, .left)
            updateCursor()
        case .changed:
            if mode == .direct {
                cursorPoint = screenPoint(location)
                onPointer?(cursorPoint, .left)
                updateCursor()
            } else {
                movePointer(by: CGPoint(x: location.x - lastDragLocation.x, y: location.y - lastDragLocation.y), buttons: .left)
            }
            lastDragLocation = location
        case .ended, .cancelled, .failed:
            onPointer?(cursorPoint, [])
        default:
            break
        }
    }

    // MARK: Pinch or scroll

    /// Remembers where each finger came down, for `gestureRecognizerShouldBegin`.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer === wheel {
            touchStarts.removeAll { $0.touch === touch || $0.touch.phase == .ended || $0.touch.phase == .cancelled }
            touchStarts.append((touch, touch.location(in: self)))
        }
        return true
    }

    /// Two fingers scroll the Mac or pinch to zoom, and whichever is recognized first
    /// ends the other. A pinch with one finger still moves the middle of the two, which
    /// used to start the scroll and lose the zoom: when the fingers have come apart or
    /// together by more than their middle has travelled, it is a pinch, and the scroll stands down.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === wheel else { return super.gestureRecognizerShouldBegin(recognizer) }
        let down = touchStarts.filter { $0.touch.phase != .ended && $0.touch.phase != .cancelled }
        guard down.count == 2 else { return true }
        let a = down[0].touch.location(in: self), b = down[1].touch.location(in: self)
        let spread = abs(hypot(a.x - b.x, a.y - b.y) - hypot(down[0].start.x - down[1].start.x, down[0].start.y - down[1].start.y))
        let travel = hypot((a.x + b.x - down[0].start.x - down[1].start.x) / 2, (a.y + b.y - down[0].start.y - down[1].start.y) / 2)
        return spread <= travel
    }

    /// Two fingers: the Mac's scroll, content following the fingers.
    @objc private func wheeled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            guard content.frame.width > 0 else { return }
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            let pixelsPerPoint = screenSize.width / content.frame.width
            let at = mode == .direct ? screenPoint(recognizer.location(in: self)) : cursorPoint
            // A notch per 16 of the phone's points, as before.
            onScroll?(at, CGPoint(x: translation.x * pixelsPerPoint, y: translation.y * pixelsPerPoint), 16 * pixelsPerPoint)
        case .ended, .cancelled, .failed:
            onScrollEnded?()
        default:
            break
        }
    }

    /// Three fingers, as on the Mac: swiping left brings in the desktop on the right.
    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        switch recognizer.direction {
        case .left: onSpace?(.nextDesktop)
        case .right: onSpace?(.previousDesktop)
        case .up: onSpace?(.missionControl)
        case .down: onSpace?(.appWindows)
        default: break
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    /// No three-finger undo, redo or copy while typing: those swipes are the Mac's.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var inputAccessoryView: UIView? { keyRow }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    func insertText(_ text: String) {
        onText?(text, takeModifiers())
    }

    func deleteBackward() {
        onKey?(RFBKeys.backspace, takeModifiers())
    }

    /// The held modifiers apply to one key, then let go (as the terminal's ctrl).
    func takeModifiers() -> [UInt32] {
        defer { heldModifiers = []; keyRow.update() }
        return heldModifiers
    }

    /// A hardware keyboard: shortcuts and keys the text path can't carry.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var modifiers: [UInt32] = []
            if key.modifierFlags.contains(.command) { modifiers.append(RFBKeys.command) }
            if key.modifierFlags.contains(.control) { modifiers.append(RFBKeys.control) }
            if key.modifierFlags.contains(.alternate) { modifiers.append(RFBKeys.option) }
            if key.modifierFlags.contains(.shift) { modifiers.append(RFBKeys.shift) }
            let special: [UIKeyboardHIDUsage: UInt32] = [
                .keyboardEscape: RFBKeys.escape, .keyboardLeftArrow: RFBKeys.left, .keyboardRightArrow: RFBKeys.right,
                .keyboardUpArrow: RFBKeys.up, .keyboardDownArrow: RFBKeys.down, .keyboardTab: RFBKeys.tab,
                .keyboardDeleteForward: RFBKeys.delete, .keyboardPageUp: RFBKeys.pageUp, .keyboardPageDown: RFBKeys.pageDown,
                .keyboardHome: RFBKeys.home, .keyboardEnd: RFBKeys.end,
            ]
            if let keysym = special[key.keyCode] {
                onKey?(keysym, modifiers)
                handled = true
            } else if modifiers.contains(where: { $0 != RFBKeys.shift }),
                      let character = key.charactersIgnoringModifiers.first, let keysym = RFBKeys.keysym(for: character) {
                onKey?(keysym, modifiers)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

private extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(Swift.max(self, low), Swift.max(low, high)) }
}

/// The keys above the keyboard: esc, tab, the modifiers (held for the next
/// key), arrows, copy and paste.
final class ScreenKeyRow: UIInputView {
    private weak var canvas: ScreenCanvasView?
    private var modifierButtons: [(UInt32, UIButton)] = []

    init(canvas: ScreenCanvasView) {
        self.canvas = canvas
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    private enum Key {
        case keysym(String, UInt32, accessibility: String)
        case symbol(String, UInt32, accessibility: String)
        case modifier(String, UInt32, accessibility: String)
        case copy
        case paste
    }

    private func build() {
        let keys: [Key] = [
            .keysym("esc", RFBKeys.escape, accessibility: "Escape"),
            .keysym("tab", RFBKeys.tab, accessibility: "Tab"),
            .modifier("⌃", RFBKeys.control, accessibility: "Control"),
            .modifier("⌥", RFBKeys.option, accessibility: "Option"),
            .modifier("⌘", RFBKeys.command, accessibility: "Command"),
            .symbol("arrow.left", RFBKeys.left, accessibility: "Left arrow"),
            .symbol("arrow.up", RFBKeys.up, accessibility: "Up arrow"),
            .symbol("arrow.down", RFBKeys.down, accessibility: "Down arrow"),
            .symbol("arrow.right", RFBKeys.right, accessibility: "Right arrow"),
            .copy,
            .paste,
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        for key in keys {
            let button = UIButton(configuration: Self.configuration(key, selected: false))
            switch key {
            case let .keysym(_, keysym, accessibility), let .symbol(_, keysym, accessibility):
                button.accessibilityLabel = accessibility
                button.addAction(UIAction { [weak self] _ in
                    UIDevice.current.playInputClick()
                    guard let canvas = self?.canvas else { return }
                    canvas.onKey?(keysym, canvas.takeModifiers())
                }, for: .touchUpInside)
            case let .modifier(_, keysym, accessibility):
                button.accessibilityLabel = accessibility
                modifierButtons.append((keysym, button))
                button.addAction(UIAction { [weak self] _ in
                    guard let canvas = self?.canvas else { return }
                    if let index = canvas.heldModifiers.firstIndex(of: keysym) {
                        canvas.heldModifiers.remove(at: index)
                    } else {
                        canvas.heldModifiers.append(keysym)
                    }
                    self?.update()
                }, for: .touchUpInside)
            case .copy:
                button.accessibilityLabel = "Copy from the Mac to this iPhone"
                button.addAction(UIAction { [weak self] _ in self?.canvas?.onCopy?() }, for: .touchUpInside)
            case .paste:
                button.accessibilityLabel = "Paste on the Mac"
                button.addAction(UIAction { [weak self] _ in self?.canvas?.onPaste?() }, for: .touchUpInside)
            }
            stack.addArrangedSubview(button)
        }
    }

    /// Shows which modifiers are held.
    func update() {
        let held = canvas?.heldModifiers ?? []
        for (keysym, button) in modifierButtons {
            guard let title = button.configuration?.title else { continue }
            button.configuration = Self.configuration(.modifier(title, keysym, accessibility: ""), selected: held.contains(keysym))
        }
    }

    private static func configuration(_ key: Key, selected: Bool) -> UIButton.Configuration {
        let tint = UIColor(PTTheme.accentEnd)
        var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = selected ? tint : tint.withAlphaComponent(0.14)
        config.baseForegroundColor = selected ? .white : tint
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        config.titleLineBreakMode = .byClipping
        func title(_ text: String) {
            config.title = text
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
                return attributes
            }
        }
        func symbol(_ name: String) {
            config.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        }
        switch key {
        case let .keysym(text, _, _), let .modifier(text, _, _): title(text)
        case let .symbol(name, _, _): symbol(name)
        case .copy: symbol("doc.on.doc")
        case .paste: symbol("doc.on.clipboard")
        }
        return config
    }
}

extension ScreenKeyRow: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// SwiftUI wrapper: feeds frames in, routes input to the model, and shows or
/// hides the keyboard.
struct ScreenCanvas: UIViewRepresentable {
    @ObservedObject var model: ScreenModel
    var mode: ScreenTouchMode
    @Binding var keyboard: Bool

    func makeUIView(context: Context) -> ScreenCanvasView {
        let view = ScreenCanvasView(frame: .zero)
        view.onPointer = { [weak model] point, buttons in model?.pointer(at: point, buttons: buttons) }
        view.onClick = { [weak model] point, button in model?.click(at: point, button: button) }
        view.onScroll = { [weak model] point, delta, notch in model?.scroll(at: point, by: delta, notch: notch) }
        view.onScrollEnded = { [weak model] in model?.scrollEnded() }
        view.onNeedsKeyframe = { [weak model] in model?.videoNeedsKeyframe() }
        model.onVideoFrame = { [weak view] sample in view?.enqueue(sample) ?? false }
        // A new display (first, or remade) can't use the frames in between: start it from a keyframe.
        model.videoNeedsKeyframe()
        view.onKey = { [weak model] keysym, modifiers in model?.key(keysym, modifiers: modifiers) }
        view.onText = { [weak model] text, modifiers in model?.type(text, modifiers: modifiers) }
        view.onPaste = { [weak model] in model?.pastePhoneClipboard() }
        view.onCopy = { [weak model] in model?.copyFromMac() }
        view.onSpace = { [weak model] action in model?.perform(action) }
        model.onFrame = { [weak view] image in view?.show(image, size: CGSize(width: image.width, height: image.height)) }
        return view
    }

    func updateUIView(_ view: ScreenCanvasView, context: Context) {
        view.show(model.image, size: model.screenSize)
        if view.mode != mode { view.mode = mode }
        guard keyboard != view.isFirstResponder else { return }
        // After this update, not inside it: changing the first responder makes SwiftUI read
        // its graph again (focus), and doing that mid-update hung the app in landscape.
        DispatchQueue.main.async { [keyboard] in
            if keyboard, !view.isFirstResponder {
                _ = view.becomeFirstResponder()
            } else if !keyboard, view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ view: ScreenCanvasView, coordinator: ()) {
        _ = view.resignFirstResponder()
    }
}
