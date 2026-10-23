import SwiftUI
import UIKit
import SwiftTerm
import PassthroughUI

/// The terminal's colors and type, matched to the rest of the app.
enum TerminalStyle {
    /// `PTBackground`'s dark base.
    static let background = UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    static let foreground = UIColor(white: 0.9, alpha: 1)
    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}

/// Owns one SwiftTerm `TerminalView` and relays its input and size changes.
/// Nothing here logs what passes through it.
@MainActor
final class TerminalDriver: NSObject, ObservableObject, TerminalViewDelegate {
    let view: ShellTerminalView
    /// Bytes the user typed (keyboard or key row).
    var onInput: ((Data) -> Void)?
    /// The terminal's grid changed after its first layout.
    var onResize: ((Int, Int) -> Void)?
    /// Output being fed is a replay: the terminal's answers to queries in it
    /// (device attributes, cursor position, colors…) and clipboard writes are dropped.
    var replaying = false
    private var feeding = false
    private var laidOut = false
    private var whenLaidOut: [(Int, Int) -> Void] = []

    init(readOnly: Bool, scrollback: Int) {
        var options = TerminalOptions.default
        options.scrollback = scrollback
        view = ShellTerminalView(frame: .zero, font: TerminalStyle.font, options: options)
        super.init()
        view.readOnly = readOnly
        view.terminalDelegate = self
        view.backgroundColor = TerminalStyle.background
        view.layer.backgroundColor = TerminalStyle.background.cgColor
        view.nativeBackgroundColor = TerminalStyle.background
        view.nativeForegroundColor = TerminalStyle.foreground
        view.caretColor = UIColor(PTTheme.accentStart)
        view.selectedTextBackgroundColor = UIColor(PTTheme.accentEnd).withAlphaComponent(0.4)
        view.keyboardAppearance = .dark
        view.contentInsetAdjustmentBehavior = .never
        if readOnly {
            view.inputAccessoryView = nil
        } else {
            view.inputAccessoryView = TerminalKeyRow(terminal: view)
        }
        view.onFirstLayout = { [weak self] cols, rows in
            guard let self else { return }
            self.laidOut = true
            let pending = self.whenLaidOut
            self.whenLaidOut = []
            pending.forEach { $0(cols, rows) }
        }
    }

    /// Whether the terminal takes input; switchable, e.g. once its session ends.
    var readOnly: Bool { view.readOnly }

    /// Turns input on or off. Read-only drops the keyboard (it can't come back),
    /// the key row and the cursor, and ignores input; the output stays
    /// scrollable. Editable brings them back and takes the keyboard.
    func setReadOnly(_ readOnly: Bool) {
        guard readOnly != view.readOnly else { return }
        if readOnly {
            view.readOnly = true
            _ = view.resignFirstResponder()
            view.inputAccessoryView = nil
            view.controlModifier = false
            // SwiftTerm doesn't expose its caret view; a clear caret draws nothing.
            view.caretColor = .clear
        } else {
            view.readOnly = false
            view.inputAccessoryView = TerminalKeyRow(terminal: view)
            view.caretColor = UIColor(PTTheme.accentStart)
            _ = view.becomeFirstResponder()
        }
    }

    var cols: Int { view.getTerminal().cols }
    var rows: Int { view.getTerminal().rows }

    /// Runs `body` with the grid size once the view has its real size (now, if it has).
    func afterLayout(_ body: @escaping (Int, Int) -> Void) {
        if laidOut { body(cols, rows) } else { whenLaidOut.append(body) }
    }

    func feed(_ data: Data) {
        // Replies to queries are sent synchronously from inside `feed`; keystrokes never are.
        feeding = true
        view.feed(byteArray: ArraySlice([UInt8](data)))
        feeding = false
    }

