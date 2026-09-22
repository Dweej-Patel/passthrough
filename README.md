# Passthrough

USB-only internet for your Mac, served by your iPhone's own network stack. No Personal Hotspot, no Wi-Fi, no Bluetooth: the only link between the two devices is the cable.

```
┌──────────── Mac ─────────────┐   USB (usbmuxd)   ┌──────────── iPhone ────────────┐
│ apps → utunN → tun2socks ────┼──────────────────▶│ SOCKS5 (loopback) → cellular   │
│          (root helper)       │  127.0.0.1:17890  │ hosted in a VPN extension      │
└──────────────────────────────┘                   └────────────────────────────────┘
```

## How it works

* **iPhone app + Network Extension.** A SOCKS5 server listens on loopback only. It is hosted inside a packet tunnel extension so it keeps running with the screen off (the "tunnel" carries a single unreachable /32, so none of the phone's own traffic is touched). Falls back to foreground hosting if the extension is unavailable.
* **Mac menu bar app.** Watches usbmuxd (Apple's USB multiplexer, already on every Mac) for an attached iPhone, forwards a loopback port to the phone's SOCKS port over the cable, and pairs with the phone.
* **Mac helper (root, launchd daemon).** Creates a `utun` interface, runs an embedded userspace TCP/IP stack (hev-socks5-tunnel + lwIP) that turns every packet into a SOCKS5 stream to the loopback port, installs the default routes, and registers the interface as the primary network service so macOS believes it is online and sends DNS through it.
* **UDP** (DNS, QUIC, calls) rides inside the TCP stream using the "UDP in TCP" extension the engine speaks natively.

Because the phone opens every connection with its own stack, the carrier sees the phone's TTL, TCP fingerprint and APN, not a tethered device. There is no guarantee of undetectability: unusual volume or application-layer fingerprints can still be visible, and this likely violates your carrier's terms.

### Security model

* The phone never listens on Wi-Fi or cellular. usbmuxd only forwards from a Mac the phone has trusted.
* Each Mac pairs once with a six-digit code shown on the phone (single use, five minutes). The phone issues a 256-bit token; the Mac keeps it in its Keychain, the phone keeps only a SHA-256 hash.
* Every SOCKS5 connection authenticates with that token, so no other process on the Mac can ride the proxy.
* The root helper accepts XPC only from apps signed by your team, and only ever talks to `127.0.0.1`.
* The helper tears the tunnel down automatically if the menu bar app quits or crashes.

## Flow map

Both apps show a live map of the route traffic takes: Mac ⟶ USB ⟶ iPhone ⟶ radio ⟶ (VPN) ⟶ Internet. Particles ride the wires at a speed and density that follow the current throughput (teal toward the Mac, violet away from it), the VPN node slides in with a lock over the encrypted hop when the layer is on, the Mac gets a pulsing halo while keep-awake holds it up, and the USB hop shows the live rates. It is one `Canvas` driven by a `TimelineView` at up to 30 fps (15 fps when idle, fully paused when nothing is connected), with stateless particle math and no per-particle views, so it costs next to nothing (`PassthroughUI/FlowMap.swift`).

## Keep Mac awake

A toggle in the menu panel (and Settings ▸ General) keeps the Mac from sleeping so long sessions survive when you step away — a download, a remote/Claude session, or the tunnel itself. It has two layers:

* Idle sleep is held with an `IOPMAssertion` (no privileges).
* Lid-close sleep is disabled via the root helper running `pmset -a disablesleep 1`.

It is **off by default**, sits directly under the passthrough switch, and works even when passthrough is off. It reverts automatically when you turn it off, quit the app, or if the app disconnects (the helper re-enables sleep when its last client goes away), so the Mac can never get stuck unable to sleep.

**Low-battery auto-off:** in Settings ▸ General you set a battery percentage (default 20%). When keep-awake is on and the Mac is on battery power, it switches keep-awake off automatically at that level so a closed laptop can sleep instead of draining. It does not trigger on AC power. Turning keep-awake **on** while already at or below the limit is refused up front (the toggle stays off), and a warning appears under the toggle stating the current level and the limit.

The menu-bar icon composes the three toggles: a phone (plain when passthrough is off, radiating when connected), a lock while the VPN layer is connected, and a coffee cup while keep-awake is on.

Caution: a closed, running Mac in a bag can overheat and drain the battery — use lid-closed on power or in open air.

## VPN layer

A third toggle, under the passthrough switch, wraps everything the Mac sends in one encrypted VPN flow on top of the passthrough. The iPhone and the carrier then see a single UDP (or TCP) stream to a VPN server instead of the Mac's individual connections, which removes the destination and fingerprint signals that could otherwise hint at tethering. It also works without passthrough, over Wi-Fi or Ethernet, like any VPN client.

Two engines are bundled inside the app (`Contents/MacOS/`), so nothing else needs installing:

* **WireGuard** via `wireguard-go` (MIT). Import a standard wg-quick style `.conf`.
* **OpenVPN** via the `openvpn` 2.6 binary (GPLv2, run as a separate process). Import any `.ovpn`, or use **Settings ▸ VPN ▸ Add NordVPN…**, which fetches Nord's official manual-setup profile for their recommended server (optionally in a chosen country, UDP or TCP 443) and stores your Nord *service credentials* in the Keychain. "Pick a fresh recommended server" re-fetches later.

How it is layered (all in the root helper, `VPNEngine.swift`):

* The engine's utun owns four `/2` routes (`0.0.0.0/2` … `192.0.0.0/2`, and the IPv6 equivalents). Longest prefix wins, so they beat the passthrough's `/1` routes without touching them.
* Each VPN endpoint gets a `/32` host route through the underlay (the passthrough utun when it is up, otherwise the current default gateway), so the encrypted flow itself never loops into the VPN.
* DNS: over the passthrough the helper swaps the passthrough service's resolvers for the ones the VPN pushed (Nord's, or your WireGuard `DNS =`); over Wi-Fi it publishes the VPN interface as the primary service.
* Passthrough connecting or disconnecting underneath restarts the VPN session automatically so the flow follows the new underlay.
* **Block IPv6** (default on): most VPN servers, NordVPN included, hand out no IPv6, and the kernel won't route v6 into an interface without a v6 address, so v6 would otherwise slip past the VPN to the underlay. The helper rejects v6 while the VPN is up (apps fall back to v4 instantly). Settings ▸ VPN can turn it off if you need v6 and accept the bypass; when the VPN does carry v6, it is routed through it either way.
* **Kill switch** (default on): while the VPN is down the `/2` routes become reject routes, so nothing falls back to the bare underlay until the session is back. With it off, traffic falls through to the passthrough/Wi-Fi meanwhile. The helper retries with backoff; an auth failure or bad profile stops with the reason shown under the toggle.
* Engines are signed on copy with your Team ID and the helper verifies that signature before executing them as root, since the app bundle sits in a user-writable location.
* OpenVPN credentials go to the engine over stdin (`--auth-user-pass /dev/stdin`), never to disk or the process list; the profile text is written to a root-only file under `/var/run/passthrough` for the duration of the session.

Rebuild the engines with `scripts/build-vpn-engines.sh` (needs `brew install go openssl@3 lzo lz4`); the OpenVPN build links OpenSSL, LZO and LZ4 statically so the binary depends only on system libraries. Licences are in `Vendor/VPNEngines/licenses`.

Prefer WireGuard when you control the endpoint (home router/Pi) and OpenVPN UDP for NordVPN; use the TCP 443 profile only on networks that block UDP.

Diagnostics: `PASSTHROUGH_NO_AUTOCONNECT=1` launches the app without taking over the network; `PASSTHROUGH_VPN_TEST=<file>` (plus `PASSTHROUGH_VPN_TEST_USER/PASS`) imports that profile as a temporary one and turns the VPN layer on, which is how the engines are exercised without clicking through the UI.

## Layout

```
Packages/PassthroughCore   Swift package: SOCKS5 server, control channel, pairing, stats,
                           usbmuxd client, local forwarder, shared SwiftUI design layer, tests
iOS/App                    SwiftUI iPhone app
iOS/Tunnel                 Packet tunnel extension hosting the servers
macOS/App                  SwiftUI menu bar app
macOS/Helper               Root helper: utun + tun2socks + routes + DNS
macOS/Shared               XPC protocol shared by app and helper
Vendor/HevSocks5Tunnel     Prebuilt tun2socks engine (arm64) + headers
Vendor/hev-socks5-tunnel   Engine source (MIT), rebuilt with scripts/build-hev.sh
Vendor/VPNEngines          Prebuilt wireguard-go + openvpn (arm64) for the VPN layer, plus licences
project.yml                XcodeGen spec that produces Passthrough.xcodeproj
```

## Setup

1. `brew install xcodegen` (already done if you built once), then `xcodegen generate`.
2. Copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig` and set your Team ID (`DEVELOPMENT_TEAM = XXXXXXXXXX`), then regenerate. `Signing.xcconfig` is gitignored so your Team ID stays local. The `.xcodeproj` is generated (also gitignored); run `xcodegen generate` after cloning.
3. In Xcode, the bundle IDs default to `dev.dpatel.passthrough.*`. Change `bundleIdPrefix` in `project.yml` if you want your own, and update the same string in `PassthroughProtocol.appGroup`, `TunnelController.providerBundleID`, `HelperConstants`, and the daemon plist.
4. Xcode will create the App IDs, the App Group (`group.dev.dpatel.passthrough`) and the Network Extension (packet tunnel) capability automatically with automatic signing. If it complains, enable *Network Extensions* and *App Groups* for both iOS identifiers in the developer portal.
5. **iPhone:** run the `Passthrough` scheme on a real device. Tap the power button. iOS asks once to add the VPN configuration.
6. **Mac:** run `PassthroughMac`. On first connect macOS asks you to allow the helper under *System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background*.
7. Plug the iPhone in, trust the Mac if prompted, and flip the switch in the menu bar. The first time it asks for the pairing code shown by the *Pair* button on the phone.

The Mac app runs unsandboxed (it needs the usbmuxd socket) with hardened runtime, and installs no persistent network settings: everything lives in the dynamic store and vanishes when the tunnel stops.

## Failure recovery

* The helper sweeps the system at every start: leftover kill-switch or VPN routes, dummy `feth` interfaces, a disabled sleep setting, stale network-service entries and engine files from a crashed run are all removed before it accepts clients. Network-service entries are published as temporary values, so configd drops them by itself if the helper dies.
* The VPN layer has a 60 s connect deadline; an engine that never establishes a session is restarted with backoff, and a fatal failure (rejected credentials, bad profile) lifts the kill switch instead of leaving the Mac blackholed. Endpoint addresses are cached so reconnects under the kill switch need no DNS.
* The Mac app keeps retrying the USB link (backoff capped at 30 s) for as long as a phone is attached, so starting the proxy on the phone later just works. Routes are removed before the loopback listener closes on disconnect.
* The phone's tunnel is registered with an on-demand "always connect" rule, so iOS relaunches the extension by itself if it is killed or after a reboot; stopping it from the app clears the rule. New connections tolerate up to 30 s without a viable path (tower handoff, radio waking) before failing, and existing ones simply resume if the path returns in time.
* On the phone, "Cellular only" now degrades gracefully: a path monitor tracks whether cellular data is actually usable, and while it isn't (radio asleep after a handoff, brief carrier outage) new connections use whatever network the phone has instead of failing with "network is down"; it switches back the moment cellular is viable, logging both transitions. Private, link-local and multicast destinations (home-LAN probes, the router's DNS) are refused immediately rather than waiting on the radio.
* On the phone, a UDP peer whose socket fails or never becomes viable is replaced on the next packet; a client that never completes the SOCKS handshake is dropped after 20 s; sessions are capped.
* If launchd is still running the helper from an old bundle location, the app re-registers it from its current location the next time nothing is connected.

## Verifying without a phone

The SOCKS server can run on the Mac for protocol testing:

```
cd Packages/PassthroughCore
swift test                       # 12 tests: handshake, auth, CONNECT, UDP framing, pairing, control
swift run passthrough-devserver  # then:
curl --socks5-hostname 127.0.0.1:7890 --proxy-user dev:dev-token https://example.com
```

Panel previews: `Passthrough.app/Contents/MacOS/Passthrough --snapshot /tmp/panels` renders the menu bar panel in every state, light and dark. On the simulator the iOS app honours `PASSTHROUGH_AUTOSTART=1`, `PASSTHROUGH_SHOW_PAIRING=1` and `PASSTHROUGH_SHOW_SETTINGS=1`.

## Troubleshooting

* **Connecting cuts every open connection on the Mac** (SSH sessions, terminals talking to an API, video calls). That is the default route switching to the tunnel, the same as any VPN. Connect before you start long-lived work, not in the middle of it.
* **Same public IP as before**: the phone was on Wi-Fi and *Cellular only* was off. It is on by default now; check the pill next to the power button on the phone, it reads "Wi-Fi" when the Mac would ride the phone's Wi-Fi.
* **Tailscale over the tunnel (verified working, incl. wifi off):** Tailscale's transport rides the phone like everything else, and MagicDNS stays the resolver. One macOS quirk had to be worked around: Tailscale hard-ignores every interface named `utun` when deciding whether the machine has any network (`isInterestingInterface` in `net/netmon/netmon_darwin.go`). With only our `utun` tunnel present (laptop truly remote, wifi off) it would declare itself offline even though the tunnel works. The helper therefore brings up a tiny dummy `feth` ("fake ethernet") interface with a private address whenever the tunnel is active, purely so that check passes. No traffic is routed over it; real traffic still follows the default route into the tunnel. It is torn down when the tunnel stops. Behind carrier NAT, Tailscale connects via DERP relay (expected), which is fully functional.
* **Reading logs**: if your shell aliases `log`, call `/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.dpatel.passthrough"'`. Crashes land in `~/Library/Logs/DiagnosticReports` (app) and `/Library/Logs/DiagnosticReports` (helper).

* **"The iPhone refused the connection"**: the proxy is not running on the phone. Start it there.
* **Stuck on "Helper needs approval"**: approve it in Login Items, then *Try again*. After rebuilding the helper, the app restarts the stale daemon automatically (version check over XPC).
* **Mac shows online but DNS fails**: check the helper's log with `log stream --predicate 'process == "PassthroughHelper"'`; the DNS servers are configurable in Settings ▸ Network.
* **iOS "VPN extension is not available"**: the tunnel provisioning profile is missing the Network Extension entitlement, or you are on the simulator. Foreground hosting still works (keep the app open).
* Diagnostics logs are in both apps' Settings.

## Known limits

* Apple Silicon only for the prebuilt engine. Run `scripts/build-hev.sh` with `x86_64` flags to add Intel.
* SOCKS5 `UDP ASSOCIATE` (the standard UDP mode) is not offered because usbmuxd carries TCP only; the UDP-in-TCP extension covers it.
* The phone's app deliberately does not expose the proxy on Wi-Fi. If you ever want that, it is one flag (`loopbackOnly`), but then do it behind TLS.
