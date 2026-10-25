import Foundation
import Combine
import PassthroughCore

/// What phones see of the Mac (Keep awake, battery, heat, the VPN) and what
/// they may change. Turning things on is quiet; a phone turning the VPN off
/// drops a notice from the notch that stays until someone at the Mac sees it.
/// The Mac's own limits (battery, heat) still apply to whatever a phone asks.
@MainActor
final class MacStateBridge {
    private let shell: RemoteShellController
    private let keepAwake: KeepAwakeController
    private let vpn: VPNLayer
    private let notice = NotchNotice()
    private var cancellables: Set<AnyCancellable> = []

    init(shell: RemoteShellController, keepAwake: KeepAwakeController, vpn: VPNLayer) {
        self.shell = shell
        self.keepAwake = keepAwake
        self.vpn = vpn
        shell.onMacControl = { [weak self] label, change in self?.apply(change, from: label) }
        // Each publisher fires before its value changes: read the state on the next turn.
        Publishers.MergeMany(
            keepAwake.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            vpn.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.publish() }
            .store(in: &cancellables)
        publish()
    }

    private func publish() {
        shell.updateMacState(Self.state(keepAwake: keepAwake, vpn: vpn))
    }

    static func state(keepAwake: KeepAwakeController, vpn: VPNLayer) -> MacState {
        let battery = keepAwake.battery
        var state = MacState(awake: keepAwake.isOn, awakeStopped: keepAwake.stoppedBy,
                             hot: KeepAwakeController.isHot(keepAwake.thermal))
        if battery.hasBattery, battery.percent >= 0 {
            state.battery = Double(battery.percent) / 100
            state.charging = battery.isOnAC
            let floor = keepAwake.batteryAutoOff ? keepAwake.batteryAutoOffThreshold : 0
            if keepAwake.batteryAutoOff { state.batteryFloor = Double(floor) / 100 }
            if let toEmpty = battery.minutesToEmpty, battery.percent > floor {
                // macOS estimates time to empty; Keep awake stops at the floor. Rounded so it doesn't churn.
                let toFloor = Double(toEmpty) * Double(battery.percent - floor) / Double(battery.percent)
                state.minutesLeft = Int((toFloor / 5).rounded()) * 5
            }
        }
        if let profile = vpn.activeProfile {
            state.vpnName = profile.name
            state.killSwitch = vpn.killSwitch
            state.vpn = !vpn.isWanted ? MacState.vpnOff
                : vpn.status.state == "failed" ? MacState.vpnFailed
                : vpn.status.isConnected ? MacState.vpnOn
                : MacState.vpnConnecting
        }
        return state
    }

    private func apply(_ change: MacControl, from label: String) {
        switch change {
        case .awake(let on):
            ptLog(.info, "\(label) turned Keep awake \(on ? "on" : "off")")
            keepAwake.set(on)
            if on, let refused = keepAwake.blockedReason {
                notice.show(.quiet(title: "\(label) asked to keep the Mac awake", detail: refused, symbol: "cup.and.saucer"))
            } else {
                notice.show(.quiet(title: "\(label) turned Keep awake \(on ? "on" : "off")", detail: nil, symbol: "cup.and.saucer"))
            }
        case .vpn(let on):
            ptLog(.info, "\(label) turned the VPN \(on ? "on" : "off")")
            guard on != vpn.isWanted else { return publish() }
            vpn.set(on)
            if on {
                notice.show(.quiet(title: "\(label) turned the VPN on", detail: vpn.activeProfile?.name, symbol: "lock.shield"))
            } else {
                notice.show(.lowered(title: "\(label) turned the VPN off", detail: vpn.killSwitch ? "Kill switch off too" : nil,
                                     action: "Turn back on") { [weak self] in self?.vpn.set(true) })
            }
        }
        publish()
    }
}
