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
        var state: String
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

    /// The sessions as they are now, and those someone is looking at. Sends
    /// what that calls for to every registered phone.
    public func update(_ sessions: [ShellSessionInfo], looking: Set<String>, macName: String) {
        let planned = plan(sessions, looking: looking, macName: macName)
        guard !planned.isEmpty, let client = client?(), let registrations = registrations?(), !registrations.isEmpty else { return }
        for item in planned {
            for (phoneID, registration) in registrations where allow(phoneID) {
                send(item, to: registration, phoneID: phoneID, client: client)
            }
        }
    }

    /// What the change from the last list calls for. Exposed for tests.
    func plan(_ sessions: [ShellSessionInfo], looking: Set<String>, macName: String) -> [Planned] {
        lock.lock(); defer { lock.unlock() }
        var planned: [Planned] = []
        var next: [String: Tracked] = [:]
        for session in sessions where session.running {
            guard let status = session.status else { continue }
            var track = tracked[session.id] ?? Tracked(state: status.state)
            // A turn starts when it starts working, and lasts through its
            // questions until it is done, fails or goes idle.
            if status.isWorking, track.workingSince == nil { track.workingSince = status.since }
            if status.state == ShellStatus.idle { track.workingSince = nil }
            track.state = status.state
            let watched = looking.contains(session.id)
            switch status.state {
            case ShellStatus.blocked:
                let about = "blocked|\(status.kind ?? "")|\(status.message ?? "")"
                if track.settled != about {
                    track.settled = about
                    if !watched { planned.append(Planned(notice: Self.notice(session, status, worked: nil, macName: macName), timeSensitive: true)) }
                }
            case ShellStatus.done, ShellStatus.error:
                let about = "\(status.state)|\(status.since)"
                if track.settled != about {
                    track.settled = about
                    let worked = track.workingSince.map { status.since - $0 }
                    if !watched, !status.seen, let worked, worked >= Self.minimumWork {
                        planned.append(Planned(notice: Self.notice(session, status, worked: worked, macName: macName), timeSensitive: false))
                    }
                    track.workingSince = nil
                }
            default:
                break
            }
            next[session.id] = track
        }
        tracked = next
        return planned
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

    private func send(_ item: Planned, to registration: PushRegistration, phoneID: String, client: APNsClient) {
        guard let key = Data(base64Encoded: registration.key),
              let sealed = try? PushBox.seal(item.notice, key: key, macID: registration.mac) else { return }
        let payload = Self.payload(sealed: sealed, macID: registration.mac, session: item.notice.session, timeSensitive: item.timeSensitive)
        let onTokenGone = onTokenGone, onResult = onResult
        Task {
            switch await client.send(payload, to: registration, collapseID: item.notice.session, timeSensitive: item.timeSensitive) {
            case .sent:
                onResult?(nil)
            case .tokenGone:
                ptLog(.info, "push: a phone's token no longer works; forgetting it")
                onTokenGone?(phoneID)
            case .credentialsRefused(let reason):
                ptLog(.error, "push: APNs refused the key (\(reason))")
                onResult?("Apple refused the push key (\(reason)). Check the Team ID, the Key ID and the key file.")
            case .failed(let reason):
                ptLog(.warning, "push: a notice was not sent (\(reason))")
                onResult?("The last notice was not sent (\(reason)).")
            }
        }
    }
}
#endif
