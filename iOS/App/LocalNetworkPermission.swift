import Foundation
import Network
import PassthroughCore

/// Only the app can show iOS's Local Network prompt, and until it has been
/// answered the tunnel extension's listeners silently receive nothing. A short
/// peer-to-peer browse from the app raises the prompt.
enum LocalNetworkPermission {
    private static var browser: NWBrowser?

    static func request() {
        browser?.cancel()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: PeerProbeServer.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { state in ptLog(.info, "local network permission check: \(state)") }
        browser.start(queue: .main)
        self.browser = browser
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { browser.cancel(); if self.browser === browser { self.browser = nil } }
    }
}
