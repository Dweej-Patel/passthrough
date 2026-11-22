import AppKit
import IOSurface
import IrohTransport
import LocalAuthentication
import PassthroughCore
import ScreenClient
import ScreenEngine
import ShellHost
import SwiftUI

/// A PC's screen, seen and controlled from this Mac with access a phone handed
/// over (`ReachableComputer`, with the screen scope): the PC's own Remote
/// Desktop, relayed by its Passthrough service. The Remote Desktop engine runs
/// in a sandboxed helper process, never in this app; the app keeps the
/// connection and hands the helper only the session's bytes.
struct PCScreenWindow: View {
    static let id = "pc-screen"

    let hostID: String
    @EnvironmentObject private var shell: RemoteShellController
    @StateObject private var model = PCScreenModel()
    /// Confirmed with Touch ID or this Mac's password, once per window.
    @State private var unlocked = false
    @State private var unlocking = false
    @State private var shown = false
    /// The context that prompt satisfied: it reads and writes the saved Windows login without a second prompt.
    @State private var context = LAContext()
    /// The picture's area in points; in pixels at this display's scale, it is the desktop Windows is asked for.
    @State private var viewPoints = CGSize.zero
    @Environment(\.displayScale) private var displayScale
    private var viewPixels: CGSize { CGSize(width: viewPoints.width * displayScale, height: viewPoints.height * displayScale) }

    private var computer: ReachableComputer? { shell.reachableComputers.first { $0.id == hostID } }

    var body: some View {
        ZStack {
            Color.black
            PCScreenCanvas(model: model, live: model.phase == .live)
                .opacity(model.phase == .live ? 1 : 0)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { viewPoints = geometry.size }
                            .onChange(of: geometry.size) { _, size in viewPoints = size }
                    }
                }
            switch model.phase {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to \(model.name)…").foregroundStyle(.secondary)
                }
            case .live:
                EmptyView()
            case let .signIn(error):
                PCSignInForm(name: model.name, account: model.account, error: error) { login, remember in
                    model.connect(login, remember: remember, pixels: viewPixels, scale: displayScale)
                }
            case .inUse:
                VStack(spacing: 14) {
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Someone is using \(model.name) right now. Connecting locks its screen and they lose their place.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                    HStack {
                        Button("Not Now") { model.end("\(model.name) is in use.", canRetry: true) }
                            .keyboardShortcut(.defaultAction)
                        Button("Connect Anyway") { model.connectAnyway() }
                    }
                }
                .padding(24)
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
        .overlay(alignment: .top) {
            // Said once, when the picture first shows: what being here does at the PC.
            if model.showsLockedNote {
                Text("\(model.name)'s own screen is locked while you're here, and stays locked when you leave.")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsLockedNote)
        .frame(minWidth: 480, minHeight: 300)
        .focusedSceneValue(\.pcScreen, model)
        .onChange(of: viewPoints) { _, _ in model.viewChanged(pixels: viewPixels, scale: displayScale) }
        // Moved to a display with another scale: the same points are other pixels.
        .onChange(of: displayScale) { _, _ in model.viewChanged(pixels: viewPixels, scale: displayScale) }
        .navigationTitle(model.name)
        .navigationSubtitle(model.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Send Ctrl+Alt+Del") { model.windows(.ctrlAltDel) }
                    Button("Start") { model.windows(.start) }
                    Button("Task View") { model.windows(.taskView) }
                    Button("Switch Apps (Alt+Tab)") { model.windows(.altTab) }
                    Button("Show Desktop") { model.windows(.showDesktop) }
                    Button("Close Window (Alt+F4)") { model.windows(.closeWindow) }
                } label: {
                    Label("Windows", systemImage: "square.grid.2x2")
                }
                .help("Keys for \(model.name) that this Mac's keyboard keeps for itself")
                .disabled(model.phase != .live)
                Button { model.sendClipboard() } label: { Label("Send Clipboard", systemImage: "doc.on.clipboard") }
                    .help("Paste this Mac's clipboard text on \(model.name)")
                    .disabled(model.phase != .live)
                Button { model.copyFromPC() } label: { Label("Copy from PC", systemImage: "square.and.arrow.down.on.square") }
                    .help("Copy what is selected on \(model.name) to this Mac's clipboard")
                    .disabled(model.phase != .live)
            }
        }
        .onAppear {
            shown = true
            PCScreenWindows.opened()
            start()
            NSApp.activate()
        }
        .onDisappear {
            shown = false
            model.close()
            PCScreenWindows.closed()
        }
        .onChange(of: shell.reachableComputers) { _, computers in
            // The access was taken away while the window was open.
            guard !computers.contains(where: { $0.id == hostID }) else { return }
            model.end("This Mac no longer has access to \(model.name).")
        }
    }

    private func start() {
        // Access still waiting for the PC's owner is tried too: the PC says whether it has been allowed since.
        guard let computer, computer.mayAskForScreen else {
            model.end("This Mac has no access to that computer's screen. Share it again from your phone.")
            return
        }
        guard unlocked else { return unlock(computer) }
        let context = self.context
        let pin = computer.credential.loginPin
        model.begin(computer, identity: shell.identityForReaching,
                    remembered: { WindowsLoginStore.read(hostID: hostID, pin: pin, context: context) },
                    remember: { login in
                        if let login { WindowsLoginStore.save(login, hostID: hostID, pin: pin, context: context) } else { WindowsLoginStore.delete(hostID: hostID) }
                    })
        // A login saved for this PC signs in without asking; the picture's area is known by now.
        model.connectRemembered(pixels: viewPixels, scale: displayScale)
    }

    private func unlock(_ computer: ReachableComputer) {
        guard !unlocking else { return }
        unlocking = true
        model.locked(computer.credential.macName)
        Task { @MainActor in
            // Shown as "Passthrough is trying to …".
            let fresh = LAContext()
            let ok = (try? await fresh.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: "see and control \(computer.credential.macName)'s screen")) ?? false
            if ok { context = fresh }
            unlocking = false
            guard ok, shown else { return }
            unlocked = true
            start()
        }
    }
}

