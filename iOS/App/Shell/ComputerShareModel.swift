import Foundation
import IrohTransport
import LocalAuthentication
import PassthroughCore

/// Lets another of this phone's computers (V) use one it has a shell on (H),
/// without this phone (stage 7 a.6): asks V first for its identity key (in
/// its `host`), then asks H for access for it (`computerGrant`), then hands
/// that access to V (`computerPass`). V's connection stays open throughout,
/// and H's until V kept it: if the hand-over fails, the phone takes the
/// access back from H (`computerRevoke`).
@MainActor
final class ComputerShareModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// How long the whole hand-over may take before it's given up.
    static let timeout: TimeInterval = 40
    /// How long V has, after `ready`, to say its identity key.
    static let identityWait: TimeInterval = 5
    /// How long access being taken back gets to reach H before its connection closes.
    static let revokeGrace: TimeInterval = 2

    /// The connection to the computer that gets access, open from the start.
    private var viewer: (client: ShellClient, dialer: IrohShellDialer?)?
    /// The connection to the computer being shared, kept open until V has the access.
    private var shared: (client: ShellClient, dialer: IrohShellDialer?)?
    /// What H granted, until V kept it.
    private var granted: String?
    private var generation = 0

    var isWorking: Bool { if case .working = phase { true } else { false } }

    /// After Face ID, lets `viewerHost` use `sharedHost` with `scopes`.
    func share(_ sharedHost: ShellCredential, with viewerHost: ShellCredential, scopes: [String], shell: ShellModel) {
        guard !isWorking, sharedHost.macID != viewerHost.macID, let scopes = Computers.validScopes(scopes) else { return }
        let name = ScreenPass.cleanName(viewerHost.macName)
        guard ScreenPass.isValidName(name), ScreenPass.isValidName(ScreenPass.cleanName(sharedHost.macName)) else {
            phase = .failed("Give both computers a name first, then try again.")
            return
        }
        generation += 1
        let gen = generation
        phase = .working("Confirming it's you…")
        Task {
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                       localizedReason: "Let \(viewerHost.macName) use \(sharedHost.macName)") else {
                    return cancelled(gen)
                }
            } catch {
                return cancelled(gen)
            }
            guard gen == generation else { return }
            ask(viewerHost, about: sharedHost, name: name, scopes: scopes, shell: shell, generation: gen)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                guard let self, gen == self.generation, self.isWorking else { return }
                self.failed("That took too long. Check that both computers are awake with Passthrough on, then try again.")
            }
        }
    }

    /// The sheet went away: anything still under way stops (access not handed over is taken back).
    func reset() {
        if isWorking { failed(nil) } else { closeAll() }
        phase = .idle
    }

    // MARK: Steps

    /// Step 1: V says its identity key in its `host`. Its connection stays open for step 3.
    private func ask(_ viewerHost: ShellCredential, about sharedHost: ShellCredential, name: String, scopes: [String],
                     shell: ShellModel, generation gen: Int) {
        phase = .working("Asking \(viewerHost.macName)…")
        let tooOld = "\(viewerHost.macName) needs the latest Passthrough to use other computers."
        askedViewer = false
        viewer =shell.oneOffConnection(to: viewerHost) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else {
                    if case let .screen(stream, _) = event { stream.cancel() }
                    return
                }
                switch event {
                case .ready:
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.identityWait) { [weak self] in
                        guard let self, gen == self.generation, !self.askedViewer else { return }
                        self.failed(tooOld)
                    }
                case let .host(info):
                    guard !self.askedViewer else { return }
                    guard let hex = info.idKey, let idKey = ComputerProof.publicKey(hex: hex) else { return self.failed(tooOld) }
                    self.askedViewer = true
                    let kind = Hosts.isRecordable(info.kind) ? info.kind : nil
                    self.grant(sharedHost, to: viewerHost, name: name, scopes: scopes, idKey: idKey, kind: kind, shell: shell, generation: gen)
                case .computerPassSaved:
                    self.saved(viewerHost, sharedHost)
                case .failed(.badRequest, _):
                    self.failed(self.granted == nil ? "Couldn't ask \(viewerHost.macName). Try again." : tooOld)
                case .failed(.passConflict, _):
                    self.failed("\(viewerHost.macName) already has access to a computer called \(sharedHost.macName) with different details. Remove it under Other computers on \(viewerHost.macName), then try again.")
                case let .failed(error, _):
                    self.failed(error.message ?? "\(viewerHost.macName) refused the access.")
                case .disconnected:
                    self.failed("Couldn't reach \(viewerHost.macName). Check that it's awake and Passthrough is on.")
                case let .screen(stream, _):
                    stream.cancel()
                default:
                    break
                }
            }
        }
    }

    /// V said its identity key (step 1 is over).
    private var askedViewer = false
    /// What H granted, for step 3's sentence.
    private var grantedScopes: (scopes: [String], pending: [String]) = ([], [])

    /// Step 2: H gives V access, then the phone hands it to V on V's open connection.
    private func grant(_ sharedHost: ShellCredential, to viewerHost: ShellCredential, name: String, scopes: [String], idKey: Data,
                       kind: String?, shell: ShellModel, generation gen: Int) {
        phase = .working("Asking \(sharedHost.macName) for access…")
        shared = shell.oneOffConnection(to: sharedHost) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else {
                    if case let .screen(stream, _) = event { stream.cancel() }
                    return
                }
                switch event {
                case .ready:
                    self.shared?.client.grantComputer(name: name, viewer: viewerHost.macID, scopes: scopes, idKey: idKey, kind: kind)
                case let .macInfo(info):
                    // Where H is now: the access carries that, not what the phone last knew.
                    shell.applyMacInfo(info, for: sharedHost.macID)
                case let .computerGranted(id, key, grantedScopes, pending):
                    self.granted = id
                    self.grantedScopes = (grantedScopes, pending)
                    let current = shell.macs.first { $0.macID == sharedHost.macID } ?? sharedHost
                    var pass = ScreenPass.credential(from: current, viewerID: id, key: key)
                    pass.hostKind = shell.kind(of: sharedHost.macID) == .windows ? HostInfo.kindWindows : HostInfo.kindMac
                    guard Computers.isUsable(pass) else {
                        return self.failed("This \(ThisDevice.name)'s details for \(sharedHost.macName) can't be handed over. Open \(sharedHost.macName) on this \(ThisDevice.name) so they refresh, then try again.")
                    }
                    self.phase = .working("Handing it to \(viewerHost.macName)…")
                    self.viewer?.client.giveComputerPass(pass, scopes: grantedScopes, pending: pending)
                case let .failed(error, _):
                    guard self.granted == nil else { return }   // the hand-over's outcome decides
                    self.failed(Self.grantMessage(error, shared: sharedHost.macName))
                case .disconnected:
                    guard self.granted == nil else { return }
                    self.failed("Couldn't reach \(sharedHost.macName). Check that it's awake and Passthrough is on.")
                case let .screen(stream, _):
                    stream.cancel()
                default:
                    break
                }
            }
        }
    }

    /// Step 3 done: V kept it. Retired first: closing the connections sends their `disconnected`, which isn't a failure now.
    private func saved(_ viewerHost: ShellCredential, _ sharedHost: ShellCredential) {
        guard granted != nil else { return }
        generation += 1
        granted = nil
        closeAll()
        let v = viewerHost.macName, h = sharedHost.macName
        let shell = grantedScopes.scopes.contains(Computers.scopeShell)
        let screen = grantedScopes.scopes.contains(Computers.scopeScreen)
        if grantedScopes.pending.contains(Computers.scopeScreen) {
            phase = .done("\(v) can now open shells on \(h). To let it see the screen too, allow it in Passthrough on \(h).")
        } else if shell && screen {
            phase = .done("\(v) can now open shells on \(h) and see its screen. Find it under Your computers on \(v).")
        } else if shell {
            phase = .done("\(v) can now open shells on \(h). Find it under Your computers on \(v).")
        } else {
            phase = .done("\(v) can now see \(h)'s screen. Find it under Your computers on \(v).")
        }
    }

    private static func grantMessage(_ error: ShellError, shared: String) -> String {
        switch error {
        case .notAllowed:
            "\(shared) doesn't let this \(ThisDevice.name) share access. Turn on May share access with other computers for it in Passthrough's settings on \(shared)."
        case .tooManyComputers:
            "\(shared) already lets as many computers in as it allows. Remove one in its settings first."
        case .screenNotAllowed:
            "This \(ThisDevice.name) isn't allowed to see \(shared)'s screen, so it can't share it. Turn on Screen for it in Passthrough's settings on \(shared)."
        case .badRequest:
            "\(shared) needs the latest Passthrough to share with another computer."
        default:
            error.message ?? "\(shared) refused to share access."
        }
    }

    // MARK: Endings

    private func cancelled(_ gen: Int) {
        guard gen == generation else { return }
        phase = .idle
    }

    /// Stops with `message` (nil: quietly). Access granted but not handed over
    /// is taken back on H's still-open connection, then everything closes.
    private func failed(_ message: String?) {
        generation += 1
        closeViewer()
        if let message { phase = .failed(message) }
        guard let connection = shared else { return closeAll() }
        shared = nil
        if let id = granted { connection.client.revokeComputer(id) }
        granted = nil
        // As `ScreenShareModel`: give the request time to reach H, then close. The closure keeps the
        // connection alive even if the sheet (and this model) has gone.
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
