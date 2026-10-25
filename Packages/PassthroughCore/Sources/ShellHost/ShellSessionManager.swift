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
    /// The scrollback replay for an attach has been handed over; what follows is live.
    func shellReplayed(session: String)
}

public extension ShellAttachment {
    func shellReplayed(session: String) {}
}

/// The Mac's interactive shell sessions. They keep running while nothing is
/// attached; a client that attaches is replayed the recent output, and a later
/// attach takes the session over.
public final class ShellSessionManager: @unchecked Sendable {
    /// Fires after the session list changes. Called off the manager's queue.
    public var onChange: (@Sendable () -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    enum InputEscape { case none, escape, csi, ss3 }

    private final class Session {
        let id: String
        let startedAt: Date
        /// The phone that opened it, so revoking that phone ends it; any
        /// authorized phone may still attach to it meanwhile.
        let openedBy: String?
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
        /// Looked for a question since the last output.
        var checkedSinceOutput = true
        /// A look is already scheduled; output meanwhile pushes it back.
        var lookScheduled = false
        var exitStatus: Int32?
        var running = true
        var attachment: ShellAttachment?
        /// What `attach` returned for `attachment`.
        var generation: UInt64 = 0

        init(id: String, startedAt: Date, openedBy: String?, process: PTYProcess, writer: TranscriptWriter) {
            self.id = id; self.startedAt = startedAt; self.openedBy = openedBy; self.process = process; self.writer = writer
            lastOutputAt = startedAt
        }

        var info: ShellSessionInfo {
            ShellSessionInfo(id: id, title: title, startedAt: startedAt.timeIntervalSince1970,
                             lastOutputAt: lastOutputAt.timeIntervalSince1970, running: running, exitStatus: exitStatus,
                             waiting: running ? waiting : nil)
        }
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
    private var opening = 0
    /// Numbers every attach, so a late detach can be told from a current one.
    private var lastGeneration: UInt64 = 0
    private var changeHandler: (@Sendable () -> Void)?

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
        queue.sync { order.compactMap { table[$0]?.info } }
    }

    /// Starts a login shell. The spawn and the transcript's first write happen
    /// outside the manager's queue, so listing or using other sessions never
    /// waits on them; a slot is held meanwhile so the cap still holds.
    /// `phoneID` is the phone opening it (`closeSessions(openedBy:)`).
    public func open(phoneLabel: String, phoneID: String? = nil, cols: Int, rows: Int) throws -> String {
        try queue.sync {
            for id in order where table[id]?.running == false { remove(id) }
            guard table.values.filter(\.running).count + opening < RemoteShell.maxSessions else { throw ShellError.tooManySessions }
            opening += 1
        }
        var reserved = true
        defer { if reserved { queue.sync { opening -= 1 } } }

        let id = UUID().uuidString
        let now = Date()
        let (executable, arguments) = command()
        let process = try PTYProcess(executable: executable, arguments: arguments, directory: directory,
                                     environment: environment(), cols: Self.dimension(cols), rows: Self.dimension(rows))
        let writer: TranscriptWriter
        do {
            writer = try transcripts.begin(id: id, title: "~", phoneLabel: phoneLabel, cols: cols, rows: rows, at: now)
        } catch {
            process.terminate()   // never started; dropping it hangs up and reaps
            throw error
        }
        let session = Session(id: id, startedAt: now, openedBy: phoneID, process: process, writer: writer)
        // Weak: the session owns the process, so a strong capture would be a cycle that leaks every session.
        process.onOutput = { [weak self, weak session] data in
            self?.queue.async { if let session { self?.received(data, session: session) } }
        }
        process.onExit = { [weak self, weak session] status in
            self?.queue.async { if let session { self?.ended(session, status: status) } }
        }
        queue.sync {
            opening -= 1
            reserved = false
            table[id] = session
            order.append(id)
            process.start()
            ptLog(.info, "shell: opened session")
            notifyChange()
        }
        return id
    }

    /// Replays the scrollback to `client`, then streams live output to it. A client
    /// attached earlier is told it was detached, with the generation its own
    /// attach returned. Returns this attach's generation, unique per manager.
    @discardableResult
    public func attach(_ id: String, client: ShellAttachment, cols: Int, rows: Int) throws -> UInt64 {
        try queue.sync {
            guard let session = table[id] else { throw ShellError.noSuchSession }
            lastGeneration += 1
            let generation = lastGeneration
            if let previous = session.attachment, previous !== client {
                let old = session.generation
                callouts.async { previous.shellDetached(session: id, generation: old) }
            }
            if session.running { resize(session, cols: cols, rows: rows) }
            let replay = session.scrollback.replay
            var offset = 0
            while offset < replay.count {
                let chunk = Data(replay[(replay.startIndex + offset)..<(replay.startIndex + min(offset + RemoteShell.outputChunk, replay.count))])
                offset += chunk.count
                callouts.async { client.shellOutput(chunk, session: id) }
            }
            callouts.async { client.shellReplayed(session: id) }
            if session.running {
                session.attachment = client
                session.generation = generation
            } else if let status = session.exitStatus {
                callouts.async { client.shellEnded(session: id, exitStatus: status) }
            }
            return generation
        }
    }

    /// Stops sending to `client` without telling it.
    public func detach(client: ShellAttachment) {
        queue.sync {
            for session in table.values where session.attachment === client { session.attachment = nil }
        }
    }

    public func input(_ id: String, _ data: Data) {
        queue.async { [self] in
            guard let session = table[id], session.running else { return }
            session.process.write(data)
            if !session.titleKnown { learnTitle(from: data, session: session) }
            // Someone answered: it isn't waiting any more, and only what
            // comes next can ask again.
            session.tail.removeAll(keepingCapacity: true)
            if session.waiting != nil {
                session.waiting = nil
                notifyChange()
            }
        }
    }

    public func resize(_ id: String, cols: Int, rows: Int) {
        queue.async { [self] in
            guard let session = table[id], session.running else { return }
            resize(session, cols: cols, rows: rows)
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
    private func resize(_ session: Session, cols: Int, rows: Int) {
        let cols = Self.dimension(cols), rows = Self.dimension(rows)
        session.process.resize(cols: cols, rows: rows)
        session.writer.resize(cols: Int(cols), rows: Int(rows), at: Date())
    }

    private func received(_ data: Data, session: Session) {
        guard session.running else { return }
        let now = Date()
        session.scrollback.append(data)
        session.outputCount += data.count
        session.writer.append(data, at: now)
        session.lastOutputAt = now
        if session.pendingTitle != nil { adoptEchoedTitle(session) }
        noteOutput(data, session: session)
        if let client = session.attachment, table[session.id] === session {
            let id = session.id
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

    private func lookForQuestion(_ session: Session) {
        guard session.running, !session.checkedSinceOutput, table[session.id] === session else { return }
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
        if let client = session.attachment {
            let id = session.id
            callouts.async { client.shellEnded(session: id, exitStatus: status) }
        }
        session.attachment = nil
        ptLog(.info, "shell: session ended (\(status))")
        notifyChange()
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

    private static func dimension(_ value: Int) -> UInt16 { UInt16(clamping: max(1, value)) }
}
#endif
