import CoreGraphics
import Foundation
import PassthroughCore

/// macOS Screen Sharing (`RFBClient`) as a `ScreenBackend`: wheel notches for
/// scrolling, keysyms for typing, the clipboard plus ⌘V for paste, ⌘C for copy.
/// Input on main; events on the queue given to `init`, which must be main too
/// (the scroll remainder and the last paste are kept by both).
public final class ScreenSharingBackend: ScreenBackend, @unchecked Sendable {
    public let capabilities: ScreenCapabilities = [.signIn]
    public var macStream: (any MacStreamControls)? { nil }

    private let client: RFBClient
    /// Scroll not yet sent: a fraction of a wheel notch, in pixels.
    private var scrollRemainder: CGFloat = 0
    /// What Paste last put on the Mac, which Screen Sharing sends back.
    private var lastPaste: String?

    /// `initialBytes`: what arrived after `screenReady` with it.
    public init(stream: any ByteStream, initialBytes: Data = Data(), login: ScreenLogin, queue: DispatchQueue = .main,
                onEvent: @escaping (ScreenBackendEvent) -> Void) {
        // The client is made before `self` is whole: it reaches the backend through this, and never keeps it alive.
        weak var backend: ScreenSharingBackend?
        client = RFBClient(stream: stream, initialBytes: initialBytes, login: login, queue: queue) { event in
            guard let backend else { return }
            backend.translate(event).forEach(onEvent)
        }
        backend = self
    }

    public func start() { client.start() }
    public func close() { client.close() }

    // MARK: Input

    public func pointer(at point: CGPoint, buttons: ScreenButtons) {
        client.pointer(x: Int(point.x), y: Int(point.y), buttons: RFBClient.Buttons(buttons))
    }

    /// Screen Sharing only knows wheel notches, one per `notch` pixels.
    public func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat) {
        scrollRemainder += delta.y
        let notches = Int(scrollRemainder / notch)
        guard notches != 0 else { return }
        scrollRemainder -= CGFloat(notches) * notch
        // Fingers down (positive) bring earlier content in: the wheel turns up.
        let button: RFBClient.Buttons = notches > 0 ? .wheelUp : .wheelDown
        for _ in 0..<abs(notches) {
            client.pointer(x: Int(point.x), y: Int(point.y), buttons: button)
            client.pointer(x: Int(point.x), y: Int(point.y), buttons: [])
        }
    }

    public func scrollEnded() { scrollRemainder = 0 }

    public func key(_ key: ScreenKey, modifiers: ScreenModifiers) {
        let held = modifiers.keysyms
        held.forEach { client.key($0, down: true) }
        client.key(key, down: true)
        client.key(key, down: false)
        held.reversed().forEach { client.key($0, down: false) }
    }

    public func text(_ text: String) {
        for character in text {
            if let keysym = RFBKeys.keysym(for: character) { key(keysym, modifiers: []) }
        }
    }

    public func paste(_ text: String) -> Bool {
        client.clipboard(text)
        lastPaste = text
        key(0x76, modifiers: .command)   // ⌘V
        return true
    }

    /// ⌘C; the Mac's clipboard comes back as `.clipboardChanged` if it changed.
    public func copySelection() { key(0x63, modifiers: .command) }

    public func presented(_ number: UInt32) {}
    public func needsKeyframe() {}

    // MARK: Events

    private func translate(_ event: RFBClient.Event) -> [ScreenBackendEvent] {
        switch event {
        case let .connected(width, height, _):
            return [.size(width: width, height: height)]
        case let .frame(image):
            return [.image(image)]
        case let .clipboard(text):
            // Screen Sharing sends the Mac's clipboard whenever it changes: never this phone's own paste coming back.
            return text == lastPaste ? [] : [.clipboardChanged(text)]
        case .bell:
            return [.bell]
        case let .closed(failure):
            return [.ended(Self.end(for: failure))]
        }
    }

    /// How a Screen Sharing connection ended, in the backend's words.
    static func end(for failure: RFBClient.Failure?) -> ScreenEnd {
        switch failure {
        case nil: .closedHere
        case .loginFailed?: .signIn(.wrongPassword)
        case .noLoginOffered?: .identityMismatch
        case .unsupportedServer?: .unsupported("Screen Sharing")
        case let .protocolError(detail)?: .protocolError(detail)
        case .connectionLost?: .connectionLost
        }
    }
}
