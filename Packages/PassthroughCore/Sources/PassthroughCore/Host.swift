import Foundation

/// What a host says about itself in `host`, sent right after `ready` (after
/// `macInfo`) and again whenever it changes (protocol/README.md, "The host").
/// Every field is optional; a host that sends no `host` is a Mac from before it.
public struct HostInfo: Codable, Equatable, Sendable {
    /// `mac` or `windows`; a client keeps a kind it doesn't know and treats it as neither.
    public var kind: String?
    /// The operating system and version, for showing ("macOS 15.4", "Windows 11 Pro 24H2").
    public var os: String?
    /// The account that granted this phone has a session on the host (locked counts).
    public var signedIn: Bool?
    /// Passthrough is running in that session, so shells can start.
    public var app: Bool?
    /// Who is at the host's screen: `active`, `locked`, `signedOut` or `otherUser`; absent when unknown.
    public var console: String?
    /// Seconds since someone last used the host's own keyboard or mouse, with `console` `active`.
    public var idleSeconds: Int?
    /// The shells a phone may open, for `open`'s `shell`; at most one is the `default`.
    public var shells: [HostShell]?
    /// How its screen can be seen: any of `video`, `rfb`, `rdp`.
    public var screens: [String]?
    /// Whether the Remote Desktop relay can be used: `ready`, or why not (`off`, `edition`,
    /// `account`, `service`, `exposed`, `policy`).
    public var rdp: String?
    /// What this connection's device may do here.
    public var access: HostAccess?
    /// This device may lock the host's screen (`lock`).
    public var lock: Bool?
    /// The host's identity public key for computer passes (protocol/README.md, "Computers").
    public var idKey: String?
    /// The name its Windows sign-in takes, sent only to a device allowed the screen.
    public var user: String?
    /// Seconds on mains until the host sleeps; 0 for never.
    public var sleepAfter: Int?

    public init(kind: String? = nil, os: String? = nil, signedIn: Bool? = nil, app: Bool? = nil, console: String? = nil,
                idleSeconds: Int? = nil, shells: [HostShell]? = nil, screens: [String]? = nil, rdp: String? = nil,
                access: HostAccess? = nil, lock: Bool? = nil, idKey: String? = nil, user: String? = nil, sleepAfter: Int? = nil) {
        self.kind = kind; self.os = os; self.signedIn = signedIn; self.app = app; self.console = console
        self.idleSeconds = idleSeconds; self.shells = shells; self.screens = screens; self.rdp = rdp; self.access = access
        self.lock = lock; self.idKey = idKey; self.user = user; self.sleepAfter = sleepAfter
    }

    public static let kindMac = "mac", kindWindows = "windows"
    public static let consoleStates = ["active", "locked", "signedOut", "otherUser"]
    public static let screenVideo = "video", screenRFB = "rfb", screenRDP = "rdp"
    public static let maxShells = 32
    /// Longest `host` line either side sends or accepts.
    public static let maxLineBytes = 16_384
    /// With `console` `active` and less idle than this, someone is using the host.
    public static let inUseIdleSeconds = 120

    /// What a client may rely on: nil without a `kind`; malformed fields dropped,
    /// shells checked, at most one default, unknown `console` values dropped.
    public func cleaned() -> HostInfo? {
        guard let kind, HostInfo.isLine(kind, max: 32) else { return nil }
        var info = self
        info.kind = kind
        if let os, !HostInfo.isLine(os, max: 64) { info.os = nil }
        if let console, !HostInfo.consoleStates.contains(console) { info.console = nil }
        if let idleSeconds, idleSeconds < 0 { info.idleSeconds = nil }
        if let sleepAfter, sleepAfter < 0 { info.sleepAfter = nil }
        if let rdp, !HostInfo.isLine(rdp, max: 32) { info.rdp = nil }
        if let user, !HostInfo.isLine(user, max: 256) { info.user = nil }
        if let idKey, !(idKey.utf8.count <= 512 && idKey.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) { info.idKey = nil }
        info.screens = screens.map { Array($0.filter { HostInfo.isLine($0, max: 16) }.prefix(8)) }
        if let shells {
            var seen = Set<String>(), kept: [HostShell] = [], hasDefault = false
            for var shell in shells where kept.count < HostInfo.maxShells {
                guard HostShell.isValidID(shell.id), HostInfo.isLine(shell.name, max: 64), seen.insert(shell.id).inserted else { continue }
                if shell.default == true { if hasDefault { shell.default = nil } else { hasDefault = true } }
                kept.append(shell)
            }
            info.shells = kept
        }
        return info
    }

    /// One line of 1 to `max` UTF-16 units (as Kotlin and C# count, so all three keep the same text), with no
    /// control, format (bidi overrides, zero-width) or line and paragraph separator characters.
    static func isLine(_ text: String, max: Int) -> Bool {
        let count = text.utf16.count
        return count >= 1 && count <= max && !text.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }
}

/// A shell a host offers (`HostInfo.shells`).
public struct HostShell: Codable, Equatable, Sendable {
    /// Stable id, sent back in `open`'s `shell`: `pwsh`, `cmd`, `wsl:Ubuntu`, a Mac's `login`.
    public var id: String
    /// What to show: "PowerShell", "Ubuntu".
    public var name: String
    /// The one a plain `open` starts.
    public var `default`: Bool?

    public init(id: String, name: String, default isDefault: Bool? = nil) {
        self.id = id; self.name = name; self.default = isDefault
    }

    /// The id a Mac gives its login shell.
    public static let loginID = "login"

    /// 1 to 80 characters: a letter or digit, then letters, digits, `:`, `.`, `_` or `-`.
    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...80).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x3A || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    private static func isAlphanumeric(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }
}

/// What the device on this connection may do on the host (`HostInfo.access`).
public struct HostAccess: Codable, Equatable, Sendable {
    public var shell: Bool?
    public var screen: Bool?
    /// May hand access to this host on to another computer.
    public var share: Bool?

    public init(shell: Bool? = nil, screen: Bool? = nil, share: Bool? = nil) {
        self.shell = shell; self.screen = screen; self.share = share
    }
}

/// Why a host is about to go away, on its live connections (`goingAway`).
public enum GoingAwayReason: String, Sendable, CaseIterable {
    case sleeping
    case turnedOff = "turned_off"
    case shuttingDown = "shutting_down"
}
