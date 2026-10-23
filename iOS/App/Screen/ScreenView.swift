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
                desktopsMenu
                modeButton
                keyboardButton
            }
        }
        .tint(PTTheme.accentEnd)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Landscape: the same controls in a column beside the screen.
    private var sideBar: some View {
        VStack(spacing: 22) {
            Button { model.stop(); dismiss() } label: { Image(systemName: "xmark") }
                .font(.body.weight(.semibold))
                .accessibilityLabel("Done")
            Spacer(minLength: 0)
            if model.phase == .live {
                desktopsMenu
                modeButton
                keyboardButton
            }
        }
        .font(.title3)
        .tint(PTTheme.accentEnd)
        .frame(width: 44)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }

    private var modeButton: some View {
        Button {
            modeSetting = (mode == .trackpad ? ScreenTouchMode.direct : .trackpad).rawValue
        } label: {
            Image(systemName: mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left")
        }
        .accessibilityLabel(mode == .trackpad ? "Trackpad mode. Switch to tapping where you click." : "Direct mode. Switch to trackpad.")
    }

    private var keyboardButton: some View {
        Button { keyboard.toggle() } label: {
            Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
        }
        .accessibilityLabel(keyboard ? "Hide keyboard" : "Show keyboard")
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
            Image(systemName: "square.stack.3d.up")
        }
        .accessibilityLabel("Desktops and Mission Control")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .live:
            ScreenCanvas(model: model, mode: mode, keyboard: $keyboard)
                .ignoresSafeArea(.container, edges: .bottom)
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(model.macName)…").font(.subheadline).foregroundStyle(.secondary)
            }
        case let .login(error):
            ScreenLoginForm(macName: model.macName, error: error) { login, remember in
                model.connect(login, remember: remember)
            }
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
