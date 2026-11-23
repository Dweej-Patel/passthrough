import GameController
import SwiftUI
import PassthroughCore
import PassthroughUI
import RemoteDesktop
import ScreenClient

/// The full-screen view of the selected Mac's screen: the Mac's login when
/// it's needed, then the screen with touch and keyboard controls. It's the
/// one view that turns to landscape, where its controls move to the side.
struct ScreenView: View, Equatable {
    /// The same Mac's shell: nothing else comes from outside. Without this the view was
    /// rebuilt whenever the app's model changed (about every second), open menus included.
    nonisolated static func == (a: ScreenView, b: ScreenView) -> Bool { a.shell === b.shell }

    /// Not observed: the shell model changes all the time (every session's status), and each
    /// change redrew this whole view, open menus included, which made them flicker.
    /// The one thing shown from it, whether the Mac can be locked, is followed below.
    let shell: ShellModel
    /// How to close it when it isn't in a SwiftUI presentation (it's presented through UIKit).
    var onClose: (() -> Void)?
    @State private var canLock = false
    @EnvironmentObject private var lock: AppLock
    @StateObject private var model = ScreenModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.displayScale) private var displayScale
    @AppStorage("screenTouchMode") private var modeSetting = ScreenTouchMode.trackpad.rawValue
    @State private var keyboard = false
    /// A hardware keyboard is connected: a PC's menu then offers what its ⌘ key is.
    @State private var hardwareKeyboard = GCKeyboard.coalesced != nil
    /// iPad: the floating bar is put away at the side (it covers the Mac's menu bar), remembered.
    /// View state, saved by hand: a change to a stored setting doesn't animate.
    @State private var barAside = UserDefaults.standard.bool(forKey: "screenBarAside")
    /// The bar's own width, for how far it slides.
    @State private var barWidth: CGFloat = 0

    private var mode: ScreenTouchMode { ScreenTouchMode(rawValue: modeSetting) ?? .trackpad }
    private var landscape: Bool { verticalSize == .compact }
    /// iPad: the screen fills the display under a floating bar, in every orientation.
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if pad {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
                    .overlay(alignment: .top) { padControls }
            } else {
                phoneLayout
            }
        }
        // Safe here because the view has its own controller (`ScreenCoverPresenter`): under
        // SwiftUI's cover this preference and the app root's took turns several times a second.
        .preferredColorScheme(.dark)
        .hiddenWhileCaptured { covered in
            if covered { keyboard = false }
        }
        .persistentSystemOverlays(landscape || pad ? .hidden : .automatic)
        // iPad: the Mac's screen fills the display, its menu bar where the iPad's status bar
        // is, which iPadOS draws over it on a blur. The Mac's own clock and battery are there.
        .statusBarHidden(pad)
        .task { model.begin(shell: shell, context: lock.context) }
        .onReceive(shell.$macState.map { $0?.locked == false && $0?.control == true }.removeDuplicates()) { canLock = $0 }
        // A connected keyboard types into the Mac from the start, without the on-screen one.
        .onChange(of: model.phase == .live) { _, live in if live, GCKeyboard.coalesced != nil { keyboard = true } }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            hardwareKeyboard = true
            if model.phase == .live { keyboard = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hardwareKeyboard = GCKeyboard.coalesced != nil
            keyboard = false
        }
        .onAppear { AppOrientation.allowed = AppOrientation.standard == .all ? .all : .allButUpsideDown }
        .onDisappear {
            model.stop()
            AppOrientation.allowed = AppOrientation.standard
        }
    }

    /// iPhone: one layout that changes shape, so turning the phone keeps the same canvas
    /// (its zoom, and its video display, which a new one would have to wait a keyframe for).
    @ViewBuilder private var phoneLayout: some View {
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if !landscape { topBar }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: landscape ? .vertical : [])
            if landscape { sideBar }
        }
    }

    /// A little past its mark and back, as a thing slid to the edge of the screen settles.
    private static let barSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    /// How much of the bar stays on screen once it's aside: its first button, now an arrow.
    private static let barStub: CGFloat = 54

    /// The bar is aside only once the screen is live: before that it has the way out.
    private var aside: Bool { barAside && model.phase == .live }

    private func setAside(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "screenBarAside")
        withAnimation(Self.barSpring) { barAside = on }
    }

    /// iPad: the bar where it belongs, top centre, or slid off the right edge (and down, clear
    /// of the Mac's menu bar) until only its first button shows, as an arrow that slides it back.
    /// It's one bar all along, so going aside and coming back are the same motion; a swipe along
    /// it does the same as its arrows.
    private var padControls: some View {
        GeometryReader { proxy in
            padBar
                .frame(maxWidth: .infinity)
                .offset(x: aside ? (proxy.size.width + barWidth) / 2 - Self.barStub : 0, y: aside ? 52 : 8)
                .animation(Self.barSpring, value: aside)
                .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
                    guard model.phase == .live, abs(drag.translation.width) > abs(drag.translation.height) * 1.5 else { return }
                    if drag.translation.width > 50, !barAside { setAside(true) }
                    if drag.translation.width < -30, barAside { setAside(false) }
                })
        }
    }

    /// iPad: one floating glass bar over the screen, its controls labelled
    /// since there's room. A connected keyboard and trackpad go straight to
    /// the Mac (`ScreenCanvas`), so the on-screen keyboard is only a fallback.
    private var padBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                // Aside, this end is all that shows: the way back, in Done's place.
                ZStack {
                    Button { model.stop(); close() } label: {
                        Image(systemName: "xmark").font(.body.weight(.bold)).frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .accessibilityLabel("Done")
                    .opacity(aside ? 0 : 1)
                    .scaleEffect(aside ? 0.5 : 1)
                    .allowsHitTesting(!aside)
                    .accessibilityHidden(aside)
                    Button { setAside(false) } label: {
                        Image(systemName: model.microphone == .on ? "mic.fill" : "chevron.left")
                            .font(.body.weight(.bold))
                            .foregroundStyle(model.microphone == .on ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Show the controls")
                    .opacity(aside ? 1 : 0)
                    .scaleEffect(aside ? 1 : 0.5)
                    .allowsHitTesting(aside)
                    .accessibilityHidden(!aside)
                }
                if model.phase == .live {
                    Divider().frame(height: 24)
                    Picker("Touch", selection: $modeSetting) {
                        Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag(ScreenTouchMode.trackpad.rawValue)
                        Label("Direct", systemImage: "hand.point.up.left").tag(ScreenTouchMode.direct.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Divider().frame(height: 24)
                    keyboardButton.frame(width: 44, height: 44)
                    if model.canUseMicrophone { microphoneButton.frame(width: 44, height: 44) }
                    clipboardMenu.frame(width: 44, height: 44)
                    desktopsMenu.frame(height: 44)
                    displayMenu.frame(height: 44)
                    Divider().frame(height: 24)
                    Button { setAside(true) } label: {
                        Image(systemName: "chevron.right").font(.body.weight(.bold)).frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .accessibilityLabel("Move the controls aside")
                } else {
                    Text(model.macName).font(.subheadline.weight(.semibold)).padding(.trailing, 12)
                }
            }
            .padding(.horizontal, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            .background(GeometryReader { bar in Color.clear.preference(key: BarWidthKey.self, value: bar.size.width) })
            .onPreferenceChange(BarWidthKey.self) { barWidth = $0 }
            if model.phase == .live {
                Text(model.slowReason ?? (model.macHidden ? "Hidden on \(model.macName)'s own display" : padHint))
                    .font(.caption)
                    .foregroundStyle(model.slowReason == nil ? Color.secondary : PTTheme.warning)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .lineLimit(1)
                    .opacity(aside ? 0 : 1)
            }
        }
        .tint(PTTheme.accentEnd)
    }

    private var padHint: String {
        mode == .trackpad
            ? "Drag to move · tap to click · three fingers switch desktops · or use a trackpad"
            : model.pinchesMac ? "Tap to click · hold to drag · three-finger double-tap to zoom · or use a trackpad"
            : "Tap to click · hold to drag · pinch to zoom · or use a trackpad"
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Done") { model.stop(); close() }
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(model.macName).font(.subheadline.weight(.semibold)).lineLimit(1)
                if model.phase == .live {
                    if let slow = model.slowReason {
                        Text(slow).font(.caption2).foregroundStyle(PTTheme.warning).lineLimit(2).multilineTextAlignment(.center)
                    } else {
                        Text(model.macHidden ? "Hidden on \(model.macName)'s own display"
                             : mode == .trackpad ? "Drag to move · tap to click · hold to drag" : "Tap to click · hold to drag")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if model.phase == .live {
                clipboardMenu
                desktopsMenu
                displayMenu
                modeButton
                if model.canUseMicrophone { microphoneButton }
                keyboardButton
            }
        }
        .tint(PTTheme.accentEnd)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Landscape: the same controls in a column beside the screen. With the keyboard up
    /// there's only room for about three of them, so they pair up in two columns (the
    /// screen is letterboxed then, so the width is free). The shape follows `keyboard`,
    /// never a measurement: one that depends on the space the keyboard leaves (as
    /// ViewThatFits did) can flip back and forth as the keyboard comes up, and hung the app.
    private var sideBar: some View {
        VStack(spacing: 6) {
            doneButton
            Spacer(minLength: 0)
            if model.phase == .live {
                if keyboard {
                    HStack(spacing: 4) { clipboardMenu; desktopsMenu; displayMenu }
                    HStack(spacing: 4) { modeButton; if model.canUseMicrophone { microphoneButton }; keyboardButton }
                } else {
                    clipboardMenu
                    desktopsMenu
                    displayMenu
                    modeButton
                    if model.canUseMicrophone { microphoneButton }
                    keyboardButton
                }
            }
        }
        .font(.title3)
        .tint(PTTheme.accentEnd)
        .padding(.vertical, keyboard ? 8 : 14)
        .padding(.horizontal, 6)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var doneButton: some View {
        Button { model.stop(); close() } label: { Image(systemName: "xmark").sideTarget(landscape) }
            .font(.body.weight(.semibold))
            .accessibilityLabel("Done")
    }

    private var modeButton: some View {
        Button {
            modeSetting = (mode == .trackpad ? ScreenTouchMode.direct : .trackpad).rawValue
        } label: {
            Image(systemName: mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left")
                .sideTarget(landscape)
        }
        .accessibilityLabel(mode == .trackpad ? "Trackpad mode. Switch to tapping where you click." : "Direct mode. Switch to trackpad.")
    }

    /// This device as the Mac's microphone: filled while the Mac hears it.
    private var microphoneButton: some View {
        Button { model.toggleMicrophone() } label: {
            Image(systemName: model.microphone == .off ? "mic" : "mic.fill")
                .symbolEffect(.pulse, isActive: model.microphone == .starting)
                .foregroundStyle(model.microphone == .on ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .sideTarget(landscape)
        }
        .accessibilityLabel(model.microphone == .off ? "Use this \(ThisDevice.name) as \(model.macName)'s microphone" : "Turn the microphone off")
    }

    private var keyboardButton: some View {
        Button { keyboard.toggle() } label: {
            Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                .sideTarget(landscape)
        }
        .accessibilityLabel(keyboard ? "Hide keyboard" : "Show keyboard")
    }

    /// Copy and paste between the Mac and this iPhone, also on the keyboard's key row.
    private var clipboardMenu: some View {
        ScreenClipboardMenu(model: model, macName: model.macName, copying: model.copying, landscape: landscape).equatable()
    }

    /// Mission Control: the same as the canvas's three-finger swipes. For a PC, the Windows menu in its place.
    @ViewBuilder private var desktopsMenu: some View {
        if model.windowsView {
            ScreenWindowsMenu(model: model, shell: shell, macName: model.macName, canLock: canLock, hardwareKeyboard: hardwareKeyboard,
                              commandIsWindows: model.commandIsWindows, pad: pad, landscape: landscape).equatable()
        } else {
            ScreenDesktopsMenu(model: model, shell: shell, macName: model.macName, canLock: canLock, pad: pad, landscape: landscape).equatable()
        }
    }

    /// How the Mac's screen is shown here: its shape, text size, picture and gestures, and
    /// how the view reaches the Mac. Each choice is one row opening its options, so the
    /// menu fits a phone held sideways (a menu taller than the screen doesn't scroll).
    private var displayMenu: some View {
        ScreenDisplayMenu(model: model, macName: model.macName, canHideMac: model.canHideMac, path: model.connectionPath,
                          fitsDevice: model.fitsDevice, space: model.space, quality: model.quality,
                          pinchesMac: model.pinchesMacOnItsDisplay, playsSound: model.playsSound, macHidden: model.macHidden,
                          windows: model.windowsView, windowsShape: model.windowsShapeChoice, windowsSpace: model.windowsSpace,
                          windowsHasDisplay: model.windowsHostDisplay != nil,
                          pad: pad, landscape: landscape).equatable()
    }

    static func describe(_ path: ShellPath) -> (text: String, symbol: String)? {
        switch path {
        case .local: ("Connected over your network or Tailscale", "wifi")
        case .direct: ("Connected directly", "arrow.left.and.right")
        case .relay: ("Through a relay (slower)", "arrow.triangle.branch")
        case .unknown: nil
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .live:
            ScreenCanvas(model: model, mode: mode, keyboard: $keyboard)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay(alignment: .bottom) {
                    if let notice = model.notice {
                        Text(notice)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 14)
                            .padding(.horizontal, 16)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.notice)
                .overlay(alignment: .top) {
                    // Also open elsewhere: one tap makes this the one.
                    if let other = model.otherViewers.first {
                        UseHereBanner(others: model.otherViewers.count > 1 ? "\(other) and \(model.otherViewers.count - 1) more" : other) {
                            model.useHere()
                        }
                        .padding(.top, pad ? 64 : 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.otherViewers)
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(model.macName)…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The area the screen will fill (as the canvas does: into the bottom edge), so a
            // display made for this device has that size from the first ask, not a second one.
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { model.viewPixelsChanged(CGSize(width: geometry.size.width * displayScale, height: geometry.size.height * displayScale)) }
                        .onChange(of: geometry.size) { _, size in
                            model.viewPixelsChanged(CGSize(width: size.width * displayScale, height: size.height * displayScale))
                        }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        case let .login(error):
            ScreenLoginForm(macName: model.macName, error: error, style: model.loginStyle) { login, remember in
                model.connect(login, remember: remember)
            }
        case .confirmScreenSharing:
            ScreenSharingPrompt(macName: model.macName, reason: model.slowReason,
                                onUse: { model.useScreenSharing(always: $0) },
                                onCancel: { model.stop(); close() })
        case let .movedAway(name):
            VStack(spacing: 16) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 40)).foregroundStyle(PTTheme.accentEnd)
                Text("\(model.macName)'s screen is open on \(name) now.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button { model.takeBack(shell: shell, context: lock.context) } label: {
                    Label("Use Here", systemImage: pad ? "ipad" : "iphone").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PTTheme.accentEnd)
            }
            .padding(32)
        case let .failed(message):
            VStack(spacing: 16) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 40)).foregroundStyle(PTTheme.warning)
                Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button { model.begin(shell: shell, context: lock.context) } label: {
                    Label("Try again", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(PTTheme.accentEnd)
            }
            .padding(32)
        }
    }
}

private extension View {
    /// A full 44 pt tap target in the landscape side bar, where the controls sit close
    /// together; the portrait top bar keeps its tighter row.
    func sideTarget(_ on: Bool) -> some View {
        frame(width: on ? 44 : nil, height: on ? 44 : nil).contentShape(Rectangle())
    }
}

private struct BarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Menus
//
// Each menu is its own view, equal while what it shows is equal: SwiftUI rebuilds an
// open menu whenever the view holding it is evaluated again, which showed as the menu
// flickering under the finger. The models are held only to act on, not observed.

struct ScreenClipboardMenu: View, Equatable {
    let model: ScreenModel
    let macName: String
    let copying: Bool
    let landscape: Bool
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.macName == b.macName && a.copying == b.copying && a.landscape == b.landscape
    }

    @ViewBuilder var body: some View {
        Menu {
            Button { model.copyFromMac() } label: { Label("Copy from \(macName)", systemImage: "doc.on.doc") }
                .disabled(copying)
            Button { model.pastePhoneClipboard() } label: { Label("Paste on \(macName)", systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "doc.on.clipboard").sideTarget(landscape)
        }
        .accessibilityLabel("Copy and paste")
    }
}

struct ScreenDesktopsMenu: View, Equatable {
    let model: ScreenModel
    let shell: ShellModel
    let macName: String
    let canLock: Bool
    let pad: Bool
    let landscape: Bool
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.macName == b.macName && a.canLock == b.canLock && a.pad == b.pad && a.landscape == b.landscape
    }

    @ViewBuilder var body: some View {
        Menu {
            Section("Or swipe with three fingers") {
                Button { model.perform(.previousDesktop) } label: { Label("Previous desktop", systemImage: "arrow.left.square") }
                Button { model.perform(.nextDesktop) } label: { Label("Next desktop", systemImage: "arrow.right.square") }
                Button { model.perform(.missionControl) } label: { Label("Mission Control", systemImage: "rectangle.3.group") }
                Button { model.perform(.appWindows) } label: { Label("App windows", systemImage: "macwindow.on.rectangle") }
            }
            Button { model.perform(.showDesktop) } label: { Label("Show desktop", systemImage: "menubar.dock.rectangle") }
            // Only the lock: the Mac stays awake, and this view stays open on its lock screen.
            if canLock {
                Button { shell.control(.lock) } label: { Label("Lock \(macName)", systemImage: "lock") }
            }
        } label: {
            if pad {
                Label("Desktops", systemImage: "square.stack.3d.up").font(.subheadline.weight(.semibold)).padding(.horizontal, 10)
            } else {
                Image(systemName: "square.stack.3d.up").sideTarget(landscape)
            }
        }
        .accessibilityLabel("Desktops and Mission Control")
    }
}

/// A PC's keys that a touch screen has no way to press, in place of the Mac's Desktops.
struct ScreenWindowsMenu: View, Equatable {
    let model: ScreenModel
    let shell: ShellModel
    let macName: String
    let canLock: Bool
    let hardwareKeyboard: Bool
    let commandIsWindows: Bool
    let pad: Bool
    let landscape: Bool
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.macName == b.macName && a.canLock == b.canLock && a.hardwareKeyboard == b.hardwareKeyboard
            && a.commandIsWindows == b.commandIsWindows && a.pad == b.pad && a.landscape == b.landscape
    }

    @ViewBuilder var body: some View {
        Menu {
            Button { model.windows(.ctrlAltDel) } label: { Label("Ctrl+Alt+Del", systemImage: "keyboard") }
            Button { model.windows(.start) } label: { Label("Start", systemImage: "square.grid.2x2") }
            Section("Or swipe with three fingers") {
                Button { model.windows(.previousDesktop) } label: { Label("Previous desktop", systemImage: "arrow.left.square") }
                Button { model.windows(.nextDesktop) } label: { Label("Next desktop", systemImage: "arrow.right.square") }
                Button { model.windows(.taskView) } label: { Label("Task View", systemImage: "rectangle.3.group") }
                Button { model.windows(.showDesktop) } label: { Label("Show desktop", systemImage: "menubar.dock.rectangle") }
            }
            Button { model.windows(.altTab) } label: { Label("Alt+Tab", systemImage: "rectangle.on.rectangle") }
            Button { model.windows(.closeWindow) } label: { Label("Close window", systemImage: "xmark.rectangle") }
            Button { model.windows(.delete) } label: { Label("Delete", systemImage: "delete.forward") }
            Menu {
                ForEach(1...12, id: \.self) { number in
                    Button("F\(number)") { model.windows(.function(number)) }
                }
            } label: {
                Label("F1–F12", systemImage: "fn")
            }
            // Only the lock: the PC stays on, and this view stays open on its lock screen.
            if canLock {
                Button { shell.control(.lock) } label: { Label("Lock \(macName)", systemImage: "lock") }
            }
            // A hardware keyboard's ⌘: Control, so the shortcuts in the fingers work, or the Windows key.
            if hardwareKeyboard {
                Picker(selection: Binding(get: { commandIsWindows }, set: { model.setCommandIsWindows($0) })) {
                    Text("Ctrl").tag(false)
                    Text("Windows key").tag(true)
                } label: {
                    Label("⌘ acts as", systemImage: "command")
                }
                .pickerStyle(.menu)
            }
        } label: {
            if pad {
                Label("Windows", systemImage: "square.grid.2x2").font(.subheadline.weight(.semibold)).padding(.horizontal, 10)
            } else {
                Image(systemName: "square.grid.2x2").sideTarget(landscape)
            }
        }
        .accessibilityLabel("Windows keys and desktops")
    }
}

struct ScreenDisplayMenu: View, Equatable {
    let model: ScreenModel
    let macName: String
    let canHideMac: Bool
    let path: ShellPath?
    let fitsDevice: Bool
    let space: Int
    let quality: ScreenVideoWire.Quality
    let pinchesMac: Bool
    let playsSound: Bool
    let macHidden: Bool
    /// A PC: its desktop's shape and Windows' text size, in place of the Mac's rows.
    var windows = false
    var windowsShape = WindowsDisplay.Shape.fit
    var windowsSpace = 100
    /// The PC said what its own monitor is: its own size can be kept.
    var windowsHasDisplay = false
    let pad: Bool
    let landscape: Bool
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.macName == b.macName && a.canHideMac == b.canHideMac && a.path == b.path && a.fitsDevice == b.fitsDevice && a.space == b.space
            && a.quality == b.quality && a.pinchesMac == b.pinchesMac && a.playsSound == b.playsSound && a.macHidden == b.macHidden && a.pad == b.pad
            && a.landscape == b.landscape && a.windows == b.windows && a.windowsShape == b.windowsShape && a.windowsSpace == b.windowsSpace
            && a.windowsHasDisplay == b.windowsHasDisplay
    }

    @ViewBuilder var body: some View {
        if canHideMac || windows || path.flatMap(ScreenView.describe) != nil {
            Menu {
                // How far the picture travels: a relay is the likeliest reason it lags.
                if let path = path, let reach = ScreenView.describe(path) {
                    Section { Label(reach.text, systemImage: reach.symbol) }
                }
                // A PC makes its desktop the shape it is asked for: this device's, or a standard one to pan and zoom.
                if windows {
                    Picker(selection: Binding(get: { windowsShape }, set: { model.setWindowsShape($0) })) {
                        Label("Fit to this \(ThisDevice.name)", systemImage: pad ? "ipad" : "iphone").tag(WindowsDisplay.Shape.fit)
                        Label("Standard (16:10)", systemImage: "display").tag(WindowsDisplay.Shape.standard)
                        // Nothing on the PC's desktop moves, here or back at the PC; pan and pinch to zoom.
                        if windowsHasDisplay {
                            Label("\(macName)'s own size", systemImage: "pc").tag(WindowsDisplay.Shape.own)
                        }
                    } label: {
                        Label("Screen shape", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    }
                    .pickerStyle(.menu)
                    // The PC's own size is what it is: pinch to zoom instead.
                    if windowsShape != .own || !windowsHasDisplay {
                        Picker(selection: Binding(get: { windowsSpace }, set: { model.setWindowsSpace($0) })) {
                            Label("Larger text", systemImage: "textformat.size.larger").tag(80)
                            Label("Default", systemImage: "textformat.size").tag(100)
                            Label("More space", systemImage: "textformat.size.smaller").tag(125)
                        } label: {
                            Label("Text size", systemImage: "textformat.size")
                        }
                        .pickerStyle(.menu)
                    }
                }
                // Only the Mac's own stream has these; Screen Sharing shows the screen as it is.
                if canHideMac {
                    // The Mac's own display as it is, or one it makes in this device's shape (which its own mirror meanwhile).
                    Picker(selection: Binding(get: { fitsDevice }, set: { model.setFitsDevice($0) })) {
                        Label("\(macName)'s display", systemImage: "laptopcomputer").tag(false)
                        Label("Fit to this \(ThisDevice.name)", systemImage: pad ? "ipad" : "iphone").tag(true)
                    } label: {
                        Label("Screen shape", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    }
                    .pickerStyle(.menu)
                    // Only for a display made for this device: how big the Mac draws things on it.
                    if fitsDevice {
                        Picker(selection: Binding(get: { space }, set: { model.setSpace($0) })) {
                            Label("Larger text", systemImage: "textformat.size.larger").tag(80)
                            Label("Default", systemImage: "textformat.size").tag(100)
                            Label("More space", systemImage: "textformat.size.smaller").tag(125)
                        } label: {
                            Label("Text size", systemImage: "textformat.size")
                        }
                        .pickerStyle(.menu)
                    }
                    Picker(selection: Binding(get: { quality }, set: { model.setQuality($0) })) {
                        Text("Sharp: crisp text, 60 fps").tag(ScreenVideoWire.Quality.sharp)
                        Text("Smooth: crisp text, \(ScreenModel.topFPS) fps").tag(ScreenVideoWire.Quality.smooth)
                        Text("Fast: softer text, \(ScreenModel.topFPS) fps").tag(ScreenVideoWire.Quality.fast)
                    } label: {
                        Label("Picture", systemImage: "sparkles.tv")
                    }
                    .pickerStyle(.menu)
                    // Black on the Mac's own displays while this view goes on showing the screen.
                    Toggle(isOn: Binding(get: { macHidden }, set: { model.setMacHidden($0) })) {
                        Label("Hide \(macName)'s display", systemImage: "eye.slash")
                    }
                    Toggle(isOn: Binding(get: { playsSound }, set: { model.setPlaysSound($0) })) {
                        Label("Play \(macName)'s sound here", systemImage: "speaker.wave.2")
                    }
                    // Pinch and rotate: the Mac's on a display made for this device; a choice on its own display.
                    if fitsDevice {
                        Section {
                            Label("Pinch and rotate go to \(macName). Three-finger double-tap zooms here.", systemImage: "hand.pinch")
                        }
                    } else {
                        Toggle(isOn: Binding(get: { pinchesMac }, set: { model.setPinchesMacOnItsDisplay($0) })) {
                            Label("Pinch and rotate go to \(macName)", systemImage: "hand.pinch")
                        }
                    }
                }
            } label: {
                if pad {
                    Label("Display", systemImage: "display").font(.subheadline.weight(.semibold)).padding(.horizontal, 10)
                } else {
                    Image(systemName: "display").sideTarget(landscape)
                }
            }
            .accessibilityLabel("Display settings")
        }
    }
}

/// "Also open on iPad · Use Here": the Mac's screen is being viewed on another
/// device too; using it here ends the view there.
struct UseHereBanner: View {
    let others: String
    let onUse: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Also open on \(others)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Use Here", action: onUse)
                .font(.caption.weight(.bold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .tint(PTTheme.accentEnd)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Use Here", onUse)
    }
}

/// Asked when the Mac's own stream didn't work, before the Mac's login is
/// sent to Screen Sharing: once, always for this Mac, or not.
struct ScreenSharingPrompt: View {
    let macName: String
    let reason: String?
    let onUse: (_ always: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 40)).foregroundStyle(PTTheme.warning)
            Text("Use Screen Sharing with your Mac login?").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("\(macName) can't stream its screen itself right now. Screen Sharing is slower and needs the name and password of your account on \(macName): the one saved on this \(ThisDevice.name), if there is one.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button { onUse(false) } label: {
                    Text("Use Screen Sharing").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                Button { onUse(true) } label: {
                    Text("Always for This Mac").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                Button("Cancel", action: onCancel).font(.subheadline)
            }
            .buttonBorderShape(.capsule)
            .tint(PTTheme.accentEnd)
        }
        .padding(32)
        .frame(maxWidth: 420)
    }
}

/// The account name and password the far computer checks: a Mac's for Screen
/// Sharing, or a PC's Windows account for Remote Desktop.
struct ScreenLoginForm: View {
    enum Style: Equatable {
        case mac
        /// `account`: the one to sign in as (the last used, or the one the PC named); nil asks for it.
        case windows(account: String?)
    }

    let macName: String
    let error: String?
    var style: Style = .mac
    let onConnect: (ScreenLogin, Bool) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    /// Windows: the account field is shown (none was known, or "Use a different account").
    @State private var editsAccount = false
    @FocusState private var focus: Field?

    private enum Field { case account, password }

    private var windows: Bool { style != .mac }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(windows ? "Sign in to \(macName)" : "Log in to \(macName)").font(.title3.weight(.semibold))
                Text(windows
                     ? "Windows asks for your account's password, not your PIN. Passthrough passes it to Windows and keeps it on this \(ThisDevice.name) behind Face ID."
                     : "Use the name and password of your account on \(macName). Screen Sharing on the Mac checks them.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(PTTheme.warning)
                }
                VStack(spacing: 0) {
                    if !windows || editsAccount {
                        TextField(windows ? "Account name or email" : "Account name", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .account)
                            .padding(12)
                        Divider()
                    }
                    SecureField(windows && !username.isEmpty ? "Password for \(username)" : "Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .padding(12)
                        .onSubmit(connect)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Toggle("Remember on this \(ThisDevice.name)", isOn: $remember)
                    .font(.subheadline)
                    .tint(PTTheme.accentEnd)
                Text("Kept in this \(ThisDevice.name)'s Keychain behind Face ID, like your shell keys.")
                    .font(.caption).foregroundStyle(.secondary)
                if windows, !editsAccount {
                    Button("Use a different account") {
                        editsAccount = true
                        focus = .account
                    }
                    .font(.subheadline)
                }
                Button(action: connect) {
                    Text(windows ? "Sign in" : "Connect").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PTTheme.accentEnd)
                .disabled(username.isEmpty || password.isEmpty)
            }
            .padding(24)
        }
        .onAppear {
            if case let .windows(account) = style, let account, !account.isEmpty {
                username = account
                focus = .password
            } else {
                editsAccount = true
                focus = .account
            }
        }
    }

    private func connect() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty else { return }
        onConnect(ScreenLogin(username: name, password: password), remember)
    }
}
