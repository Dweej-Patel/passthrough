#if os(macOS)
import Foundation
import PassthroughCore

/// Whoever is looking at a session right now. Called on a private queue, never
/// while the manager holds its own, so an implementation may call back in.
public protocol ShellAttachment: AnyObject, Sendable {
    func shellOutput(_ data: Data, session: String)
    func shellEnded(session: String, exitStatus: Int32)
    /// Another client attached to the session and took it over. `generation` is
    /// that of the attach that returned it: a notice queued before the client
    /// attached again belongs to the older attach.
    func shellDetached(session: String, generation: UInt64)
    /// The scrollback replay for an attach comes next: output handed over
    /// before this was live, and is in the replay too.
    func shellReplaying(session: String)
    /// The scrollback replay for an attach has been handed over; what follows is live.
    func shellReplayed(session: String)
    /// Someone is looking at what this client shows: a result that arrives
    /// then (Claude Code's "done") is seen. A phone says so; a terminal
    /// window on the Mac is on its screen.
    var isLooking: Bool { get }
}

public extension ShellAttachment {
    func shellReplaying(session: String) {}
    func shellReplayed(session: String) {}
    var isLooking: Bool { true }
}

/// Where a session was started: by a phone, or in a terminal window on the Mac.
public enum ShellSessionOrigin: String, Sendable {
    case phone, mac
}

/// A live session as the Mac itself shows it: who is looking at it right now.
public struct ShellSessionDetail: Equatable, Sendable, Identifiable {
    public var info: ShellSessionInfo
    public var origin: ShellSessionOrigin
    /// A phone is attached.
    public var phoneAttached: Bool
    /// Terminal windows on the Mac showing it.
    public var macViewers: Int
    /// The phone or computer that opened it (its shell id); nil for one of this Mac's own terminals.
    public var openedBy: String? = nil
    public var id: String { info.id }
}

