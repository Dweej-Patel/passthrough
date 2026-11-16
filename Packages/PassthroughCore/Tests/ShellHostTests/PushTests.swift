#if os(macOS)
import CryptoKit
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

/// Notices to phones through APNs: sealing, the request, and when one is sent.
final class PushTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)
    private lazy var registration = PushRegistration(token: String(repeating: "ab", count: 32), environment: PushRegistration.sandbox,
                                                     topic: "dev.example.ios", key: key.base64EncodedString(), mac: "mac-1")

    // MARK: Sealing

    func testANoticeOpensOnlyWithItsKeyAndForItsMac() throws {
        let notice = PushNotice(macName: "Studio", title: "claude needs you", body: "approve Bash: ls", session: "s1", state: "blocked")
        let sealed = try PushBox.seal(notice, key: key, macID: "mac-1")
        XCTAssertEqual(PushBox.open(sealed, key: key, macID: "mac-1"), notice)
        XCTAssertNil(PushBox.open(sealed, key: Data(repeating: 8, count: 32), macID: "mac-1"), "another phone's key")
        XCTAssertNil(PushBox.open(sealed, key: key, macID: "mac-2"), "a box for one Mac never opens as another's")
        XCTAssertFalse(sealed.contains("approve"))
        XCTAssertEqual(PushBox.newKey().count, 32)
    }

    func testRegistrationsAreChecked() {
        XCTAssertTrue(registration.isValid)
        var bad = registration; bad.token = "ABCD"; XCTAssertFalse(bad.isValid, "short, upper case")
        bad = registration; bad.token = String(repeating: "zz", count: 32); XCTAssertFalse(bad.isValid, "not hex")
        bad = registration; bad.environment = "staging"; XCTAssertFalse(bad.isValid)
        bad = registration; bad.topic = "dev/../x"; XCTAssertFalse(bad.isValid)
        bad = registration; bad.key = Data(count: 16).base64EncodedString(); XCTAssertFalse(bad.isValid)
        bad = registration; bad.mac = ""; XCTAssertFalse(bad.isValid)
    }

    func testThePhonesKeysAreMadeOncePerMac() {
        let secrets = InMemorySecrets()
        let first = PushKeys.keyCreating(for: "mac-1", in: secrets)
        XCTAssertNotNil(first)
        XCTAssertEqual(PushKeys.keyCreating(for: "mac-1", in: secrets), first)
        XCTAssertNotEqual(PushKeys.keyCreating(for: "mac-2", in: secrets), first)
        PushKeys.forget("mac-1", in: secrets)
        XCTAssertNil(PushKeys.key(for: "mac-1", in: secrets))
    }

    // MARK: APNs

    final class FakeTransport: PushTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [(Int, String)]
        private(set) var requests: [URLRequest] = []
        init(_ answers: [(Int, String)]) { self.answers = answers }
        func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            let (status, body) = answers.isEmpty ? (200, "") : answers.removeFirst()
            return (status, Data(body.utf8))
        }
        var sent: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    private let signingKey = P256.Signing.PrivateKey()
    private var credentials: APNsCredentials {
        APNsCredentials(teamID: "TEAM123456", keyID: "KEY1234567", privateKey: signingKey.pemRepresentation)
    }

    func testCredentialsAreChecked() {
        XCTAssertNil(credentials.problem)
        XCTAssertNotNil(APNsCredentials(teamID: "short", keyID: "KEY1234567", privateKey: signingKey.pemRepresentation).problem)
        XCTAssertNotNil(APNsCredentials(teamID: "TEAM123456", keyID: "KEY1234567", privateKey: "not a key").problem)
    }

    func testTheRequestIsSignedAndAddressed() async throws {
        let transport = FakeTransport([(200, "")])
        let client = APNsClient(credentials: credentials, transport: transport)
        let outcome = await client.send(Data("{}".utf8), to: registration, collapseID: "s1", timeSensitive: true)
        XCTAssertEqual(outcome, .sent)
        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/\(registration.token)")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "dev.example.ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-collapse-id"), "s1")
        // The JWT: ES256 by the key, naming the key and the team.
        let bearer = try XCTUnwrap(request.value(forHTTPHeaderField: "authorization"))
        XCTAssertTrue(bearer.hasPrefix("bearer "))
        let parts = bearer.dropFirst("bearer ".count).split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b) ?? Data()
        }
        XCTAssertEqual(String(decoding: decode(parts[0]), as: UTF8.self), #"{"alg":"ES256","kid":"KEY1234567"}"#)
        XCTAssertTrue(String(decoding: decode(parts[1]), as: UTF8.self).hasPrefix(#"{"iss":"TEAM123456","iat":"#))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(signingKey.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    func testProductionPhonesGoToProductionAndTheTokenIsReused() async throws {
        let transport = FakeTransport([])
        let client = APNsClient(credentials: credentials, transport: transport)
        var production = registration
        production.environment = PushRegistration.production
        _ = await client.send(Data(), to: production, collapseID: nil, timeSensitive: false)
        _ = await client.send(Data(), to: production, collapseID: nil, timeSensitive: false)
        XCTAssertEqual(transport.sent.first?.url?.host, "api.push.apple.com")
        XCTAssertEqual(transport.sent.first?.value(forHTTPHeaderField: "apns-priority"), "5")
        XCTAssertNil(transport.sent.first?.value(forHTTPHeaderField: "apns-collapse-id"))
        XCTAssertEqual(transport.sent[0].value(forHTTPHeaderField: "authorization"), transport.sent[1].value(forHTTPHeaderField: "authorization"))
    }

    func testAPNsAnswers() async {
        let answers: [(Int, String, APNsClient.Outcome)] = [
            (410, #"{"reason":"Unregistered"}"#, .tokenGone),
            (400, #"{"reason":"BadDeviceToken"}"#, .tokenGone),
            (403, #"{"reason":"InvalidProviderToken"}"#, .credentialsRefused("InvalidProviderToken")),
            (400, #"{"reason":"TopicDisallowed"}"#, .credentialsRefused("TopicDisallowed")),
            (429, #"{"reason":"TooManyRequests"}"#, .failed("TooManyRequests")),
            (500, "", .failed("HTTP 500")),
        ]
        for (status, body, expected) in answers {
            let client = APNsClient(credentials: credentials, transport: FakeTransport([(status, body)]))
            let outcome = await client.send(Data(), to: registration, collapseID: nil, timeSensitive: false)
            XCTAssertEqual(outcome, expected, "\(status) \(body)")
        }
    }

    // MARK: When

    private func session(_ state: String, since: Double, id: String = "s1", title: String = "claude", kind: String? = nil,
                         message: String? = nil, seen: Bool = false) -> ShellSessionInfo {
        ShellSessionInfo(id: id, title: title, startedAt: 0, lastOutputAt: since, running: true,
                         status: ShellStatus(state: state, kind: kind, message: message, since: since, seen: seen))
    }

    private func plan(_ notifier: PushNotifier, _ sessions: [ShellSessionInfo], looking: Set<String> = []) -> [String] {
        sessions.compactMap { notifier.plan($0, looking: looking.contains($0.id), macName: "Studio") }
            .map { "\($0.notice.title) | \($0.notice.body)\($0.timeSensitive ? " !" : "")" }
    }

    func testAQuestionIsToldOnceAndANewOneAgain() {
        let notifier = PushNotifier()
        XCTAssertEqual(plan(notifier, [session("working", since: 100)]), [])
        XCTAssertEqual(plan(notifier, [session("blocked", since: 110, kind: "permission", message: "approve Bash: ls")]),
                       ["claude needs you | approve Bash: ls !"])
        XCTAssertEqual(plan(notifier, [session("blocked", since: 110, kind: "permission", message: "approve Bash: ls")]), [], "the same question")
        XCTAssertEqual(plan(notifier, [session("blocked", since: 120, kind: "question", message: "answer: Pick (A · B)")]),
                       ["claude needs you | answer: Pick (A · B) !"])
    }

    /// Answered, then the same question again in the same turn: news again.
    func testTheSameQuestionAgainAfterAnAnswerIsToldAgain() {
        let notifier = PushNotifier()
        let ask = session("blocked", since: 110, kind: "permission", message: "approve Bash: npm test")
        XCTAssertEqual(plan(notifier, [ask]).count, 1)
        _ = plan(notifier, [session("working", since: 115)])
        XCTAssertEqual(plan(notifier, [session("blocked", since: 130, kind: "permission", message: "approve Bash: npm test")]),
                       ["claude needs you | approve Bash: npm test !"])
    }

    /// A session gone, or back to a plain shell, starts over.
    func testAnEndedSessionIsForgotten() {
        let notifier = PushNotifier()
        XCTAssertEqual(plan(notifier, [session("blocked", since: 1, kind: "question", message: "q")]).count, 1)
        var ended = session("blocked", since: 1, kind: "question", message: "q")
        ended.running = false
        XCTAssertEqual(plan(notifier, [ended]), [])
        XCTAssertEqual(plan(notifier, [session("blocked", since: 1, kind: "question", message: "q")]).count, 1, "a new start")
    }

    func testNothingAboutASessionSomeoneIsLookingAt() {
        let notifier = PushNotifier()
        XCTAssertEqual(plan(notifier, [session("blocked", since: 110, kind: "question")], looking: ["s1"]), [])
        XCTAssertEqual(plan(notifier, [session("blocked", since: 110, kind: "question")]), [], "they saw it ask; leaving is not news")
    }

    func testDoneIsToldAfterALongTurnOnly() {
        let notifier = PushNotifier()
        _ = plan(notifier, [session("working", since: 100)])
        _ = plan(notifier, [session("blocked", since: 120, kind: "permission")])
        _ = plan(notifier, [session("working", since: 125)])
        XCTAssertEqual(plan(notifier, [session("done", since: 190)]), ["claude is done | Finished after 1 min."], "90 s from the start of the turn")
        XCTAssertEqual(plan(notifier, [session("done", since: 190)]), [])
        _ = plan(notifier, [session("working", since: 200)])
        XCTAssertEqual(plan(notifier, [session("done", since: 210)]), [], "a short turn")
        _ = plan(notifier, [session("working", since: 300)])
        XCTAssertEqual(plan(notifier, [session("done", since: 400, seen: true)]), [], "seen")
        _ = plan(notifier, [session("working", since: 500)])
        XCTAssertEqual(plan(notifier, [session("error", since: 600, message: "rate limited")]), ["claude stopped with an error | rate limited"])
    }

    func testDoneWithoutHavingSeenItWorkIsNotNews() {
        let notifier = PushNotifier()
        XCTAssertEqual(plan(notifier, [session("done", since: 500)]), [], "the Mac app just started, say")
    }

    func testAnUntitledSessionIsAShell() {
        let notifier = PushNotifier()
        XCTAssertEqual(plan(notifier, [session("blocked", since: 1, title: "~", kind: "auth")]), ["A shell needs you | It needs you to sign in. !"])
    }

    /// End to end: what goes to APNs opens, with the phone's key, to what happened.
    func testWhatIsSentOpensOnThePhone() async throws {
        let transport = FakeTransport([])
        let client = APNsClient(credentials: credentials, transport: transport)
        let notifier = PushNotifier()
        let registration = self.registration
        notifier.client = { client }
        notifier.registrations = { ["phone-1": registration] }
        notifier.observe(session("blocked", since: 1, kind: "question", message: "answer: Pick (A · B)"), looking: false, macName: "Studio")
        let deadline = Date().addingTimeInterval(5)
        while transport.sent.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let body = try XCTUnwrap(transport.sent.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(aps["mutable-content"] as? Int, 1)
        XCTAssertEqual(aps["interruption-level"] as? String, "time-sensitive")
        XCTAssertEqual((aps["alert"] as? [String: String])?["body"], PushBox.fallbackBody, "Apple carries nothing about what happened")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("Pick"))
        let sealed = try XCTUnwrap(json[PushBox.payloadKey] as? [String: String])
        XCTAssertEqual(sealed["m"], "mac-1")
        let notice = try XCTUnwrap(PushBox.open(try XCTUnwrap(sealed["b"]), key: key, macID: "mac-1"))
        XCTAssertEqual(notice, PushNotice(macName: "Studio", title: "claude needs you", body: "answer: Pick (A · B)", session: "s1", state: "blocked"))
    }

    func testAPhoneGetsAtMostTenAMinute() {
        let notifier = PushNotifier()
        var allowed = 0
        let transport = FakeTransport([])
        let client = APNsClient(credentials: credentials, transport: transport)
        let registration = self.registration
        notifier.client = { client }
        notifier.registrations = { ["phone-1": registration] }
        for n in 0..<15 {
            notifier.observe(session("blocked", since: Double(n), kind: "question", message: "q\(n)"), looking: false, macName: "Studio")
        }
        let deadline = Date().addingTimeInterval(5)
        while transport.sent.count < PushNotifier.perPhoneLimit, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.2)
        allowed = transport.sent.count
        XCTAssertEqual(allowed, PushNotifier.perPhoneLimit)
    }

    // MARK: Registry

    func testTheRegistryKeepsPhonesUntilRemoved() {
        let secrets = InMemorySecrets()
        let registry = PushRegistry(secrets: secrets)
        registry.set(registration, for: "phone-1")
        registry.set(registration, for: "phone-2")
        XCTAssertEqual(Set(PushRegistry(secrets: secrets).all.keys), ["phone-1", "phone-2"], "kept across launches")
        registry.remove("phone-1")
        XCTAssertEqual(Set(registry.all.keys), ["phone-2"])
        registry.remove("phone-2")
        XCTAssertNil(secrets.read(PushRegistry.account), "nothing left in the Keychain")
    }

    /// A build's tokens are for the APNs its profile names.
    func testTheEnvironmentComesFromTheProvisioningProfile() {
        func profile(_ aps: String?) -> Data {
            let entitlements = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            return Data(("\u{30}\u{82}signed-junk<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
                + "<key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>more-junk").utf8)
        }
        XCTAssertEqual(PushRegistration.environment(ofProfile: profile("development")), PushRegistration.sandbox)
        XCTAssertEqual(PushRegistration.environment(ofProfile: profile("production")), PushRegistration.production)
        XCTAssertEqual(PushRegistration.environment(ofProfile: profile(nil)), PushRegistration.production)
        XCTAssertEqual(PushRegistration.environment(ofProfile: Data("garbage".utf8)), PushRegistration.production)
    }

    // MARK: The session manager

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(ShellSessionInfo, Bool)] = []
        func add(_ s: ShellSessionInfo, _ l: Bool) { lock.lock(); items.append((s, l)); lock.unlock() }
        var states: [String] { lock.lock(); defer { lock.unlock() }; return items.map { $0.0.running ? ($0.0.status?.state ?? "none") : "ended" } }
    }

    /// A status that lasts a moment (done, then the program gone) still
    /// reaches the notifier: each change is handed over as it happens.
    func testEveryShownStatusChangeIsHandedOverInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PushTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ShellSessionManager(transcripts: try TranscriptStore(directory: directory), command: { ("/bin/sh", []) },
                                          environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
                                          directory: URL(fileURLWithPath: "/tmp"), endedRetention: 600, quietBeforeAsking: 0.2)
        defer { manager.closeAll() }
        let recorder = Recorder()
        manager.onStatusChange = { recorder.add($0, $1) }
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        // Working with changing messages (not handed over), done, then gone at once.
        let msg = { (t: String) in Data(t.utf8).base64EncodedString() }
        manager.input(id, Data(("sh -c \"printf '\\033]7501;state=working:msg=\(msg("a"))\\007'; printf '\\033]7501;state=working:msg=\(msg("b"))\\007'; "
            + "printf '\\033]7501;state=done\\007'\"\n").utf8))
        let deadline = Date().addingTimeInterval(10)
        while recorder.states.count < 3, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(recorder.states, ["working", "done", "none"])
    }

    /// A program the shell `exec`ed runs in the shell's own process: what it
    /// reports lasts while it runs, though the shell's group is in front.
    func testAProgramTheShellExecedKeepsItsStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PushTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ShellSessionManager(transcripts: try TranscriptStore(directory: directory), command: { ("/bin/sh", []) },
                                          environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
                                          directory: URL(fileURLWithPath: "/tmp"), endedRetention: 600, quietBeforeAsking: 0.2)
        defer { manager.closeAll() }
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        let status = { manager.sessions.first { $0.id == id }?.status?.state }
        // awk replaces the shell, reports, then keeps running.
        manager.input(id, Data("exec /usr/bin/awk 'BEGIN { printf \"\\033]7501;state=working\\007\"; system(\"sleep 5\") }'\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while status() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(status(), "working")
        manager.input(id, Data("x\n".utf8))   // more output while it runs: still its status
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(status(), "working")
    }
}
#endif