/// The Windows account's name and password, which Windows itself checks.
private struct PCSignInForm: View {
    let name: String
    let account: String?
    let error: String?
    let onSignIn: (ScreenLogin, Bool) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var editsAccount = false
    @FocusState private var focus: Field?

    private enum Field { case account, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to \(name)").font(.title3.weight(.semibold))
            Text("Windows asks for your account's password, not your PIN. Passthrough passes it to Windows and keeps it on this Mac behind Touch ID.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editsAccount {
                TextField("Account name or email", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .account)
            }
            SecureField(editsAccount || username.isEmpty ? "Password" : "Password for \(username)", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(signIn)
            Toggle("Remember on this Mac", isOn: $remember)
            HStack {
                if !editsAccount {
                    Button("Use a different account") {
                        editsAccount = true
                        focus = .account
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            if let account, !account.isEmpty {
                username = account
                focus = .password
            } else {
                editsAccount = true
                focus = .account
            }
        }
    }

    private func signIn() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty else { return }
        onSignIn(ScreenLogin(username: name, password: password), remember)
        password = ""
    }
}

// MARK: - Model

@MainActor
final class PCScreenModel: ObservableObject, RemoteScreenSource {
    enum Phase: Equatable {
        /// Waiting for the Windows account's password; `error` says why again.
        case signIn(error: String?)
        /// Someone is at the PC: connecting would lock its screen under them.
        case inUse
        case connecting, live
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var canRetry = true
    @Published private(set) var name = "PC"
    @Published private(set) var subtitle = ""
    /// The account the sign-in form starts with: the one last used in this window.
    @Published private(set) var account: String?
    @Published private(set) var streamSize: CGSize = .zero
    private(set) var cursor: (image: CGImage, size: CGSize, hotSpot: CGPoint)?
    private(set) var remotePointer: (x: Double, y: Double, visible: Bool)?
    /// Set by the canvas: the surface to show (nil: none), and that its pixels changed.
    var onSurface: ((IOSurface?) -> Void)?
    var onSurfaceChanged: (() -> Void)?
    var onCursorChange: (() -> Void)?
    private(set) var surface: IOSurface?

