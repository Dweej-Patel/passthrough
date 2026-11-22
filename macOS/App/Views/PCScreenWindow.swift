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
    /// The picture's area in pixels: the desktop Windows is asked for.
    @State private var viewPixels = CGSize.zero
    @Environment(\.displayScale) private var displayScale

    private var computer: ReachableComputer? { shell.reachableComputers.first { $0.id == hostID } }

    var body: some View {
        ZStack {
            Color.black
            PCScreenCanvas(model: model, live: model.phase == .live)
                .opacity(model.phase == .live ? 1 : 0)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { viewPixels = CGSize(width: geometry.size.width * displayScale, height: geometry.size.height * displayScale) }
                            .onChange(of: geometry.size) { _, size in
                                viewPixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
                            }
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
                PCSignInForm(name: model.name, account: model.account, error: error) { login in
                    model.connect(login, pixels: viewPixels, scale: displayScale)
                }
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
        .frame(minWidth: 480, minHeight: 300)
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
            start()
            NSApp.activate()
        }
        .onDisappear {
            shown = false
            model.stop()
        }
        .onChange(of: shell.reachableComputers) { _, computers in
            // The access was taken away while the window was open.
            guard !computers.contains(where: { $0.id == hostID }) else { return }
            model.end("This Mac no longer has access to \(model.name).")
        }
    }

    private func start() {
        guard let computer, computer.scopes.contains(Computers.scopeScreen) else {
            model.end("This Mac has no access to that computer's screen. Share it again from your phone.")
            return
        }
        guard unlocked else { return unlock(computer) }
        model.begin(computer, identity: shell.identityForReaching)
    }

    private func unlock(_ computer: ReachableComputer) {
        guard !unlocking else { return }
        unlocking = true
        model.locked(computer.credential.macName)
        Task { @MainActor in
            // Shown as "Passthrough is trying to …".
            let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: "see and control \(computer.credential.macName)'s screen")) ?? false
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
    let onSignIn: (ScreenLogin) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var editsAccount = false
    @FocusState private var focus: Field?

    private enum Field { case account, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to \(name)").font(.title3.weight(.semibold))
            Text("Windows asks for your account's password, not your PIN. Passthrough passes it to Windows.")
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
        onSignIn(ScreenLogin(username: name, password: password))
        password = ""
    }
}

// MARK: - Model

@MainActor
final class PCScreenModel: ObservableObject, RemoteScreenSource {
    enum Phase: Equatable {
        /// Waiting for the Windows account's password; `error` says why again.
        case signIn(error: String?)
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
    private var shape = ScreenShape(width: 1920, height: 1200)
    private var visible = true

    var isLive: Bool { phase == .live }
    var buttonsHeld: Bool { !buttons.isEmpty }
    /// ⌥ is a PC's Alt.
    var optionIsShortcut: Bool { true }

    private var words: HostWords { HostWords(kind: .windows, name: name, device: "Mac") }

    /// The window opened (or Try Again): Windows wants a password before anything is dialled.
    func begin(_ computer: ReachableComputer, identity: (any ComputerIdentitySigning)?) {
        stop()
        self.computer = computer
        self.identity = identity
        name = computer.credential.macName
        subtitle = ""
        canRetry = true
        phase = .signIn(error: nil)
    }

    /// Waiting for Touch ID or the password before anything else.
    func locked(_ name: String) {
        stop()
        self.name = name
        subtitle = ""
        canRetry = true
        phase = .failed("Confirm it's you to see and control \(name)'s screen.")
    }

    /// Stops for good with `message`: nothing to try again with.
    func end(_ message: String) {
        stop()
        canRetry = false
        phase = .failed(message)
    }

