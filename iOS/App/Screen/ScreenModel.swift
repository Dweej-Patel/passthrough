import CoreGraphics
import CoreMedia
import Foundation
import IrohTransport
import LocalAuthentication
import UIKit
import PassthroughCore
import ScreenClient

/// One view of the selected Mac's screen: its own shell connection, which asks
/// for the screen. First the Mac's own H.264 stream (`ScreenVideoClient`,
/// protocol/README.md "Screen video"): smooth, and no password. A Mac that
/// can't stream (it lacks Screen Recording or Accessibility, or predates it)
/// says so, and the same connection asks for Screen Sharing instead, handed
/// to an `RFBClient` with the Mac's login ("Screen"). Frames go straight to
/// the canvas (`onFrame`, `onVideoFrame`; not published: a frame must not
/// re-render the SwiftUI screen around it); takes pointer and key input.
@MainActor
final class ScreenModel: ObservableObject {
    enum Phase: Equatable {
        /// Waiting for the Mac's account name and password; `error` says why again.
        case login(error: String?)
        case connecting
        case live
        case failed(String)
    }

    @Published private(set) var phase = Phase.connecting
    /// The latest frame.
    private(set) var image: CGImage?
    /// The canvas, which draws each frame as it arrives.
    var onFrame: ((CGImage) -> Void)?
    /// The canvas's video display; false (or unset) when it couldn't take the frame, and a keyframe is asked for.
    var onVideoFrame: ((CMSampleBuffer) -> Bool)?
    /// The Mac's screen in pixels.
    @Published private(set) var screenSize = CGSize.zero
    @Published private(set) var macName = "your Mac"
    /// Why the view is on Screen Sharing rather than the Mac's own stream; nil when it isn't.
    @Published private(set) var slowReason: String?

    private var shell: ShellModel?
    private var context: LAContext?
    private var macID: String?
    private var client: ShellClient?
    private var dialer: IrohShellDialer?
    private var rfb: RFBClient?
    private var video: ScreenVideoClient?
    /// The connection is asking for the Mac's own stream (not Screen Sharing).
    private var wantsVideo = false
    /// Scroll not yet sent: a fraction of a point (stream) or of a wheel notch (Screen Sharing).
    private var scrollRemainder = CGPoint.zero
    /// Where the Mac last heard the pointer was, in screen pixels.
    private var lastPointer: CGPoint?
    /// The stream has shown its size: a stream ending before that never worked, so Screen Sharing is tried.
    private var videoStarted = false
    /// Bumped by every start and stop, so a stale connection's events are dropped.
    private var generation = 0
    private var pendingLogin: (login: RFBClient.Login, remember: Bool)?

    /// Uses the saved login if there is one, else asks for it.
    func begin(shell: ShellModel, context: LAContext) {
        #if DEBUG
        if let demo = Self.demoState { return applyDemo(demo) }
        #endif
        self.shell = shell
        self.context = context
        guard let mac = shell.macs.first(where: { $0.macID == shell.selectedMacID }) else {
            phase = .failed("Choose a Mac first.")
            return
        }
        macID = mac.macID
        macName = mac.macName
        slowReason = nil
        open(video: true)
    }

    /// Screen Sharing, with the Mac account's login.
    func connect(_ login: RFBClient.Login, remember: Bool) {
        #if DEBUG
        if Self.demoState != nil { return applyDemo("live") }
        #endif
        pendingLogin = (login, remember)
        open(video: false)
    }