    private var computer: ReachableComputer?
    private var identity: (any ComputerIdentitySigning)?
    private var client: ShellClient?
    private var dialer: IrohShellDialer?
    private var splice: StreamSplice?
    private var connection: NSXPCConnection?
    private var engine: (any ScreenEngineXPC)?
    /// Kept by the connection for as long as it lasts.
    private var receiver: EngineReceiver?
    private var generation = 0
    private var path: ShellPath?
    private var buttons: RFBClient.Buttons = []
    /// Held only between the form and the helper's start, then let go.
    private var login: ScreenLogin?
    /// The login this window signed in with, kept while the window is open so a dropped view comes back without asking.
    private var held: (login: ScreenLogin, remember: Bool)?
    /// The saved login for this PC, and how to save one (nil: forget it): the window's, with its Touch ID context.
    private var remembered: (() -> ScreenLogin?)?
    private var remember: ((ScreenLogin?) -> Void)?
    private var shape = ScreenShape(width: 1920, height: 1200)
    private var visible = true
    /// The picture's area and this display's scale, as the window is now.
    private var view = (pixels: CGSize(width: 2560, height: 1600), scale: CGFloat(2))
    /// What the PC said of itself on this connection: whether someone is at it, and its own monitor's scale.
    private var host: HostInfo?
    private var askedAnyway = false
    private var rdpAsked = false
    private var hostWait: Task<Void, Never>?
    /// Reshaping: what Windows was last asked for, and when.
    private var asked: ScreenShape?
    private var askedAt: TimeInterval?
    private var reshapeTask: Task<Void, Never>?
    /// Reconnecting: how many tries in a row, and since when the picture has been live.
    private var retries = 0
    private var liveSince: TimeInterval?
    private var retryTask: Task<Void, Never>?
    /// The waits between tries after a view that worked dropped: three, under the PC's four quick opens in ten minutes.
    static let retryWaits: [TimeInterval] = [1, 4, 10]
    /// The bytes stopped before the helper said why: what it says within a moment wins.
    private var lostTask: Task<Void, Never>?
    /// Copy from PC was asked until then: the helper's answer is taken only while it waits.
    private var copyUntil: TimeInterval?
    @Published private(set) var showsLockedNote = false
    private var saidLockedNote = false
    private var noteTask: Task<Void, Never>?

    var isLive: Bool { phase == .live }
    var buttonsHeld: Bool { !buttons.isEmpty }
    /// ⌥ is a PC's Alt.
    var optionIsShortcut: Bool { true }

    private var words: HostWords { HostWords(kind: .windows, name: name, device: "Mac") }

    /// The window opened (or Try Again): Windows wants a password before anything is dialled.
    func begin(_ computer: ReachableComputer, identity: (any ComputerIdentitySigning)?,
               remembered: @escaping () -> ScreenLogin?, remember: @escaping (ScreenLogin?) -> Void) {
        stop()
        self.computer = computer
        self.identity = identity
        self.remembered = remembered
        self.remember = remember
        name = computer.credential.macName
        subtitle = ""
        canRetry = true
        retries = 0
        askedAnyway = false
        phase = .signIn(error: nil)
    }

    /// Signs in with the login this window already used, else the one saved for this PC; without either, the form stays.
    func connectRemembered(pixels: CGSize, scale: CGFloat) {
        guard phase == .signIn(error: nil) else { return }
        if let held { return connect(held.login, remember: held.remember, pixels: pixels, scale: scale) }
        if let saved = remembered?() { connect(saved, remember: true, pixels: pixels, scale: scale) }
    }

    /// The window closed: nothing of the login stays in memory.
    func close() {
        stop()
        held = nil
        remembered = nil
        remember = nil
    }

    /// Forgets the login saved for this PC (the window's own stays until it closes).
    func forgetSavedLogin() {
        remember?(nil)
        if let current = held { held = (current.login, false) }
    }

    /// Waiting for Touch ID or the password before anything else.
    func locked(_ name: String) {
        stop()
        self.name = name
        subtitle = ""
        canRetry = true
        phase = .failed("Confirm it's you to see and control \(name)'s screen.")
    }

    /// Stops with `message`; for good unless `canRetry`.
    func end(_ message: String, canRetry: Bool = false) {
        stop()
        self.canRetry = canRetry
        phase = .failed(message)
    }

    /// Dials the PC and asks for its Remote Desktop, to sign in as `login` once it answers.
    /// `pixels`: the picture's area, which the desktop takes; `scale`: this display's.
    func connect(_ login: ScreenLogin, remember: Bool, pixels: CGSize, scale: CGFloat) {
        guard let computer else { return }
        stop()
        generation += 1
        let gen = generation
        self.login = login
        held = (login, remember)
        account = login.username
        if pixels.width > 0, pixels.height > 0 { view = (pixels, scale) }
        host = nil
        rdpAsked = false
        phase = .connecting
        guard let identity else {
            return fail("Turn on Remote Shell on this Mac first: it proves to \(name) which Mac this is.")
        }
        let credential = computer.credential
        let dialer = credential.irohID.map(IrohInfo.isValidID) == true ? IrohShellDialer() : nil
        self.dialer = dialer
        let client = ShellClient(credential: credential, queue: .main, iroh: dialer, mode: .automatic, identity: identity) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, generation: gen) }
        }
        self.client = client
        client.connect(discovered: nil)
    }

