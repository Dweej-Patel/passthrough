import SwiftUI
import AppKit
import SwiftTerm
import PassthroughCore
import PassthroughUI
import ShellHost

/// Every recorded shell session, newest first, beside a read-only replay of
/// the selected one's output, drawn at the size the phone's terminal had.
struct ShellHistoryWindow: View {
    static let id = "shell-history"

    @EnvironmentObject private var shell: RemoteShellController
    @State private var selection: String?
    @State private var query = ""
    @State private var notFound = false
    /// The selected session's output, read once per selection, off the main actor.
    @State private var loaded: Transcript?
    @StateObject private var terminal = TerminalHandle()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(shell.history, id: \.id) { entry in
                    let recording = shell.isRecording(entry.id)
                    HistoryRow(entry: entry, recording: recording)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(entry.id) }.disabled(recording)
                        }
                        .swipeActions {
                            if !recording { Button("Delete", role: .destructive) { delete(entry.id) } }
                        }
                }
            }
            .onDeleteCommand { if let selection, !shell.isRecording(selection) { delete(selection) } }
            .overlay {
                if shell.history.isEmpty {
                    ContentUnavailableView("No Sessions Yet", systemImage: "apple.terminal",
                                           description: Text("Shells opened from your phone are recorded here."))
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            detail
                .navigationTitle(selectedEntry?.title ?? "Shell History")
                .navigationSubtitle(selectedEntry.map { "\($0.phoneLabel) · \(Date(timeIntervalSince1970: $0.startedAt).formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Find in session")
        .onSubmit(of: .search, findNext)
        .onChange(of: query) { _, _ in notFound = false }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if notFound { Text("Not found").font(.callout).foregroundStyle(.secondary) }
                Button(action: findNext) { Label("Find Next", systemImage: "arrow.down.circle") }
                    .disabled(query.isEmpty || selection == nil)
                    .help("Find the next match in this session (Return in the search field)")
                Button(role: .destructive) { if let selection { delete(selection) } } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection.map(shell.isRecording) ?? true)
                    .help(selection.map(shell.isRecording) == true ? "A running session can be deleted once it ends" : "Delete this session's recording")
            }
        }
        .frame(minWidth: 780, minHeight: 460)
        .onAppear { shell.refreshHistory() }
        // Cancelled and restarted whenever the selection changes.
        .task(id: selection) {
            notFound = false
            guard let id = selection else { loaded = nil; return }
            if case .ready(id, _) = loaded { return }
            loaded = nil
            let output = await shell.transcript(id)
            guard !Task.isCancelled, selection == id else { return }
            loaded = output.map { .ready(id, $0) } ?? .failed(id)
        }
    }

    private var selectedEntry: ShellHistoryEntry? {
        selection.flatMap { id in shell.history.first { $0.id == id } }
    }

    @ViewBuilder private var detail: some View {
        if let selection, case .ready(selection, let replay) = loaded {
            TranscriptView(replay: replay, handle: terminal)
                .id(selection)   // a fresh terminal per session
        } else if let selection, case .failed(selection) = loaded {
            ContentUnavailableView("Can't Read This Session", systemImage: "exclamationmark.triangle",
                                   description: Text("Its recording is missing or damaged."))
        } else if selection != nil {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a Session", systemImage: "sidebar.left",
                                   description: Text("Its output appears here as the phone's terminal showed it."))
        }
    }

    private enum Transcript {
        case ready(String, [ShellReplayChunk])
        case failed(String)
    }

    private func findNext() {
        guard !query.isEmpty, let view = terminal.view else { return }
        notFound = !view.findNext(query)
    }

    private func delete(_ id: String) {
        if selection == id { selection = nil }
        shell.deleteHistory(id)
    }
}

private struct HistoryRow: View {
    let entry: ShellHistoryEntry
    /// Still running (an entry without an end that isn't was cut short, e.g. by a crash).
    let recording: Bool

    private var started: Date { Date(timeIntervalSince1970: entry.startedAt) }

    private var duration: String {
        guard let ended = entry.endedAt else { return recording ? "Running" : "Interrupted" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, ended - entry.startedAt)) ?? ""
    }

    private var status: String? {
        guard entry.endedAt != nil else { return nil }
        return entry.exitStatus.map { "exit \($0)" } ?? "ended"
    }

    /// A non-zero exit or a session cut short stands out; a clean one doesn't.
    private var statusColor: SwiftUI.Color {
        if recording { return PTTheme.success }
        guard entry.endedAt != nil else { return PTTheme.warning }
        return (entry.exitStatus ?? 0) == 0 ? .secondary : PTTheme.warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if recording {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(PTTheme.success, in: Capsule())
                }
            }
            Text("\(entry.phoneLabel) · \(started.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text([duration, status].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(statusColor)
        }
        .padding(.vertical, 3)
    }
}

