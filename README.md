# Passthrough

Internet for your Mac over a USB cable, served by your phone's own network stack. Works with an **iPhone** or an **Android phone**. By default the cable is the only link between the two devices; an optional [wireless link](#wireless-link) (iPhone for now) carries the same traffic when it is unplugged.

```
┌──────────── Mac ─────────────┐        USB         ┌──────────── Phone ─────────────┐
│ apps → utunN → tun2socks ────┼───────────────────▶│ SOCKS5 (loopback) → cellular   │
│          (root helper)       │ usbmuxd (iPhone)   │ iPhone: VPN extension          │
│                              │ adb (Android)      │ Android: foreground service    │
└──────────────────────────────┘                    └────────────────────────────────┘
```

| | iPhone | Android |
|---|---|---|
| Phone app | SwiftUI, iOS 17+ | Kotlin + Jetpack Compose, Android 8.0+ |
| Keeps serving with the screen off | Packet tunnel extension | Foreground service |
| USB link from the Mac | usbmuxd (built into macOS) | adb (`brew install android-platform-tools`) |
| Phone setup | Trust this Mac | Turn on USB debugging, allow this Mac |

Both phone apps look the same and speak the same protocol, so the Mac app treats them the same way.

## How it works

* **Phone app.** A SOCKS5 server listens on the phone's loopback address only, next to a small control channel for pairing and live status. On an iPhone it is hosted inside a packet tunnel extension so it keeps running with the screen off (the "tunnel" carries a single unreachable /32, so none of the phone's own traffic is touched), with foreground hosting as a fallback. On Android it runs in a foreground service with a notification, which likewise routes none of the phone's own traffic.
* **Mac menu bar app.** Watches for an attached phone: usbmuxd (Apple's USB multiplexer, already on every Mac) for iPhones, and the local adb server for Android phones. It forwards a loopback port to the phone's SOCKS port over the cable and pairs with the phone.
* **Mac helper (root, launchd daemon).** Creates a `utun` interface, runs an embedded userspace TCP/IP stack (hev-socks5-tunnel + lwIP) that turns every packet into a SOCKS5 stream to the loopback port, installs the default routes, and registers the interface as the primary network service so macOS believes it is online and sends DNS through it.
* **UDP** (DNS, QUIC, calls) rides inside the TCP stream using the "UDP in TCP" extension the engine speaks natively.

Because the phone opens every connection with its own stack, the carrier sees the phone's TTL, TCP fingerprint and APN, not a tethered device. There is no guarantee of undetectability: unusual volume or application-layer fingerprints can still be visible, and this likely violates your carrier's terms.

### Security model

* The phone never listens on Wi-Fi or cellular. usbmuxd only forwards from a Mac the iPhone has trusted, and adb only from a Mac whose USB debugging key the Android phone has allowed. The Mac ignores adb over Wi-Fi and emulators.
* Each Mac pairs once with a six-digit code shown on the phone (single use, five minutes). The phone issues a 256-bit token; the Mac keeps it in its Keychain (one per phone), the phone keeps only a SHA-256 hash. On Android that hash is excluded from cloud backup and device transfer.
* Every SOCKS5 connection authenticates with that token, so no other process on the Mac can ride the proxy.
* The root helper accepts XPC only from apps signed by your team (an unsigned helper refuses every client), and only ever talks to `127.0.0.1`.
* Imported OpenVPN profiles are never handed to the root `openvpn` process as-is. They are tokenised with OpenVPN's own rules, checked against an allowlist of client directives with typed arguments, limited to inline certificate blocks, and re-emitted canonically; anything that could run code, touch files, open a control socket, weaken crypto or route around the endpoint pinning is refused with a specific message. The helper also forces AEAD/CBC ciphers only, TLS 1.2+, no compression and `remote-cert-tls server` on the command line.
* Engine binaries are copied into the root-only state directory and that copy is verified (strict validation, Team ID and identifier) before it is executed, so nothing can be swapped between check and exec.
* NordVPN profiles are accepted only if their certificate authority is Nord's (pinned by hash) and they pin the exact server that was requested.
* Pairing codes are withdrawn after five wrong guesses; tokens are validated for format before use; the control channel is capped at eight peers.
* The wireless link is set up over the cable: the Mac hands the phone its certificate fingerprint and a per-phone link key. The phone dials out (it still never listens), accepts only TLS 1.3 with that certificate, and proves the key by answering a fresh challenge (HMAC-SHA256); the Mac accepts only phones linked this way. The key sits in the Keychain on both sides (this device only). Anyone on the same network can reach the Mac's listener, so before proving the key a connection gets at most two handshake slots per address and a 128 KB first message. Forgetting a Mac on the phone ends its wireless link at once.
* A fatal VPN failure (rejected credentials, bad profile) keeps the kill switch engaged until you turn the layer off, so no peer can "fail" you into the clear. Kill-switch reject routes sit one step more specific than the VPN's routes, so engaging or lifting them never leaves a gap.
* Profiles, keys and credentials live in the data-protection keychain, this device only.
* The helper tears the tunnel down automatically if the menu bar app quits or crashes.

## Android specifics

* **Cellular only** asks Android to keep mobile data up alongside Wi-Fi and binds every outbound socket to the cellular network, so unlike the iPhone it keeps using cellular while the phone is on Wi-Fi. It falls back to any network only after cellular has been unusable for 10 seconds, and the radio pill reads "Wi-Fi (cell down)" while it does.
* **The Mac starts adb itself.** It looks for platform-tools in the usual places (Homebrew, Android Studio's SDK, `ANDROID_HOME`) and runs `adb start-server` when nothing answers. Settings ▸ General ▸ Android shows whether adb was found and can turn Android support off.
* **Radio label.** Android files the network type (5G, LTE) under its phone permission, which it describes as making and managing calls. It is therefore opt-in from Settings; without it the label reads "Cellular".
* **A wake lock** keeps the CPU serving while the proxy runs. It is renewed every minute and released on stop.

## Flow map

All the apps show a live map of the route traffic takes: Mac ⟶ USB ⟶ phone ⟶ radio ⟶ (VPN) ⟶ Internet. Particles ride the wires at a speed and density that follow the current throughput (teal toward the Mac, violet away from it), the VPN node slides in with a lock over the encrypted hop when the layer is on, the Mac gets a pulsing halo while keep-awake holds it up, and the USB hop shows the live rates. It is one `Canvas` driven by a `TimelineView` at up to 30 fps (15 fps when idle, fully paused when nothing is connected), with stateless particle math and no per-particle views, so it costs next to nothing (`PassthroughUI/FlowMap.swift`).

## Wireless link

Off by default. Set **Connect over** to **Wireless only** or **Automatic** in the Mac's settings and turn on **Wireless link** in the iPhone's settings. The phone links the next time it is connected over USB, and from then on it can serve the Mac without the cable (Automatic prefers the cable when one is plugged in).

* The Mac joins the iPhone's **Personal Hotspot**; the phone finds the Mac there and dials it. While passthrough is down, the Mac's **hotspot guard** (on by default) rejects everything but the link to the phone, so the hotspot's own data allowance is not spent.
* **Use peer-to-peer Wi-Fi** (Apple's AWDL, no hotspot needed) is an option on the iPhone. It drops for a minute or more while the phone is locked, so the hotspot is the default.
* A dropped link resumes: both sides keep the session's connections for up to two minutes while the phone redials, so apps see a pause rather than errors. Traffic is the same SOCKS5 and control streams as over the cable, multiplexed over one TLS connection (see [protocol/README.md](protocol/README.md)).
* Android's wireless link (a Wi-Fi Direct group the phone hosts) is not built yet.

## Keep Mac awake

A toggle in the menu panel (and Settings ▸ General) keeps the Mac from sleeping so long sessions survive when you step away — a download, a remote/Claude session, or the tunnel itself. It has two layers:

* Idle sleep is held with an `IOPMAssertion` (no privileges).
* Lid-close sleep is disabled via the root helper running `pmset -a disablesleep 1`.

It is **off by default**, sits directly under the passthrough switch, and works even when passthrough is off. It reverts automatically when you turn it off, quit the app, or if the app disconnects (the helper re-enables sleep when its last client goes away), so the Mac can never get stuck unable to sleep.

**Low-battery auto-off:** in Settings ▸ General you set a battery percentage (default 20%). When keep-awake is on and the Mac is on battery power, it switches keep-awake off automatically at that level so a closed laptop can sleep instead of draining. It does not trigger on AC power. Turning keep-awake **on** while already at or below the limit is refused up front (the toggle stays off), and a warning appears under the toggle stating the current level and the limit.

The menu-bar icon composes the three toggles: a phone (plain when passthrough is off, radiating when connected), a lock while the VPN layer is connected, and a coffee cup while keep-awake is on.

Caution: a closed, running Mac in a bag can overheat and drain the battery — use lid-closed on power or in open air.

## VPN layer

A third toggle, under the passthrough switch, wraps everything the Mac sends in one encrypted VPN flow on top of the passthrough. The phone and the carrier then see a single UDP (or TCP) stream to a VPN server instead of the Mac's individual connections, which removes the destination and fingerprint signals that could otherwise hint at tethering. It also works without passthrough, over Wi-Fi or Ethernet, like any VPN client.

Two engines are bundled inside the app (`Contents/MacOS/`), so nothing else needs installing:

* **WireGuard** via `wireguard-go` (MIT). Import a standard wg-quick style `.conf`.
* **OpenVPN** via the `openvpn` 2.6 binary (GPLv2, run as a separate process). Import any `.ovpn`, or use **Settings ▸ VPN ▸ Add NordVPN…**, which fetches Nord's official manual-setup profile for their recommended server (optionally in a chosen country, UDP or TCP 443) and stores your Nord *service credentials* in the Keychain. "Pick a fresh recommended server" re-fetches later.

How it is layered (all in the root helper, `VPNEngine.swift`):

* The engine's utun owns four `/2` routes (`0.0.0.0/2` … `192.0.0.0/2`, and the IPv6 equivalents). Longest prefix wins, so they beat the passthrough's `/1` routes without touching them.
* Each VPN endpoint gets a `/32` host route through the underlay (the passthrough utun when it is up, otherwise the current default gateway), so the encrypted flow itself never loops into the VPN.
* DNS: over the passthrough the helper swaps the passthrough service's resolvers for the ones the VPN pushed (Nord's, or your WireGuard `DNS =`); over Wi-Fi it publishes the VPN interface as the primary service.
* Passthrough connecting or disconnecting underneath restarts the VPN session automatically so the flow follows the new underlay.
* **Block IPv6** (default on): most VPN servers, NordVPN included, hand out no IPv6, and the kernel won't route v6 into an interface without a v6 address, so v6 would otherwise slip past the VPN to the underlay. The helper rejects v6 while the VPN is up (apps fall back to v4 instantly). Settings ▸ VPN can turn it off if you need v6 and accept the bypass; when the VPN does carry v6, it is routed through it either way.
* **Kill switch** (default on): while the VPN is down, `/3` reject routes override the VPN's `/2` routes, so nothing falls back to the bare underlay until the session is back. With it off, traffic falls through to the passthrough/Wi-Fi meanwhile. The helper retries with backoff; an auth failure or bad profile stops with the reason shown under the toggle.
* Engines are signed on copy with your Team ID and the helper verifies that signature before executing them as root, since the app bundle sits in a user-writable location.
* OpenVPN credentials go to the engine over stdin (`--auth-user-pass /dev/stdin`), never to disk or the process list; the profile text is written to a root-only file under `/var/run/passthrough` for the duration of the session.

Rebuild the engines with `scripts/build-vpn-engines.sh` (needs `brew install go openssl@3 lzo lz4`); the OpenVPN build links OpenSSL, LZO and LZ4 statically so the binary depends only on system libraries. Licences are in `Vendor/VPNEngines/licenses`.

Prefer WireGuard when you control the endpoint (home router/Pi) and OpenVPN UDP for NordVPN; use the TCP 443 profile only on networks that block UDP.

Diagnostics: `PASSTHROUGH_NO_AUTOCONNECT=1` launches the app without taking over the network; `PASSTHROUGH_VPN_TEST=<file>` (plus `PASSTHROUGH_VPN_TEST_USER/PASS`) imports that profile as a temporary one and turns the VPN layer on, which is how the engines are exercised without clicking through the UI.

## Layout

```
protocol/                  Wire protocol spec and fixtures.json, read by both the Swift and Kotlin tests
Packages/PassthroughCore   Swift package:
  PassthroughCore            SOCKS5 server, control channel, pairing, stats (the phone side)
  PhoneTransport             phone links (usbmuxd, adb), device watchers, local forwarder, control client (the Mac side)
  PassthroughUI              shared SwiftUI design layer
iOS/App                    SwiftUI iPhone app
iOS/Tunnel                 Packet tunnel extension hosting the servers
macOS/App                  SwiftUI menu bar app: Session/, VPN/, Power/, Views/
macOS/Helper               Root helper: utun + tun2socks + routes + DNS
macOS/Shared               XPC protocol shared by app and helper
android/                   Kotlin + Jetpack Compose Android app (same protocol, own tests)
Vendor/HevSocks5Tunnel     Prebuilt tun2socks engine (arm64) + headers
Vendor/hev-socks5-tunnel   Engine source (MIT), rebuilt with scripts/build-hev.sh
Vendor/VPNEngines          Prebuilt wireguard-go + openvpn (arm64) for the VPN layer, plus licences
project.yml                XcodeGen spec that produces Passthrough.xcodeproj
```

### Seams

The code is built around a few small interfaces, so a new phone, link or host plugs in without touching the rest:

| Interface | Implementations | What it hides |
|-----------|-----------------|---------------|
| `PhoneLink` (Swift) | `USBMuxLink`, `ADBLink` | How the Mac opens a stream to a port on the phone |
| `DeviceWatcher` (Swift) | `USBMuxWatcher`, `ADBWatcher` | How phones are found; `DeviceDirectory` merges them |
| `ControlConnection` / `LineBuffer` (Swift), `LineReader` (Kotlin) | shared by both ends | Control-channel framing |
| `ProxyHost` (iOS) | `ExtensionHost`, `InProcessHost` | Whether the proxy runs in the VPN extension or the app |
| `Egress` / `EgressProvider` (Kotlin) | `DefaultEgress`, `CellularEgressProvider` | Which network outbound connections leave on |

On the Mac, `SessionCoordinator` runs the passthrough link and owns two independent parts, `VPNLayer` and `KeepAwakeController`, which the views observe directly.

## Setup

### Mac (needed for either phone)

1. `brew install xcodegen`, then `xcodegen generate`. The `.xcodeproj` is generated and gitignored, so run this after cloning.
2. Copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`, set your Team ID (`DEVELOPMENT_TEAM = XXXXXXXXXX`), and regenerate. `Signing.xcconfig` is gitignored so your Team ID stays local.
3. The Mac app uses the data-protection keychain, which needs a provisioning profile: build once with `xcodebuild … -allowProvisioningUpdates -allowProvisioningDeviceRegistration` (or run it from Xcode) so your Mac is registered and the profile is created.
4. Bundle IDs default to `dev.dpatel.passthrough.*`. To use your own, change `bundleIdPrefix` in `project.yml` and the same string in `PassthroughProtocol.appGroup`, `TunnelController.providerBundleID`, `HelperConstants` and the daemon plist.
5. Run `PassthroughMac`. On first connect macOS asks you to allow the helper under *System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background*.

The Mac app runs unsandboxed (it needs the usbmuxd and adb sockets) with hardened runtime, and installs no persistent network settings: everything lives in the dynamic store and vanishes when the tunnel stops.

### iPhone

1. Xcode creates the App IDs, the App Group (`group.dev.dpatel.passthrough`) and the Network Extension (packet tunnel) capability with automatic signing. If it complains, enable *Network Extensions* and *App Groups* for both iOS identifiers in the developer portal.
2. Run the `Passthrough` scheme on a real device and tap the power button. iOS asks once to add the VPN configuration.
3. Plug the iPhone into the Mac, trust the Mac if prompted, and flip the switch in the menu bar. The first time, it asks for the code shown by *Pair* on the phone.

### Android

1. On the Mac: `brew install android-platform-tools`.
2. Build and install the app with `./gradlew installDebug` in `android/` (JDK 17 and the Android SDK; see [android/README.md](android/README.md)), or open `android/` in Android Studio.
3. On the phone, enable Developer options (tap *Build number* seven times in *About phone*) and turn on *USB debugging*. The app warns you while it is off.
4. Plug the phone into the Mac and allow this Mac's USB debugging key when asked.
5. Tap the power button in Passthrough, then flip the switch in the Mac's menu bar and enter the code shown by *Pair your Mac*.

## Failure recovery

* The helper sweeps the system at every start: leftover kill-switch or VPN routes, dummy `feth` interfaces, a disabled sleep setting, stale network-service entries and engine files from a crashed run are all removed before it accepts clients. Network-service entries are published as temporary values, so configd drops them by itself if the helper dies.
* OpenVPN pings the server every 10 s (whatever it pushes) so carrier NAT never drops the flow, and uses the server's own ping-restart (NordVPN: 180 s; 120 s if none is pushed). The timeout has to outlast the server's ping interval: OpenVPN pings are one-way, so an idle session hears from a NordVPN server only once a minute, and a shorter timeout restarts it every idle half minute. Network changes under the VPN restart the session straight away regardless.
* The helper checks the VPN session is alive: while data arrives it is; after a quiet spell it sends one DNS question through the VPN interface, and two unanswered probes in a row (about 30 s after the session died) restart it. When the phone under the passthrough moves between Wi-Fi and cellular its public address changes, so the Mac restarts the VPN session straight away.
* The kill switch blocks with reject routes one step more specific (/3) than the VPN's /2 routes, added fresh so the kernel really rejects (it ignores `-reject` on `route change`): blocked connections fail at once instead of hanging, and turning it on or off never leaves a moment without a route.
* The VPN layer has a 60 s connect deadline; an engine that never establishes a session is restarted with backoff, and a fatal failure (rejected credentials, bad profile) stops retrying and shows why; the kill switch stays engaged until you turn the layer off. Endpoint addresses are cached so reconnects under the kill switch need no DNS.
* The Mac app keeps retrying the USB link (backoff capped at 30 s) for as long as a phone is attached, so starting the proxy on the phone later just works. Routes are removed before the loopback listener closes on disconnect.
* The phone's tunnel is registered with an on-demand "always connect" rule, so iOS relaunches the extension by itself if it is killed or after a reboot; stopping it from the app clears the rule. New connections tolerate up to 30 s without a viable path (tower handoff, radio waking) before failing, and existing ones simply resume if the path returns in time.
* On the phone, "Cellular only" now degrades gracefully: a path monitor tracks whether cellular data is actually usable, and while it isn't (radio asleep after a handoff, brief carrier outage) new connections use whatever network the phone has instead of failing with "network is down"; it switches back the moment cellular is viable, logging both transitions. Private, link-local and multicast destinations (home-LAN probes) are refused immediately rather than waiting on the radio. DNS aimed at a private address is the exception: Tailscale, for one, keeps sending lookups to the last Wi-Fi router the Mac saw, even with the Mac's Wi-Fi off, so the phone forwards those queries to its own network's DNS server (the carrier's, or its Wi-Fi's; 1.1.1.1 if it knows none) instead of letting every lookup fail.
* On the phone, a UDP peer whose socket fails or never becomes viable is replaced on the next packet; a client that never completes the SOCKS handshake is dropped after 20 s; sessions are capped.
* The phone reports whether its current network routes IPv6. When it doesn't (plenty of home Wi-Fi, some carriers), the helper turns the tunnel's IPv6 routes into reject routes, so apps fall back to IPv4 immediately instead of hanging on IPv6 connections tun2socks accepts but the phone can never make; they flip back when IPv6 returns. A tunnel engine that won't stop makes the helper restart itself, since its utun would otherwise block every new tunnel.
* If launchd is still running the helper from an old bundle location, the app re-registers it from its current location the next time nothing is connected.

## Verifying without a phone

The SOCKS server can run on the Mac for protocol testing:

```
cd Packages/PassthroughCore
swift test                       # handshake, auth, CONNECT, UDP framing, pairing, control, adb parsing, protocol fixtures
swift run passthrough-devserver  # then:
curl --socks5-hostname 127.0.0.1:7890 --proxy-user dev:dev-token https://example.com
```

With an Android phone or emulator running Passthrough (proxy started, *Pair* sheet open), an opt-in test pairs over adb and fetches a page through the phone:

```
PASSTHROUGH_ADB_SERIAL=emulator-5554 PASSTHROUGH_ADB_CODE=123456 swift test --filter AndroidEndToEndTests
```

Panel previews: `Passthrough.app/Contents/MacOS/Passthrough --snapshot /tmp/panels` renders the menu bar panel in every state, light and dark. On the simulator the iOS app honours `PASSTHROUGH_AUTOSTART=1`, `PASSTHROUGH_SHOW_PAIRING=1` and `PASSTHROUGH_SHOW_SETTINGS=1`.

## Troubleshooting

* **Connecting cuts every open connection on the Mac** (SSH sessions, terminals talking to an API, video calls). That is the default route switching to the tunnel, the same as any VPN. Connect before you start long-lived work, not in the middle of it.
* **Same public IP as before**: the phone is on Wi-Fi, so the Mac rides its Wi-Fi. On the iPhone this happens even with *Cellular only* on: while Wi-Fi is up iOS lets cellular data sleep, and forced-cellular UDP (DNS, QUIC, VPNs) then never gets a route, so everything but plain web pages would fail. The phone and the Mac menu both say when this is happening; turn off Wi-Fi on the phone to use cellular.
* **Tailscale over the tunnel (verified working, incl. wifi off):** Tailscale's transport rides the phone like everything else, and MagicDNS stays the resolver. One macOS quirk had to be worked around: Tailscale hard-ignores every interface named `utun` when deciding whether the machine has any network (`isInterestingInterface` in `net/netmon/netmon_darwin.go`). With only our `utun` tunnel present (laptop truly remote, wifi off) it would declare itself offline even though the tunnel works. The helper therefore brings up a tiny dummy `feth` ("fake ethernet") interface with a private address whenever the tunnel is active, purely so that check passes. No traffic is routed over it; real traffic still follows the default route into the tunnel. It is torn down when the tunnel stops. Behind carrier NAT, Tailscale connects via DERP relay (expected), which is fully functional.
* **Reading logs**: if your shell aliases `log`, call `/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.dpatel.passthrough"'`. Crashes land in `~/Library/Logs/DiagnosticReports` (app) and `/Library/Logs/DiagnosticReports` (helper).

* **"The iPhone refused the connection"** / **"The phone refused the connection"**: the proxy is not running on the phone. Start it there.
* **Android phone not detected**: check Settings ▸ General ▸ Android on the Mac. "Not installed" means adb is missing (`brew install android-platform-tools`). If the panel says to allow USB debugging, unlock the phone and accept the prompt; if it never appears, revoke USB debugging authorisations in Developer options and replug.
* **Android stops serving after a while**: some manufacturers kill foreground services aggressively. Exempt Passthrough from battery optimisation in the phone's app settings.
* **Stuck on "Helper needs approval"**: approve it in Login Items, then *Try again*. After rebuilding the helper, the app restarts the stale daemon automatically (version check over XPC).
* **Mac shows online but DNS fails**: check the helper's log with `log stream --predicate 'process == "PassthroughHelper"'`; the DNS servers are configurable in Settings ▸ Network.
* **iOS "VPN extension is not available"**: the tunnel provisioning profile is missing the Network Extension entitlement, or you are on the simulator. Foreground hosting still works (keep the app open).
* Diagnostics logs are in both apps' Settings.

## Known limits

* Apple Silicon only for the prebuilt engine. Run `scripts/build-hev.sh` with `x86_64` flags to add Intel.
* SOCKS5 `UDP ASSOCIATE` (the standard UDP mode) is not offered because usbmuxd and adb carry TCP only; the UDP-in-TCP extension covers it.
* Android needs USB debugging left on while you use Passthrough, which also lets any Mac the phone has authorised run adb commands on it.
* The Android app has been tested on an Android 15 emulator, not yet across physical phones and manufacturers.
* The phone's app deliberately does not expose the proxy on Wi-Fi. If you ever want that, it is one flag (`loopbackOnly`), but then do it behind TLS.

## Contributing

Pull requests are welcome against the `dev` branch. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and the checklist, and [SECURITY.md](SECURITY.md) for how to report a vulnerability privately.

## Support

Passthrough is free and open source. If it saved your day (or your data plan), you can [buy me a coffee](https://buymeacoffee.com/dwepat). ☕

## Licence

Passthrough is released under the [MIT License](LICENSE). The vendored engines (hev-socks5-tunnel, lwIP, wireguard-go, OpenVPN) keep their own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
