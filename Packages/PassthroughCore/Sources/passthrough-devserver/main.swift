import Foundation
import PassthroughCore

// Runs the iPhone-side servers on this Mac for development and protocol testing.
// Usage: swift run passthrough-devserver [socksPort] [controlPort]
// Prints a pairing code; pair with the control channel or use client "dev" / token "dev-token".

let socksPort = UInt16(CommandLine.arguments.dropFirst().first ?? "") ?? PassthroughProtocol.defaultSOCKSPort
let controlPort = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") ?? PassthroughProtocol.defaultControlPort
let defaults = UserDefaults(suiteName: "dev.dpatel.passthrough.devserver")!
let registry = PairingRegistry(defaults: defaults)

// Seed a client so hev/curl can be pointed at it without pairing.
// Optional args 3 & 4 override the default dev/dev-token, to match a real Mac's creds.
let seedID = CommandLine.arguments.dropFirst(3).first ?? "dev"
let seedToken = CommandLine.arguments.dropFirst(4).first ?? "dev-token"
defaults.set(try? JSONEncoder().encode([PairedClient(id: seedID, name: "Dev client", tokenHash: PairingRegistry.hash(token: seedToken), pairedAt: Date())]), forKey: PairingRegistry.clientsKey)

var options = PassthroughService.Options()
options.refuseLocalDestinations = false
options.disableAuth = CommandLine.arguments.contains("noauth")
options.socksPort = socksPort
options.controlPort = controlPort
let noAuth = CommandLine.arguments.contains("noauth")
let service = PassthroughService(registry: noAuth ? PairingRegistry(defaults: UserDefaults(suiteName: "dev.dpatel.passthrough.devserver.noauth")!) : registry, options: options) {
    DeviceStatus(deviceName: "Dev server", radio: "LAN", hosting: "devserver")
}
PassthroughLog.shared.onAppend = { entry in print("[\(entry.level.rawValue)] \(entry.message)") }
service.onClientsChanged = { macs in print("connected macs: \(macs.map(\.name))") }
try service.start()
let (code, _) = registry.issueCode()
print("SOCKS5 on 127.0.0.1:\(socksPort) (user dev / password dev-token), control on \(controlPort), pairing code \(code)")
print("try: curl --socks5-hostname 127.0.0.1:\(socksPort) --proxy-user dev:dev-token https://example.com")

signal(SIGINT) { _ in service.stop(); exit(0) }
let ticker = Timer(timeInterval: 5, repeats: true) { _ in
    let s = service.counter.snapshot()
    print("rx \(ByteFormat.bytes(s.rx)) tx \(ByteFormat.bytes(s.tx)) active \(s.active) total \(s.totalConnections)")
}
RunLoop.main.add(ticker, forMode: .common)
RunLoop.main.run()
