import Foundation
import IrohTransport
import LocalAuthentication
import PassthroughCore

/// Lets one of this phone's Macs see another's screen: asks the Mac being
/// shared for a screen-only pass (`ScreenPass`) for the other, then hands the
/// pass to the other Mac, which can then connect on its own, from anywhere.
/// The phone needs a shell credential for both and screen access to the first.
/// If the hand-over fails, the phone takes the pass back from the first Mac.
@MainActor
final class ScreenShareModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// How long the whole hand-over may take before it's given up.
    static let timeout: TimeInterval = 40
    /// How long a pass being taken back gets to reach the Mac before its connection closes.
    static let revokeGrace: TimeInterval = 2

    /// The connection to the Mac being shared, kept open until the other Mac has the pass.
    private var shared: (client: ShellClient, dialer: IrohShellDialer?)?
    /// The connection to the Mac that gets the pass.
    private var viewer: (client: ShellClient, dialer: IrohShellDialer?)?
    /// The pass the shared Mac granted, until the other Mac kept it.
    private var granted: String?
    private var generation = 0

    var isWorking: Bool { if case .working = phase { true } else { false } }

    /// After Face ID, lets `viewerMac` see `sharedMac`'s screen.
    func share(_ sharedMac: ShellCredential, with viewerMac: ShellCredential, shell: ShellModel) {
        guard !isWorking, sharedMac.macID != viewerMac.macID else { return }
        let name = ScreenPass.cleanName(viewerMac.macName)
        guard ScreenPass.isValidName(name), ScreenPass.isValidName(ScreenPass.cleanName(sharedMac.macName)) else {
            phase = .failed("Give both Macs a name first (System Settings › General › About), then try again.")
            return
        }
        generation += 1
        let gen = generation
        phase = .working("Confirming it's you…")
        Task {
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                       localizedReason: "Let \(viewerMac.macName) see \(sharedMac.macName)'s screen") else {
                    return cancelled(gen)
                }
            } catch {
                return cancelled(gen)
            }
            guard gen == generation else { return }
            ask(sharedMac, for: viewerMac, name: name, shell: shell, generation: gen)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                guard let self, gen == self.generation, self.isWorking else { return }
                self.failed("That took too long. Check that both Macs are awake with Remote Shell on, then try again.")
            }
        }
    }

    /// The sheet went away: anything still under way stops (a pass not handed over is taken back).
    func reset() {
        if isWorking { failed(nil) } else { closeAll() }
        phase = .idle
    }

    // MARK: Steps

    /// Step 1: the shared Mac issues a pass for the viewer. Its connection stays
    /// open, so the pass can be taken back if step 2 fails.
    private func ask(_ sharedMac: ShellCredential, for viewerMac: ShellCredential, name: String, shell: ShellModel, generation gen: Int) {
        phase = .working("Asking \(sharedMac.macName) for a pass…")
        shared = shell.oneOffConnection(to: sharedMac) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else {
                    if case let .screen(stream, _) = event { stream.cancel() }
                    return
                }
                switch event {
                case .ready:
                    self.shared?.client.grantScreen(name: name, viewer: viewerMac.macID)
                case let .macInfo(info):
                    // Where the Mac is now: the pass carries that, not what the phone last knew.
                    shell.applyMacInfo(info, for: sharedMac.macID)
                case let .screenGranted(viewerID, key):
                    self.granted = viewerID
                    let current = shell.macs.first { $0.macID == sharedMac.macID } ?? sharedMac
                    let pass = ScreenPass.credential(from: current, viewerID: viewerID, key: key)
                    self.hand(pass, to: viewerMac, shell: shell, generation: gen)
                case let .failed(error, _):
                    guard self.granted == nil else { return }   // the hand-over's outcome decides
                    self.failed(Self.grantMessage(error, shared: sharedMac.macName))
                case .disconnected:
                    guard self.granted == nil else { return }
                    self.failed("Couldn't reach \(sharedMac.macName). Check that it's awake and Remote Shell is on.")
                case let .screen(stream, _):
                    stream.cancel()
                default:
                    break
                }
            }
        }
    }

    /// Step 2: the viewer keeps the pass.
    private func hand(_ pass: ShellCredential, to viewerMac: ShellCredential, shell: ShellModel, generation gen: Int) {
        phase = .working("Handing the pass to \(viewerMac.macName)…")
        viewer = shell.oneOffConnection(to: viewerMac) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.viewer != nil else {
                    if case let .screen(stream, _) = event { stream.cancel() }
                    return
                }
                switch event {
                case .ready:
                    self.viewer?.client.giveScreenPass(pass)
                case .screenPassSaved:
                    // Retired first: closing the connections sends their `disconnected`, which isn't a failure now.
                    self.generation += 1
                    self.granted = nil
                    self.closeAll()
                    self.phase = .done("\(viewerMac.macName) can now see \(pass.macName)'s screen. Open it from Passthrough's menu on \(viewerMac.macName).")
                case .failed(.badRequest, _):
                    self.failed("\(viewerMac.macName) needs the latest Passthrough to view other Macs. Update it, then try again.")
                case let .failed(error, _):
                    self.failed(error.message ?? "\(viewerMac.macName) refused the pass.")
                case .disconnected:
                    self.failed("Couldn't reach \(viewerMac.macName). Check that it's awake and Remote Shell is on.")
                case let .screen(stream, _):
                    stream.cancel()
                default:
                    break
                }
            }
        }
    }

    private static func grantMessage(_ error: ShellError, shared: String) -> String {
        switch error {
        case .screenNotAllowed:
            "This \(ThisDevice.name) isn't allowed to see \(shared)'s screen, so it can't share it. Turn on Screen for it in Passthrough's Remote Shell settings on \(shared)."
        case .badRequest:
            "\(shared) needs the latest Passthrough to share its screen with another Mac. Update it, then try again."
        default:
            error.message ?? "\(shared) refused to share its screen."
        }
    }

    // MARK: Endings

    private func cancelled(_ gen: Int) {
        guard gen == generation else { return }
        phase = .idle
    }

    /// Stops with `message` (nil: quietly). A pass granted but not handed over
    /// is taken back on the still-open connection, then everything closes.
    private func failed(_ message: String?) {
        generation += 1
        closeViewer()
        if let message { phase = .failed(message) }
        guard let viewerID = granted, let connection = shared else { return closeAll() }
        granted = nil
        shared = nil
        // The step-1 handler now drops this connection's events (the generation
        // moved on), so rather than wait for `screenRevoked`, give the request
        // time to reach the Mac before closing. The closure keeps the connection
        // alive even if the sheet (and this model) has gone.
        connection.client.revokeScreen(viewerID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revokeGrace) {
            connection.client.disconnect()
            connection.dialer?.shutdown()
        }
    }

    private func closeViewer() {
        viewer?.client.disconnect()
        viewer?.dialer?.shutdown()
        viewer = nil
    }

    private func closeAll() {
        closeViewer()
        shared?.client.disconnect()
        shared?.dialer?.shutdown()
        shared = nil
        granted = nil
    }
}
