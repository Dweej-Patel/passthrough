import Darwin
import Foundation
import PassthroughCore

// passthrough-term: runs inside a terminal window on the Mac and shows one of
// the Passthrough app's shell sessions in it, so paired phones can see the
// same terminal (`LocalTerminalClient`). The app installs a small script that
// calls it with the app's socket; nobody needs to type it.
//
//   passthrough-term hook             a new terminal's shell asking by itself (the startup hook)
//   passthrough-term new              start a shared session in this window
//   passthrough-term attach SESSION   show a session that is already running
//   passthrough-term list             the running sessions

var arguments = Array(CommandLine.arguments.dropFirst())
var socketPath = ProcessInfo.processInfo.environment["PASSTHROUGH_SOCKET"]
if arguments.first == "--socket", arguments.count >= 2 {
    socketPath = arguments[1]
    arguments.removeFirst(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("passthrough-term: \(message)\n".utf8))
    exit(1)
}

func explain(_ reason: String) -> String {
    switch reason {
    case LocalTerminalClient.notRunning, LocalTerminalClient.noAnswer:
        return "Passthrough isn't running, or Remote shell is off."
    case LocalTerminalWire.Refused.notSharing:
        return "Passthrough isn't sharing terminals right now."
    case LocalTerminalWire.Refused.tooManySessions:
        return "Too many terminals are shared already. Close one and try again."
    case LocalTerminalWire.Refused.noSuchSession:
        return "No running session with that id. `passthrough-term list` shows them."
    default:
        return "Passthrough refused (\(reason))."
    }
}

guard let command = arguments.first else {
    fail("usage: passthrough-term [--socket PATH] hook | new | attach SESSION | list")
}
guard let socketPath else { fail("no socket given (--socket PATH or PASSTHROUGH_SOCKET)") }

var environment = ProcessInfo.processInfo.environment
// The session's shell is the terminal's first, not one inside another.
environment["SHLVL"] = nil
environment["PASSTHROUGH_SOCKET"] = nil

switch command {
case "hook":
    // Quietly nothing unless this is a terminal that isn't a session already:
    // the shell that asked then carries on as it would have.
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
          environment[RemoteShell.sessionVariable] == nil else { exit(0) }
    let outcome = LocalTerminalClient.run(.init(socketPath: socketPath, mode: .hook, environment: environment))
    switch outcome {
    case .ended(let status):
        // Descriptor 3 is how the hook hears that a session really ran and
        // ended: anything else (this tool missing, crashing, refused) leaves
        // it empty, and the terminal carries on with its own shell.
        if fcntl(3, F_GETFD) != -1 {
            let line = Data("ended:\(status)\n".utf8)
            _ = line.withUnsafeBytes { write(3, $0.baseAddress, line.count) }
        }
    case .lost:
        let note = "\r\n[Passthrough stopped, and this terminal's shell with it. Starting a new shell here.]\r\n"
        FileHandle.standardOutput.write(Data(note.utf8))
    case .detached, .unavailable, .listed:
        break
    }
    exit(0)

case "new":
    switch LocalTerminalClient.run(.init(socketPath: socketPath, mode: .new, environment: environment)) {
    case .ended(let status): exit(status)
    case .unavailable(let reason): fail(explain(reason))
    case .lost: fail("Passthrough stopped, and the session with it.")
    case .detached, .listed: exit(0)
    }

case "attach":
    guard arguments.count >= 2 else { fail("usage: passthrough-term attach SESSION") }
    switch LocalTerminalClient.run(.init(socketPath: socketPath, mode: .attach, session: arguments[1])) {
    case .ended(let status):
        print("[session ended: \(status)]")
        exit(0)
    case .detached:
        print("[no longer shown here; the session carries on]")
        exit(0)
    case .unavailable(let reason): fail(explain(reason))
    case .lost: fail("Passthrough stopped, and the session with it.")
    case .listed: exit(0)
    }

case "list":
    switch LocalTerminalClient.run(.init(socketPath: socketPath, mode: .list)) {
    case .listed(let sessions):
        for session in sessions where session.running {
            print("\(session.id.prefix(8))  \(session.isOnMac ? "mac  " : "phone")  \(session.title)")
        }
        exit(0)
    case .unavailable(let reason): fail(explain(reason))
    default: fail("Passthrough did not answer.")
    }

default:
    fail("unknown command \(command)")
}
