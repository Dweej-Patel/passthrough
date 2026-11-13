#if os(macOS)
import Foundation
import PassthroughCore
import Security

/// What the terminals socket lets a connection ask for (`LocalTerminalServer`).
///
/// Every process of the user's can reach the socket, and a session's shell
/// runs inside Passthrough, with its privacy permissions (Full Disk Access
/// and the rest), which that process may not have. So:
/// - a new session (`hook`, `new`) and the list are only for while the owner
///   has turned on showing new terminals on phones, which is that trade made on purpose;
/// - showing a running session (`attach`) needs a token the app made for that
///   session when it opened a window for it ("Open here"): good for one
///   window, for a minute, after which it and its file go. There is none
///   until the owner clicks, so nothing gets in at other times.
///
/// The file is readable by any process of the user's. One that reads it and
/// asks first is let in, but the window Passthrough opened then asks with the
/// same token: a token used twice means something else had it, and the owner
/// is told (`onContested`), and the app takes the session off its windows.
/// So the file stays for the token's minute even once used: removed on first
/// use, the window would find nothing to run and never ask, and nobody would know.
/// What this can't catch is a process that also keeps that window from
/// asking (changing what it runs): a process with the user's rights can do
/// that to any terminal window. That is the accepted limit.
///
/// "Open here" also asks that the window it opens stays a plain terminal:
/// that window's shell must run the `attach` itself, not a session of its
/// own. The window is known by the command its terminal typed into it before
/// its shell started (`Hello.typeahead`); a new terminal tab has none.
public final class LocalTerminalAccess: @unchecked Sendable {
    /// How long an "Open here" window has to show up.
    public static let lifetime: TimeInterval = 60

    private struct Grant {
        let session: String
        let file: URL?
        let until: Date
        /// The window should stay plain and has not asked yet.
        var plain: Bool
    }

    private let lock = NSLock()
    private var sharing = false
    private var grants: [String: Grant] = [:]
    /// Tokens a window was let in with, until they would have run out: one
    /// asked with again means another window had it.
    private var used: [String: (session: String, file: URL?, until: Date)] = [:]
    private var contestedHandler: (@Sendable (String) -> Void)?
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Whether new terminals are shown on phones (the startup hook is in place).
    public var isSharing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return sharing }
        set { lock.lock(); sharing = newValue; lock.unlock() }
    }

    /// A token was asked with again after a window was let in with it, for
    /// this session: something else had it. Called on any queue.
    public var onContested: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return contestedHandler }
        set { lock.lock(); contestedHandler = newValue; lock.unlock() }
    }

    /// A token for one window to show `session`. `file` is the command file
    /// that carries it, removed when the token runs out (`sweep`). `plain`: the
    /// window's own shell must not become a session (the hook is on).
    public func grant(session: String, file: URL? = nil, plain: Bool) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes for a terminal token")
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let stale = expire()
        grants[token] = Grant(session: session, file: file, until: now().addingTimeInterval(Self.lifetime), plain: plain)
        lock.unlock()
        stale.forEach(remove)
        return token
    }

    /// The window could not be opened after all.
    public func revoke(_ token: String) {
        lock.lock()
        let grant = grants.removeValue(forKey: token)
        lock.unlock()
        if let file = grant?.file { remove(file) }
    }

    /// Drops the grants that ran out, and their files.
    public func sweep() {
        lock.lock()
        let stale = expire()
        lock.unlock()
        stale.forEach(remove)
    }

    /// Every grant goes, with its file: the socket stopped.
    public func revokeAll() {
        lock.lock()
        let files = grants.values.compactMap(\.file) + used.values.compactMap(\.file)
        grants = [:]
        used = [:]
        lock.unlock()
        files.forEach(remove)
    }

    /// Whether `hello` is let in. An `attach` uses its token up.
    public func admits(_ hello: LocalTerminalWire.Hello) -> Bool {
        lock.lock()
        var stale = expire()
        var contested: (handler: @Sendable (String) -> Void, session: String)?
        let answer: Bool
        switch hello.mode {
        case .hook:
            if !sharing {
                answer = false
            } else if hello.typeahead == true, let key = grants.filter({ $0.value.plain }).min(by: { $0.value.until < $1.value.until })?.key {
                // The window "Open here" opened: its shell stays plain, to run the command typed into it.
                grants[key]?.plain = false
                answer = false
            } else {
                answer = true
            }
        case .new, .list:
            answer = sharing
        case .attach:
            if let token = hello.token, let grant = grants[token], grant.session == hello.session {
                grants[token] = nil
                used[token] = (grant.session, grant.file, grant.until)
                answer = true
            } else if let token = hello.token, let earlier = used[token], earlier.session == hello.session {
                // Used already: another window had this token.
                used[token] = nil
                if let file = earlier.file { stale.append(file) }
                if let handler = contestedHandler { contested = (handler, earlier.session) }
                answer = false
            } else {
                answer = false
            }
        }
        lock.unlock()
        stale.forEach(remove)
        if let contested { contested.handler(contested.session) }
        return answer
    }

    /// Lock held. Drops the grants that ran out; their files, to remove once it isn't.
    private func expire() -> [URL] {
        let now = now()
        var files: [URL] = []
        for (token, grant) in grants where grant.until <= now {
            grants[token] = nil
            if let file = grant.file { files.append(file) }
        }
        for (token, earlier) in used where earlier.until <= now {
            used[token] = nil
            if let file = earlier.file { files.append(file) }
        }
        return files
    }

    private func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
#endif
