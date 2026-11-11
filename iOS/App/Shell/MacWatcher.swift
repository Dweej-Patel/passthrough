import Foundation
import Network
import UIKit
import IrohTransport
import PassthroughCore

/// Keeps an eye on the paired Macs other than the selected one while the app
/// is in the foreground: one `ShellClient` per watched Mac, dialled as
/// `ShellModel.connect` dials, that only listens to what the Mac sends unasked
/// (`sessions`, `macState`). It never opens, attaches, closes or changes
/// anything, so the Mac being watched sees no difference.
@MainActor
final class MacWatcher: ObservableObject {
    /// What a watched Mac last said.
    struct Seen: Equatable {
        /// Its sessions, minus the finished ones this phone removed; nil until it sends them.
        var sessions: [ShellSessionInfo]?
        var state: MacState?
        var reachable: Bool
        var lastHeard: Date?
    }

    /// By Mac ID; only Macs being watched.
    @Published private(set) var seen: [String: Seen] = [:]

    /// The finished sessions this phone removed, per Mac. Set by the owner.
    var hiddenSessions: () -> ShellHiddenSessions = { ShellHiddenSessions() }
    /// The Bonjour result to dial for a Mac, if any. Set by the owner.
    var discovered: (ShellCredential) -> NWEndpoint? = { _ in nil }
    /// How recently each Mac was used (seconds since 1970). Set by the owner.
    var recency: () -> [String: Double] = { [:] }

    /// The wait before dialling a watched Mac again after it dropped or couldn't be reached.
    static let redialDelay: TimeInterval = 30
    /// At most this many Macs besides pinned ones.
    static let limit = 4
    /// Slower than the live connection's: a watch only needs to notice a dead
    /// connection eventually, and each ping costs battery and data.
    static let liveness = ShellClient.Liveness(interval: 15, silence: 45, probe: 3)

    private struct Watch {
        let credential: ShellCredential
        var client: ShellClient?
        var redial: Task<Void, Never>?
        /// The Mac refused the key: dialling again won't help.
        var refused = false
    }

    private var watches: [String: Watch] = [:]
    private var connectMode: ShellConnectMode?
    /// Bumped per `ShellClient`, so a stopped client's late events are dropped.
    private var generation = 0
    private var generations: [String: Int] = [:]

    /// Watches the Macs `MacProfiles.watched` picks from `credentials` (never
    /// `selected`; every `pinned` one), ending watches no longer wanted.
    func update(credentials: [ShellCredential], selected: String?, pinned: Set<String>, connectMode: ShellConnectMode) {
        if self.connectMode != connectMode {
            stop()
            self.connectMode = connectMode
        }
        let ids = MacProfiles.watched(candidates: credentials.map(\.macID), selected: selected, recency: recency(),
                                      pinned: pinned, limit: Self.limit)
        let wanted = ids.compactMap { id in credentials.first { $0.macID == id } }
        let changes = MacProfiles.watchChanges(running: watches.mapValues(\.credential), wanted: wanted)
        for id in changes.stop { end(id) }
        for credential in changes.start {
            watches[credential.macID] = Watch(credential: credential)
            dial(credential.macID)
        }
    }

    /// Ends every watch (backgrounding, relock) and forgets what they said.
    func stop() {
        for id in Array(watches.keys) { end(id) }
        seen = [:]
    }

    // MARK: Private

    private func end(_ id: String) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        generations[id] = nil
        watch.redial?.cancel()
        watch.client?.disconnect()
        seen[id] = nil
    }

    private func dial(_ id: String) {
        guard var watch = watches[id], let connectMode else { return }
        watch.redial?.cancel()
        watch.redial = nil
        generation += 1
        let gen = generation
        generations[id] = gen
        let credential = watch.credential
        let triesIroh = connectMode == .automatic && credential.irohID.map(IrohInfo.isValidID) == true
        // A fresh iroh endpoint per connect, as for the live connection; the client shuts it down.
        let client = ShellClient(credential: credential, queue: .main, iroh: triesIroh ? IrohShellDialer() : nil,
                                 mode: connectMode, liveness: Self.liveness) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, mac: id, generation: gen) }
        }
        watch.client = client
        watches[id] = watch
        if seen[id] == nil { seen[id] = Seen(sessions: nil, state: nil, reachable: false, lastHeard: Self.storedLastHeard(id)) }
        client.connect(discovered: discovered(credential))
    }

    private func handle(_ event: ShellClient.Event, mac id: String, generation gen: Int) {
        guard generations[id] == gen, watches[id] != nil else { return }
        switch event {
        case .ready:
            let now = Date()
            ShellModel.noteHeard(id, at: now)
            seen[id]?.reachable = true
            seen[id]?.lastHeard = now
        case let .sessions(list):
            seen[id]?.sessions = hiddenSessions().visible(list, on: id)
        case let .macState(state):
            seen[id]?.state = state
        case .failed(.notAuthorized, _):
            watches[id]?.refused = true
        case let .disconnected(error):
            watches[id]?.client = nil
            if seen[id]?.reachable == true {
                let now = Date()
                ShellModel.noteHeard(id, at: now)
                seen[id]?.reachable = false
                seen[id]?.lastHeard = now
            }
            // nil: this side hung up (`end` already dropped the watch).
            guard error != nil, watches[id]?.refused == false else { return }
            scheduleRedial(id)
        case let .screen(stream, _):
            // A watch never asks for the screen.
            stream.cancel()
        case .macInfo, .events, .opened, .openedDetached, .openFailed, .output, .attached,
             .ended, .detached, .history, .transcript, .transcriptResize, .failed:
            // Nothing a watch asks for (`ended` is followed by a fresh `sessions`).
            break
        }
    }

    private func scheduleRedial(_ id: String) {
        watches[id]?.redial?.cancel()
        watches[id]?.redial = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.redialDelay))
            guard !Task.isCancelled, let self, self.watches[id]?.client == nil,
                  UIApplication.shared.applicationState != .background else { return }
            self.dial(id)
        }
    }

    private static func storedLastHeard(_ id: String) -> Date? {
        ShellModel.lastHeardStore[id].map(Date.init(timeIntervalSince1970:))
    }

    #if DEBUG
    /// For the demo (`-PTDemoShell`): what the watched demo Macs say, without dialling.
    func demoShow(_ seen: [String: Seen]) {
        for id in Array(watches.keys) { end(id) }
        self.seen = seen
    }
    #endif
}
