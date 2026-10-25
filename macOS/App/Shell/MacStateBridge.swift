import Foundation
import Combine
import PassthroughCore

/// What phones see of the Mac (Internet, Keep awake, battery, heat, the VPN)
/// and what they may change. Turning things on is quiet; a phone turning the
/// VPN off drops a notice from the notch that stays until someone at the Mac
/// sees it, or the VPN comes back on. The Mac's own limits (battery, heat)
/// still apply to whatever a phone asks.
@MainActor
final class MacStateBridge {
    private let session: SessionCoordinator
    private let notice = NotchNotice()
    private let recorder: MacEventRecorder
    private var cancellables: Set<AnyCancellable> = []
    /// When each refusal reason was last told, so a phone retrying at a limit doesn't stack them.
    private var refusedAt: [String: Date] = [:]

    private var shell: RemoteShellController { session.shell }
    private var keepAwake: KeepAwakeController { session.keepAwake }
    private var vpn: VPNLayer { session.vpnLayer }

    init(session: SessionCoordinator, recorder: MacEventRecorder) {
        self.session = session
        self.recorder = recorder
        shell.onMacControl = { [weak self] label, change in self?.apply(change, from: label) }
        // Each publisher fires before its value changes: read the state on the next turn.
        Publishers.MergeMany(
            session.keepAwake.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.vpnLayer.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.$phase.map { $0.isConnected || $0.isBusy }.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.publish() }
            .store(in: &cancellables)
        // The VPN back on, by any path: the "VPN turned off" notice has nothing left to say.
        session.vpnLayer.$isWanted.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.notice.hideLowered() }
            .store(in: &cancellables)
        publish()
    }

    private func publish() {
        shell.updateMacState(Self.state(session: session))
    }

    static func state(session: SessionCoordinator) -> MacState {
        let keepAwake = session.keepAwake, vpn = session.vpnLayer
        let battery = keepAwake.battery
        var state = MacState(awake: keepAwake.isOn, awakeStopped: keepAwake.stoppedBy,
                             hot: KeepAwakeController.isHot(keepAwake.thermal), internet: session.internetShared)
        if battery.hasBattery, battery.percent >= 0 {
            state.battery = Double(battery.percent) / 100
            state.charging = battery.isOnAC
            let floor = keepAwake.batteryAutoOff ? keepAwake.batteryAutoOffThreshold : 0
            if keepAwake.batteryAutoOff { state.batteryFloor = Double(floor) / 100 }
            if let toEmpty = battery.minutesToEmpty {
                state.minutesLeft = MacState.minutesLeft(percent: battery.percent, toEmpty: toEmpty, floor: floor)
            }
        }
        if let profile = vpn.activeProfile {
            state.vpnName = profile.name
            state.killSwitch = vpn.killSwitch
            state.vpn = !vpn.isWanted ? MacState.vpnOff
                : vpn.status.isFailing ? MacState.vpnFailed
                : vpn.status.isConnected ? MacState.vpnOn
                : MacState.vpnConnecting
        }
        return state
    }

    private func apply(_ change: MacControl, from label: String) {
        switch change {
        case .awake(let on):
            ptLog(.info, "\(label) turned Keep awake \(on ? "on" : "off")")
            // Nothing to change (a moment resending what's already so): no notice, no log.
            guard on != keepAwake.isOn else { return publish() }
            keepAwake.set(on)
            if on, let refused = keepAwake.blockedReason {
                let key = keepAwake.stoppedBy ?? refused
                if let last = refusedAt[key], Date.now.timeIntervalSince(last) < 60 { return publish() }
                refusedAt[key] = .now
                recorder.phoneRefused(change, by: label, reason: refused)
                notice.show(.quiet(title: "\(label) asked to keep the Mac awake", detail: refused, symbol: "cup.and.saucer"))
            } else {
                recorder.phoneChanged(change, by: label)
                notice.show(.quiet(title: "\(label) turned Keep awake \(on ? "on" : "off")", detail: nil, symbol: "cup.and.saucer"))
            }
        case .vpn(let on):
            ptLog(.info, "\(label) turned the VPN \(on ? "on" : "off")")
            guard on != vpn.isWanted else { return publish() }
            recorder.phoneChanged(change, by: label)
            let killSwitch = vpn.killSwitch
            vpn.set(on)
            if on {
                notice.show(.quiet(title: "\(label) turned the VPN on", detail: vpn.activeProfile?.name, symbol: "lock.shield"))
            } else {
                notice.show(.lowered(title: "VPN turned off", detail: "by \(label)\(killSwitch ? " · kill switch off too" : "")",
                                     action: "Turn back on") { [weak self] in self?.vpn.set(true) })
            }
        }
        publish()
    }
}