    /// Dials the PC and asks for its Remote Desktop, to sign in as `login` once it answers.
    /// `pixels`: the picture's area, which the desktop takes; `scale`: this display's.
    func connect(_ login: ScreenLogin, pixels: CGSize, scale: CGFloat) {
        guard let computer else { return }
        stop()
        generation += 1
        let gen = generation
        self.login = login
        account = login.username
        shape = Self.shape(pixels: pixels, scale: scale)
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

    /// The desktop to ask for: the picture's own pixels (even, within Remote Desktop's limits and 4096 a side),
    /// with Windows' text at this display's scale.
    static func shape(pixels: CGSize, scale: CGFloat) -> ScreenShape {
        let fit = min(1, 4096 / max(pixels.width, pixels.height, 1))
        let width = min(max(Int(pixels.width * fit), 800), 8192) & ~1
        let height = min(max(Int(pixels.height * fit), 600), 8192) & ~1
        let wanted = Int((scale * fit * 100).rounded())
        let desktopScale = WindowsDisplay.scales.last { $0 <= max(wanted, 100) } ?? 100
        return ScreenShape(width: width, height: height, desktopScale: desktopScale, deviceScale: WindowsDisplay.deviceScale(for: desktopScale))
    }

    func stop() {
        generation += 1
        login = nil
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
            client?.requestRDP()
        case let .rdp(stream, initialBytes, certSHA256):
            client = nil   // it let go of the stream; the dialer stays up for it
            startEngine(stream: stream, initialBytes: initialBytes, certSHA256: certSHA256, generation: gen)
        case let .rdpRefused(error, detail, retryAfter):
            let refusal = WindowsScreenCopy.refusal(error, detail: detail, retryAfter: retryAfter, words)
            fail(refusal?.sentence ?? HostCopy.error(error, words) ?? "\(name) refused the connection.")
        case let .failed(error, _):
            fail(HostCopy.error(error, words) ?? "\(name) refused the connection.")
        case .disconnected:
            fail("Can't reach \(name). It may be asleep, off, or offline.")
        default:
            break
        }
    }

    /// The PC handed the connection over to its Remote Desktop: the bytes go to a helper process through a socket
    /// pair, and the helper signs in. The helper never sees the network, and this app never runs the engine.
    private func startEngine(stream: any ByteStream, initialBytes: Data, certSHA256: String, generation gen: Int) {
        guard let login, let pair = FileDescriptorStream.socketPair() else {
            stream.cancel()
            return fail("This Mac couldn't start the screen view. Try again.")
        }
        self.login = nil
        let helperEnd = FileHandle(fileDescriptor: pair.1, closeOnDealloc: true)
        splice = StreamSplice(stream, initialBytes: initialBytes, FileDescriptorStream(descriptor: pair.0)) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The helper says why a session ended; this is the connection going first.
                    guard let self, gen == self.generation, self.phase == .live || self.phase == .connecting else { return }
                    self.ended(.connectionLost, generation: gen)
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
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, self.phase == .live || self.phase == .connecting else { return }
                    self.ended(.connectionLost, generation: gen)
                }
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

    // MARK: What the helper says (checked in `EngineReceiver`, then here on main)

    fileprivate func showSurface(_ surface: IOSurface, width: Int, height: Int, generation gen: Int) {
        guard gen == generation else { return }
        self.surface = surface
        streamSize = CGSize(width: width, height: height)
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
        guard gen == generation else { return }
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
        stop()
        switch end {
        case .closedHere:
            break
        case .signIn(.wrongPassword), .signIn(.other):
            phase = .signIn(error: WindowsScreenCopy.signInError(end))
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

    func copyFromPC() { engine?.copySelection() }
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

/// The PCs this Mac may see the screen of (access a phone handed over, with the screen scope), each one click away.
struct PCScreensSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openWindow) private var openWindow

    private var computers: [ReachableComputer] {
        shell.reachableComputers.filter { $0.credential.hostKind == HostInfo.kindWindows && $0.scopes.contains(Computers.scopeScreen) }
    }

    var body: some View {
        if !computers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your computers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(computers) { computer in
                    Button {
                        openWindow(id: PCScreenWindow.id, value: computer.id)
                        NSApp.activate()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "pc").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text("View \(computer.credential.macName)'s screen").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help("Open \(computer.credential.macName)'s screen in a window." + (computer.from.map { " Handed over by \($0)." } ?? ""))
                }
            }
        }
    }
}