    private func open(video: Bool) {
        let login = pendingLogin
        stop()
        pendingLogin = login
        guard let shell else { return }
        generation += 1
        let gen = generation
        wantsVideo = video
        videoStarted = false
        lastPointer = nil
        phase = .connecting
        guard let connection = shell.screenConnection(onEvent: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, generation: gen) }
        }) else {
            phase = .failed("Choose a Mac first.")
            return
        }
        client = connection.client
        dialer = connection.dialer
    }

    /// The Mac can't stream its screen itself: Screen Sharing on the same connection, if a login is saved.
    private func fallBackToScreenSharing() {
        wantsVideo = false
        slowReason = "Slower: allow Passthrough Screen Recording and Accessibility on \(macName) for the smooth view."
        if pendingLogin == nil, let macID, let context, let saved = ScreenLoginStore.read(macID: macID, context: context) {
            pendingLogin = (saved, false)
        }
        if pendingLogin != nil {
            client?.requestScreen(video: false)
        } else {
            stop()
            phase = .login(error: nil)
        }
    }

    /// Ends the view; the shell sessions are untouched.
    func stop() {
        generation += 1
        rfb?.close()
        rfb = nil
        video?.close()
        video = nil
        pendingLogin = nil
        client?.disconnect()
        client = nil
        dialer?.shutdown()
        dialer = nil
    }

    private func handle(_ event: ShellClient.Event, generation gen: Int) {
        guard gen == generation else {
            if case let .screen(stream, _) = event { stream.cancel() }
            return
        }
        switch event {
        case .ready:
            client?.requestScreen(video: wantsVideo)
        case let .screen(stream, initialBytes) where wantsVideo:
            client = nil   // it let go of the stream; the dialer stays up for it
            let native = UIScreen.main.nativeBounds.size
            let video = ScreenVideoClient(stream: stream, initialBytes: initialBytes, maxSide: Int(max(native.width, native.height))) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
            self.video = video
            video.start()
        case .failed(.screenVideoUnavailable, _) where wantsVideo, .failed(.badRequest, _) where wantsVideo:
            fallBackToScreenSharing()
        case let .screen(stream, initialBytes):
            client = nil   // it let go of the stream; the dialer stays up for it
            guard let login = pendingLogin?.login else { return stream.cancel() }
            let rfb = RFBClient(stream: stream, initialBytes: initialBytes, login: login) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
            self.rfb = rfb
            rfb.start()
        case let .failed(error, _):
            phase = .failed(error.message ?? "Your Mac refused the connection.")
            stop()
        case .disconnected:
            phase = .failed("Couldn't reach \(macName). Check that it's awake and Remote shell is on.")
            stop()
        default:
            break
        }
    }

    private func handle(_ event: ScreenVideoClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case let .size(width, height):
            screenSize = CGSize(width: width, height: height)
            videoStarted = true
            phase = .live
        case let .frame(sample, number):
            // Not shown (no canvas yet, or its display failed): what follows needs a new keyframe.
            if onVideoFrame?(sample) != true { video?.requestKeyframe() }
            video?.shown(number)
        case .closed:
            let worked = videoStarted
            stop()
            guard worked else {
                // The Mac said yes but couldn't capture or encode after all.
                slowReason = "Slower: \(macName) couldn't stream its screen. Reopening Passthrough on it may help."
                if let macID, let context, let saved = ScreenLoginStore.read(macID: macID, context: context) {
                    return connect(saved, remember: false)
                }
                phase = .login(error: nil)
                return
            }
            phase = .failed("The connection to \(macName) was lost.")
        }
    }

    private func handle(_ event: RFBClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case let .connected(width, height, _):
            screenSize = CGSize(width: width, height: height)
            phase = .live
            if let pending = pendingLogin, pending.remember, let macID, let context {
                ScreenLoginStore.save(pending.login, macID: macID, context: context)
            }
            pendingLogin = nil
        case let .frame(image):
            self.image = image
            let size = CGSize(width: image.width, height: image.height)
            if size != screenSize { screenSize = size }
            onFrame?(image)
        case let .clipboard(text):
            // Screen Sharing sends the Mac's clipboard whenever it changes, whatever is on it.
            if !text.isEmpty, let macID, ScreenClipboardSetting.isOn(macID: macID) { MacClipboard.put(text) }
        case .bell:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .closed(failure):
            stop()
            switch failure {
            case nil:
                break
            case .loginFailed?:
                if let macID { ScreenLoginStore.delete(macID: macID) }
                image = nil
                phase = .login(error: "Your Mac didn't accept that name and password.")
            case .unsupportedServer?:
                phase = .failed("Screen Sharing on your Mac answered in a way this app doesn't understand.")
            case .protocolError?:
                phase = .failed("The screen connection broke. Try again.")
            case .connectionLost?:
                phase = .failed("The connection to \(macName) was lost.")
            }
        }
    }

    // MARK: Input

    /// `point` in screen pixels.
    func pointer(at point: CGPoint, buttons: RFBClient.Buttons) {
        lastPointer = point
        if let video, screenSize.width > 0 {
            video.pointer(x: point.x / max(screenSize.width - 1, 1), y: point.y / max(screenSize.height - 1, 1), buttons: buttons)
        } else {
            rfb?.pointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
        }
    }

    func click(at point: CGPoint, button: RFBClient.Buttons = .left) {
        pointer(at: point, buttons: button)
        pointer(at: point, buttons: [])
    }

    /// Fingers moved `delta` (screen pixels) with the pointer at `point`: content follows them.
    /// The stream scrolls by as much (its pixels are about the Mac's points); Screen Sharing
    /// only knows wheel notches, one per `notch` pixels.
    func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat) {
        scrollRemainder.x += delta.x
        scrollRemainder.y += delta.y
        if let video {
            // Scrolling goes where the pointer is: there first (a direct-mode scroll is under the fingers).
            if lastPointer != point { pointer(at: point, buttons: []) }
            let dx = Int(scrollRemainder.x), dy = Int(scrollRemainder.y)
            scrollRemainder.x -= CGFloat(dx)
            scrollRemainder.y -= CGFloat(dy)
            video.scroll(dx: dx, dy: dy)
        } else {
            let notches = Int(scrollRemainder.y / notch)
            guard notches != 0 else { return }
            scrollRemainder = CGPoint(x: 0, y: scrollRemainder.y - CGFloat(notches) * notch)
            // Fingers down (positive) bring earlier content in: the wheel turns up.
            let button: RFBClient.Buttons = notches > 0 ? .wheelUp : .wheelDown
            for _ in 0..<abs(notches) { click(at: point, button: button) }
        }
    }

    func scrollEnded() { scrollRemainder = .zero }

    /// A key with modifiers held around it.
    func key(_ keysym: UInt32, modifiers: [UInt32] = []) {
        if let video { return video.key(keysym, modifiers: Self.mask(modifiers)) }
        modifiers.forEach { rfb?.key($0, down: true) }
        rfb?.key(keysym, down: true)
        rfb?.key(keysym, down: false)
        modifiers.reversed().forEach { rfb?.key($0, down: false) }
    }

    func type(_ text: String, modifiers: [UInt32] = []) {
        if let video, modifiers.isEmpty {
            // Return and Tab are keys, not characters, to the apps on the Mac.
            var run = ""
            for character in text {
                if character == "\n" || character == "\r" || character == "\t", let keysym = RFBKeys.keysym(for: character) {
                    if !run.isEmpty { video.text(run); run = "" }
                    video.key(keysym, modifiers: [])
                } else {
                    run.append(character)
                }
            }
            if !run.isEmpty { video.text(run) }
            return
        }
        for character in text {
            if let keysym = RFBKeys.keysym(for: character) { key(keysym, modifiers: modifiers) }
        }
    }

    /// Mission Control's shortcuts, as macOS sets them by default (System
    /// Settings › Keyboard › Keyboard Shortcuts › Mission Control).
    enum SpaceAction {
        case previousDesktop, nextDesktop, missionControl, appWindows, showDesktop
    }

    func perform(_ action: SpaceAction) {
        switch action {
        case .previousDesktop: key(RFBKeys.left, modifiers: [RFBKeys.control])
        case .nextDesktop: key(RFBKeys.right, modifiers: [RFBKeys.control])
        case .missionControl: key(RFBKeys.up, modifiers: [RFBKeys.control])
        case .appWindows: key(RFBKeys.down, modifiers: [RFBKeys.control])
        case .showDesktop: key(RFBKeys.function(11))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Puts the phone's clipboard on the Mac's and pastes it there.
    func pastePhoneClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if let video { video.clipboard(text) } else { rfb?.clipboard(text) }
        key(0x76, modifiers: [RFBKeys.command])   // ⌘V
    }

    /// The display lost its place (it was in the background, say): ask for a keyframe.
    func videoNeedsKeyframe() { video?.requestKeyframe() }

    private static func mask(_ modifiers: [UInt32]) -> ScreenVideoWire.Modifiers {
        modifiers.reduce(into: []) { mask, keysym in
            switch keysym {
            case RFBKeys.command: mask.insert(.command)
            case RFBKeys.shift: mask.insert(.shift)
            case RFBKeys.option: mask.insert(.option)
            case RFBKeys.control: mask.insert(.control)
            default: break
            }
        }
    }
}

