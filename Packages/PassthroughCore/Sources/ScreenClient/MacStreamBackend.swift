import CoreGraphics
import CoreMedia
import Foundation
import PassthroughCore

/// The Mac's own stream (`ScreenVideoClient`) as a `ScreenBackend`, and its own
/// `MacStreamControls`. Pointer positions go as fractions of the screen,
/// scrolling as the Mac's points, long text as a paste. Input on main; events
/// on the queue given to `init`, which must be main too (the pointer, the
/// screen's size and the scroll remainder are kept by both).
public final class MacStreamBackend: ScreenBackend, MacStreamControls, @unchecked Sendable {
    public let capabilities: ScreenCapabilities = [.macStream, .smoothScroll, .unicodeText, .resize, .drawsOwnPointer, .frameAcks]
    public var macStream: (any MacStreamControls)? { self }

    private let client: ScreenVideoClient
    /// The stream's size in pixels, from its last `.size`.
    private var size: CGSize = .zero
    /// Where the Mac last heard the pointer was, in screen pixels.
    private var lastPointer: CGPoint?
    /// Scroll not yet sent: a fraction of a point.
    private var scrollRemainder = CGPoint.zero

    /// `initialBytes`: what arrived after `screenVideoReady` with it.
    public init(stream: any ByteStream, initialBytes: Data = Data(), layout: ScreenVideoClient.Layout, queue: DispatchQueue = .main,
                onEvent: @escaping (ScreenBackendEvent) -> Void) {
        // The client is made before `self` is whole: it reaches the backend through this, and never keeps it alive.
        weak var backend: MacStreamBackend?
        client = ScreenVideoClient(stream: stream, initialBytes: initialBytes, layout: layout, queue: queue) { event in
            guard let backend, let translated = backend.translate(event) else { return }
            onEvent(translated)
        }
        backend = self
    }

    public func start() { client.start() }
    public func close() { client.close() }

    // MARK: Input

    public func pointer(at point: CGPoint, buttons: ScreenButtons) {
        lastPointer = point
        guard size.width > 0 else { return }
        client.pointer(x: point.x / max(size.width - 1, 1), y: point.y / max(size.height - 1, 1), buttons: RFBClient.Buttons(buttons))
    }

    /// Scrolls by as much as the fingers moved (the stream's pixels are about the Mac's points).
    public func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat) {
        scrollRemainder.x += delta.x
        scrollRemainder.y += delta.y
        // Scrolling goes where the pointer is: there first (a direct-mode scroll is under the fingers).
        if lastPointer != point { pointer(at: point, buttons: []) }
        let dx = Int(scrollRemainder.x), dy = Int(scrollRemainder.y)
        scrollRemainder.x -= CGFloat(dx)
        scrollRemainder.y -= CGFloat(dy)
        client.scroll(dx: dx, dy: dy)
    }

    public func scrollEnded() { scrollRemainder = .zero }

    public func key(_ key: ScreenKey, modifiers: ScreenModifiers) {
        client.key(key, modifiers: Self.mask(modifiers))
    }

    public func text(_ text: String) {
        // Long text (a paste, dictation) is pasted: the Mac types only short text as keys,
        // and apps that read keys, not characters (Windows App's RDP), get nothing else right.
        if text.utf16.count > ScreenVideoWire.typedAsKeys, client.clipboard(text) {
            return key(0x76, modifiers: .command)   // ⌘V
        }
        // Return and Tab are keys, not characters, to the apps on the Mac.
        var run = ""
        for character in text {
            if character == "\n" || character == "\r" || character == "\t", let keysym = RFBKeys.keysym(for: character) {
                if !run.isEmpty { client.text(run); run = "" }
                client.key(keysym, modifiers: [])
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty { client.text(run) }
    }

    public func paste(_ text: String) -> Bool {
        // Longer than the Mac takes: pasting would paste what was there before.
        guard client.clipboard(text) else { return false }
        key(0x76, modifiers: .command)   // ⌘V
        return true
    }

    /// The Mac copies and answers with what it copied (`.copied`).
    public func copySelection() { client.copySelection() }

    public func presented(_ number: UInt32) { client.shown(number) }
    public func needsKeyframe() { client.requestKeyframe() }

    // MARK: MacStreamControls

    public func relayout(_ layout: ScreenVideoClient.Layout) { client.relayout(layout) }
    public func useHere() { client.useHere() }
    public func curtain(_ hidden: Bool) { client.curtain(hidden) }
    public func sound(_ on: Bool) { client.sound(on) }
    public func microphone(_ on: Bool) { client.microphone(on) }
    public func voice(_ samples: Data) { client.voice(samples) }
    public func function(_ down: Bool) { client.function(down) }
    public func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        client.gesture(gesture, phase: phase, value: value)
    }

    // MARK: Events

    private func translate(_ event: ScreenVideoClient.Event) -> ScreenBackendEvent? {
        switch event {
        case let .size(width, height):
            size = CGSize(width: width, height: height)
            return .size(width: width, height: height)
        case let .frame(sample, number):
            return .sample(sample, number: number)
        case let .cursor(x, y, visible):
            guard size.width > 0 else { return nil }
            return .pointerPosition(CGPoint(x: x * (size.width - 1), y: y * (size.height - 1)), visible: visible)
        case let .cursorShape(image, size, hotSpot):
            return .pointerShape(image, size: size, hotSpot: hotSpot)
        case let .copied(result):
            return .copied(Self.copyResult(result))
        case let .fitted(fit):
            return .macStream(.fitted(fit))
        case let .viewers(names):
            return .macStream(.viewers(names))
        case let .movedAway(name):
            return .macStream(.movedAway(to: name))
        case let .curtained(hidden):
            return .macStream(.curtained(hidden))
        case let .microphone(state):
            return .macStream(.microphone(state))
        case let .sound(state):
            return .macStream(.sound(state))
        case let .soundPacket(packet):
            return .macStream(.soundPacket(packet))
        case let .closed(error):
            return .ended(error == nil ? .closedHere : .connectionLost)
        }
    }

    static func copyResult(_ result: ScreenVideoWire.CopyResult) -> ScreenCopyResult {
        switch result {
        case let .text(text): .text(text)
        case .nothing: .nothing
        case .tooLong: .tooLong
        case .notText: .notText
        }
    }

    /// The stream's modifier bits: the same numbers (`ScreenModifiers`' raw values); the Mac has no Windows key.
    static func mask(_ modifiers: ScreenModifiers) -> ScreenVideoWire.Modifiers {
        ScreenVideoWire.Modifiers(rawValue: modifiers.subtracting(.windows).rawValue)
    }
}