    /// The desktop to ask for: the picture's area in this Mac's points, drawn at the PC's own scale (100 % until it
    /// says otherwise), so things are about the size they are on this Mac and Windows' scale never changes. Even
    /// sides, at least 800 x 600, at most 4096.
    static func shape(pixels: CGSize, scale: CGFloat, hostScale: Int = 100) -> ScreenShape {
        let points = CGSize(width: pixels.width / max(scale, 1), height: pixels.height / max(scale, 1))
        let wide = points.width * CGFloat(hostScale) / 100, high = points.height * CGFloat(hostScale) / 100
        let fit = min(1, 4096 / max(wide, high, 1))
        let width = min(max(Int(wide * fit), 800), 4096) & ~1
        let height = min(max(Int(high * fit), 600), 4096) & ~1
        return ScreenShape(width: width, height: height, desktopScale: hostScale, deviceScale: WindowsDisplay.deviceScale(for: hostScale))
    }

    /// The user chose to connect though someone is at the PC.
    func connectAnyway() {
        guard phase == .inUse else { return }
        askedAnyway = true
        phase = .connecting
        askForScreen()
    }

    /// The picture's area changed (the window was resized, or moved to another display): once it has settled, the
    /// desktop is asked to follow, as on the phone.
    func viewChanged(pixels: CGSize, scale: CGFloat) {
        guard pixels.width > 0, pixels.height > 0 else { return }
        view = (pixels, scale)
        guard phase == .live, engine != nil else { return }
        reshapeTask?.cancel()
        let wait = WindowsDisplay.wait(now: ProcessInfo.processInfo.systemUptime, lastAsked: askedAt)
        let gen = generation
        reshapeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled, let self, gen == self.generation, let engine = self.engine else { return }
            let next = Self.shape(pixels: self.view.pixels, scale: self.view.scale, hostScale: self.hostScale)
            guard WindowsDisplay.worthAsking(next, current: self.asked) else { return }
            self.asked = next
            self.askedAt = ProcessInfo.processInfo.systemUptime
            engine.reshape(width: next.width, height: next.height, desktopScale: next.desktopScale, deviceScale: next.deviceScale)
        }
    }

    /// The PC's own scale, which the session keeps (100 % until it says).
    private var hostScale: Int {
        guard let scale = host?.display?.scale, WindowsDisplay.scales.contains(scale) else { return 100 }
        return scale
    }

    func stop() {
        generation += 1
        login = nil
        hostWait?.cancel()
        reshapeTask?.cancel()
        retryTask?.cancel()
        noteTask?.cancel()
        lostTask?.cancel()
        lostTask = nil
        copyUntil = nil
        showsLockedNote = false
        asked = nil
        askedAt = nil
        liveSince = nil
        client?.disconnect()
        client = nil
        engine?.stop()
        engine = nil
        connection?.invalidate()
        connection = nil
        receiver = nil
        splice?.cancel()
        splice = nil
        dialer?.shutdown()
        dialer = nil
        buttons = []
        cursor = nil
        remotePointer = nil
        if surface != nil {
            surface = nil
            onSurface?(nil)
        }
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    private func handle(_ event: ShellClient.Event, generation gen: Int) {
        guard gen == generation else {
            if case let .rdp(stream, _, _) = event { stream.cancel() }
            return
        }
        switch event {
        case let .ready(path):
            self.path = path
            // What the PC says of itself comes right behind: whether someone is at it decides if the user is asked first.
            hostWait?.cancel()
            hostWait = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, gen == self.generation else { return }
                self.askForScreen()
            }
        case let .host(info):
            host = info
            hostWait?.cancel()
            let inUse = info.console == "active" && (info.idleSeconds ?? .max) < HostInfo.inUseIdleSeconds
            // Not asked again for a reconnect, or once the user said to go ahead.
            if inUse, !askedAnyway, retries == 0, !rdpAsked {
                phase = .inUse
            } else {
                askForScreen()
            }
        case let .rdp(stream, initialBytes, certSHA256):
            client = nil   // it let go of the stream; the dialer stays up for it
            startEngine(stream: stream, initialBytes: initialBytes, certSHA256: certSHA256, generation: gen)
        case .rdpRefused(.screenNotAllowed, _, _):
            // A computer's screen waits for the PC's owner, who allows it on the notice the hand-over left there.
            fail("Screen is off for this Mac. On \(name), click Passthrough's icon and choose Allow screen on the notice about this Mac.")
        case let .rdpRefused(error, detail, retryAfter):
            let refusal = WindowsScreenCopy.refusal(error, detail: detail, retryAfter: retryAfter, words)
            fail(refusal?.sentence ?? HostCopy.error(error, words) ?? "\(name) refused the connection.")
        case let .failed(error, _):
            fail(HostCopy.error(error, words) ?? "\(name) refused the connection.")
        case .disconnected where retries > 0 && held != nil:
            // A reconnect that couldn't reach the PC yet (the network is still coming back): the next wait.
            ended(.connectionLost, generation: gen)
        case .disconnected:
            fail("Can't reach \(name). It may be asleep, off, or offline.")
        default:
            break
        }
    }

    private func askForScreen() {
        guard !rdpAsked, let client else { return }
        rdpAsked = true
        client.requestRDP()
    }

    /// The PC handed the connection over to its Remote Desktop: the bytes go to a helper process through a socket
    /// pair, and the helper signs in. The helper never sees the network, and this app never runs the engine.
    private func startEngine(stream: any ByteStream, initialBytes: Data, certSHA256: String, generation gen: Int) {
        guard let login, let pair = FileDescriptorStream.socketPair() else {
            stream.cancel()
            return fail("This Mac couldn't start the screen view. Try again.")
        }
        self.login = nil
        shape = Self.shape(pixels: view.pixels, scale: view.scale, hostScale: hostScale)
        asked = shape
        let helperEnd = FileHandle(fileDescriptor: pair.1, closeOnDealloc: true)
        splice = StreamSplice(stream, initialBytes: initialBytes, FileDescriptorStream(descriptor: pair.0)) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The helper says why a session ended, a moment after the bytes stop (it reads them through
                    // this splice): wait for it, or Windows ending the session reads as a dropped connection.
                    self?.lostUnlessTold(generation: gen)
                }
            }
        }
        let service = ScreenEngineService.name(appBundleID: Bundle.main.bundleIdentifier ?? "")
        let connection = NSXPCConnection(serviceName: service)
        connection.remoteObjectInterface = ScreenEngineService.interface()
        connection.exportedInterface = ScreenEngineService.clientInterface()
        let receiver = EngineReceiver(model: self, generation: gen)
        connection.exportedObject = receiver
        // Only this app's own helper (the same team's signature) may answer.
        if let requirement = ScreenEngineService.sameTeamRequirement() { connection.setCodeSigningRequirement(requirement) }
        let gone: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.lostUnlessTold(generation: gen) }
            }
        }
        connection.interruptionHandler = gone
        connection.invalidationHandler = gone
        connection.resume()
        guard let engine = connection.remoteObjectProxyWithErrorHandler({ _ in gone() }) as? any ScreenEngineXPC else {
            connection.invalidate()
            return fail("This Mac couldn't start the screen view. Try again.")
        }
        self.connection = connection
        self.receiver = receiver
        self.engine = engine
        engine.start(username: login.username, password: login.password, certSHA256: certSHA256, clientName: "Mac",
                     width: shape.width, height: shape.height, desktopScale: shape.desktopScale, deviceScale: shape.deviceScale,
                     transport: helperEnd) { [weak self] started in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, !started else { return }
                    self.fail("\(self.name)'s screen isn't in this build of Passthrough.")
                }
            }
        }
        engine.setActive(visible)
    }

    /// The connection or the helper went before the helper said why the session ended: it usually says within a
    /// moment, and what it says wins; else the connection was lost.
    private func lostUnlessTold(generation gen: Int) {
        guard gen == generation, phase == .live || phase == .connecting, lostTask == nil else { return }
        lostTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, gen == self.generation, self.phase == .live || self.phase == .connecting else { return }
            self.ended(.connectionLost, generation: gen)
        }
    }

    // MARK: What the helper says (checked in `EngineReceiver`, then here on main)

    fileprivate func showSurface(_ surface: IOSurface, width: Int, height: Int, generation gen: Int) {
        guard gen == generation else { return }
        self.surface = surface
        streamSize = CGSize(width: width, height: height)
        if liveSince == nil {
            // Windows took the login: kept or forgotten as the user chose, only now.
            liveSince = ProcessInfo.processInfo.systemUptime
            if let held { remember?(held.remember ? held.login : nil) }
            if !saidLockedNote {
                saidLockedNote = true
                showsLockedNote = true
                noteTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    self?.showsLockedNote = false
                }
            }
        }
        phase = .live
        subtitle = switch path {
        case .relay?: "Keys go to \(name) · through a relay"
        case .direct?: "Keys go to \(name) · direct"
        case .local?: "Keys go to \(name) · local network"
        default: "Keys go to \(name)"
        }
        onSurface?(surface)
    }

    fileprivate func surfaceChanged(sequence: UInt64, generation gen: Int) {
        guard gen == generation else { return }
        onSurfaceChanged?()
        engine?.presented(sequence)
    }

    fileprivate func pointerShape(_ image: CGImage, hotSpot: CGPoint, generation gen: Int) {
        guard gen == generation else { return }
        cursor = (image, CGSize(width: image.width, height: image.height), hotSpot)
        onCursorChange?()
    }

    fileprivate func pointerHidden(generation gen: Int) {
        guard gen == generation else { return }
        cursor = nil
        onCursorChange?()
    }

    fileprivate func pointerMoved(x: Int, y: Int, generation gen: Int) {
        guard gen == generation, streamSize.width > 0, streamSize.height > 0 else { return }
        remotePointer = (min(max(Double(x) / streamSize.width, 0), 1), min(max(Double(y) / streamSize.height, 0), 1), true)
        onCursorChange?()
    }

    fileprivate func copied(_ result: ScreenCopyResult, generation gen: Int) {
        // Only an answer to Copy from PC, while it waits: the helper runs the engine, and the PC can't push here.
        guard gen == generation, let until = copyUntil, ProcessInfo.processInfo.systemUptime <= until else { return }
        copyUntil = nil
        switch result {
        case let .text(text) where !text.isEmpty:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            NSSound.beep()
        }
    }

    fileprivate func ended(_ end: ScreenEnd, generation gen: Int) {
        guard gen == generation else { return }
        let liveFor = liveSince.map { ProcessInfo.processInfo.systemUptime - $0 }
        stop()
        switch end {
        case .closedHere:
            break
        case .signIn(.wrongPassword), .signIn(.other):
            // A password Windows refused is forgotten, here and in the Keychain: one attempt, then the form.
            held = nil
            remember?(nil)
            phase = .signIn(error: WindowsScreenCopy.signInError(end))
        case .signIn(.passwordExpired):
            // Windows wants a new one: this password won't sign in again.
            held = nil
            remember?(nil)
            phase = .failed(WindowsScreenCopy.ending(end, words)?.sentence ?? "Windows refused the sign-in.")
        case .signIn:
            // Locked, turned off, or not allowed remotely: fixed on the PC, then Try Again with the saved login (if any);
            // this window doesn't keep re-sending its own.
            held = nil
            phase = .failed(WindowsScreenCopy.ending(end, words)?.sentence ?? "Windows refused the sign-in.")
        case .connectionLost where (liveFor != nil || retries > 0) && held != nil:
            // A view that worked and dropped (the network, this Mac's sleep, the helper) comes back by itself, a few
            // times, a try that didn't get through counting as one; one that lasted half a minute starts the count
            // again. Nothing else reconnects on its own.
            if let liveFor, liveFor > 30 { retries = 0 }
            guard retries < Self.retryWaits.count, let held else {
                phase = .failed("The connection to \(name) was lost.")
                return
            }
            let wait = Self.retryWaits[retries]
            retries += 1
            phase = .connecting
            let again = generation
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                guard !Task.isCancelled, let self, again == self.generation, self.phase == .connecting else { return }
                let kept = self.retries
                self.connect(held.login, remember: held.remember, pixels: self.view.pixels, scale: self.view.scale)
                self.retries = kept
            }
        default:
            phase = .failed(WindowsScreenCopy.ending(end, words)?.sentence ?? "The connection to \(name) was lost.")
        }
    }

    // MARK: Input

    private func pixel(_ x: Double, _ y: Double) -> (x: Int, y: Int) {
        (Int(x * Double(max(streamSize.width - 1, 0))), Int(y * Double(max(streamSize.height - 1, 0))))
    }

    private var buttonBits: Int {
        (buttons.contains(.left) ? 1 : 0) | (buttons.contains(.middle) ? 2 : 0) | (buttons.contains(.right) ? 4 : 0)
    }

    private var lastPointer = (x: 0, y: 0)

    func pointer(x: Double, y: Double) {
        lastPointer = pixel(x, y)
        engine?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: buttonBits)
    }

    func button(_ button: RFBClient.Buttons, down: Bool, x: Double, y: Double) {
        if down { buttons.insert(button) } else { buttons.remove(button) }
        pointer(x: x, y: y)
    }

    /// Scrolls by (`dx`, `dy`) desktop pixels; positive `dy` brings earlier content into view. A wheel notch is about 50 of them.
    func scroll(dx: CGFloat, dy: CGFloat) {
        engine?.scroll(x: lastPointer.x, y: lastPointer.y, dx: Double(dx), dy: Double(dy), notch: 50)
    }

    func scrollEnded() { engine?.scrollEnded() }

    /// This Mac's modifiers as a PC takes them: ⌘ and ⌃ are Ctrl, ⌥ is Alt.
    func key(_ keysym: UInt32, modifiers: ScreenVideoWire.Modifiers) {
        var held: ScreenModifiers = []
        if modifiers.contains(.command) || modifiers.contains(.control) { held.insert(.control) }
        if modifiers.contains(.option) { held.insert(.option) }
        if modifiers.contains(.shift) { held.insert(.shift) }
        engine?.key(keysym, modifiers: Int(held.rawValue))
    }

    func text(_ text: String) {
        // A long composition goes in pieces the helper takes.
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(1000)
            engine?.text(String(piece))
            rest = rest.dropFirst(piece.count)
        }
    }

    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {}

    /// These never leave this Mac while the picture has the keyboard: ⌘Tab (the system's anyway), ⌘` (next window), ⌃⌘F (full screen).
    func staysLocal(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, event.keyCode == 48 || event.keyCode == 50 { return true }
        if flags == [.command, .control], event.keyCode == 3 { return true }
        return false
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        engine?.setActive(visible)
    }

    /// A key of Windows' own that this Mac's keyboard has no way to press.
    func windows(_ shortcut: WindowsShortcut) {
        let chord = shortcut.chord
        engine?.key(chord.key, modifiers: Int(chord.modifiers.rawValue))
    }

    func sendClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, let engine else { return NSSound.beep() }
        engine.paste(text) { ok in
            if !ok { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    func copyFromPC() {
        guard let engine else { return }
        // The PC's copy window and its answer's wait (RDPClipboard's 2 s and 3 s, in the helper), and a moment.
        copyUntil = ProcessInfo.processInfo.systemUptime + 6
        engine.copySelection()
    }
}

/// The model of the PC window in front, for the menu bar's Windows menu.
struct PCScreenFocusKey: FocusedValueKey {
    typealias Value = PCScreenModel
}

extension FocusedValues {
    var pcScreen: PCScreenModel? {
        get { self[PCScreenFocusKey.self] }
        set { self[PCScreenFocusKey.self] = newValue }
    }
}

/// The app has no Dock icon or menu bar of its own. While a PC's screen window is open it takes both, so the
/// Windows menu and the standard window commands are there; when the last one closes it goes back.
@MainActor
enum PCScreenWindows {
    private static var count = 0

    static func opened() {
        count += 1
        if count == 1 { NSApp.setActivationPolicy(.regular) }
    }

    static func closed() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The menu bar's Windows menu: the same keys as the toolbar's, for the PC window in front.
struct PCScreenCommands: Commands {
    @FocusedValue(\.pcScreen) private var model

    var body: some Commands {
        CommandMenu("Windows") {
            Group {
                Button("Send Ctrl+Alt+Del") { model?.windows(.ctrlAltDel) }
                Button("Start") { model?.windows(.start) }
                Button("Task View") { model?.windows(.taskView) }
                Button("Switch Apps (Alt+Tab)") { model?.windows(.altTab) }
                Button("Show Desktop") { model?.windows(.showDesktop) }
                Button("Close Window (Alt+F4)") { model?.windows(.closeWindow) }
                Divider()
                Button("Send Clipboard") { model?.sendClipboard() }
                Button("Copy from PC") { model?.copyFromPC() }
            }
            .disabled(model?.phase != .live)
            Divider()
            Button("Forget Saved Sign-In") { model?.forgetSavedLogin() }
                .disabled(model == nil)
        }
    }
}

/// What the helper sends, on the connection's queue: every value is checked here before the model sees it. The helper
/// runs a parser of whatever the PC's Remote Desktop sends, so nothing it says is taken on trust.
private final class EngineReceiver: NSObject, ScreenEngineClientXPC, @unchecked Sendable {
    private weak var model: PCScreenModel?
    private let generation: Int
    private let lock = NSLock()
    /// The size of the surface in use, for clipping what is said to have changed.
    private var size = (width: 0, height: 0)

    init(model: PCScreenModel, generation: Int) {
        self.model = model
        self.generation = generation
    }

    private func onMain(_ body: @escaping @MainActor (PCScreenModel, Int) -> Void) {
        let generation = self.generation
        DispatchQueue.main.async { [weak model] in
            MainActor.assumeIsolated {
                guard let model else { return }
                body(model, generation)
            }
        }
    }

    func phase(_ code: Int) {}

    func surface(_ surface: IOSurface, width: Int, height: Int) {
        // The surface must really be what the message says: BGRA, that size, with room for every row.
        guard ScreenEngineCodes.validSize(width: width, height: height), surface.width == width, surface.height == height,
              surface.pixelFormat == 0x4247_5241, surface.bytesPerElement == 4, surface.bytesPerRow >= width * 4,
              surface.allocationSize >= surface.bytesPerRow * height else {
            return onMain { model, generation in model.ended(.protocolError("Remote Desktop"), generation: generation) }
        }
        lock.lock(); size = (width, height); lock.unlock()
        onMain { model, generation in model.showSurface(surface, width: width, height: height, generation: generation) }
    }

    func dirty(x: Int, y: Int, width: Int, height: Int, sequence: UInt64) {
        lock.lock(); let size = self.size; lock.unlock()
        guard size.width > 0, ScreenEngineCodes.clipped(x: x, y: y, width: width, height: height, in: size) != nil else { return }
        onMain { model, generation in model.surfaceChanged(sequence: sequence, generation: generation) }
    }

    func pointerShape(_ bgra: Data, width: Int, height: Int, hotX: Int, hotY: Int) {
        guard ScreenEngineCodes.validPointer(bytes: bgra.count, width: width, height: height, hotX: hotX, hotY: hotY),
              let provider = CGDataProvider(data: bgra as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        onMain { model, generation in model.pointerShape(image, hotSpot: CGPoint(x: hotX, y: hotY), generation: generation) }
    }

    func pointerHidden() {
        onMain { model, generation in model.pointerHidden(generation: generation) }
    }

    func pointerPosition(x: Int, y: Int) {
        onMain { model, generation in model.pointerMoved(x: x, y: y, generation: generation) }
    }

    func copied(_ code: Int, text: String?) {
        let result = ScreenEngineCodes.copyResult(code, text: text)
        onMain { model, generation in model.copied(result, generation: generation) }
    }

    func ended(_ code: Int, detail: String?) {
        let end = ScreenEngineCodes.end(code, detail: detail)
        onMain { model, generation in model.ended(end, generation: generation) }
    }
}

// MARK: - Canvas

private struct PCScreenCanvas: NSViewRepresentable {
    let model: PCScreenModel
    /// A value of its own, so SwiftUI updates the view when the picture goes live or stops.
    let live: Bool

    func makeNSView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(model: model)
        model.onSurface = { [weak view] surface in view?.show(surface: surface) }
        model.onSurfaceChanged = { [weak view] in view?.surfaceChanged() }
        model.onCursorChange = { [weak view] in view?.updateCursor() }
        view.show(surface: model.surface)
        return view
    }

    func updateNSView(_ view: RemoteScreenView, context: Context) {
        view.needsLayout = true
        view.liveChanged()
    }
}

/// What the panel and Settings say about access to another computer.
extension ReachableComputer {
    /// Not a Mac (another Mac's screen is a pass), with the screen scope: given, or still waiting for the
    /// PC's owner to allow it. The hand-over records "waiting"; only the PC knows whether it has been allowed since.
    var mayAskForScreen: Bool {
        credential.hostKind != HostInfo.kindMac
            && (scopes.contains(Computers.scopeScreen) || pending?.contains(Computers.scopeScreen) == true)
    }

    /// The hand-over said the screen waits for the PC's owner to allow it.
    var screenWaitsForOwner: Bool {
        !scopes.contains(Computers.scopeScreen) && pending?.contains(Computers.scopeScreen) == true
    }

    /// "PC", "Mac", or "Computer" when it didn't say.
    var kindName: String {
        switch credential.hostKind {
        case HostInfo.kindWindows: "PC"
        case HostInfo.kindMac: "Mac"
        default: "Computer"
        }
    }
}
