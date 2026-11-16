#if os(macOS)
import Foundation
import PassthroughCore

/// OSC 7501, the Program Status Protocol, read from a session's output: a
/// program that speaks it (Claude Code does) says whether it is working,
/// blocked on the user (and why), done, idle or failed, without anyone
/// reading its screen.
///
/// It asks first (`ESC ] 7501 ; ?`, then the device attributes): the Mac
/// answers that, for every terminal a session is shown in, since the phone's
/// terminal knows nothing of it. From then on it sends reports, `ESC ] 7501 ;
/// key=value:key=value… ST`. Each one replaces a record: the root (no `id`)
/// is the program itself; Claude Code gives each of its agents a record of
/// its own (`id`, a `title`), and clears it when the agent finishes.
///
/// https://mitchellh.com/writing/program-status-osc7501 (spec 0.4).
struct ProgramStatus {
    /// What a terminal that supports the protocol answers the query with.
    static let supportReply = Data("\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\".utf8)

    struct Record: Equatable {
        var state: String
        var kind: String?
        var message: String?
        var title: String?
    }

    /// By `id`; the root under "".
    private(set) var records: [String: Record] = [:]

    static let clear = "clear"
    static let states: Set<String> = [ShellStatus.idle, ShellStatus.working, ShellStatus.done, ShellStatus.blocked, ShellStatus.error, clear]
    static let kinds: Set<String> = ["permission", "question", "auth"]
    static let maxSequence = 4096
    static let maxRecords = 256
    static let maxMessageBytes = 2048
    static let maxTitleBytes = 192

    // Parser state: a sequence can be split across chunks.
    private enum State { case ground, escape, osc, oscEscape, skipping, skippingEscape }
    private var state = State.ground
    private var body: [UInt8] = []

    /// What a chunk of output did.
    struct Outcome: OptionSet {
        let rawValue: Int
        /// The program asked whether the terminal supports the protocol.
        static let queried = Outcome(rawValue: 1)
        /// A record changed.
        static let changed = Outcome(rawValue: 2)
    }

    /// Records are left as they were when nothing in `data` changes them.
    mutating func scan(_ data: Data) -> Outcome {
        var outcome: Outcome = []
        var index = data.startIndex
        while index < data.endIndex {
            if state == .ground {
                // Nearly all output is text: only an escape can start a sequence.
                guard let escape = data[index...].firstIndex(of: 0x1B) else { break }
                index = escape
            }
            outcome.formUnion(step(data[index]))
            index += 1
        }
        return outcome
    }

    /// The program that reported went away without clearing its records
    /// (killed, crashed, or it just never clears them): nothing it said
    /// describes the session any more.
    mutating func forgetAll() -> Bool {
        guard !records.isEmpty else { return false }
        records.removeAll()
        return true
    }

    var isEmpty: Bool { records.isEmpty }

    private static func isUnfinished(_ record: Record) -> Bool {
        record.state == ShellStatus.working || record.state == ShellStatus.blocked
    }

    /// What the session as a whole is doing. Blocked anywhere is blocked
    /// (the root's question first); otherwise working while the root or any
    /// agent still is; otherwise the root's own state. Nil without records.
    var summary: (state: String, kind: String?, message: String?, agents: Int)? {
        guard !records.isEmpty else { return nil }
        let root = records[""]
        let agents = records.filter { !$0.key.isEmpty && Self.isUnfinished($0.value) }
        if root?.state == ShellStatus.blocked { return (ShellStatus.blocked, root?.kind, root?.message, agents.count) }
        if let (_, agent) = agents.sorted(by: { $0.key < $1.key }).first(where: { $0.value.state == ShellStatus.blocked }) {
            let message = [agent.title, agent.message].compactMap { $0 }.joined(separator: ": ")
            return (ShellStatus.blocked, agent.kind, message.isEmpty ? nil : message, agents.count)
        }
        if root?.state == ShellStatus.working || !agents.isEmpty { return (ShellStatus.working, nil, root?.message, agents.count) }
        guard let root else { return nil }
        return (root.state, nil, root.message, 0)
    }

    // MARK: Parsing

    private mutating func step(_ byte: UInt8) -> Outcome {
        switch state {
        case .ground:
            if byte == 0x1B { state = .escape }
        case .escape:
            switch byte {
            case UInt8(ascii: "]"): state = .osc; body.removeAll(keepingCapacity: true)
            case UInt8(ascii: "c"):
                // A full reset ends every record.
                state = .ground
                if !records.isEmpty { records.removeAll(); return .changed }
            case 0x1B: break
            default: state = .ground
            }
        case .osc:
            switch byte {
            case 0x07: state = .ground; return finish()
            case 0x1B: state = .oscEscape
            case 0x18, 0x1A: state = .ground
            default:
                body.append(byte)
                // Not this protocol, or too long to be a report: skip the rest of it.
                if body.count == 5, body != Array("7501;".utf8) { state = .skipping }
                if body.count > Self.maxSequence { state = .skipping }
            }
        case .oscEscape:
            // `ESC \` ends it; any other escape ends it too and begins a sequence.
            if byte == UInt8(ascii: "\\") { state = .ground; return finish() }
            let outcome = finish()
            state = .escape
            return outcome.union(step(byte))
        case .skipping:
            if byte == 0x07 || byte == 0x18 || byte == 0x1A { state = .ground } else if byte == 0x1B { state = .skippingEscape }
        case .skippingEscape:
            if byte == UInt8(ascii: "\\") { state = .ground } else { state = .escape; return step(byte) }
        }
        return []
    }

    private mutating func finish() -> Outcome {
        let prefix = Array("7501;".utf8)
        guard body.count >= prefix.count, Array(body.prefix(prefix.count)) == prefix else { return [] }
        let text = String(decoding: body.dropFirst(prefix.count), as: UTF8.self)
        if text == "?" { return .queried }
        return apply(text) ? .changed : []
    }

    /// One report: replaces its record (or clears records). A malformed one is ignored whole.
    private mutating func apply(_ text: String) -> Bool {
        var fields: [String: String] = [:]
        for pair in text.split(separator: ":") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        guard let state = fields["state"], Self.states.contains(state) else { return false }
        let id = fields["id"] ?? ""
        guard id.isEmpty || Self.isValidID(id) else { return false }
        if state == Self.clear {
            let before = records
            if id.isEmpty { records.removeAll() } else { records = records.filter { $0.key != id && !$0.key.hasPrefix(id + "/") } }
            return records != before
        }
        var record = Record(state: state)
        if state == ShellStatus.blocked, let kind = fields["kind"], Self.kinds.contains(kind) { record.kind = kind }
        if let value = fields["msg"] {
            guard let message = Self.text(value, limit: Self.maxMessageBytes) else { return false }
            record.message = message
        }
        if let value = fields["title"] {
            guard let title = Self.text(value, limit: Self.maxTitleBytes) else { return false }
            record.title = title
        }
        guard records[id] != record else { return false }
        guard records[id] != nil || records.count < Self.maxRecords else { return false }
        records[id] = record
        return true
    }

    /// Base64 UTF-8 without control characters, or nil.
    private static func text(_ base64: String, limit: Int) -> String? {
        guard let data = Data(base64Encoded: base64), data.count <= limit,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return text
    }

    /// `seg/seg/…`: up to 8 segments of 1–32 of `A–Z a–z 0–9 _ . + -`, 128 characters in all.
    private static func isValidID(_ id: String) -> Bool {
        guard id.utf8.count <= 128 else { return false }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= 8 else { return false }
        return segments.allSatisfy { segment in
            (1...32).contains(segment.utf8.count) && segment.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
            }
        }
    }
}
#endif
