import AppKit
import Combine
import PassthroughCore
import ShellHost

/// Writes what happens on the Mac into the event log a phone's timeline reads:
/// Keep awake and why it stopped, the VPN dropping and coming back, the phone's
/// connection, power, sleep and wake, and shells finishing, asking and being
/// answered. Changes a phone asked for are told by `phoneChanged`, so they
/// read "iPhone turned the VPN off" rather than appearing twice.
@MainActor
final class MacEventRecorder {
    private let log: MacEventLog
    private let session: SessionCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    private var awake: Bool
    private var vpnUp: Bool
    private var vpnConnected = false
    /// When a wanted VPN stopped being connected, to say how long it took to come back.
    private var vpnDroppedAt: Date?
    private var charging: Bool?
    private var connected: Bool
    private var sessions: [String: ShellSessionInfo] = [:]
    /// What a phone just asked for: the change it causes is already written.
    private var askedByPhone: (change: MacControl, at: Date)?

    init(log: MacEventLog, session: SessionCoordinator) {
        self.log = log
        self.session = session
        awake = session.keepAwake.isOn
        vpnUp = session.vpnLayer.isWanted
        vpnConnected = session.vpnLayer.status.isConnected
        connected = session.phase.isConnected
        sessions = Dictionary(uniqueKeysWithValues: session.shell.sessions.map { ($0.id, $0) })

        session.keepAwake.objectWillChange.merge(with: session.vpnLayer.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.powerAndVPNChanged() }
            .store(in: &cancellables)
        session.$phase.removeDuplicates { $0.isConnected == $1.isConnected }
            .dropFirst()
            .sink { [weak self] phase in self?.linkChanged(phase.isConnected) }
            .store(in: &cancellables)
        session.shell.$sessions
            .sink { [weak self] list in self?.sessionsChanged(list) }
            .store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log.record("sleep", "The Mac went to sleep") }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log.record("sleep", "The Mac woke up") }
        })
    }

    /// A phone asked for `change` and it's being carried out.
    func phoneChanged(_ change: MacControl, by label: String) {
        askedByPhone = (change, .now)
        switch change {
        case .awake(true): log.record("awake", "\(label) turned Keep awake on")
        case .awake(false): log.record("awake", "\(label) let the Mac sleep")
        case .vpn(true): log.record("vpn", "\(label) turned the VPN on")
        case .vpn(false): log.record("vpn", "\(label) turned the VPN off", warning: true)
        }
    }

    /// A phone asked, and the Mac's own limit said no.
    func phoneRefused(_ change: MacControl, by label: String, reason: String) {
        log.record("awake", "\(label) asked to keep the Mac awake", detail: reason, warning: true)
    }

    private func fromPhone(_ change: MacControl) -> Bool {
        guard let asked = askedByPhone, asked.change == change, Date.now.timeIntervalSince(asked.at) < 10 else { return false }
        askedByPhone = nil
        return true
    }

    private func powerAndVPNChanged() {
        let keepAwake = session.keepAwake
        let battery = keepAwake.battery
        if battery.hasBattery, battery.percent >= 0 {
            log.sample(level: Double(battery.percent) / 100, charging: battery.isOnAC)
            if let charging, charging != battery.isOnAC {
                log.record("power", battery.isOnAC ? "Plugged in at \(battery.percent)%" : "Unplugged at \(battery.percent)%")
            }
            charging = battery.isOnAC
        }
        if keepAwake.isOn != awake {
            awake = keepAwake.isOn
            if !fromPhone(.awake(awake)) {
                switch (awake, keepAwake.stoppedBy) {
                case (true, _): log.record("awake", "Keep awake turned on")
                case (false, .some("battery")): log.record("awake", "Keep awake stopped at \(battery.percent)% battery",
                                                    detail: "Your \(keepAwake.batteryAutoOffThreshold)% limit", warning: true)
                case (false, .some("heat")): log.record("awake", "Keep awake stopped: the Mac ran hot", warning: true)
                default: log.record("awake", "Keep awake turned off")
                }
            }
        }
        vpnChanged(session.vpnLayer)
    }

    private func vpnChanged(_ vpn: VPNLayer) {
        if vpn.isWanted != vpnUp {
            vpnUp = vpn.isWanted
            if !fromPhone(.vpn(vpnUp)) { log.record("vpn", vpnUp ? "VPN turned on" : "VPN turned off") }
            vpnDroppedAt = nil
        }
        let nowConnected = vpn.status.isConnected
        guard vpn.isWanted, nowConnected != vpnConnected else {
            vpnConnected = nowConnected
            return
        }
        vpnConnected = nowConnected
        if nowConnected {
            if let dropped = vpnDroppedAt {
                let seconds = max(1, Int(Date.now.timeIntervalSince(dropped).rounded()))
                log.record("vpn", "VPN reconnected after \(seconds) s",
                           detail: vpn.killSwitch ? "Kill switch held: nothing left without it" : nil)
            } else {
                log.record("vpn", "VPN connected", detail: vpn.activeProfile?.name)
            }
            vpnDroppedAt = nil
        } else if vpn.status.state == "failed" {
            log.record("vpn", "VPN failed", detail: vpn.killSwitch ? "Traffic blocked until it's turned off" : vpn.status.error, warning: true)
        } else {
            vpnDroppedAt = .now
            log.record("vpn", "VPN dropped", detail: "Reconnecting", warning: true)
        }
    }

    private func linkChanged(_ isConnected: Bool) {
        guard isConnected != connected else { return }
        connected = isConnected
        let phone = session.phoneStatus?.deviceName ?? session.phoneKindName
        log.record("link", isConnected ? "Online through \(phone)" : "Off \(phone)'s connection")
    }

    private func sessionsChanged(_ list: [ShellSessionInfo]) {
        for now in list {
            let before = sessions[now.id]
            if before?.running == true, !now.running {
                let minutes = max(0, Int((now.lastOutputAt - now.startedAt) / 60))
                let exit = now.exitStatus.map { "exit \($0)" } ?? "ended"
                log.record("shell", "\(now.title) finished", detail: "\(exit) · \(minutes) min", session: now.id,
                           warning: (now.exitStatus ?? 0) != 0)
            } else if now.running, let question = now.waiting, before?.waiting != question {
                log.record("asked", "\(now.title) asked", detail: question, session: now.id)
            } else if now.running, before?.waiting != nil, now.waiting == nil {
                log.record("answered", "\(now.title) got an answer", session: now.id)
            }
        }
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}
