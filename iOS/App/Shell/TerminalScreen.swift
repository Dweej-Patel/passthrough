import Combine
import SwiftUI
import PassthroughCore
import PassthroughUI

/// What the terminal screen does once it knows its size.
enum TerminalIntent: Identifiable, Equatable {
    /// A new session; `shell` names one of the computer's shells (nil: its default).
    case new(shell: String?)
    case attach(String)

    var id: String {
        switch self {
        case .new: "new"
        case let .attach(session): "attach." + session
        }
    }
}

/// Connects the live terminal to `ShellModel`: shows one session at a time,
/// replaces what it shows with each (re)attach's replay once that is complete
/// (so replays don't stack, and aren't watched arriving), and forwards input
/// and size changes.
@MainActor
final class ShellTerminalController: ObservableObject {
    let driver = TerminalDriver(readOnly: false, scrollback: 10_000)
    private let shell: ShellModel
    /// The session whose output the terminal shows.
    @Published private(set) var shown: String?
    /// A program on the Mac just copied to this iPhone's clipboard: said briefly, since it happens unasked.
    @Published private(set) var copiedNotice = false
    /// A paste that would run as it arrives, waiting for the user's yes.
    @Published var pendingPaste: PendingPaste?
    private var noticeTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    /// The colours the terminal draws with now (the shown session's; nil: the app's own).
    private var theme: ShellTheme?
    /// An attach's replay, held until it is complete and then drawn in one go:
    /// fed as it arrives, the session is seen scrolling past from its top on
    /// every return to the app. Nil when what arrives is live.
    private var pendingReplay: Data?
    /// A replay has been awaited long enough to say so (a quick one is not announced).
    @Published private(set) var loadingReplay = false
    private var loadingTask: Task<Void, Never>?

    init(shell: ShellModel) {
        self.shell = shell
        shell.streamStarting
            .sink { [weak self] start in self?.show(start.session, replay: start.replay) }
            .store(in: &subscriptions)
        // What arrived since the attach was asked for was live output the replay
        // holds too (drawn, it would show twice). Also a second replay of the
        // session on screen (two attaches in a row): held like the first, and
        // drawn in its place.
        shell.replayStarting
            .sink { [weak self] id in
                guard let self, id == self.shown else { return }
                self.pendingReplay = Data()
                self.driver.replaying = true
            }
            .store(in: &subscriptions)
        shell.replayFinished
            .sink { [weak self] id in
                guard let self, id == self.shown else { return }
                self.finishReplay()
            }
            .store(in: &subscriptions)
        // The replay's end will not come (the connection dropped, another
        // device took the session, the attach was refused): draw what arrived.
        // `@Published` fires before the change lands: use the values it carries.
        shell.$reach.dropFirst()
            .sink { [weak self] reach in if reach != .ready { self?.finishReplay() } }
            .store(in: &subscriptions)
        shell.$detachedSession.dropFirst()
            .sink { [weak self] detached in
                guard let self, let detached, detached == self.shown else { return }
                self.finishReplay()
            }
            .store(in: &subscriptions)
        shell.$lastError.dropFirst()
            .sink { [weak self] error in if error != nil { self?.finishReplay() } }
            .store(in: &subscriptions)
        shell.output
            .sink { [weak self] session, data in
                guard let self, session == self.shown else { return }
                if self.pendingReplay != nil { self.pendingReplay?.append(data) } else { self.driver.feed(data) }
            }
            .store(in: &subscriptions)
        // The list can come after the session is shown (a session just opened).
        shell.$sessions
            .sink { [weak self] sessions in
                guard let self, let shown = self.shown, let info = sessions.first(where: { $0.id == shown }),
                      info.theme != self.theme else { return }
                self.theme = info.theme
                self.driver.apply(info.theme)
            }
            .store(in: &subscriptions)
        driver.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
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
        // Also with no session active yet, or an ended one shown: a new tab's
        // keyboard comes up before the Mac has opened it, and the Mac sizes
        // whatever this phone has attached (every tab shows here, at this size).
        driver.onResize = { [weak self] cols, rows in
            guard self != nil else { return }
            shell.resize(cols: cols, rows: rows)
        }
        driver.onClipboardCopy = { [weak self] in self?.showCopiedNotice() }
        driver.onConfirmPaste = { [weak self] lineBreaks, paste in
            self?.pendingPaste = PendingPaste(lineBreaks: lineBreaks, paste: paste)
        }
    }

