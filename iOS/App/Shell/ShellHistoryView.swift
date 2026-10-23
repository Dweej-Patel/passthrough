import SwiftUI
import SwiftTerm
import PassthroughCore
import PassthroughUI

/// Every session the Mac recorded, newest first; each opens a read-only replay.
struct ShellHistoryView: View {
    @ObservedObject var shell: ShellModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PTBackground(glow: 0.45)
                ScrollView {
                    PTCard {
                        VStack(alignment: .leading, spacing: 8) {
                            PTSectionTitle("Sessions", icon: "clock.arrow.circlepath")
                                .padding(.bottom, 4)
                            if !shell.history.isEmpty {
                                let sorted = shell.history.sorted { $0.startedAt > $1.startedAt }
                                ForEach(sorted, id: \.id) { entry in
                                    NavigationLink(value: entry.id) { HistoryRow(entry: entry, running: isRunning(entry)) }
                                        .buttonStyle(.plain)
                                    if entry.id != sorted.last?.id { Divider().opacity(0.5) }
                                }
                            } else if shell.reach != .ready {
                                emptyState("Connect to your Mac to see its session history.", icon: "wifi.slash")
                            } else if !shell.historyLoaded {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Loading history…").font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                            } else {
                                emptyState("No sessions yet. Every session opened on this Mac is recorded here, newest first.", icon: "terminal")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { id in
                TranscriptScreen(shell: shell, entry: shell.history.first { $0.id == id })
            }
        }
        .onAppear { shell.loadHistory() }
    }

    private func emptyState(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func isRunning(_ entry: ShellHistoryEntry) -> Bool {
        entry.endedAt == nil && shell.sessions.contains { $0.id == entry.id && $0.running }
    }
}

private struct HistoryRow: View {
    let entry: ShellHistoryEntry
    let running: Bool

    private var started: Date { Date(timeIntervalSince1970: entry.startedAt) }

    private var status: (text: String, tint: SwiftUI.Color) {
        if running { return ("Running", PTTheme.success) }
        if entry.endedAt != nil {
            guard let code = entry.exitStatus else { return ("Ended", SwiftUI.Color.secondary) }
            return ("Exited \(code)", code == 0 ? SwiftUI.Color.secondary : PTTheme.warning)
        }
        return ("Interrupted", PTTheme.warning)
    }

    private var detail: String {
        "\(started.formatted(date: .abbreviated, time: .shortened)) · from \(entry.phoneLabel)"
    }

    var body: some View {
        HStack(spacing: 12) {
            PTStatusDot(color: running ? PTTheme.success : .secondary.opacity(0.5), live: running)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status.text).font(.caption.weight(.semibold)).foregroundStyle(status.tint)
                        .fixedSize()
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the recorded output")
    }
}

/// One session's recorded output in a read-only terminal, with find.
private struct TranscriptScreen: View {
    let shell: ShellModel
    let entry: ShellHistoryEntry?
    @StateObject private var driver = TerminalDriver(readOnly: true, scrollback: 100_000)
    @State private var phase: Phase = .loading
    @State private var replay: [ShellReplayChunk]?
    @State private var query = ""
    @State private var notFound = false

    private enum Phase { case loading, loaded, failed }

    var body: some View {
        ZStack {
            Color(TerminalStyle.background).ignoresSafeArea()
            VStack(spacing: 0) {
                searchBar
                ZStack {
                    if let replay {
                        ReplayTerminalHost(driver: driver, replay: replay).padding(.horizontal, 4)
                    }
                    switch phase {
                    case .loading: ProgressView()
                    case .failed:
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(PTTheme.warning)
                            Text("Couldn't load this session's output. Check that your Mac is reachable, then try again.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try again") {
                                phase = .loading
                                Task { await load() }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(PTTheme.accentEnd)
                        }
                        .padding(24)
                    case .loaded: EmptyView()
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        // The bar belongs to the light/dark sheet: match it to the terminal so its title stays legible.
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(SwiftUI.Color(TerminalStyle.background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(entry?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { find(forward: true) }
                    .onChange(of: query) { _, _ in notFound = false }
                if notFound { Text("Not found").font(.caption).foregroundStyle(.secondary) }
            }
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            Button { find(forward: false) } label: { Image(systemName: "chevron.up").font(.subheadline.weight(.bold)).frame(height: 22) }
                .accessibilityLabel("Previous match")
            Button { find(forward: true) } label: { Image(systemName: "chevron.down").font(.subheadline.weight(.bold)).frame(height: 22) }
                .accessibilityLabel("Next match")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(PTTheme.accentEnd)
        .disabled(phase != .loaded)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func find(forward: Bool) {
        guard !query.isEmpty else { return }
        let found = forward ? driver.view.findNext(query) : driver.view.findPrevious(query)
        notFound = !found
        if found { (driver.view.superview as? ReplayTerminalContainer)?.revealSelection() }
    }

    private func load() async {
        guard phase == .loading else { return }
        guard let entry, var chunks = await shell.transcript(entry.id) else {
            phase = .failed
            return
        }
        // An older Mac sends no sizes: the session's starting size, if it said.
        if ShellReplay.largestGrid(chunks) == nil, let cols = entry.cols, let rows = entry.rows,
           ShellReplay.isValid(cols: cols, rows: rows) {
            chunks.insert(.resize(cols: cols, rows: rows), at: 0)
        }
        replay = chunks
        phase = .loaded
    }
}

/// A read-only terminal showing a replay at the size the recording had, never
/// the screen's own: shells draw for their terminal's width (zsh relies on
/// autowrap at the right margin), so the same bytes at another width draw
/// something else. A recording narrower than the screen sits at the left; a
/// larger one gets a smaller font (down to `minimumFontSize`) and, past that,
/// scrolls sideways. Without sizes it fills the screen as before.
private struct ReplayTerminalHost: UIViewRepresentable {
    let driver: TerminalDriver
    let replay: [ShellReplayChunk]

    func makeUIView(context: Context) -> ReplayTerminalContainer {
        ReplayTerminalContainer(driver: driver, replay: replay)
    }

    func updateUIView(_ view: ReplayTerminalContainer, context: Context) {}

    static func dismantleUIView(_ view: ReplayTerminalContainer, coordinator: ()) {
        view.cancel()
    }
}

/// Scrolls sideways only; the terminal inside scrolls its own scrollback.
final class ReplayTerminalContainer: UIScrollView {
    static let chunkSize = 64 * 1024
    static let minimumFontSize: CGFloat = 7

    private let driver: TerminalDriver
    private var terminal: ShellTerminalView { driver.view }
    private let replay: [ShellReplayChunk]
    private let fixedGrid: Bool
    private var started = false
    private var cancelled = false

    init(driver: TerminalDriver, replay: [ShellReplayChunk]) {
        self.driver = driver
        self.replay = replay
        fixedGrid = ShellReplay.largestGrid(replay) != nil
        super.init(frame: .zero)
        backgroundColor = TerminalStyle.background
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        bounces = false
        isDirectionalLockEnabled = true
        contentInsetAdjustmentBehavior = .never
        driver.view.autoresizingMask = []
        addSubview(driver.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancel() { cancelled = true }

    /// Scrolls sideways, if needed, to show the selected text (a search match).
    func revealSelection() {
        guard fixedGrid, terminal.selectionActive, let selection = terminal.selection else { return }
        let cols = terminal.getTerminal().cols
        guard cols > 0 else { return }
        let cell = terminal.getOptimalFrameSize().width / CGFloat(cols)
        let first = min(selection.start.col, selection.end.col), last = max(selection.start.col, selection.end.col)
        let left = CGFloat(first) * cell, right = CGFloat(last + 1) * cell
        guard left < contentOffset.x || right > contentOffset.x + bounds.width else { return }
        let x = min(max(0, left - bounds.width / 3), max(0, contentSize.width - bounds.width))
        setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !started {
            started = true
            fitFont()
            place()
            feed(from: 0, offset: 0)
        } else {
            place()
        }
    }

    /// Shrinks the font, once and before feeding (a font change resizes
    /// SwiftTerm's grid to its frame), so the replay's largest grid fits.
    private func fitFont() {
        guard let largest = ShellReplay.largestGrid(replay) else { return }
        terminal.getTerminal().resize(cols: largest.cols, rows: largest.rows)
        let needed = terminal.getOptimalFrameSize().size
        let base = terminal.font.pointSize
        let scale = ShellReplay.fitScale(neededWidth: needed.width, neededHeight: needed.height,
                                         availableWidth: bounds.width, availableHeight: bounds.height,
                                         minimum: Self.minimumFontSize / base)
        guard scale < 1 else { return }
        terminal.frame = .zero   // so the font change keeps the grid
        terminal.font = UIFont.monospacedSystemFont(ofSize: max(Self.minimumFontSize, (base * scale + 1e-6).rounded(.down)), weight: .regular)
    }

    /// Exactly the grid's size (a little over, so SwiftTerm's own sizing from
    /// the frame lands on the same grid), or the whole view without sizes.
    private func place() {
        guard fixedGrid else {
            terminal.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
            return
        }
        let size = terminal.getOptimalFrameSize().size
        let frame = CGRect(x: 0, y: 0, width: size.width + 0.5, height: size.height + 0.5)
        if terminal.frame != frame { terminal.frame = frame }
        contentSize = CGSize(width: max(frame.width, bounds.width), height: bounds.height)
    }

    private func feed(from index: Int, offset: Int) {
        var index = index, offset = offset, budget = Self.chunkSize
        while !cancelled, index < replay.count, budget > 0 {
            switch replay[index] {
            case let .resize(cols, rows):
                let grid = terminal.getTerminal()
                if grid.cols != cols || grid.rows != rows {
                    grid.resize(cols: cols, rows: rows)
                    terminal.sizeChanged(source: grid)
                    place()
                    terminal.setNeedsDisplay()
                }
                index += 1
            case let .output(data):
                let end = min(offset + budget, data.count)
                driver.feed(data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)))
                budget -= end - offset
                if end == data.count { index += 1; offset = 0 } else { offset = end }
            }
        }
        guard !cancelled, index < replay.count else { return }
        DispatchQueue.main.async { [weak self] in self?.feed(from: index, offset: offset) }
    }
}
