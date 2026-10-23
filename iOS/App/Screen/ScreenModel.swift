import CoreGraphics
import Foundation
import IrohTransport
import LocalAuthentication
import UIKit
import PassthroughCore
import ScreenClient

/// One view of the selected Mac's screen: its own shell connection, which asks
/// for the screen and is handed over to an `RFBClient` (protocol/README.md,
/// "Screen"). Publishes the latest frame; takes pointer and key input.
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
    @Published private(set) var image: CGImage?
    /// The Mac's screen in pixels.
    @Published private(set) var screenSize = CGSize.zero
    @Published private(set) var macName = "your Mac"

    private var shell: ShellModel?
    private var context: LAContext?
    private var macID: String?
    private var client: ShellClient?
    private var dialer: IrohShellDialer?
    private var rfb: RFBClient?
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
        if let saved = ScreenLoginStore.read(macID: mac.macID, context: context) {
            connect(saved, remember: false)
        } else {
            phase = .login(error: nil)
        }
    }

    func connect(_ login: RFBClient.Login, remember: Bool) {
        #if DEBUG
        if Self.demoState != nil { return applyDemo("live") }
        #endif
        stop()
        guard let shell else { return }
        generation += 1
        let gen = generation
        pendingLogin = (login, remember)
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

    /// Ends the view; the shell sessions are untouched.
    func stop() {
        generation += 1
        rfb?.close()
        rfb = nil
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
            client?.requestScreen()
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
            screenSize = CGSize(width: image.width, height: image.height)
        case let .clipboard(text):
            if !text.isEmpty { UIPasteboard.general.string = text }
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

    func pointer(at point: CGPoint, buttons: RFBClient.Buttons) {
        rfb?.pointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
    }

    func click(at point: CGPoint, button: RFBClient.Buttons = .left) {
        pointer(at: point, buttons: button)
        pointer(at: point, buttons: [])
    }

    /// One wheel notch up (negative) or down (positive) per step.
    func scroll(at point: CGPoint, steps: Int) {
        let notch: RFBClient.Buttons = steps < 0 ? .wheelUp : .wheelDown
        for _ in 0..<abs(steps) { click(at: point, button: notch) }
    }

    /// A key with modifiers held around it.
    func key(_ keysym: UInt32, modifiers: [UInt32] = []) {
        modifiers.forEach { rfb?.key($0, down: true) }
        rfb?.key(keysym, down: true)
        rfb?.key(keysym, down: false)
        modifiers.reversed().forEach { rfb?.key($0, down: false) }
    }

    func type(_ text: String, modifiers: [UInt32] = []) {
        for character in text {
            if let keysym = RFBKeys.keysym(for: character) { key(keysym, modifiers: modifiers) }
        }
    }

    /// Puts the phone's clipboard on the Mac's and pastes it there.
    func pastePhoneClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        rfb?.clipboard(text)
        key(0x76, modifiers: [RFBKeys.command])   // ⌘V
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
