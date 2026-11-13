#if os(macOS)
import Foundation
import PassthroughCore

/// The lines Passthrough puts in the user's shell startup file so every new
/// terminal's shell runs as a session (and so shows on their phones), and the
/// small script those lines call.
///
/// It is written to fail open. The hook does nothing unless the script is
/// there, the shell is interactive on a terminal, and it is not already
/// inside a session; and it gives the terminal up only when the tool says, on
/// its own descriptor, that a session ran and ended. Passthrough not running,
/// the tool missing or crashing, sharing turned off: the terminal carries on
/// with its own shell.
public enum TerminalHook {
    public static let begin = "# >>> Passthrough shared terminals >>>"
    public static let end = "# <<< Passthrough shared terminals <<<"

    /// The startup file for a login shell, or nil for a shell the hook isn't written for.
    /// bash reads the first of three that exists, so that one is used.
    public static func startupFile(shell: String, home: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh":
            return home.appendingPathComponent(".zshrc")
        case "bash":
            let candidates = [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
            return candidates.first(where: exists) ?? candidates[0]
        default:
            return nil
        }
    }

    /// `script` as the hook names it: under `$HOME` when it is, so the lines
    /// hold no user name. Nil for a path the shell would not read back as
    /// written (a quote, `$`, a backquote or a backslash in it).
    static func quoted(_ script: String, home: String) -> String? {
        let unsafe = CharacterSet(charactersIn: "\"$`\\\n")
        func safe(_ text: String) -> Bool { text.rangeOfCharacter(from: unsafe) == nil }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if script.hasPrefix(prefix) {
            let rest = String(script.dropFirst(prefix.count))
            return safe(rest) ? "\"$HOME/\(rest)\"" : nil
        }
        return safe(script) ? "\"\(script)\"" : nil
    }

    /// The hook, for zsh and bash alike.
    public static func block(script: String, home: String = NSHomeDirectory()) -> String? {
        guard let tool = quoted(script, home: home) else { return nil }
        return """
        \(begin)
        # Added by Passthrough: new terminals show on your phones. Turn off
        # "Show new terminals on my phones" in Passthrough's settings to remove it.
        # Without Passthrough running, a terminal starts as usual.
        if [ -z "$\(RemoteShell.sessionVariable)" ] && [ -t 0 ] && [ -t 1 ] && [ -x \(tool) ]; then
          case $- in *i*)
            __passthrough=$(\(tool) hook 3>&1 >/dev/tty 2>&1)
            case $__passthrough in ended:*) exit "${__passthrough#ended:}" ;; esac
            unset __passthrough
          ;; esac
        fi
        \(end)

        """
    }

    public static func isInstalled(in text: String) -> Bool {
        text.contains(begin) && text.contains(end)
    }

    /// `text` without the hook (and the blank line that followed it).
    public static func removing(from text: String) -> String {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return text }
        var after = text[stop.upperBound...]
        if after.hasPrefix("\n") { after = after.dropFirst() }
        if after.hasPrefix("\n") { after = after.dropFirst() }
        return String(text[..<start.lowerBound]) + String(after)
    }

    /// `text` with the hook at its top, in place of any already there: first,
    /// so the terminal's own shell does none of the rest of its startup before
    /// the session's shell does all of it.
    public static func adding(to text: String, script: String, home: String = NSHomeDirectory()) -> String? {
        guard let block = block(script: script, home: home) else { return nil }
        return block + removing(from: text)
    }

    public enum HookError: LocalizedError {
        case unsupportedShell(String), unsafePath, unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedShell(let shell): return "New terminals can be shown for zsh and bash; your shell is \(shell)."
            case .unsafePath: return "Passthrough's folder has a character in its path that a shell startup file can't hold."
            case .unreadable(let file): return "\(file) isn't text Passthrough can read, so it was left alone."
            }
        }
    }

    /// Puts the hook in `file` (through a symlink to the real one), keeping
    /// its permissions; the file is made if there is none.
    public static func install(in file: URL, script: String, home: String = NSHomeDirectory()) throws {
        try rewrite(file) { text in
            guard let updated = adding(to: text, script: script, home: home) else { throw HookError.unsafePath }
            return updated
        }
    }

    /// Takes the hook out of `file`; nothing happens when it has none.
    public static func remove(from file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try rewrite(file) { removing(from: $0) }
    }

    public static func isInstalled(in file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8)).map(isInstalled(in:)) ?? false
    }

    private static func rewrite(_ file: URL, _ change: (String) throws -> String) throws {
        let target = file.resolvingSymlinksInPath()
        let manager = FileManager.default
        var text = ""
        var permissions: Any?
        if manager.fileExists(atPath: target.path) {
            guard let read = try? String(contentsOf: target, encoding: .utf8) else { throw HookError.unreadable(file.lastPathComponent) }
            text = read
            permissions = try? manager.attributesOfItem(atPath: target.path)[.posixPermissions]
        }
        let updated = try change(text)
        guard updated != text else { return }
        try Data(updated.utf8).write(to: target, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    /// Writes the script the hook calls: it runs the app's own tool with the
    /// app's socket. Rewritten at every launch, so it follows the app when it moves.
    public static func writeScript(at script: URL, tool: String, socket: String) throws {
        func single(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let text = """
        #!/bin/sh
        # Written by Passthrough at launch; changes are overwritten.
        # Quietly nothing once the app is gone, so a hook left behind costs a terminal nothing.
        [ -x \(single(tool)) ] || exit 0
        exec \(single(tool)) --socket \(single(socket)) "$@"

        """
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
}
#endif
