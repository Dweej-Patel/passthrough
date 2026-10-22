import Combine
import SwiftUI
import PassthroughCore
import PassthroughUI

/// What the terminal screen does once it knows its size.
enum TerminalIntent: Identifiable, Equatable {
    case new
    case attach(String)

    var id: String {
        switch self {
        case .new: "new"
        case let .attach(session): "attach." + session
        }
    }
}

/// Connects the live terminal to `ShellModel`: shows one session at a time,
/// clears before each (re)attach so replays don't stack, and forwards input
/// and size changes.
@MainActor
final class ShellTerminalController: ObservableObject {
    let driver = TerminalDriver(readOnly: false, scrollback: 10_000)
    private let shell: ShellModel
    /// The session whose output the terminal shows.
    @Published private(set) var shown: String?
    private var subscriptions: Set<AnyCancellable> = []

    init(shell: ShellModel) {
        self.shell = shell
        shell.streamStarting
            .sink { [weak self] start in self?.show(start.session, replay: start.replay) }
            .store(in: &subscriptions)
        shell.replayFinished
            .sink { [weak self] id in
                guard let self, id == self.shown else { return }
                self.driver.replaying = false
            }
            .store(in: &subscriptions)
        shell.output
            .sink { [weak self] session, data in
                guard let self, session == self.shown else { return }
                self.driver.feed(data)
            }
            .store(in: &subscriptions)
        driver.onInput = { [weak self] data in
            guard let self, let active = shell.activeSession, active == self.shown else { return }
            shell.send(data)
        }
        // `@Published` fires before the change lands: use the values it carries.
        shell.$ended.combineLatest(shell.$openTabs)
            .sink { [weak self] ended, tabs in
                guard let self else { return }
                self.driver.setReadOnly(!ended.isWritable(self.shown, openTabs: tabs))
            }
            .store(in: &subscriptions)
        driver.onResize = { [weak self] cols, rows in
            guard self != nil, shell.activeSession != nil else { return }
            shell.resize(cols: cols, rows: rows)
        }
    }

    /// Runs the screen's opening request once the terminal has its real size.
    func start(_ intent: TerminalIntent) {
        driver.afterLayout { [weak self] cols, rows in
            guard let self else { return }
            switch intent {
            case .new: self.shell.newSession(cols: cols, rows: rows)
            case let .attach(id): self.shell.attach(id, cols: cols, rows: rows)
            }
            if !self.driver.readOnly { _ = self.driver.view.becomeFirstResponder() }
        }
    }

    func newSession() { shell.newSession(cols: driver.cols, rows: driver.rows) }

    /// Shows `id`, attaching to it (and so taking it back from another device).
    func attach(_ id: String) { shell.attach(id, cols: driver.cols, rows: driver.rows) }

    private func show(_ id: String, replay: Bool) {
        shown = id
        driver.replaying = false
        driver.reset()
        driver.replaying = replay
        // An ended session's replay is its log: show it read-only.
        driver.setReadOnly(!shell.ended.isWritable(id, openTabs: shell.openTabs))
    }
}

/// The full-screen terminal: session tabs, the terminal and its key row.
struct TerminalScreen: View {
    @ObservedObject var shell: ShellModel
    let intent: TerminalIntent
    @StateObject private var controller: ShellTerminalController
    @Environment(\.dismiss) private var dismiss

    init(shell: ShellModel, intent: TerminalIntent) {
        self.shell = shell
        self.intent = intent
        _controller = StateObject(wrappedValue: ShellTerminalController(shell: shell))
    }

    /// The tab on screen: the attached one, or the one another device took.
    private var current: String? { shell.activeSession ?? shell.detachedSession }

    var body: some View {
        ZStack {
            Color(TerminalStyle.background).ignoresSafeArea()
            VStack(spacing: 0) {
                tabStrip
                ZStack(alignment: .top) {
                    TerminalHost(driver: controller.driver)
                        .padding(.horizontal, 4)
                    VStack(spacing: 8) {
                        if let detached = shell.detachedSession, detached == current { detachedBanner(detached) }
                        if let id = controller.shown, let text = shell.ended.banner(id) { endedBanner(id, text: text) }
                        if let status = statusText { statusBanner(status) }
                        if let message = shell.lastError?.message { errorBanner(message) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { controller.start(intent) }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Close terminal")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shell.openTabs, id: \.self) { id in
                            tab(id).id(id)
                        }
                        Button { controller.newSession() } label: {
                            Image(systemName: "plus").font(.caption.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(PTTheme.accentEnd)
                        .controlSize(.small)
                        .disabled(shell.reach != .ready)
                        .accessibilityLabel("New session")
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: current) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tab(_ id: String) -> some View {
        let info = shell.sessions.first { $0.id == id }
        let selected = id == current
        let isEnded = shell.ended.isEnded(id)
        let running = !isEnded && (info?.running ?? false)
        return Button {
            if id != shell.activeSession { controller.attach(id) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? PTTheme.success : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(info?.title ?? "Session")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .opacity(isEnded ? 0.55 : 1)
            .foregroundStyle(selected ? PTTheme.accentEnd : .secondary)
            .background(selected ? PTTheme.accentEnd.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(shell.reach != .ready)
        .accessibilityValue(isEnded ? "Ended" : "")
        .contextMenu {
            if isEnded {
                Button { closeTab(id) } label: { Label("Close tab", systemImage: "xmark") }
            } else {
                Button(role: .destructive) { shell.close(id) } label: { Label("End session", systemImage: "xmark") }
            }
        }
    }

    // MARK: Banners

    private func detachedBanner(_ id: String) -> some View {
        banner {
            Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(PTTheme.warning)
            Text("Opened on another device").font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button { controller.attach(id) } label: {
                Text("Take back").font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(PTTheme.accentEnd)
            .controlSize(.small)
            .disabled(shell.reach != .ready)
        }
    }

    private func endedBanner(_ id: String, text: String) -> some View {
        banner {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text(text).font(.caption.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 8)
            Button { controller.newSession() } label: {
                Text("New session").font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(PTTheme.accentEnd)
            .controlSize(.small)
            .disabled(shell.reach != .ready)
            Button { closeTab(id) } label: {
                Text("Close tab").font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.secondary)
            .controlSize(.small)
        }
    }

    /// Closes `id`'s tab and shows another, or leaves the terminal when none is left.
    private func closeTab(_ id: String) {
        let wasShown = id == controller.shown
        shell.close(id)
        guard wasShown else { return }
        if let next = shell.openTabs.last {
            if shell.reach == .ready { controller.attach(next) }
        } else {
            dismiss()
        }
    }

    private var statusText: String? {
        switch shell.reach {
        case .ready: nil
        case .connecting: "Connecting…"
        default: shell.reachMessage
        }
    }

    private func statusBanner(_ text: String) -> some View {
        banner {
            if shell.reach == .connecting { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        banner {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PTTheme.warning)
            Text(text).font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
    }
}
