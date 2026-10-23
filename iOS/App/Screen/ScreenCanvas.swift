import SwiftUI
import UIKit
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
/// two-finger drag scrolls, press-and-hold then drag drags. It is also the
/// keyboard's text input while the keyboard is up.
final class ScreenCanvasView: UIView, UIScrollViewDelegate, UIKeyInput {
    var onPointer: ((CGPoint, RFBClient.Buttons) -> Void)?
    var onClick: ((CGPoint, RFBClient.Buttons) -> Void)?
    /// Wheel notches: negative up, positive down.
    var onScroll: ((CGPoint, Int) -> Void)?
    var onKey: ((UInt32, [UInt32]) -> Void)?
    var onText: ((String, [UInt32]) -> Void)?
    var onPaste: (() -> Void)?

    var mode = ScreenTouchMode.trackpad {
        didSet { applyMode() }
    }

    private let scroll = UIScrollView()
    private let content = UIView()
    private let cursor = UIView()
    private var screenSize = CGSize.zero
    /// Where the Mac's pointer is, in screen pixels.
    private var cursorPoint = CGPoint.zero
    private var lastDragLocation = CGPoint.zero
    private var wheelRemainder: CGFloat = 0
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
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        move.require(toFail: hold)
        for recognizer in [tap, twoFingerTap, move, wheel, hold] { addGestureRecognizer(recognizer) }
        self.move = move
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private weak var move: UIPanGestureRecognizer?

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
            screenSize = size
            if cursorPoint == .zero { cursorPoint = CGPoint(x: size.width / 2, y: size.height / 2) }
            layoutContent()
            applyMode()
        }
        content.layer.contents = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroll.frame != bounds {
            scroll.frame = bounds
            layoutContent()
        }
    }

    /// Fits the screen to the view at zoom 1; zooming goes up to one Mac pixel per phone pixel (at least 3×).
    private func layoutContent() {
        guard screenSize.width > 0, bounds.width > 0 else { return }
        scroll.zoomScale = 1
        let fit = min(bounds.width / screenSize.width, bounds.height / screenSize.height)
        content.frame = CGRect(origin: .zero, size: CGSize(width: screenSize.width * fit, height: screenSize.height * fit))
        scroll.contentSize = content.frame.size
        let onePixel = 1 / (fit * max(window?.screen.scale ?? 3, 1))
        scroll.maximumZoomScale = max(3, onePixel)
        centerContent()
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

    /// Two fingers: the Mac's scroll wheel, content following the fingers.
    @objc private func wheeled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            wheelRemainder = 0
        case .changed:
            wheelRemainder += recognizer.translation(in: self).y
            recognizer.setTranslation(.zero, in: self)
            let step: CGFloat = 16
            let notches = Int(wheelRemainder / step)
            guard notches != 0 else { return }
            wheelRemainder -= CGFloat(notches) * step
            let at = mode == .direct ? screenPoint(recognizer.location(in: self)) : cursorPoint
            onScroll?(at, -notches)
        default:
            break
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
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
/// key), arrows and paste.
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
        view.onScroll = { [weak model] point, notches in model?.scroll(at: point, steps: notches) }
        view.onKey = { [weak model] keysym, modifiers in model?.key(keysym, modifiers: modifiers) }
        view.onText = { [weak model] text, modifiers in model?.type(text, modifiers: modifiers) }
        view.onPaste = { [weak model] in model?.pastePhoneClipboard() }
        return view
    }

    func updateUIView(_ view: ScreenCanvasView, context: Context) {
        view.show(model.image, size: model.screenSize)
        if view.mode != mode { view.mode = mode }
        if keyboard, !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        } else if !keyboard, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: ScreenCanvasView, coordinator: ()) {
        _ = view.resignFirstResponder()
    }
}
