import Foundation

/// The code-signing requirement text the root helper holds its XPC clients to.
public enum CodeRequirement {
    /// Our app (identifier `<id>.mac`) signed by `team`. With
    /// `allowDebuggable` false the app must also not carry
    /// `com.apple.security.get-task-allow`: a debuggable app can have code
    /// injected by any process of the same user (a debugger needs no
    /// privileges for it), which would then speak to the root helper as our
    /// app. Development builds carry it, so only a Debug helper allows it.
    public static func client(team: String, identifier: String, allowDebuggable: Bool) -> String {
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier).mac\""
        if !allowDebuggable { text += " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)" }
        return text
    }

    /// `^[A-Z0-9]+$`, as Apple's Team IDs are: it is spliced into the
    /// requirement, where a quote would change what it accepts.
    public static func isValidTeam(_ team: String) -> Bool {
        !team.isEmpty && team.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