/// The terminal shown, for search.
@MainActor
final class TerminalHandle: ObservableObject {
    weak var view: TerminalView?
}

/// A SwiftTerm terminal fed one recorded session's output. Nothing typed into
/// it goes anywhere: it has no delegate.
private struct TranscriptView: NSViewRepresentable {
    let replay: [ShellReplayChunk]
    let handle: TerminalHandle

    func makeNSView(context: Context) -> ReplayTerminalContainer {
        let container = ReplayTerminalContainer(replay: replay)
        handle.view = container.terminal
        return container
    }

    func updateNSView(_ container: ReplayTerminalContainer, context: Context) {
        handle.view = container.terminal
    }

    static func dismantleNSView(_ container: ReplayTerminalContainer, coordinator: ()) {
        container.cancel()
    }
}

/// Holds the replay's terminal at the size the recording had, never the
/// pane's own: shells draw for their terminal's width (zsh relies on autowrap
/// at the right margin), so the same bytes at another width draw something
/// else. The terminal sits at the top left with the rest of the pane blank; if
/// the largest size in the replay does not fit, the font is made smaller (once,
/// before feeding: a font change resizes SwiftTerm's grid to its frame).
///
/// Output is fed a chunk per runloop turn so a long transcript does not freeze
/// the window; the feed stops when the view goes away (the selection changed).
@MainActor
final class ReplayTerminalContainer: NSView {
    static let chunkSize = 256 * 1024
    /// Smallest font the fit shrinks to; a larger recording is clipped on the right.
    static let minimumFontSize: CGFloat = 8

    let terminal: TerminalView
    private let replay: [ShellReplayChunk]
    /// The replay carries sizes: the grid is the recording's, not the frame's.
    private let fixedGrid: Bool
    private var started = false
    private var cancelled = false

    init(replay: [ShellReplayChunk]) {
        var options = TerminalOptions.default
        options.scrollback = 100_000
        terminal = TerminalView(frame: .zero, font: nil, options: options)
        self.replay = replay
        fixedGrid = ShellReplay.largestGrid(replay) != nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        terminal.autoresizingMask = []
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func cancel() { cancelled = true }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !started {
            started = true
            fitFont()
            feed(from: 0, offset: 0)
        }
        place()
    }

    /// Shrinks the font, if needed, so the largest grid the replay takes fits the pane.
    private func fitFont() {
        guard let largest = ShellReplay.largestGrid(replay) else { return }
        terminal.getTerminal().resize(cols: largest.cols, rows: largest.rows)
        let needed = terminal.getOptimalFrameSize().size
        let base = terminal.font.pointSize
        let scale = ShellReplay.fitScale(neededWidth: needed.width, neededHeight: needed.height,
                                         availableWidth: bounds.width, availableHeight: bounds.height,
                                         minimum: Self.minimumFontSize / base)
        // The terminal has no frame yet, so this does not resize its grid.
        if scale < 1, let font = NSFont(descriptor: terminal.font.fontDescriptor, size: max(Self.minimumFontSize, (base * scale + 1e-6).rounded(.down))) {
            terminal.font = font
        }
    }

    /// Exactly the grid's size (a little over, so SwiftTerm's own sizing from
    /// the frame lands on the same grid), or the whole pane without sizes.
    private func place() {
        guard fixedGrid else { terminal.frame = bounds; return }
        let size = terminal.getOptimalFrameSize().size
        terminal.frame = CGRect(x: 0, y: 0, width: size.width + 0.5, height: size.height + 0.5)
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
                    terminal.needsDisplay = true
                }
                index += 1
            case let .output(data):
                let end = min(offset + budget, data.count)
                terminal.feed(byteArray: ArraySlice([UInt8](data[(data.startIndex + offset)..<(data.startIndex + end)])))
                budget -= end - offset
                if end == data.count { index += 1; offset = 0 } else { offset = end }
            }
        }
        guard !cancelled, index < replay.count else { return }
        DispatchQueue.main.async { [weak self] in self?.feed(from: index, offset: offset) }
    }
}