    private func showCopiedNotice() {
        copiedNotice = true
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedNotice = false
        }
    }

    /// Runs the screen's opening request once the terminal has its real size.
    func start(_ intent: TerminalIntent) {
        driver.afterLayout { [weak self] cols, rows in
            guard let self else { return }
            switch intent {
            case let .new(shell): self.shell.newSession(cols: cols, rows: rows, shell: shell)
            case let .attach(id): self.shell.attach(id, cols: cols, rows: rows)
            }
            if !self.driver.readOnly { _ = self.driver.view.becomeFirstResponder() }
        }
    }

    func newSession(shell id: String? = nil) { shell.newSession(cols: driver.cols, rows: driver.rows, shell: id) }

    /// Shows `id`, attaching to it (and so taking it back from another device).
    func attach(_ id: String) { shell.attach(id, cols: driver.cols, rows: driver.rows) }

    /// Draws the held replay (all of it, or what arrived before it was cut short) in place of the screen.
    private func finishReplay() {
        loadingTask?.cancel()
        loadingReplay = false
        guard let replay = pendingReplay else { return }
        // Cleared and redrawn in one turn of the run loop: nothing in between is seen.
        pendingReplay = nil
        driver.reset()
        driver.feed(replay)
        driver.replaying = false
    }

    private func show(_ id: String, replay: Bool) {
        // The same session attached again (back from the background, a
        // reconnect): what is on screen stays until its replay replaces it.
        let keepScreen = replay && id == shown
        shown = id
        driver.replaying = false
        // Before anything is drawn: a Mac terminal's session in that terminal's colours.
        theme = shell.sessions.first { $0.id == id }?.theme
        driver.apply(theme)
        if !keepScreen { driver.reset() }
        pendingReplay = replay ? Data() : nil
        loadingTask?.cancel()
        loadingReplay = false
        if replay {
            loadingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.pendingReplay != nil else { return }
                self.loadingReplay = true
            }
        }
        driver.replaying = replay
        // An ended session's replay is its log: show it read-only.
        driver.setReadOnly(!shell.ended.isWritable(id, openTabs: shell.openTabs))
    }
}

/// A paste into a shell that would run each of its lines as they arrive.
struct PendingPaste: Identifiable {
    let id = UUID()
    let lineBreaks: Int
    let paste: () -> Void
}

/// The full-screen terminal: session tabs, the terminal and its key row.
struct TerminalScreen: View {
    @ObservedObject var shell: ShellModel
    let intent: TerminalIntent
    /// How to close it when it isn't in a SwiftUI presentation (it's presented through UIKit).
    var onClose: (() -> Void)?
    @StateObject private var controller: ShellTerminalController
    @Environment(\.dismiss) private var dismiss
    /// The tab being renamed, while the prompt is up.
    @State private var renaming: ShellSessionInfo?

    init(shell: ShellModel, intent: TerminalIntent, onClose: (() -> Void)? = nil) {
        self.shell = shell
        self.intent = intent
        self.onClose = onClose
        _controller = StateObject(wrappedValue: ShellTerminalController(shell: shell))
    }

    /// The tab on screen: the attached one, or the one another device took.
    private var current: String? { shell.activeSession ?? shell.detachedSession }

    var body: some View {
        ZStack {
            Color(controller.driver.background).ignoresSafeArea()
            VStack(spacing: 0) {
                tabStrip
                ZStack(alignment: .top) {
                    TerminalHost(driver: controller.driver)
                        .padding(.horizontal, 4)
                    VStack(spacing: 8) {
                        if let detached = shell.detachedSession, detached == current { detachedBanner(detached) }
                        if let id = controller.shown, let text = shell.ended.banner(id) { endedBanner(id, text: text) }
                        if let status = statusText { statusBanner(status) }
                        if shell.reach == .ready, controller.shown == nil, shell.detachedSession == nil, shell.lastError == nil {
                            statusBanner("Opening a session…", busy: true)
                        }
                        if shell.reach == .ready, controller.loadingReplay, shell.lastError == nil {
                            statusBanner("Loading session…", busy: true)
                        }
                        if let message = shell.lastError?.message { errorBanner(message) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .overlay(alignment: .bottom) {
                    if controller.copiedNotice { copiedBanner.transition(.opacity.combined(with: .move(edge: .bottom))) }
                }
                .animation(.easeInOut(duration: 0.2), value: controller.copiedNotice)
            }
        }
        .environment(\.colorScheme, .dark)
        .alert("Run what you paste?", isPresented: Binding(get: { controller.pendingPaste != nil },
                                                          set: { if !$0 { controller.pendingPaste = nil } }),
               presenting: controller.pendingPaste) { pending in
            Button("Paste and Run") { pending.paste() }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("This shell runs each line of a paste as soon as it arrives. The text has \(pending.lineBreaks == 1 ? "a line break" : "\(pending.lineBreaks) line breaks"), so it runs without a chance to check it first.")
        }
        .shellRenamePrompt($renaming, shell: shell)
        .hiddenWhileCaptured { covered in
            // Typing into a terminal no one can see would be blind.
            if covered { _ = controller.driver.view.resignFirstResponder() }
        }
        .onAppear {
            controller.start(intent)
            shell.setViewing(true)
        }
        .onDisappear { shell.setViewing(false) }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 10) {
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close terminal")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shell.openTabs, id: \.self) { id in
                            tab(id).id(id)
                        }
                        let shells = shell.shells(for: shell.selectedMacID)
                        let preferred = shell.preferredShell(for: shell.selectedMacID)
                        if shells.count > 1 {
                            // A tap opens the preferred shell; a long press chooses another.
                            Menu {
                                Section("Shells open as you, never as administrator.") {
                                    ForEach(shells, id: \.id) { item in
                                        Button(item.name) { controller.newSession(shell: item.id) }
                                    }
                                }
                            } label: {
                                Self.plusLabel
                            } primaryAction: {
                                controller.newSession(shell: preferred?.id)
                            }
                            .disabled(shell.reach != .ready)
                            .opacity(shell.reach == .ready ? 1 : 0.4)
                            .accessibilityLabel("New shell")
                            .accessibilityValue(preferred?.name ?? "")
                        } else {
                            Button { controller.newSession() } label: { Self.plusLabel }
                                .buttonStyle(.plain)
                                .disabled(shell.reach != .ready)
                                .opacity(shell.reach == .ready ? 1 : 0.4)
                                .accessibilityLabel("New shell")
                        }
                    }
                }
                .onChange(of: current) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
    }

