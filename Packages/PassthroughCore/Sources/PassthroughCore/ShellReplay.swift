import Foundation

/// One step of a recorded session's replay: output, or the terminal taking a
/// new size. A replay starts with the size the terminal had when its first
/// output was written, so it is fed at the width the shell drew for (zsh, for
/// one, relies on autowrap at the right margin; fed at another width, a line
/// that reached the margin is erased).
public enum ShellReplayChunk: Equatable, Sendable {
    case output(Data)
    case resize(cols: Int, rows: Int)
}

/// Building, sending and receiving replays (protocol/README.md, `transcriptData`).
public enum ShellReplay {
    /// A size outside 1...this in either direction is not one a terminal had: ignored.
    public static let maxDimension = 1000

    public static func isValid(cols: Int, rows: Int) -> Bool {
        (1...maxDimension).contains(cols) && (1...maxDimension).contains(rows)
    }

    /// A recorded dimension brought into 1...`maxDimension`.
    public static func clamp(_ value: Int) -> Int { min(max(1, value), maxDimension) }

    /// The payload of an asciicast v2 resize event, "COLSxROWS".
    public static func sizeString(cols: Int, rows: Int) -> String { "\(cols)x\(rows)" }

    /// Parses "COLSxROWS"; nil for anything else or an invalid size.
    public static func parseSize(_ text: String) -> (cols: Int, rows: Int)? {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]),
              isValid(cols: cols, rows: rows) else { return nil }
        return (cols, rows)
    }

    /// The most columns and the most rows the replay's sizes ask for (a viewer
    /// fits its font to these once, before feeding); nil when it has no size.
    public static func largestGrid(_ chunks: [ShellReplayChunk]) -> (cols: Int, rows: Int)? {
        var cols = 0, rows = 0
        for case let .resize(c, r) in chunks {
            cols = max(cols, c)
            rows = max(rows, r)
        }
        return cols > 0 && rows > 0 ? (cols, rows) : nil
    }

    /// How much a font must shrink (never grow) for a grid that needs `needed`
    /// points at full size to fit `available`, but not below `minimum`.
    public static func fitScale(neededWidth: Double, neededHeight: Double,
                                availableWidth: Double, availableHeight: Double, minimum: Double) -> Double {
        guard neededWidth > 0, neededHeight > 0, availableWidth > 0, availableHeight > 0 else { return 1 }
        let scale = min(1, availableWidth / neededWidth, availableHeight / neededHeight)
        return max(min(minimum, 1), scale)
    }

    /// The `transcriptData` lines for a replay: output joined into pieces of
    /// at most `chunkSize` bytes, a size change as `cols`/`rows` on the line whose
    /// data follows it (a line with empty data when no output follows), and
    /// `done: true` on the last line. An empty replay is one empty `done` line.
    public static func transcriptLines(session: String, _ chunks: [ShellReplayChunk],
                                       chunkSize: Int = RemoteShell.outputChunk) -> [ShellEnvelope] {
        var lines: [ShellEnvelope] = []
        var size: (cols: Int, rows: Int)?
        var pending = Data()
        let chunkSize = max(1, chunkSize)
        func line(_ data: Data) {
            var piece = ShellEnvelope(t: ShellEnvelope.transcriptData)
            piece.session = session
            piece.data = data.base64EncodedString()
            if let size { piece.cols = size.cols; piece.rows = size.rows }
            size = nil
            lines.append(piece)
        }
        /// Sends full pieces (all of `pending` when `all`), keeping small output to join the next.
        func drain(all: Bool) {
            var offset = pending.startIndex
            while pending.endIndex - offset >= chunkSize || (all && offset < pending.endIndex) {
                let end = min(offset + chunkSize, pending.endIndex)
                line(pending.subdata(in: offset..<end))
                offset = end
            }
            pending = pending.subdata(in: offset..<pending.endIndex)
        }
        for chunk in chunks {
            switch chunk {
            case let .resize(cols, rows):
                drain(all: true)
                size = (cols, rows)   // consecutive sizes: the last one wins
            case let .output(data):
                pending.append(data)
                drain(all: false)
            }
        }
        drain(all: true)
        if size != nil || lines.isEmpty { line(Data()) }
        lines[lines.count - 1].done = true
        return lines
    }

    /// The phone's side: a replay rebuilt from `transcriptData` lines, in order.
    public struct Collector: Sendable {
        private var done: [ShellReplayChunk] = []
        /// Output since the last size change, appended in place.
        private var pending = Data()

        public init() {}

        /// The replay so far: consecutive output joined.
        public var chunks: [ShellReplayChunk] { pending.isEmpty ? done : done + [.output(pending)] }

        /// One line's contents: its size change (if any, and valid) comes before its data.
        public mutating func add(_ data: Data, cols: Int? = nil, rows: Int? = nil) {
            if let cols, let rows, ShellReplay.isValid(cols: cols, rows: rows) {
                if !pending.isEmpty { done.append(.output(pending)); pending = Data() }
                done.append(.resize(cols: cols, rows: rows))
            }
            pending.append(data)
        }
    }
}