    /// Clears the screen and scrollback, so a replay doesn't stack on old output.
    func reset() {
        // RIS, then show the cursor (RIS keeps a hidden one hidden).
        view.feed(text: "\u{1b}c\u{1b}[?25h")
        view.clearScrollback()
        view.clearSearch()
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            guard !view.readOnly, !(feeding && replaying) else { return }
            onInput?(Data(data))
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard laidOut else { return }
            onResize?(newCols, newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated {
            guard !view.readOnly, !replaying else { return }
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
    }
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A `TerminalView` that reports its first real grid size, and can be made
/// read-only (it never takes the keyboard).
///
/// A vertical drag always scrolls, as a trackpad does in Terminal.app: plain
/// output scrolls the view's own scrollback; a program that asked for the
/// mouse (Claude Code, vim, htop…) gets scroll-wheel events, and one on the
/// alternate screen without the mouse (less, man) gets up/down arrows.
/// SwiftTerm would send such a program the drag as a mouse drag, which it
/// turns into a text selection. Selecting is press-and-hold, then Select.
final class ShellTerminalView: TerminalView {
    var readOnly = false
    var onFirstLayout: ((Int, Int) -> Void)?
    private var reported = false
    private lazy var programScroll = UIPanGestureRecognizer(target: self, action: #selector(programScrolled(_:)))
    /// Drag not yet sent, short of a whole line.
    private var scrollRemainder: CGFloat = 0

    override var canBecomeFirstResponder: Bool { !readOnly && super.canBecomeFirstResponder }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !reported, bounds.width > 0, bounds.height > 0 else { return }
        reported = true
        let terminal = getTerminal()
        onFirstLayout?(terminal.cols, terminal.rows)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if programScroll.view == nil { addGestureRecognizer(programScroll) }
    }

    /// Leaves out SwiftTerm's drag-as-mouse-drag; taps still reach the program as clicks.
    override func mouseModeChanged(source: Terminal) {}

    /// Whether a drag goes to the program rather than the scrollback.
    private var programTakesScroll: Bool {
        let terminal = getTerminal()
        return !readOnly && (terminal.mouseMode != .off || terminal.isCurrentBufferAlternate)
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === programScroll {
            // A drag with a selection showing moves its ends instead.
            guard programTakesScroll, !hasActiveSelection else { return false }
            let velocity = programScroll.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        if recognizer === panGestureRecognizer && programTakesScroll { return false }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    @objc private func programScrolled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            scrollRemainder = 0
        case .changed:
            let cell = cellSize
            scrollRemainder += recognizer.translation(in: self).y
            recognizer.setTranslation(.zero, in: self)
            let lines = Int(scrollRemainder / cell.height)
            guard lines != 0 else { return }
            scrollRemainder -= CGFloat(lines) * cell.height
            sendScroll(lines: lines, at: recognizer.location(in: self), cell: cell)
        default:
            break
        }
    }

    /// `lines` > 0: the finger moved down, bringing earlier output into view.
    private func sendScroll(lines: Int, at point: CGPoint, cell: CGSize) {
        let terminal = getTerminal()
        let up = lines > 0
        if terminal.mouseMode != .off {
            let x = point.x, y = point.y - contentOffset.y
            let col = min(max(Int(x / cell.width), 0), terminal.cols - 1)
            let row = min(max(Int(y / cell.height), 0), terminal.rows - 1)
            let flags = terminal.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            for _ in 0..<abs(lines) {
                terminal.sendEvent(buttonFlags: flags, x: col, y: row, pixelX: Int(x), pixelY: Int(y))
            }
        } else {
            let app = terminal.applicationCursor
            let key = up ? (app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                         : (app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0..<abs(lines) { send(key) }
        }
    }

    /// One cell, sized as SwiftTerm sizes it (its own figure isn't public).
    private var cellSize: CGSize {
        let cols = max(getTerminal().cols, 1)
        return CGSize(width: max(contentSize.width / CGFloat(cols), 1),
                      height: max(ceil(font.ascender - font.descender + font.leading), 1))
    }
}

/// SwiftUI wrapper for a driver's terminal view.
struct TerminalHost: UIViewRepresentable {
    let driver: TerminalDriver

    func makeUIView(context: Context) -> ShellTerminalView { driver.view }
    func updateUIView(_ view: ShellTerminalView, context: Context) {}

    static func dismantleUIView(_ view: ShellTerminalView, coordinator: ()) {
        _ = view.resignFirstResponder()
    }
}

// MARK: - Key row

/// The keys above the keyboard: esc, ctrl (applies to the next key typed),
/// tab, arrows (repeat while held), `|`, `~` and paste. Styled like the app's
/// bordered capsule buttons.
final class TerminalKeyRow: UIInputView {
    private weak var terminal: TerminalView?
    private var ctrlButton: UIButton?
    private var repeatTimer: Timer?
    private var repeatDelay: Timer?
    private var resetObserver: NSObjectProtocol?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth
        build()
        // SwiftTerm clears `controlModifier` once a key uses it; follow it.
        resetObserver = NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminal, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCtrl() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    private enum Key {
        case esc, ctrl, tab, left, up, down, right, pipe, tilde, paste

        var title: String? {
            switch self {
            case .esc: "esc"
            case .ctrl: "ctrl"
            case .tab: "tab"
            case .pipe: "|"
            case .tilde: "~"
            default: nil
            }
        }

        var symbol: String? {
            switch self {
            case .left: "arrow.left"
            case .up: "arrow.up"
            case .down: "arrow.down"
            case .right: "arrow.right"
            case .paste: "doc.on.clipboard"
            default: nil
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .esc: "Escape"
            case .ctrl: "Control"
            case .tab: "Tab"
            case .left: "Left arrow"
            case .up: "Up arrow"
            case .down: "Down arrow"
            case .right: "Right arrow"
            case .pipe: "Pipe"
            case .tilde: "Tilde"
            case .paste: "Paste"
            }
        }

        var repeats: Bool { self == .left || self == .up || self == .down || self == .right }
    }

    private func build() {
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
        for key in [Key.esc, .ctrl, .tab, .left, .up, .down, .right, .pipe, .tilde, .paste] {
            let button = makeButton(key)
            if key == .ctrl { ctrlButton = button }
            stack.addArrangedSubview(button)
        }
        updateCtrl()
    }

    private func makeButton(_ key: Key) -> UIButton {
        let button = UIButton(configuration: Self.configuration(key, selected: false))
        button.accessibilityLabel = key.accessibilityLabel
        if key.repeats {
            button.addAction(UIAction { [weak self] _ in self?.startRepeat(key) }, for: .touchDown)
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
            }
        } else {
            button.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
        }
        return button
    }

    private static func configuration(_ key: Key, selected: Bool) -> UIButton.Configuration {
        let tint = UIColor(PTTheme.accentEnd)
        var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = selected ? tint : tint.withAlphaComponent(0.14)
        config.baseForegroundColor = selected ? .white : tint
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        // Ten keys share the width: keep each title on one line (it never wraps to "ctr/l").
        config.titleLineBreakMode = .byClipping
        if let title = key.title {
            var text = AttributedString(title)
            text.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            config.attributedTitle = text
        }
        if let symbol = key.symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        }
        return config
    }

    private func press(_ key: Key) {
        guard let terminal else { return }
        UIDevice.current.playInputClick()
        switch key {
        case .esc: terminal.send([0x1b])
        case .tab: terminal.send([0x09])
        case .pipe: terminal.send(txt: "|")
        case .tilde: terminal.send(txt: "~")
        case .paste: terminal.paste(nil)   // bracketed when the shell asked for it
        case .ctrl:
            terminal.controlModifier.toggle()
            updateCtrl()
        case .left, .up, .down, .right:
            let app = terminal.getTerminal().applicationCursor
            let bytes: [UInt8] = switch key {
            case .left: app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
            case .up: app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
            case .down: app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
            default: app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
            }
            terminal.send(bytes)
        }
    }

    private func startRepeat(_ key: Key) {
        stopRepeat()
        press(key)
        repeatDelay = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.press(key) }
                }
            }
        }
    }

    private func stopRepeat() {
        repeatDelay?.invalidate()
        repeatTimer?.invalidate()
        repeatDelay = nil
        repeatTimer = nil
    }

    private func updateCtrl() {
        ctrlButton?.configuration = Self.configuration(.ctrl, selected: terminal?.controlModifier ?? false)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopRepeat() }
    }
}

extension TerminalKeyRow: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