#if DEBUG
// MARK: - Demo (DEBUG builds only)

extension ScreenModel {
    /// "login", "failed" or "live": a stand-in Mac screen, no connection.
    static var demoState: String? { UserDefaults.standard.string(forKey: "PTDemoScreen") }

    fileprivate func applyDemo(_ state: String) {
        macName = "My MacBook Pro"
        switch state {
        case "login": phase = .login(error: nil)
        case "failed": phase = .failed("Screen Sharing is off on your Mac. Turn it on in System Settings › General › Sharing.")
        default:
            let size = CGSize(width: 1512, height: 982)
            image = Self.demoImage(size)
            screenSize = size
            phase = .live
        }
    }

    /// A desktop with a couple of windows, drawn rather than shipped as an asset.
    private static func demoImage(_ size: CGSize) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 1).cgColor, UIColor(red: 0.45, green: 0.25, blue: 0.55, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.black.withAlphaComponent(0.35).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 30))
            for (frame, title) in [(CGRect(x: 120, y: 120, width: 760, height: 520), "Terminal — zsh"),
                                   (CGRect(x: 640, y: 300, width: 720, height: 560), "Safari — passthrough")] {
                UIColor(white: 0.12, alpha: 1).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 12).fill()
                UIColor(white: 0.22, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 34), cornerRadius: 12).fill()
                (title as NSString).draw(at: CGPoint(x: frame.minX + 90, y: frame.minY + 8),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.white])
                for (index, color) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    UIBezierPath(ovalIn: CGRect(x: frame.minX + 14 + CGFloat(index) * 22, y: frame.minY + 11, width: 13, height: 13)).fill()
                }
            }
            ("$ swift test\nAll tests passed." as NSString).draw(at: CGPoint(x: 140, y: 170), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: UIColor(red: 0.6, green: 1, blue: 0.7, alpha: 1)])
        }.cgImage
    }
}
#endif
