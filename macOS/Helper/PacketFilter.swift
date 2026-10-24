import Foundation
import HelperLogic

/// The kill switch's pf anchor: loads `KillSwitchRules` into it and keeps pf
/// enabled while it holds rules. See `KillSwitchRules` for why the anchor
/// sits under com.apple.
///
/// pf is enabled with a reference (`pfctl -E`, released with `pfctl -X`), not
/// switched on and off outright, so whoever else uses pf keeps it on. The
/// reference lives in the state directory, so a helper started after a crash
/// can release the one its predecessor took. Releasing the last reference
/// disables pf, even if someone had enabled it without one (`pfctl -e`); so
/// pf that was on before the kill switch is turned back on afterwards.
enum PacketFilter {
    static let anchor = KillSwitchRules.anchor(identifier: HelperConstants.identifier)
    private static let pfctl = "/sbin/pfctl"
    private static var store: KillSwitchStateStore { VPNEngine.stateStore }

    enum Failure: LocalizedError {
        case notEvaluated
        case load(String)
        case enable(String)
        var errorDescription: String? {
            switch self {
            case .notEvaluated: return "pf's main rules don't include Apple's anchors (\"com.apple/*\"), so the kill switch's rules would never be read"
            case .load(let why): return "pfctl refused the kill switch's rules: \(why)"
            case .enable(let why): return "pfctl could not enable pf: \(why)"
            }
        }
    }

    /// Replaces the anchor's rules with `rules` and makes sure pf is on.
    static func apply(_ rules: String) throws {
        try ensureAnchorIsEvaluated()
        let load = Shell.output(pfctl, ["-a", anchor, "-f", "-"], input: rules)
        guard load.status == 0 else { throw Failure.load(lastLine(load.stderr)) }
        try enable()
    }

    /// Whether the anchor holds any rules now.
    static var isLoaded: Bool {
        !Shell.output(pfctl, ["-a", anchor, "-s", "rules"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Empties the anchor and releases our reference; pf is left as it was
    /// found. True if there was anything to undo.
    @discardableResult
    static func lift() -> Bool {
        var undone = false
        if isLoaded {
            let flush = Shell.output(pfctl, ["-a", anchor, "-F", "rules"])
            if flush.status != 0 { HelperLog.error("kill switch: pfctl could not flush \(anchor): \(lastLine(flush.stderr))") }
            undone = true
        }
        if let held = store.token {
            if let token = held.token {
                let release = Shell.output(pfctl, ["-X", token])
                if release.status != 0 { HelperLog.warn("kill switch: pf reference \(token) was already gone") }
            }
            if held.wasEnabled, isEnabled == false {
                Shell.output(pfctl, ["-e"])
                HelperLog.info("kill switch: pf was on before the kill switch; left on")
            }
            store.clearToken()
            undone = true
        }
        return undone
    }

    private static var isEnabled: Bool? { PFOutput.isEnabled(info: Shell.output(pfctl, ["-s", "info"]).stdout) }

    /// Takes a pf enable reference unless one is already held (this helper's,
    /// or a predecessor's kept with the kill switch).
    private static func enable() throws {
        guard store.token == nil else { return }
        let wasEnabled = isEnabled ?? false
        let result = Shell.output(pfctl, ["-E"])
        let token = PFOutput.token(fromEnable: result.stderr + "\n" + result.stdout)
        guard result.status == 0, token != nil || wasEnabled else { throw Failure.enable(lastLine(result.stderr)) }
        try store.setToken(.init(token: token, wasEnabled: wasEnabled))
        HelperLog.info("kill switch: pf enabled (reference \(token ?? "none"); it was \(wasEnabled ? "already on" : "off"))")
    }

    /// The main ruleset must reach our anchor through `anchor "com.apple/*"`.
    /// launchd loads /etc/pf.conf (which has it) at boot; if the main ruleset
    /// is empty, that is loaded again. A main ruleset of someone else's
    /// without it is left alone: the kill switch then has its routes only.
    private static func ensureAnchorIsEvaluated() throws {
        let main = Shell.output(pfctl, ["-s", "rules"]).stdout
        if PFOutput.evaluates(anchor: anchor, mainRules: main) { return }
        if main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HelperLog.warn("kill switch: pf's main ruleset is empty; loading /etc/pf.conf")
            Shell.output(pfctl, ["-f", "/etc/pf.conf"])
            if PFOutput.evaluates(anchor: anchor, mainRules: Shell.output(pfctl, ["-s", "rules"]).stdout) { return }
        }
        throw Failure.notEvaluated
    }

    /// pfctl's last line on stderr, minus the warnings it always prints.
    private static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").map(String.init)
            .last { !$0.isEmpty && !$0.contains("ALTQ") && !$0.contains("flushing of rules") && !$0.contains("/etc/pf.conf for further") } ?? "no reason given"
    }
}