/// The Mac's interactive shell sessions. They keep running while nothing is
/// attached; a client that attaches is replayed the recent output, and a later
/// attach takes the session over. A terminal on the Mac attaches as a viewer
/// instead (`shared`): it sees and types into the session beside whoever is
/// attached, and neither takes it from the other.
public final class ShellSessionManager: @unchecked Sendable {
    /// Fires after the session list changes. Called off the manager's queue.
    public var onChange: (@Sendable () -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    /// Fires as a session's `status` changes in a way anyone shows (its state,
    /// kind, agents, whether it was seen, a blocked one's question), and as
    /// the session ends, with the session as it is then and whether someone
    /// is looking at it: what happened, not what is left of it by the time a
    /// list is read. Called off the manager's queue, in order.
    public var onStatusChange: (@Sendable (_ session: ShellSessionInfo, _ looking: Bool) -> Void)? {
        get { queue.sync { statusHandler } }
        set { queue.sync { statusHandler = newValue } }
    }

    /// Fires after who is looking at a session changes (`details`). Called off the manager's queue.
    public var onViewersChange: (@Sendable () -> Void)? {
        get { queue.sync { viewersHandler } }
        set { queue.sync { viewersHandler = newValue } }
    }

    enum InputEscape { case none, escape, csi, ss3 }

    /// A terminal on the Mac showing a session beside its attachment.
    private struct Viewer {
        let client: ShellAttachment
        var size: Size
    }

    private struct Size: Equatable {
        var cols: UInt16
        var rows: UInt16
    }

    private final class Session {
        let id: String
        let startedAt: Date
        /// The phone that opened it, so revoking that phone ends it; any
        /// authorized phone may still attach to it meanwhile.
        let openedBy: String?
        let origin: ShellSessionOrigin
        /// The colours of the Mac terminal window it was started in.
        var theme: ShellTheme?
        let process: PTYProcess
        let writer: TranscriptWriter
        var scrollback = ScrollbackBuffer(capacity: RemoteShell.scrollbackBytes)
        var title = "~"
        var typed = Data()          // the line being typed, until the title is known
        var titleKnown = false
        /// Output bytes received so far, to find what arrived since a point.
        var outputCount = 0
        /// `outputCount` when the line in `typed` started.
        var lineStart: Int?
        /// Where the input is inside an escape sequence (arrow keys and the like).
        var inputEscape = InputEscape.none
        /// A typed line waiting to be seen echoed before it becomes the title:
        /// the text, where its output starts, and until when it may show up.
        var pendingTitle: (text: String, from: Int, until: Int)?
        var lastOutputAt: Date
        /// The last few KB of output since the last input, to look for a
        /// question once it goes quiet. Input empties it: an answered
        /// question must not be found again on the screen above the prompt.
        var tail = Data()
        /// The question it seems to be waiting on (`ShellQuestion`); nil once input answers it.
        var waiting: String?
        /// What the program in front says about itself (OSC 7501), and the
        /// sum of it phones see; nil for a plain shell.
        var programStatus = ProgramStatus()
        var status: ShellStatus?
        /// The foreground job (process group) when the program first reported:
        /// once that group is gone, so is everything it said.
        var statusOwner: pid_t?
        /// The arguments the session's shell started with (the program first):
        /// once they differ, the shell `exec`ed another program.
        var shellArguments: [String] = []
        /// A `redraw` is under way.
        var redrawing = false
        /// Looked for a question since the last output.
        var checkedSinceOutput = true
        /// A look is already scheduled; output meanwhile pushes it back.
        var lookScheduled = false
        var exitStatus: Int32?
        var running = true
        var attachment: ShellAttachment?
        /// What `attach` returned for `attachment`.
        var generation: UInt64 = 0
        /// The terminal size `attachment` last asked for.
        var attachmentSize: Size?
        /// Terminals on the Mac showing the session too.
        var viewers: [Viewer] = []
        /// Whoever attached or typed last: the terminal's size follows it.
        var active: ObjectIdentifier?
        /// The size the terminal has now.
        var size: Size
        /// Viewers that can't take more output yet: reading the shell waits for them.
        var pausedBy: Set<ObjectIdentifier> = []

        init(id: String, startedAt: Date, openedBy: String?, origin: ShellSessionOrigin, theme: ShellTheme?, process: PTYProcess,
             writer: TranscriptWriter, size: Size) {
            self.id = id; self.startedAt = startedAt; self.openedBy = openedBy; self.origin = origin; self.theme = theme
            self.process = process; self.writer = writer; self.size = size
            lastOutputAt = startedAt
        }

        var info: ShellSessionInfo {
            ShellSessionInfo(id: id, title: title, startedAt: startedAt.timeIntervalSince1970,
                             lastOutputAt: lastOutputAt.timeIntervalSince1970, running: running, exitStatus: exitStatus,
                             waiting: running ? question : nil, origin: origin == .mac ? ShellSessionInfo.originMac : nil,
                             theme: theme, status: running ? status : nil)
        }

        /// The question it waits on: what the program says when it reports
        /// its status (nothing while it isn't blocked), else what its screen
        /// seems to ask.
        var question: String? {
            guard let status else { return waiting }
            return status.isBlocked ? (status.message ?? "Needs you") : nil
        }

        /// Everyone output goes to.
        var clients: [ShellAttachment] { (attachment.map { [$0] } ?? []) + viewers.map(\.client) }
    }

    /// For tests: the session object, to check it is freed once pruned.
    func sessionObject(_ id: String) -> AnyObject? { queue.sync { table[id] } }
    /// For tests: the generation of the session's current attachment.
    func attachmentGeneration(_ id: String) -> UInt64? { queue.sync { table[id]?.attachment == nil ? nil : table[id]?.generation } }
    /// For tests: holds back every attachment callback until resumed.
    func suspendCallouts() { callouts.suspend() }
    func resumeCallouts() { callouts.resume() }

    private static let titleLimit = 60
    /// How much output after a typed line's return may still carry its echo.
    private static let echoWindow = 2048
    private static let typedLimit = 512
    private static let closeTimeout: TimeInterval = 5
    /// How long `redraw` leaves the terminal shorter: long enough for the
    /// program to read the size while it is different.
    static let redrawPause: TimeInterval = 0.25

    private let transcripts: TranscriptStore
    private let command: () -> (String, [String])
    private let environment: () -> [String: String]
    private let directory: URL
    private let endedRetention: TimeInterval
    /// How long output must stay quiet before the last lines are read for a question.
    private let quietBeforeAsking: TimeInterval
    private static let tailBytes = 4096

    /// Guards everything below.
    private let queue = DispatchQueue(label: "passthrough.shell.sessions")
    /// Where attachments and `onChange` are called, in the order they were queued.
    private let callouts = DispatchQueue(label: "passthrough.shell.callouts")
    private var table: [String: Session] = [:]
    private var order: [String] = []
    /// Sessions `open` is starting outside the queue, counted toward the cap.
    private var opening: [ShellSessionOrigin: Int] = [:]
    /// Numbers every attach, so a late detach can be told from a current one.
    private var lastGeneration: UInt64 = 0
    private var changeHandler: (@Sendable () -> Void)?
    private var statusHandler: (@Sendable (ShellSessionInfo, Bool) -> Void)?
    private var viewersHandler: (@Sendable () -> Void)?
    private var fallbackTheme: ShellTheme?

    public init(transcripts: TranscriptStore,
                command: @escaping () -> (String, [String]) = { LoginShell.command() },
                environment: @escaping () -> [String: String] = { LoginShell.environment() },
                directory: URL = FileManager.default.homeDirectoryForCurrentUser,
                endedRetention: TimeInterval = 600,
                quietBeforeAsking: TimeInterval = 1.5) {
        self.transcripts = transcripts
        self.command = command
        self.environment = environment
        self.directory = directory
        self.endedRetention = endedRetention
        self.quietBeforeAsking = quietBeforeAsking
    }

    public var sessions: [ShellSessionInfo] {
        queue.sync { order.compactMap { table[$0] }.map { themed($0.info) } }
    }

    /// The colours of the last terminal window on the Mac that told them: a
    /// session with none of its own (one a phone started) is listed with
    /// these, so every session looks on the phone as terminals do on the Mac.
    public var defaultTheme: ShellTheme? {
        get { queue.sync { fallbackTheme } }
        set { queue.sync { fallbackTheme = newValue?.sanitized } }
    }

    private func themed(_ info: ShellSessionInfo) -> ShellSessionInfo {
        guard info.theme == nil, let fallbackTheme else { return info }
        var info = info
        info.theme = fallbackTheme
        return info
    }

    /// The sessions with who is looking at each, for the Mac's own list.
    public var details: [ShellSessionDetail] {
        queue.sync {
            order.compactMap { table[$0] }.map {
                ShellSessionDetail(info: themed($0.info), origin: $0.origin, phoneAttached: $0.attachment != nil, macViewers: $0.viewers.count,
                                   openedBy: $0.openedBy)
            }
        }
    }

    /// Starts a login shell. The spawn and the transcript's first write happen
    /// outside the manager's queue, so listing or using other sessions never
    /// waits on them; a slot is held meanwhile so the cap still holds.
    /// `phoneID` is the phone opening it (`closeSessions(openedBy:)`).
    ///
    /// A terminal on the Mac opens one with `origin: .mac`, its own
    /// environment and its folder, so the shell starts as that terminal's
    /// own would have. Those have a cap of their own
    /// (`RemoteShell.maxMacSessions`) and never use up the phones' sessions.
    public func open(phoneLabel: String, phoneID: String? = nil, cols: Int, rows: Int,
                     origin: ShellSessionOrigin = .phone, environment given: [String: String]? = nil,
                     directory givenDirectory: URL? = nil, theme: ShellTheme? = nil) throws -> String {
        try queue.sync {
            // Ended ones of the same kind make room; a phone's stay listed for
            // their time (`endedRetention`) however many terminals open on the Mac.
            for id in order where table[id]?.running == false && table[id]?.origin == origin { remove(id) }
            let running = table.values.filter { $0.running && $0.origin == origin }.count + (opening[origin] ?? 0)
            guard running < (origin == .mac ? RemoteShell.maxMacSessions : RemoteShell.maxSessions) else { throw ShellError.tooManySessions }
            opening[origin, default: 0] += 1
        }
        var reserved = true
        defer { if reserved { queue.sync { opening[origin, default: 0] -= 1 } } }

        let id = UUID().uuidString
        let now = Date()
        let (executable, arguments) = command()
        // Every session says it is one, so a shell started inside it never asks for another (`TerminalHook`).
        var environment = given ?? environment()
        environment[RemoteShell.sessionVariable] = id
        let size = Size(cols: Self.dimension(cols), rows: Self.dimension(rows))
        let process = try PTYProcess(executable: executable, arguments: arguments, directory: givenDirectory ?? directory,
                                     environment: environment, cols: size.cols, rows: size.rows)
        let writer: TranscriptWriter
        do {
            writer = try transcripts.begin(id: id, title: "~", phoneLabel: phoneLabel, cols: cols, rows: rows, at: now)
        } catch {
            process.terminate()   // never started; dropping it hangs up and reaps
            throw error
        }
        let session = Session(id: id, startedAt: now, openedBy: phoneID, origin: origin, theme: theme?.sanitized, process: process, writer: writer, size: size)
        session.shellArguments = [executable] + arguments
        // Weak: the session owns the process, so a strong capture would be a cycle that leaks every session.
        process.onOutput = { [weak self, weak session] data in
            self?.queue.async { if let session { self?.received(data, session: session) } }
        }
        process.onExit = { [weak self, weak session] status in
            self?.queue.async { if let session { self?.ended(session, status: status) } }
        }
        queue.sync {
            opening[origin, default: 0] -= 1
            reserved = false
            table[id] = session
            order.append(id)
            if let theme = session.theme { fallbackTheme = theme }
            process.start()
            ptLog(.info, "shell: opened session")
            notifyChange()
        }
        return id
    }

    /// Replays the scrollback to `client`, then streams live output to it. A client
    /// attached earlier is told it was detached, with the generation its own
    /// attach returned. Returns this attach's generation, unique per manager.
    ///
    /// `shared` is a terminal on the Mac: it is added beside the attachment,
    /// takes nothing over and is never taken over (`detach` removes it).
    /// Either way the terminal takes this client's size, until someone else types.
    @discardableResult
    public func attach(_ id: String, client: ShellAttachment, cols: Int, rows: Int, shared: Bool = false) throws -> UInt64 {
        try queue.sync {
            guard let session = table[id] else { throw ShellError.noSuchSession }
            lastGeneration += 1
            let generation = lastGeneration
            let size = Size(cols: Self.dimension(cols), rows: Self.dimension(rows))
            if !shared, let previous = session.attachment, previous !== client {
                let old = session.generation
                callouts.async { previous.shellDetached(session: id, generation: old) }
            }
            // A Mac window joining a session someone else is using leaves its
            // size alone until someone types in the window: resizing redraws
            // the prompt, which can wipe the lines the window is about to be shown.
            let joins = shared && session.active != nil && session.active != ObjectIdentifier(client)
            let sizeBefore = session.size
            if session.running, !joins {
                session.active = ObjectIdentifier(client)
                resize(session, to: size)
            }
            let replay = session.scrollback.replay
            // A full-screen program replayed from partway: what it drew before
            // the cut isn't in the replay, so have it draw its screen again,
            // unless taking this client's size already does. Also for a Mac
            // window joining: on the alternate screen there is no prompt to wipe.
            let resized = !joins && size != sizeBefore
            if session.running, !resized,
               session.scrollback.isPartial, session.scrollback.modes.isAlternateScreen {
                redraw(session)
            }
            callouts.async { client.shellReplaying(session: id) }
            var offset = 0
            while offset < replay.count {
                let chunk = Data(replay[(replay.startIndex + offset)..<(replay.startIndex + min(offset + RemoteShell.outputChunk, replay.count))])
                offset += chunk.count
                callouts.async { client.shellOutput(chunk, session: id) }
            }
            callouts.async { client.shellReplayed(session: id) }
            if session.running, client.isLooking { markResultSeen(session) }
            if session.running, shared {
                session.viewers.removeAll { $0.client === client }
                session.viewers.append(Viewer(client: client, size: size))
                notifyViewers()
            } else if session.running {
                session.attachment = client
                session.generation = generation
                session.attachmentSize = size
                notifyViewers()
            } else if let status = session.exitStatus {
                callouts.async { client.shellEnded(session: id, exitStatus: status) }
            }
            return generation
        }
    }

    /// Stops sending to `client` without telling it.
    public func detach(client: ShellAttachment) {
        queue.sync {
            var changed = false
            for session in table.values {
                if session.attachment === client {
                    session.attachment = nil
                    session.attachmentSize = nil
                    changed = true
                }
                if session.viewers.contains(where: { $0.client === client }) {
                    session.viewers.removeAll { $0.client === client }
                    changed = true
                }
                if session.active == ObjectIdentifier(client) { followNext(session) }
                release(session, from: client)
            }
            if changed { notifyViewers() }
        }
    }

    /// `client` (a phone) has its terminal on screen now: a result waiting
    /// in what it shows is seen.
    public func lookedAt(client: ShellAttachment) {
        queue.async { [self] in
            for session in table.values where session.attachment === client || session.viewers.contains(where: { $0.client === client }) {
                markResultSeen(session)
            }
        }
    }

    /// `client` is who typed it, when known: the terminal takes that client's
    /// size if it isn't already the one it follows.
    ///
    /// What a terminal sends by itself (`TerminalReports`: its answers to a
    /// program's questions, focus in and out) is not typing: it never moves
    /// the session to that terminal, and from a terminal the session doesn't
    /// follow it is dropped, as the one it follows answers too.
    public func input(_ id: String, _ data: Data, from client: ShellAttachment? = nil) {
        queue.async { [self] in
            guard let session = table[id], session.running else { return }
            var data = TerminalReports.removingProgramStatusReplies(from: data)
            let typed = TerminalReports.removing(from: data)
            if let client {
                let followed = session.active == nil || session.active == ObjectIdentifier(client)
                if !followed { data = typed }
                if !typed.isEmpty, session.active != ObjectIdentifier(client), let size = size(of: client, in: session) {
                    session.active = ObjectIdentifier(client)
                    if size != session.size { resize(session, to: size) }
                }
            }
            guard !data.isEmpty else { return }
            session.process.write(data)
            // A terminal's answers alone: nobody typed, so nothing was answered either.
            guard !typed.isEmpty else { return }
            markResultSeen(session)
            if !session.titleKnown { learnTitle(from: typed, session: session) }
            // Someone answered: it isn't waiting any more, and only what
            // comes next can ask again.
            session.tail.removeAll(keepingCapacity: true)
            if session.waiting != nil {
                session.waiting = nil
                notifyChange()
            }
        }
    }

    /// `client` is whose terminal changed size, when known. Its size is
    /// remembered; the session's terminal takes it only while that client is
    /// the one it follows (the last to attach or type), so a phone turning
    /// does not redraw what someone is typing into on the Mac.
    public func resize(_ id: String, cols: Int, rows: Int, from client: ShellAttachment? = nil) {
        queue.async { [self] in
            guard let session = table[id], session.running else { return }
            let size = Size(cols: Self.dimension(cols), rows: Self.dimension(rows))
            if let client {
                if session.attachment === client { session.attachmentSize = size }
                if let index = session.viewers.firstIndex(where: { $0.client === client }) { session.viewers[index].size = size }
                guard session.active == nil || session.active == ObjectIdentifier(client) else { return }
            }
            resize(session, to: size)
        }
    }

    /// The colours of the terminal window on the Mac a session was started
    /// in, once the window has told them: phones hear of it in the list.
    public func setTheme(_ id: String, _ theme: ShellTheme) {
        queue.async { [self] in
            guard let session = table[id], session.running, let theme = theme.sanitized, theme != session.theme else { return }
            session.theme = theme
            fallbackTheme = theme
            notifyChange()
            notifyViewers()
        }
    }

    /// A viewer that writes to a terminal on the Mac has (`paused`) or no
    /// longer has more output waiting than it should hold: the shell is not
    /// read meanwhile, so it waits as it would on a slow terminal instead of
    /// the Mac buffering its output without end.
    public func setOutputPaused(_ id: String, _ paused: Bool, by client: ShellAttachment) {
        queue.async { [self] in
            guard let session = table[id], session.running else { return }
            if paused {
                guard session.viewers.contains(where: { $0.client === client }) else { return }
                if session.pausedBy.insert(ObjectIdentifier(client)).inserted, session.pausedBy.count == 1 {
                    session.process.setReadingPaused(true)
                }
            } else {
                release(session, from: client)
            }
        }
    }

    /// Hangs up the session's shell; it ends through the normal exit path.
    public func close(_ id: String) {
        queue.async { [self] in
            guard let session = table[id], session.running else { return }
            session.process.terminate()
        }
    }

    /// Hangs up every running session `phoneID` opened (it was revoked). They
    /// end through the normal exit path; sessions other phones opened stay,
    /// even ones this phone was attached to.
    public func closeSessions(openedBy phoneID: String) {
        queue.async { [self] in
            for session in table.values where session.running && session.openedBy == phoneID {
                session.process.terminate()
            }
        }
    }

    /// Ends every session and returns once their transcripts are finished (or
    /// after a few seconds, if a process will not die).
    public func closeAll() {
        queue.sync { for session in table.values where session.running { session.process.terminate() } }
        let deadline = Date().addingTimeInterval(Self.closeTimeout)
        while queue.sync(execute: { table.values.contains { $0.running } }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: Queue-confined

    /// Resizes the PTY, and records the size so a replay draws what follows at it.
    private func resize(_ session: Session, to size: Size) {
        session.size = size
        session.process.resize(cols: size.cols, rows: size.rows)
        session.writer.resize(cols: Int(size.cols), rows: Int(size.rows), at: Date())
    }

    /// Has the program draw its whole screen again. Programs do that when
    /// the size changes, and only then (a SIGWINCH alone, at the same size,
    /// is ignored), so the terminal is one row shorter for a moment.
    private func redraw(_ session: Session) {
        // One at a time: a second would take the shorter size for the real one.
        guard !session.redrawing else { return }
        let size = session.size
        guard size.rows > 1 else { return }
        let shorter = Size(cols: size.cols, rows: size.rows - 1)
        session.redrawing = true
        resize(session, to: shorter)
        queue.asyncAfter(deadline: .now() + Self.redrawPause) { [weak session, self] in
            guard let session else { return }
            session.redrawing = false
            // Unless someone's terminal changed size meanwhile: that size stands.
            guard session.running, session.size == shorter else { return }
            resize(session, to: size)
        }
    }

    /// The client the session followed is gone: it follows whoever is left
    /// (the attachment, else the Mac window that came last) at that one's
    /// size, so what that terminal shows isn't drawn for one that isn't there.
    private func followNext(_ session: Session) {
        session.active = nil
        let next: (ShellAttachment, Size)?
        if let attachment = session.attachment, let size = session.attachmentSize {
            next = (attachment, size)
        } else if let viewer = session.viewers.last {
            next = (viewer.client, viewer.size)
        } else {
            next = nil
        }
        guard let (client, size) = next, session.running else { return }
        session.active = ObjectIdentifier(client)
        if size != session.size { resize(session, to: size) }
    }

    /// The size `client`'s terminal last had, if it is looking at `session`.
    private func size(of client: ShellAttachment, in session: Session) -> Size? {
        if session.attachment === client { return session.attachmentSize }
        return session.viewers.first { $0.client === client }?.size
    }

    /// `client` no longer holds the shell's output back.
    private func release(_ session: Session, from client: ShellAttachment) {
        guard session.pausedBy.remove(ObjectIdentifier(client)) != nil, session.pausedBy.isEmpty else { return }
        session.process.setReadingPaused(false)
    }

    private func received(_ data: Data, session: Session) {
        guard session.running else { return }
        let now = Date()
        session.scrollback.append(data)
        session.outputCount += data.count
        session.writer.append(data, at: now)
        session.lastOutputAt = now
        if session.pendingTitle != nil { adoptEchoedTitle(session) }
        readStatus(data, session: session, at: now)
        noteOutput(data, session: session)
        guard table[session.id] === session else { return }
        let id = session.id
        for client in session.clients {
            callouts.async { client.shellOutput(data, session: id) }
        }
    }

    /// Keeps the tail and looks for a question once the output has been
    /// quiet for `quietBeforeAsking`.
    private func noteOutput(_ data: Data, session: Session) {
        session.tail.append(data)
        if session.tail.count > Self.tailBytes { session.tail = session.tail.suffix(Self.tailBytes) }
        session.checkedSinceOutput = false
        scheduleLook(session, after: quietBeforeAsking)
    }

    /// One pending look per session, however much output streams in: when it
    /// fires early it waits out the rest of the quiet time.
    private func scheduleLook(_ session: Session, after delay: TimeInterval) {
        guard !session.lookScheduled else { return }
        session.lookScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
            guard let self, let session else { return }
            session.lookScheduled = false
            let quiet = Date().timeIntervalSince(session.lastOutputAt)
            if quiet < quietBeforeAsking { return scheduleLook(session, after: quietBeforeAsking - quiet) }
            lookForQuestion(session)
        }
    }

    /// Answers a program asking whether the terminal speaks OSC 7501 (before
    /// anything goes out: its answer must arrive ahead of the terminal's
    /// reply to the device attributes query that follows), and follows what
    /// it then reports.
    private func readStatus(_ data: Data, session: Session, at now: Date) {
        var summaries: [ProgramStatus.Summary?] = []
        let outcome = session.programStatus.scan(data, summaries: &summaries)
        if outcome.contains(.queried) { session.process.write(ProgramStatus.supportReply) }
        let changed = outcome.contains(.changed)
        // A program killed mid-task never clears its records. Once another job
        // is in front (the shell's prompt is output too) and the reporting
        // job's process group is gone, nothing it said holds any more. A job
        // that is only stopped (^Z) or in the background keeps its status for
        // when it comes back. One ioctl per chunk, only while there are records.
        // The shell's own group alone doesn't mean the shell is in front: a
        // program the shell `exec`ed runs in it (`shellIsInFront`).
        //
        // The reporter may be gone by the time its output is read, with its
        // last reports and the prompt in one chunk: those reports still count,
        // in turn, and then it is over.
        if !session.programStatus.isEmpty {
            let group = session.process.foregroundGroup
            if session.statusOwner == nil {
                if shellIsInFront(session, group: group) {
                    if session.programStatus.forgetAll() { summaries.append(nil) }
                } else {
                    session.statusOwner = group
                }
            } else if let owner = session.statusOwner, let group, group != owner, !Self.groupExists(owner) {
                if !changed || shellIsInFront(session, group: group) {
                    if session.programStatus.forgetAll() { summaries.append(nil) }
                } else {
                    // Another program in front reported: what is said now is its.
                    session.statusOwner = group
                }
            }
        }
        if session.programStatus.isEmpty { session.statusOwner = nil }
        // Each change in turn: a moment's state (done, then the program gone) still counts.
        for summary in summaries { updateStatus(session, to: summary, at: now) }
    }

    private func updateStatus(_ session: Session, to summary: ProgramStatus.Summary?, at now: Date) {
        let previous = session.status
        var next: ShellStatus?
        if let summary {
            let sameState = previous?.state == summary.state
            let finished = summary.state == ShellStatus.done || summary.state == ShellStatus.error
            next = ShellStatus(state: summary.state, kind: summary.kind,
                               message: summary.message.map { Self.oneLine($0, limit: ShellStatus.maxMessage) },
                               agents: summary.agents,
                               since: sameState ? (previous?.since ?? now.timeIntervalSince1970) : now.timeIntervalSince1970,
                               // Done while someone is looking at it: they saw it.
                               seen: finished && ((sameState && previous?.seen == true) || session.clients.contains { $0.isLooking }))
        }
        guard next != previous else { return }
        session.status = next
        // What it is doing while it works changes with every step and nothing
        // shows it: that alone goes out with the next change that shows.
        let shown = next?.state != previous?.state || next?.kind != previous?.kind || next?.seen != previous?.seen
            || next?.agents != previous?.agents || (next?.isBlocked == true && next?.message != previous?.message)
        guard shown else { return }
        notifyChange()
        notifyStatus(session)
    }

    private func notifyStatus(_ session: Session) {
        guard let handler = statusHandler else { return }
        let info = session.info
        let looking = session.clients.contains { $0.isLooking }
        callouts.async { handler(info, looking) }
    }

    /// Someone has the session in front of them: a result waiting there is seen.
    private func markResultSeen(_ session: Session) {
        guard let status = session.status, status.isUnseenResult else { return }
        session.status?.seen = true
        notifyChange()
        notifyStatus(session)
    }

    /// Whether any process is left in process group `group`.
    private static func groupExists(_ group: pid_t) -> Bool {
        kill(-group, 0) == 0 || errno == EPERM
    }

    /// The shell itself is in front: its own group, with the arguments it
    /// started with (a program it `exec`ed has its own; macOS's /bin/sh
    /// becomes bash but keeps them).
    private func shellIsInFront(_ session: Session, group: pid_t?) -> Bool {
        guard let group, group == session.process.pid else { return false }
        return Self.arguments(of: group) == session.shellArguments
    }

    /// The arguments `pid` runs with, the program first (KERN_PROCARGS2), or
    /// nil once it is gone.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // the executable's path
        while index < size, buffer[index] == 0 { index += 1 }   // and its padding
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private func lookForQuestion(_ session: Session) {
        // A program that reports its status says when it is asking.
        guard session.running, !session.checkedSinceOutput, session.status == nil, table[session.id] === session else { return }
        session.checkedSinceOutput = true
        let question = ShellQuestion.find(in: session.tail)
        guard question != session.waiting else { return }
        session.waiting = question
        notifyChange()
    }

    private func ended(_ session: Session, status: Int32) {
        guard session.running else { return }
        session.running = false
        session.exitStatus = status
        session.writer.finish(exitStatus: status, at: Date())
        if session.status != nil { notifyStatus(session) }
        let id = session.id
        for client in session.clients {
            callouts.async { client.shellEnded(session: id, exitStatus: status) }
        }
        session.attachment = nil
        session.attachmentSize = nil
        session.viewers = []
        session.active = nil
        session.pausedBy = []
        ptLog(.info, "shell: session ended (\(status))")
        notifyChange()
        notifyViewers()
        // Weak: a session pruned earlier (by `open`) must not be kept alive, with its scrollback, until this fires.
        queue.asyncAfter(deadline: .now() + endedRetention) { [weak self, weak session] in
            guard let self, let session, table[session.id] === session else { return }
            remove(session.id)
            notifyChange()
        }
    }

    /// The first typed line the shell echoed back becomes the title, so a
    /// line typed at a no-echo prompt (a password) never does. Only printable
    /// input counts; escape sequences (arrow keys…) are skipped whole, and
    /// ctrl-C or ctrl-U start the line over.
    private func learnTitle(from data: Data, session: Session) {
        for byte in data {
            switch session.inputEscape {
            case .escape:
                session.inputEscape = byte == 0x5B ? .csi : byte == 0x4F ? .ss3 : .none
                continue
            case .csi:
                if (0x40...0x7E).contains(byte) { session.inputEscape = .none }
                continue
            case .ss3:
                session.inputEscape = .none
                continue
            case .none:
                break
            }
            switch byte {
            case 0x1B:
                session.inputEscape = .escape
            case 0x0D:
                let line = String(decoding: session.typed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let from = session.lineStart ?? session.outputCount
                session.typed = Data()
                session.lineStart = nil
                guard !line.isEmpty else { continue }
                session.pendingTitle = (String(line.prefix(Self.titleLimit)), from, session.outputCount + Self.echoWindow)
                adoptEchoedTitle(session)
                if session.titleKnown { return }
            case 0x03, 0x15:
                session.typed = Data()
                session.lineStart = nil
            case 0x7F, 0x08:
                if !session.typed.isEmpty { session.typed.removeLast() }
            case 0x20...:
                guard session.typed.count < Self.typedLimit else { continue }
                if session.typed.isEmpty, session.lineStart == nil { session.lineStart = session.outputCount }
                session.typed.append(byte)
            default:
                break
            }
        }
    }

    /// Makes the pending line the title if the output since it was typed shows
    /// it (escape sequences aside); drops it once its echo window has passed.
    private func adoptEchoedTitle(_ session: Session) {
        guard let pending = session.pendingTitle, !session.titleKnown else { return }
        let since = min(session.outputCount - pending.from, RemoteShell.scrollbackBytes)
        if Self.echoShows(pending.text, in: session.scrollback.contents.suffix(since)) {
            session.pendingTitle = nil
            session.title = pending.text
            session.titleKnown = true
            session.writer.setTitle(session.title)
            notifyChange()
        } else if session.outputCount >= pending.until {
            session.pendingTitle = nil
        }
    }

    /// Whether `output` shows `line` on one line. A typed line holds no line
    /// breaks, so it cannot match text that spans one.
    static func echoShows(_ line: String, in output: Data) -> Bool {
        visibleText(output).range(of: Data(line.utf8)) != nil
    }

    /// Output without escape sequences or control characters: what a line
    /// editor's echo looks like once its colors and cursor moves are gone.
    /// CR and LF become a line break (LF), so text either side stays apart.
    static func visibleText(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var state = 0   // 0 text, 1 after ESC, 2 CSI, 3 OSC/DCS string, 4 ESC inside a string
        for byte in data {
            switch state {
            case 1:
                state = byte == 0x5B ? 2 : (byte == 0x5D || byte == 0x50) ? 3 : 0
            case 2:
                if (0x40...0x7E).contains(byte) { state = 0 }
            case 3:
                if byte == 0x07 { state = 0 } else if byte == 0x1B { state = 4 }
            case 4:
                state = byte == 0x5C ? 0 : 3
            default:
                if byte == 0x1B {
                    state = 1
                } else if byte == 0x0D || byte == 0x0A {
                    out.append(0x0A)
                } else if byte >= 0x20, byte != 0x7F {
                    out.append(byte)
                }
            }
        }
        return out
    }

    private func remove(_ id: String) {
        table[id] = nil
        order.removeAll { $0 == id }
    }

    private func notifyChange() {
        guard let handler = changeHandler else { return }
        callouts.async { handler() }
    }

    private func notifyViewers() {
        guard let handler = viewersHandler else { return }
        callouts.async { handler() }
    }

    private static func dimension(_ value: Int) -> UInt16 { UInt16(clamping: max(1, value)) }
}
#endif
