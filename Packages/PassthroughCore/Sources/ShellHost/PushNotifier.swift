#if os(macOS)
import Foundation
import PassthroughCore

/// Tells phones, through Apple's push service, when a session needs them
/// or has finished, from what its program reports (`ShellStatus`):
///
/// - blocked (a permission prompt, a question): at once, as Time Sensitive,
///   and again only when it asks something else;
/// - done or failed after working at least `minimumWork`, and not seen
///   (nobody had it in front of them when it finished);
/// - never about a session someone is looking at (a phone with its terminal
///   on screen, or a terminal window on this Mac while someone is at it).
///
/// Each phone's notice is sealed with its own key (`PushBox`); Apple sees
/// only that a notice went to the device, when, and whether it was Time Sensitive.
public final class PushNotifier: @unchecked Sendable {
    /// A turn shorter than this finishing is not worth a notice.
    public static let minimumWork: TimeInterval = 30
    /// At most this many notices to one phone a minute, whatever happens.
    public static let perPhoneLimit = 10

    /// A notice the rules call for, before it is sealed for each phone.
    public struct Planned: Equatable, Sendable {
        public var notice: PushNotice
        public var timeSensitive: Bool
    }

    private struct Tracked {
        var workingSince: Double?
        /// What the last notice (or look) was about, so it isn't sent twice.
        var settled: String?
    }

    private let lock = NSLock()
    private var tracked: [String: Tracked] = [:]
    private var sentAt: [String: [Date]] = [:]
    private let now: @Sendable () -> Date

    /// Where notices go; set by the app. Nil while there is no push key: nothing is sent.
    public var client: (@Sendable () -> APNsClient?)?
    public var registrations: (@Sendable () -> [String: PushRegistration])?
    /// A phone's token stopped working: it should be forgotten.
    public var onTokenGone: (@Sendable (_ phoneID: String) -> Void)?
    /// How the last attempt went, for Settings: nil after a success, else why it failed.
    public var onResult: (@Sendable (_ problem: String?) -> Void)?

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// A session's status changed (`ShellSessionManager.onStatusChange`):
    /// sends what that calls for to every registered phone.
    public func observe(_ session: ShellSessionInfo, looking: Bool, macName: String) {
        guard let item = plan(session, looking: looking, macName: macName),
              let client = client?(), let registrations = registrations?() else { return }
        for (phoneID, registration) in registrations where allow(phoneID) {
            Task { _ = await deliver(item.notice, timeSensitive: item.timeSensitive, to: registration, phoneID: phoneID, client: client) }
        }
    }

    /// What one change calls for. Exposed for tests.
    func plan(_ session: ShellSessionInfo, looking watched: Bool, macName: String) -> Planned? {
        lock.lock(); defer { lock.unlock() }
        guard session.running, let status = session.status else {
            tracked[session.id] = nil   // ended, or a plain shell again
            return nil
        }
        var track = tracked[session.id] ?? Tracked()
        defer { tracked[session.id] = track }
        // A turn starts when it starts working, and lasts through its
        // questions until it is done, fails or goes idle.
        if status.isWorking, track.workingSince == nil { track.workingSince = status.since }
        if status.state == ShellStatus.idle { track.workingSince = nil }
        switch status.state {
        case ShellStatus.blocked:
            let about = "blocked|\(status.kind ?? "")|\(status.message ?? "")"
            guard track.settled != about else { return nil }
            track.settled = about
            return watched ? nil : Planned(notice: Self.notice(session, status, worked: nil, macName: macName), timeSensitive: true)
        case ShellStatus.done, ShellStatus.error:
            let about = "\(status.state)|\(status.since)"
            guard track.settled != about else { return nil }
            track.settled = about
            let worked = track.workingSince.map { status.since - $0 }
            track.workingSince = nil
            guard !watched, !status.seen, let worked, worked >= Self.minimumWork else { return nil }
            return Planned(notice: Self.notice(session, status, worked: worked, macName: macName), timeSensitive: false)
        default:
            // Answered: the same question asked again later is news again.
            if track.settled?.hasPrefix("blocked|") == true { track.settled = nil }
            return nil
        }
    }

    static func notice(_ session: ShellSessionInfo, _ status: ShellStatus, worked: TimeInterval?, macName: String) -> PushNotice {
        let name = session.title.isEmpty || session.title == "~" ? "A shell" : session.title
        let title: String, body: String
        switch status.state {
        case ShellStatus.blocked:
            title = "\(name) needs you"
            body = status.message ?? (status.kind == "permission" ? "It is asking for permission."
                : status.kind == "auth" ? "It needs you to sign in." : "It is asking you something.")
        case ShellStatus.error:
            title = "\(name) stopped with an error"
            body = status.message ?? "Open it to see what happened."
        default:
            title = "\(name) is done"
            body = worked.map { "Finished after \(duration($0))." } ?? "Finished."
        }
        return PushNotice(macName: macName, title: title, body: body, session: session.id, state: status.state)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    /// The APNs request body: a notice that says nothing, for the phone's
    /// extension to replace with what the sealed box says.
    public static func payload(sealed: String, macID: String, session: String, timeSensitive: Bool) -> Data {
        let aps: [String: Any] = [
            "alert": ["title": PushBox.fallbackTitle, "body": PushBox.fallbackBody],
            "mutable-content": 1,
            "sound": "default",
            "interruption-level": timeSensitive ? "time-sensitive" : "active",
            "thread-id": session,
        ]
        let body: [String: Any] = ["aps": aps, PushBox.payloadKey: ["m": macID, "b": sealed]]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    private func allow(_ phoneID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-60)
        var recent = (sentAt[phoneID] ?? []).filter { $0 > cutoff }
        guard recent.count < Self.perPhoneLimit else { return false }
        recent.append(now())
        sentAt[phoneID] = recent
        return true
    }

    /// Seals `notice` for one phone and sends it; a token that stopped
    /// working is forgotten (`onTokenGone`) and how it went is said (`onResult`).
    /// Also what Settings' test notice goes through.
    public func deliver(_ notice: PushNotice, timeSensitive: Bool, to registration: PushRegistration, phoneID: String,
                        client: APNsClient) async -> APNsClient.Outcome {
        guard let key = Data(base64Encoded: registration.key),
              let sealed = try? PushBox.seal(notice, key: key, macID: registration.mac) else { return .failed("unreadable registration") }
        let payload = Self.payload(sealed: sealed, macID: registration.mac, session: notice.session, timeSensitive: timeSensitive)
        let outcome = await client.send(payload, to: registration, collapseID: notice.session.isEmpty ? nil : notice.session,
                                        timeSensitive: timeSensitive)
        switch outcome {
        case .sent:
            onResult?(nil)
        case .tokenGone:
            ptLog(.info, "push: a phone's token no longer works; forgetting it")
            onTokenGone?(phoneID)
        case .credentialsRefused(let reason):
            ptLog(.error, "push: APNs refused the key (\(reason))")
            onResult?("Apple refused the push key (\(reason)). Check PASSTHROUGH_PUSH_KEY_FILE and the key's team (DEVELOPMENT_TEAM or PASSTHROUGH_PUSH_TEAM_ID) in Config/Signing.xcconfig, then rebuild.")
        case .failed(let reason):
            ptLog(.warning, "push: a notice was not sent (\(reason))")
            onResult?("The last notice was not sent (\(reason)).")
        }
        return outcome
    }
}
#endif
