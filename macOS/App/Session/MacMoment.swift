import Foundation
import PassthroughCore

/// The Mac's one reading of Desk / Away / Public and its one way of applying
/// them, for the panel's picker and its Heading-out tip alike: built on
/// `Moment.plan`, as the phones are, so every side agrees.
extension SessionCoordinator {
    /// Online through a phone, or on its way there: the Internet part of a
    /// moment (`MacState.internet`).
    var internetShared: Bool { phase.isConnected || phase.isBusy }

    var currentMoment: Moment {
        Moment.current(internet: internetShared, awake: keepAwake.isOn, vpn: vpnLayer.isWanted)
    }

    /// What picking `moment` would change; nil for `custom`.
    func plan(_ moment: Moment) -> MomentPlan? {
        moment.plan(internet: internetShared, awake: keepAwake.isOn, vpn: vpnLayer.isWanted)
    }

    /// What to say before letting the Mac sleep while phones' shells run; nil when none do.
    var sleepWarning: String? {
        let running = shell.sessions.filter(\.running).count
        guard running > 0 else { return nil }
        let shells = running == 1 ? "A shell from your phone is" : "\(running) shells from your phone are"
        return "\(shells) running. Asleep, the Mac pauses \(running == 1 ? "it" : "them") until it wakes."
    }

    /// Sets the switches `moment` changes. Ask with `sleepWarning` first when
    /// `plan(moment)?.letsSleep`. False when it needs a VPN set up first
    /// (`momentNote` says so, and the caller opens VPN settings).
    @discardableResult
    func apply(_ moment: Moment) -> Bool {
        momentNote = nil
        guard let plan = plan(moment), !plan.isEmpty else { return true }
        if plan.needsVPN, vpnLayer.activeProfile == nil {
            momentNote = "\(moment.title) needs a VPN. Add one in Settings ▸ VPN."
            return false
        }
        pendingMoment = moment
        switch plan.internet {
        case true?:
            if device != nil {
                connect()
            } else {
                momentNote = "Plug in the phone (or bring it near, for the wireless link) to go online through it."
            }
        case false?:
            disconnect()
            momentNote = offPhoneCaution
        case nil: break
        }
        if let awake = plan.awake { keepAwake.set(awake) }
        if let vpn = plan.vpn { vpnLayer.set(vpn) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.pendingMoment == moment { self?.pendingMoment = nil }
        }
        return true
    }

    /// Off the phone's connection with nothing else to go online on: a caution,
    /// since the path monitor can't see every way the Mac could get online.
    private var offPhoneCaution: String? {
        if onPhoneHotspot { return "This Mac's Wi-Fi is a phone's hotspot: it goes when the phone does, and the Mac can't be reached then." }
        if ownNetwork == false { return "This Mac doesn't seem to have Wi-Fi or Ethernet of its own: off the phone it may be offline and out of reach." }
        return nil
    }
}
