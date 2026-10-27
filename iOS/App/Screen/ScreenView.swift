import SwiftUI
import PassthroughUI
import ScreenClient

/// The full-screen view of the selected Mac's screen: the Mac's login when
/// it's needed, then the screen with touch and keyboard controls. It's the
/// one view that turns to landscape, where its controls move to the side.
struct ScreenView: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject private var lock: AppLock
    @StateObject private var model = ScreenModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize
    @AppStorage("screenTouchMode") private var modeSetting = ScreenTouchMode.trackpad.rawValue
    @State private var keyboard = false

    private var mode: ScreenTouchMode { ScreenTouchMode(rawValue: modeSetting) ?? .trackpad }
    private var landscape: Bool { verticalSize == .compact }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // One layout that changes shape, so turning the phone keeps the same canvas
            // (its zoom, and its video display, which a new one would have to wait a keyframe for).
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if !landscape { topBar }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: landscape ? .vertical : [])
                if landscape { sideBar }
            }
        }
        .preferredColorScheme(.dark)
        .hiddenWhileCaptured { covered in
            if covered { keyboard = false }
        }
        .persistentSystemOverlays(landscape ? .hidden : .automatic)
        .task { model.begin(shell: shell, context: lock.context) }
        .onAppear { AppOrientation.allowed = .allButUpsideDown }
        .onDisappear {
            model.stop()
            AppOrientation.allowed = .portrait
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Done") { model.stop(); dismiss() }
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(model.macName).font(.subheadline.weight(.semibold)).lineLimit(1)
                if model.phase == .live {
                    if let slow = model.slowReason {
                        Text(slow).font(.caption2).foregroundStyle(PTTheme.warning).lineLimit(2).multilineTextAlignment(.center)
                    } else {
                        Text(mode == .trackpad ? "Drag to move · tap to click · hold to drag" : "Tap to click · hold to drag")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if model.phase == .live {
                clipboardMenu
                desktopsMenu
                modeButton
                keyboardButton
            }
        }
        .tint(PTTheme.accentEnd)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Landscape: the same controls in a column beside the screen. With the keyboard up
    /// there's only room for about three of them, so they pair up in two columns (the
    /// screen is letterboxed then, so the width is free) and scroll as a last resort.
    private var sideBar: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 6) {
                doneButton
                Spacer(minLength: 0)
                if model.phase == .live {
                    clipboardMenu
                    desktopsMenu
                    modeButton
                    keyboardButton
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    doneButton
                    if model.phase == .live {
                        HStack(spacing: 4) { clipboardMenu; desktopsMenu }
                        HStack(spacing: 4) { modeButton; keyboardButton }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .font(.title3)
        .tint(PTTheme.accentEnd)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }

    private var doneButton: some View {
        Button { model.stop(); dismiss() } label: { Image(systemName: "xmark").sideTarget(landscape) }
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

    private var keyboardButton: some View {
        Button { keyboard.toggle() } label: {
            Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                .sideTarget(landscape)
        }
        .accessibilityLabel(keyboard ? "Hide keyboard" : "Show keyboard")
    }

    /// Copy and paste between the Mac and this iPhone, also on the keyboard's key row.
    private var clipboardMenu: some View {
        Menu {
            Button { model.copyFromMac() } label: { Label("Copy from \(model.macName)", systemImage: "doc.on.doc") }
                .disabled(model.copying)
            Button { model.pastePhoneClipboard() } label: { Label("Paste on \(model.macName)", systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "doc.on.clipboard").sideTarget(landscape)
        }
        .accessibilityLabel("Copy and paste")
    }

    /// Mission Control: the same as the canvas's three-finger swipes.
    private var desktopsMenu: some View {
        Menu {
            Section("Or swipe with three fingers") {
                Button { model.perform(.previousDesktop) } label: { Label("Previous desktop", systemImage: "arrow.left.square") }
                Button { model.perform(.nextDesktop) } label: { Label("Next desktop", systemImage: "arrow.right.square") }
                Button { model.perform(.missionControl) } label: { Label("Mission Control", systemImage: "rectangle.3.group") }
                Button { model.perform(.appWindows) } label: { Label("App windows", systemImage: "macwindow.on.rectangle") }
            }
            Button { model.perform(.showDesktop) } label: { Label("Show desktop", systemImage: "menubar.dock.rectangle") }
        } label: {
            Image(systemName: "square.stack.3d.up").sideTarget(landscape)
        }
        .accessibilityLabel("Desktops and Mission Control")
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
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(model.macName)…").font(.subheadline).foregroundStyle(.secondary)
            }
        case let .login(error):
            ScreenLoginForm(macName: model.macName, error: error) { login, remember in
                model.connect(login, remember: remember)
            }
        case .confirmScreenSharing:
            ScreenSharingPrompt(macName: model.macName, reason: model.slowReason,
                                onUse: { model.useScreenSharing(always: $0) },
                                onCancel: { model.stop(); dismiss() })
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
    @ViewBuilder func sideTarget(_ on: Bool) -> some View {
        if on { frame(width: 44, height: 44).contentShape(Rectangle()) } else { self }
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
            Text("\(macName) can't stream its screen itself right now. Screen Sharing is slower and needs the name and password of your account on \(macName): the one saved on this iPhone, if there is one.")
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

/// The Mac account's name and password, which Screen Sharing on the Mac checks.
struct ScreenLoginForm: View {
    let macName: String
    let error: String?
    let onConnect: (RFBClient.Login, Bool) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Log in to \(macName)").font(.title3.weight(.semibold))
                Text("Use the name and password of your account on \(macName). Screen Sharing on the Mac checks them.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(PTTheme.warning)
                }
                VStack(spacing: 0) {
                    TextField("Account name", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(12)
                    Divider()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(12)
                        .onSubmit(connect)
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Toggle("Remember on this iPhone", isOn: $remember)
                    .font(.subheadline)
                    .tint(PTTheme.accentEnd)
                Text("Kept in this iPhone's Keychain behind Face ID, like your shell keys.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: connect) {
                    Text("Connect").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PTTheme.accentEnd)
                .disabled(username.isEmpty || password.isEmpty)
            }
            .padding(24)
        }
        .onAppear { focused = true }
    }

    private func connect() {
        guard !username.isEmpty, !password.isEmpty else { return }
        onConnect(RFBClient.Login(username: username, password: password), remember)
    }
}