    private func tab(_ id: String) -> some View {
        let info = shell.sessions.first { $0.id == id }
        let selected = id == current
        let isEnded = shell.ended.isEnded(id)
        let running = !isEnded && (info?.running ?? false)
        return Button {
            if id != shell.activeSession, shell.reach == .ready { controller.attach(id) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? Self.dotColor(info) : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(shell.title(of: id, fallback: info?.title ?? "Session"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .opacity(isEnded ? 0.55 : 1)
            .foregroundStyle(selected ? PTTheme.accentEnd : .secondary)
            .background(selected ? PTTheme.accentEnd.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // An ended tab stays enabled offline so its menu can remove it; selecting still needs the Mac.
        .disabled(shell.reach != .ready && !isEnded)
        .accessibilityValue(isEnded ? "Ended" : (selected ? "Selected" : ""))
        .accessibilityHint("Touch and hold for more")
        .contextMenu {
            if let info { Button { renaming = info } label: { Label("Rename", systemImage: "pencil") } }
            if isEnded {
                Button { closeTab(id) } label: { Label("Remove", systemImage: "trash") }
            } else {
                Button(role: .destructive) { shell.close(id) } label: { Label("End session", systemImage: "xmark") }
            }
        }
    }

    /// A running tab's dot: amber while it needs you, red when it failed
    /// unseen (what the program reports, e.g. Claude Code), else green.
    private static func dotColor(_ info: ShellSessionInfo?) -> Color {
        guard let info else { return PTTheme.success }
        if info.isAsking { return PTColor.attention }
        if let status = info.status, status.isUnseenResult, status.state == ShellStatus.error { return PTColor.problem }
        return PTTheme.success
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
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(text).font(.caption.weight(.semibold))
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        let shells = shell.shells(for: shell.selectedMacID)
                        controller.newSession(shell: shells.count > 1 ? shell.preferredShell(for: shell.selectedMacID)?.id : nil)
                    } label: {
                        Label("New shell", systemImage: "plus").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PTTheme.accentEnd)
                    .disabled(shell.reach != .ready)
                    Button { closeTab(id) } label: {
                        Text("Close tab").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
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
            close()
        }
    }

    private var macName: String {
        shell.macs.first { $0.macID == shell.selectedMacID }?.macName ?? shell.words.your
    }

    /// The tab strip's `+`.
    private static var plusLabel: some View {
        Image(systemName: "plus")
            .font(.caption.weight(.bold))
            .foregroundStyle(PTTheme.accentEnd)
            .frame(width: 34, height: 32)
            .background(PTTheme.accentEnd.opacity(0.16), in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var copiedBanner: some View {
        Label("Copied from \(macName)", systemImage: "doc.on.clipboard")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }

    private var statusText: String? {
        switch shell.reach {
        case .ready: nil
        case .connecting: shell.isRedialing ? "Reconnecting…" : "Connecting…"
        default: shell.reachMessage
        }
    }

    private func statusBanner(_ text: String, busy: Bool = false) -> some View {
        banner {
            if busy || shell.reach == .connecting { ProgressView().controlSize(.small) }
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
