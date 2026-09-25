import Foundation
import Network
import PassthroughCore

/// Only the app can show iOS's Local Network prompt, and until it has been
/// answered the tunnel extension's browser finds no Macs. A short browse for
/// the same service from the app raises the prompt; peer-to-peer is included
/// so the answer covers that setting too.
enum LocalNetworkPermission {
    private static var browser: NWBrowser?

    static func request() {
        browser?.cancel()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: WirelessLink.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { state in ptLog(.info, "local network permission check: \(state)") }
        browser.start(queue: .main)
        self.browser = browser
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { browser.cancel(); if self.browser === browser { self.browser = nil } }
    }
}
