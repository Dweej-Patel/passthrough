# Passthrough

Internet for your Mac over a USB cable, served by your phone's own network stack. Works with an **iPhone** or an **Android phone**. By default the cable is the only link between the two devices; an optional [wireless link](#wireless-link) (iPhone for now) carries the same traffic when it is unplugged.

```
┌──────────── Mac ─────────────┐  USB or wireless   ┌──────────── Phone ─────────────┐
│ apps → utunN → tun2socks ────┼───────────────────▶│ SOCKS5 (loopback) → cellular   │
│          (root helper)       │ usbmuxd (iPhone)   │ iPhone: VPN extension          │
│                              │ adb (Android)      │ Android: foreground service    │
│                              │ TLS (wireless)     │                                │
└──────────────────────────────┘                    └────────────────────────────────┘
```

| | iPhone | Android |
|---|---|---|
| Phone app | SwiftUI, iOS 17.5+ | Kotlin + Jetpack Compose, Android 8.0+ |
| Keeps serving with the screen off | Packet tunnel extension | Foreground service |
| USB link from the Mac | usbmuxd (built into macOS) | adb (`brew install android-platform-tools`) |
| Phone setup | Trust this Mac | Turn on USB debugging, allow this Mac |

Both phone apps look the same and speak the same protocol, so the Mac app treats them the same way.

What else it does, built on the same pairing:

* **[VPN layer](#vpn-layer):** WireGuard or OpenVPN (NordVPN built in) on top of the passthrough, or over any other network.
* **[Keep Mac awake](#keep-mac-awake):** lid closed or not, with battery and heat limits, so long jobs survive while you are away.
* **[Remote shell](#remote-shell):** a real terminal on your Mac from the phone, over the local network, Tailscale, or from anywhere through a built-in encrypted connection. Sessions survive disconnects and are recorded.
* **[Screen](#screen):** see and control the Mac's screen from the iPhone, as smooth hardware-encoded video.
* **[Flow map](#flow-map) and [top apps](#top-apps):** where the traffic goes, live.

## How it works

* **Phone app.** A SOCKS5 server listens on the phone's loopback address only, next to a small control channel for pairing and live status. On an iPhone it is hosted inside a packet tunnel extension so it keeps running with the screen off (the "tunnel" carries a single unreachable /32, so none of the phone's own traffic is touched), with foreground hosting as a fallback. On Android it runs in a foreground service with a notification, which likewise routes none of the phone's own traffic.
* **Mac menu bar app.** Watches for an attached phone: usbmuxd (Apple's USB multiplexer, already on every Mac) for iPhones, and the local adb server for Android phones; with the [wireless link](#wireless-link) on, also for linked phones dialing in. It forwards a loopback port to the phone's SOCKS port over whichever link is in use, and pairs with the phone (pairing and linking always happen over the cable).
* **Mac helper (root, launchd daemon).** Creates a `utun` interface, runs a userspace TCP/IP stack (hev-socks5-tunnel + lwIP, in a child process) that turns every packet into a SOCKS5 stream to the loopback port, installs the default routes, and registers the interface as the primary network service so macOS believes it is online and sends DNS through it.
* **UDP** (DNS, QUIC, calls) rides inside the TCP stream using the "UDP in TCP" extension the engine speaks natively.

Because the phone opens every connection with its own stack, the carrier sees the phone's TTL, TCP fingerprint and APN, not a tethered device. There is no guarantee of undetectability: unusual volume or application-layer fingerprints can still be visible, and this likely violates your carrier's terms.

### Security model

* The phone never listens on Wi-Fi or cellular. usbmuxd only forwards from a Mac the iPhone has trusted, and adb only from a Mac whose USB debugging key the Android phone has allowed. The Mac ignores adb over Wi-Fi and emulators.
* Each Mac pairs once with a six-digit code shown on the phone (single use, five minutes). The phone issues a 256-bit token; the Mac keeps it in its Keychain (one per phone, by iPhone UDID or Android serial), the phone keeps only a SHA-256 hash. On Android that hash is excluded from cloud backup and device transfer.
* After pairing the token never crosses the cable again. On every control connection the phone proves first that it holds the pairing (HMAC-SHA256 over fresh nonces from both sides), and only then does the Mac prove it back and send anything else; a device that merely answers on the phone's port (another phone, a fake adb server, an app squatting the port) learns nothing and gets no link or shell key. The phone acts on nothing privileged until the Mac's proof checks out, and closes connections that prove nothing within 10 seconds (unless a pairing code is showing).
* Every SOCKS5 connection authenticates with a password derived from that token, so no other process on the Mac can ride the proxy, and whoever squats the SOCKS port can't use what it sees on the control channel.
* The root helper accepts XPC only from apps signed by your team (an unsigned helper refuses every client), and only ever talks to `127.0.0.1`. A Release helper also refuses an app that carries `com.apple.security.get-task-allow` (every development-signed Debug build does): any process of yours could attach to such an app and speak to the helper through it. Release builds of the app and helper are signed without it; use one for everyday use (see [Setup](#setup)). Every value the helper takes over XPC is type- and range-checked, and a tunnel or VPN is owned by the exact connection that started it, so a client that disconnects mid-call never leaves one running unowned.
* Imported OpenVPN profiles are never handed to the root `openvpn` process as-is. They are tokenised with OpenVPN's own rules, checked against an allowlist of client directives with typed arguments, limited to inline certificate blocks, and re-emitted canonically; anything that could run code, touch files, open a control socket, weaken crypto or route around the endpoint pinning is refused with a specific message. The helper also forces AEAD/CBC ciphers only, TLS 1.2+, no compression and `remote-cert-tls server` on the command line.
* Engine binaries are copied into the root-only state directory and that copy is verified (strict validation, Team ID and identifier) before it is executed, so nothing can be swapped between check and exec. Only the bytes of a regular file are copied (a symlink planted in the bundle is refused, never followed), into a freshly created root-owned `0700` file, and that file is checked again right before every exec. Engines start with a fixed, minimal environment: OpenSSL in the root `openvpn` is pointed away from its compiled-in, user-writable Homebrew config, provider and engine directories. Engines left running by a helper that crashed are ended when the helper restarts.
* NordVPN profiles are accepted only if their certificate authority is Nord's (pinned by hash) and they pin the exact server that was requested.
* Five wrong pairing codes lock code entry for 30 seconds (the code stays valid); the Mac only takes a token that answers its own code; tokens are validated for format before use; the control channel is capped at eight peers. The Mac and phone apps must run the same protocol version: each refuses the other with a note saying which one to update.
* The wireless link is set up over the cable: the Mac hands the phone its certificate fingerprint and a per-phone link key. The phone dials out (it still never listens), accepts only TLS 1.3 with that certificate, and proves the key by answering a fresh challenge (HMAC-SHA256); the Mac accepts only phones linked this way. The key sits in the Keychain on both sides (this device only). Anyone on the same network can reach the Mac's listener, so before proving the key a connection gets at most two handshake slots per address and a 128 KB first message. Forgetting a Mac on the phone ends its wireless link at once.
* Remote shell is off by default. While it is off the Mac has no shell listener at all. Turning it on starts a TLS 1.3 listener on port 7893 that accepts peers only from private or Tailscale address ranges (RFC 1918, link-local, loopback, IPv6 ULA, 100.64.0.0/10 and `fd7a:115c:a1e0::/48`; the last two only while the Mac itself is on such a network, as 100.64.0.0/10 is also carrier NAT space). Unless you turn off *Reach this Mac from anywhere (built-in)*, the Mac also runs a built-in [iroh](https://www.iroh.computer) endpoint that is reachable from the internet by design: anyone who can reach its UDP port directly (the same LAN, or public IPv6) or who knows its endpoint id and comes through a relay can start a handshake, which the limits below bound and the shell-key proof gates; see [Reaching the Mac](#remote-shell) and [SECURITY.md](SECURITY.md) for what gates it. With that option off, a Mac with a public address takes no shell connections from the internet.
* A phone gets shell access only over the cable, while the setting is on: the Mac hands it a per-phone 256-bit key and its certificate fingerprint on the control channel. On the local and Tailscale path the phone pins that certificate (TLS 1.3); on the built-in path the transport is iroh's QUIC (TLS 1.3, the Mac authenticated by its endpoint id), with no further TLS inside. Either way the phone proves the key with an HMAC-SHA256 challenge before anything it sends is read; before that, there are at most 16 unproven connections in total, 2 per remote address (a public IPv4 address counts by its /24, IPv6 by its /64) on direct paths and 8 arriving through relays, each with 10 seconds from when it arrives and a hard 4096-byte limit on its handshake lines; 4 of the 16 are kept for addresses that proved a key in the last 30 days, so a crowd of strangers can't lock your phones out. Revoking a phone in the Mac's settings, or **Forget pairing**, deletes its key, drops its live connection and ends the sessions it opened at once (sessions your other phones opened keep running). iPhones share one pairing on the Mac, so **Forget pairing** revokes the attached phone (and, for an iPhone paired before each iPhone had its own pairing and not plugged in since, every iPhone that shared that old pairing).
* On the phone the key sits in a user-presence Keychain item (iPhone, this device only) or a Keystore key bound to a strong biometric or the device credential (Android). Until the app is next unlocked, a newly granted key waits sealed to a key only the unlocked app can use (see *Key storage* below), never in the clear. The whole phone app is behind Face ID / Touch ID / fingerprint / face with passcode fallback and relocks after 60 seconds in the background; a phone with no passcode cannot use Remote shell (an Android phone without a screen lock cannot hold a shell key at all). Someone who has your passcode and your unlocked phone can still open a shell: revoke the phone on the Mac, or remove it from your tailnet.
* Screen is off for every phone until you turn on its **Screen** switch in the Mac's Remote shell settings; a phone needs shell access as well. It asks for the screen on its authorized shell connection, so the same transport, key proof and limits apply. Passthrough's own screen stream asks for no Mac password: the switch is your consent, and a phone allowed Screen controls the Mac as you, as it already can through a shell. Streaming needs **Screen Recording** and **Accessibility** granted to Passthrough, so while they are granted, a network-reachable app holds them. Shells inherit them too (see below), so while they are granted, any phone with shell access can capture the screen and post input from a shell (`screencapture`, `osascript`), whatever its Screen switch says: treat shell access as including the screen. The switch gates Passthrough's own stream and the Screen Sharing relay. Turning a phone's Screen off ends its views at once. The Screen Sharing fallback is relayed to macOS Screen Sharing on loopback only, and Screen Sharing checks the Mac account's name and password itself; the iPhone can remember that login in a user-presence Keychain item (this device only). Before every relay the root helper checks who holds the listening socket on port 5900: only launchd and Apple's `screensharingd` (as root) count as Screen Sharing, so another app listening there while Screen Sharing is off never gets a phone (or its password). Without the helper, nothing is relayed.
* Shells run as your Mac user, inside the Passthrough app, so they inherit its privacy permissions. Turning Remote shell on asks for **Full Disk Access** so unattended scripts do not hang on prompts; while that is granted, a network-reachable app holds it.
* Every shell session is recorded as output only (typed passwords at no-echo prompts are not captured) in `~/Library/Application Support/<identifier>/ShellHistory/`, readable only by you (folder `0700`, files `0600`) and excluded from Time Machine and other backups. Transcripts are plain text on disk, protected by those permissions and FileVault, and can contain secrets a script printed. They never leave the Mac except when a paired phone fetches one. Finished sessions are deleted after 30 days by default (*Keep shell history*: 7, 30 or 90 days, or forever), and the oldest go first once the folder passes 2 GB.
* A fatal VPN failure (rejected credentials, bad profile) keeps the kill switch engaged until you turn the layer off, so no peer can "fail" you into the clear. Kill-switch reject routes sit one step more specific than the VPN's routes, so engaging or lifting them never leaves a gap, and a packet filter (pf) drops anything headed outside the VPN even when the network pushes routes around it (DHCP option 121, "TunnelVision"). Neither a crash of the app nor of the helper lifts it; only turning the VPN off does.
* Profiles, keys and credentials live in the data-protection keychain, this device only.
* The helper tears the tunnel down automatically if the menu bar app quits or crashes. A VPN with its kill switch on is different: a crash leaves traffic blocked until Passthrough is reopened or the VPN is turned off (see [VPN layer](#vpn-layer)).

## Android specifics

* **Cellular only** asks Android to keep mobile data up alongside Wi-Fi and binds every outbound socket to the cellular network, so unlike the iPhone it keeps using cellular while the phone is on Wi-Fi. It falls back to any network only after cellular has been unusable for 10 seconds, and the radio pill reads "Wi-Fi (cell down)" while it does.
* **The Mac starts adb itself.** It looks for platform-tools in the usual places (Homebrew, Android Studio's SDK, `ANDROID_HOME`) and runs `adb start-server` when nothing answers. Settings ▸ General ▸ Android shows whether adb was found and can turn Android support off.
* **Radio label.** Android files the network type (5G, LTE) under its phone permission, which it describes as making and managing calls. It is therefore opt-in from Settings; without it the label reads "Cellular".
* **A wake lock** keeps the CPU serving while the proxy runs. It is renewed every minute and released on stop.

## Flow map

All the apps show a live map of the route traffic takes: Mac ⟶ USB or wireless ⟶ phone ⟶ radio ⟶ (VPN) ⟶ Internet. Particles ride the wires at a speed and density that follow the current throughput (teal toward the Mac, violet away from it), the VPN node slides in with a lock over the encrypted hop when the layer is on, the Mac gets a pulsing halo while keep-awake holds it up, and the Mac–phone hop shows the live rates and names what carries it. It is one `Canvas` driven by a `TimelineView` at up to 30 fps (15 fps when idle, fully paused when nothing is connected), with stateless particle math and no per-particle views, so it costs next to nothing (`PassthroughUI/FlowMap.swift`).

## Top apps

While passthrough is connected, the Mac's menu panel lists the five apps that have moved the most data through the phone this session, with an "Other" line so the list adds up to the session total. It reads macOS's own `nettop` every two seconds (about 2% of one core) and counts only connections on the tunnel's interface (the VPN's while the VPN layer is on). Connections that open and close between samples can't be tied to the tunnel, so their bytes, and VPN overhead, land in "Other". Nothing is stored after the session ends (`PhoneTransport/AppUsage.swift`, `macOS/App/Session/NettopSampler.swift`).

## Wireless link

Off by default. Set **Connect over** to **Wireless only** or **Automatic** in the Mac's settings and turn on **Wireless link** in the iPhone's settings. The phone links the next time it is connected over USB, and from then on it can serve the Mac without the cable (Automatic prefers the cable when one is plugged in).

* The Mac joins the iPhone's **Personal Hotspot**; the phone finds the Mac there and dials it. While passthrough is down, the Mac's **hotspot guard** (on by default) rejects everything but the link to the phone, so the hotspot's own data allowance is not spent.
* **Use peer-to-peer Wi-Fi** (Apple's AWDL, no hotspot needed) is an option on the iPhone. It drops for a minute or more while the phone is locked, so the hotspot is the default.
* A dropped link resumes: both sides keep the session's connections for up to two minutes while the phone redials, so apps see a pause rather than errors. Traffic is the same SOCKS5 and control streams as over the cable, multiplexed over one TLS connection (see [protocol/README.md](protocol/README.md)).
* Android's wireless link (a Wi-Fi Direct group the phone hosts) is not built yet.

## Keep Mac awake

A toggle in the menu panel (and Settings ▸ General) keeps the Mac from sleeping so long sessions survive when you step away — a download, a remote/Claude session, or the tunnel itself. It has two layers:

* Idle sleep is held with an `IOPMAssertion` (no privileges).
* Lid-close sleep is disabled via the root helper running `pmset -a disablesleep 1`. Until the helper is approved only idle sleep is held, and the menu says so.

The display still turns off and the screen still locks on their usual schedule; that pauses nothing. Apps and command-line tools, such as a Claude Code session and the agents it starts, keep running with the lid open or closed. They still need a network: over Passthrough that means the phone link stays up (it does with the phone locked). If the Mac does sleep (keep-awake off, the battery or heat limits below, or macOS forcing it), everything pauses, work in flight is likely to fail, and you resume it after waking.

It is **off by default**, sits directly under the passthrough switch, and works even when passthrough is off. It reverts automatically when you turn it off, quit the app, or if the app disconnects (the helper re-enables sleep when its last client goes away), so the Mac can never get stuck unable to sleep.

**Low-battery auto-off:** in Settings ▸ General you set a battery percentage (default 20%). When keep-awake is on and the Mac is on battery power, it switches keep-awake off automatically at that level so a closed laptop can sleep instead of draining. It does not trigger on AC power. Turning keep-awake **on** while already at or below the limit is refused up front (the toggle stays off), and a warning appears under the toggle stating the current level and the limit.

**Heat auto-off** (Settings ▸ General ▸ Heat, on by default): macOS reports how hard it is working to stay cool. When that reaches *serious*, the point where it starts slowing the Mac down, keep-awake switches itself off so a closed laptop can sleep and cool, and turning it on is refused until the Mac has cooled. It uses the public thermal state rather than raw sensor temperatures.

The menu-bar icon composes the three toggles: a phone (plain when passthrough is off, radiating when connected), a lock while the VPN layer is connected, and a coffee cup while keep-awake is on.

Caution: the heat and battery limits are a safety net, not a licence. A closed, running Mac in a bag can still get very hot; use lid-closed on power or in open air.

## Remote shell

A real terminal on your Mac from the phone, so a stalled job (a script only you may run, with your own credentials) does not mean going back to the desk. It works from the iPhone and Android apps; the wire protocol is in [protocol/README.md](protocol/README.md#remote-shell).

**Turning it on.** It is **off by default**; while off, the Mac listens for nothing. Switch it on in Settings ▸ General ▸ Remote shell. It then asks for **Full Disk Access**, because shells started from your phone inherit Passthrough's macOS privacy permissions, not Terminal's: without it, a command that touches Desktop, Documents, Downloads, iCloud Drive or an external drive makes macOS show a prompt on an unattended Mac, and the command hangs until someone answers it. The shell works without it, and the section shows a warning until it is granted. The Mac must be awake to answer, so turn on [Keep Mac awake](#keep-mac-awake) if you will be away.

**Giving a phone access.** Only over the cable (USB), while the setting is on: the Mac gives that phone its own key. Pairing another phone never revokes an existing one. Plugging it in again gives it a fresh key; its old key keeps working until the phone first uses the new one (it picks the new key up the next time the app is unlocked). Revoke a phone under Remote shell in the Mac's settings, or use **Forget pairing**; either ends its live connection immediately. Each phone has its own pairing on the Mac, so forgetting it revokes only that phone. Forgetting the Mac on the phone deletes the phone's key.

**Reaching the Mac.** Three ways, tried together:

* On the same Wi-Fi the phone finds the Mac with Bonjour (`_passthrough-sh._tcp`, port 7893).
* Through [Tailscale](https://tailscale.com) or a similar private network on both devices; the listener accepts only private and Tailscale address ranges.
* From anywhere, through the built-in connection, which needs no VPN, port forwarding or account. It uses [iroh](https://www.iroh.computer): the Mac keeps a persistent endpoint identity, phones dial it by that id, and the two connect directly when the network allows (hole punching) and through a relay when it doesn't. The relay only forwards end-to-end encrypted QUIC packets: it sees both endpoint ids, IP addresses, timing and traffic volume, never content.

The phone learns the Mac's details (endpoint id, relay, addresses) over the cable when it is granted access, and the Mac re-sends them after every connection, so nothing is typed in. A phone dials the Mac's relay as it was last given: if the Mac's home relay moves while a phone is away, that phone may not reach it through the relay until its next connection on any path (local, Tailscale, or a direct built-in one) brings the new details. If the phone cannot reach the Mac, the Remote shell card says so; when connected it shows *direct* or *via relay*.

**Mac settings** (Settings ▸ General ▸ Remote shell):

* *Reach this Mac from anywhere (built-in)*: on by default while Remote shell is on. Turn it off and the Mac has no iroh endpoint at all.
* *Relay*: *Default* uses iroh's public relays. They are free but development-grade, with no uptime or performance guarantee, and are run by n0, the iroh developers. Or set a custom relay URL, with an optional access token, to use your own; see [Self-hosting a relay](#self-hosting-a-relay). The Mac is the only source of relay settings; phones follow it. The token is stored in the Mac's Keychain, and the Mac also gives it to each paired phone (when granting access and after every connection), which keeps it in its own secure storage, so a lost phone holds it. To rotate it, change it on the relay and in the Mac's settings; phones get the new one at their next connection on a path that still works (local, Tailscale or direct).
* A status line shows the short endpoint id, the home relay, and for each phone connected right now over the built-in path whether it is direct or via a relay.
* *Reset built-in identity...* generates a new endpoint identity (the key is stored in the Mac's Keychain). Phones lose the old one and reconnect once over the cable or the same Wi-Fi or Tailscale, which hands them the new details. Use it if you think the id was exposed or you want to cut off a phone's stale knowledge of the Mac; revoking a phone's shell key is still what removes its access.

**On the phone**, per device: *Connect using* is *Automatic* (default) or *Local and Tailscale only*. Automatic races the local and Tailscale addresses against the built-in path: the built-in attempt starts about 0.75 s later, or immediately when the phone has no local address to try, and the first to be accepted wins. *Local and Tailscale only* never uses the built-in path. On the iPhone the built-in path runs in the app, not the VPN extension, so it works while Passthrough is serving. On Android it is loaded on first use and the phone quietly falls back to local-only if the library cannot load (for example an unsupported CPU). Release builds ship arm64-v8a and armeabi-v7a.

* **iPhone VPN slot.** iOS runs one VPN at a time, and both the Tailscale app and Passthrough's serving tunnel use it, so they cannot both be active on an iPhone. With the built-in connection you do not need Tailscale at all, so the shell works from anywhere while Passthrough is serving. Android's serving does not use the VPN slot, so it has no such limit.
* **App lock.** The phone app opens with Face ID / Touch ID (iPhone) or fingerprint / face (Android), with passcode fallback, and relocks after 60 seconds in the background. A phone with no passcode opens without a lock but cannot use Remote shell. The lock covers the UI only; serving continues while it is locked.
* **Key storage.** The shell key lives in a Keychain item that requires user presence (iPhone) or in an Android Keystore key bound to a strong biometric or the device credential. An Android phone without a screen lock cannot hold the key, so it cannot use Remote shell. The Android shell needs Android 10 or later.
* **Until the app is unlocked.** The part of Passthrough that takes the grant over the cable (the iPhone's VPN extension, Android's service) runs while the phone is locked and never sees the app's keys, so it stores the new shell key sealed (P-256 ECDH, HKDF-SHA256, AES-GCM) to a key only the app can use: a Secure Enclave key that needs user presence on the iPhone (a user-presence Keychain item on a device without one), and a key inside the Android shell key vault, which opens only with the app's unlock. The next time you unlock the app it opens the key and moves it into its own storage. Until you have opened the app once after installing or updating, the phone has no sealing key to use, so it keeps no shell key at all and does not confirm the grant; the Mac grants again later and on every cable connection. A key an older version left waiting unsealed is deleted at the next unlock, and the Mac grants a new one the next time the phone is plugged in. Android 9 and earlier never store a grant, as they cannot use Remote shell.

**Sessions.** Each is your login shell (`$SHELL -l`) as your Mac user, up to 8 at once, hosted by the Mac app. It starts from what a new Terminal.app window gets (your `HOME`, `USER`, `LOGNAME` and `SHELL`, a plain `PATH`, `TERM`, `LANG`, `TMPDIR`, `SSH_AUTH_SOCK`, and `TERM_PROGRAM=Passthrough`), not from Passthrough's own environment, so whatever launched the app (a script, another Claude Code session) does not leak into your shells. They keep running when the phone disconnects, locks or loses signal; coming back reattaches and replays what was printed meanwhile. One device is attached to a session at a time: attaching from another takes it over, and the first shows that it was opened elsewhere. Quitting Passthrough ends all sessions.

**The iPhone's terminal.** A swipe scrolls: through the scrollback for plain output, as scroll-wheel events for programs that take the mouse (Claude Code, vim, htop), and as arrow keys on the alternate screen (less, man). To select, press and hold until the haptic tap, then drag: a program that takes the mouse gets a real mouse drag, so it selects and copies its own way, and plain output gets a selection with Copy when you lift. Holding without moving shows Paste and Select. The key row above the keyboard has esc, ctrl (for the next key), tab, arrows that repeat while held, `|`, `~` and paste.

**History.** Every session is recorded, output only (so passwords typed at a no-echo prompt are not captured), as an [asciicast v2](https://docs.asciinema.org/manual/asciicast/v2/) file in `~/Library/Application Support/<identifier>/ShellHistory/`, in a `0700` folder with `0600` files. It never leaves the Mac except when a paired phone fetches it. View it in the Mac's History window (Remote shell section) or from the phone's Remote shell card. Whatever a script prints, secrets included, is in the transcript; it is protected by file permissions and FileVault, not encrypted by Passthrough. A session's recording stops at 64 MiB (marked `[transcript truncated]`), and viewing or fetching one shows at most its last 8 MiB. The folder is excluded from backups. *Keep shell history* in the Mac's Remote shell settings (7 days, 30 days by default, 90 days, or forever) deletes finished sessions older than that at launch, when you change it and whenever a session ends; past 2 GB in all the oldest finished sessions go first. Delete one session or clear everything from the Mac; sessions still running are never deleted.

### Self-hosting a relay

The default relays are shared and meant for development and testing. For anything you depend on, run your own `iroh-relay` server. Use a 1.x release, to match the iroh 1.x this app is built on (iroh-ffi 1.1.0 and `computer.iroh:iroh-android` 1.1.0), built from the [`iroh-relay` crate](https://github.com/n0-computer/iroh/tree/main/iroh-relay) with its `server` feature. It needs a public hostname. A minimal `config.toml`, started with `iroh-relay -c config.toml`:

```
http_bind_addr = "[::]:80"

[tls]
https_bind_addr = "[::]:443"
hostname = "relay.example.org"
cert_mode = "LetsEncrypt"
cert_dir = "/var/lib/iroh-relay/certs"
contact = "you@example.org"

# Optional access control (default is everyone):
# access.shared_token = ["a-long-random-token"]
# or: access.allowlist = ["<endpoint id>"]
```

Open TCP 80 and 443 (Let's Encrypt and the relay protocol) and UDP 7842 (QUIC address discovery, on by default and requires TLS). Then enter `https://relay.example.org` (and the token, if you set `shared_token`) under *Relay* in the Mac's settings. Phones pick it up at their next connection. Without a token or allowlist anyone can use your relay, so set one if it is public. The config above is a sketch: check the options for the exact version you run in the [iroh relay documentation](https://docs.iroh.computer/concepts/relays) and the [`iroh-relay` source](https://github.com/n0-computer/iroh/tree/main/iroh-relay).

## Screen

See and control your Mac's screen from the iPhone (Android: not yet). It rides Remote shell: with Remote shell on and the phone granted, turn on that phone's **Screen** switch in Settings ▸ General ▸ Remote shell, then tap *See and control the screen* on the phone's Remote shell card. It reaches the Mac the same ways the shell does (local network, Tailscale, or the built-in connection from anywhere). While a phone is watching, the Mac's menu panel says so, with **Stop**.

**How the Mac serves it.** Two ways; the phone picks for itself.

* **Passthrough's own stream** (the default). The Mac captures its main display with ScreenCaptureKit at the display's size in points (1728×1117 on a 16-inch MacBook Pro), up to 60 frames a second and only when something changes, and compresses it to H.264 with the hardware encoder in its low-latency mode, at about 8 Mb/s for that size. The iPhone decodes it in hardware. The phone acknowledges each frame it shows, and the Mac sends a new frame only while fewer than two are unacknowledged, always the newest picture (older ones are dropped before encoding). On a slow path you get fewer frames a second, never a picture from the past. When the screen goes still, its last frame is sent twice more so text sharpens. Your touches and keys become the Mac's own input events. It needs **Screen Recording** (to see the screen) and **Accessibility** (to click and type) for Passthrough: grant them from the *Screen Recording and Accessibility* step in the Mac's Remote shell settings. macOS may want Passthrough reopened after Screen Recording; quitting it drops the passthrough, so do it while you aren't using it. No Mac password is involved.
* **Screen Sharing** (the fallback). When the Mac can't stream (those permissions are missing, or it runs an older Passthrough), the phone asks for macOS Screen Sharing instead, on the same connection; the Mac relays it from loopback port 5900. Turn it on in System Settings ▸ General ▸ Sharing. Screen Sharing asks for your Mac account's name and password, which the iPhone can remember behind Face ID. When the phone falls back by itself it asks first (*Use Screen Sharing with your Mac login?*) before sending a saved login, unless you chose *Always for This Mac*; and it only ever logs in with Apple's method, refusing a server that offers to skip the login. It is much slower, because Apple's server is only fast with Apple's own viewer, and the phone's top bar says when it is in this mode and why.

**Controls on the phone.**

* *Trackpad* mode (the default): drag to move the pointer, tap to click where it is. *Direct* mode: tap where you want to click, drag to pan a zoomed-in screen. The button in the top bar switches.
* Two-finger tap right-clicks; two-finger drag scrolls (smoothly, by pixels, on the stream); press and hold, then drag, drags; pinch zooms in, up to one Mac pixel per phone pixel.
* Three-finger swipes do what they do on a Mac trackpad: left and right move between desktops, up opens Mission Control, down shows the app's windows. The *Desktops* menu in the top bar does the same, plus *Show desktop*. They send the Mac's default shortcuts (⌃← ⌃→ ⌃↑ ⌃↓, F11), so they don't work if you've changed or turned those off under Keyboard Shortcuts ▸ Mission Control.
* The keyboard button brings up the keyboard with a row of esc, tab, ⌃ ⌥ ⌘ (held for the next key), arrows, and paste, which puts the iPhone's clipboard on the Mac's and presses ⌘V. A hardware keyboard's shortcuts go through as they are.
* Turn the phone and the screen view goes landscape, with its controls in a column at the side; the rest of the app stays portrait.

The wire protocol for both ways is in [protocol/README.md](protocol/README.md#screen) ("Screen" and "Screen video").

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
* **Kill switch** (default on): two layers. While the VPN is down, `/3` reject routes override the VPN's `/2` routes, so nothing falls back to the bare underlay until the session is back. And from the moment the VPN starts until you turn it off, pf rules let out only: loopback, the VPN's interface (once connected), the VPN server's addresses and ports (on any interface, so it works over the passthrough and over Wi-Fi), DHCP and IPv6 neighbour discovery, link-local addresses and link-scoped multicast (Bonjour, AirDrop), Tailscale (its interfaces: up, point-to-point `utun`s with an address in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`, never the one the VPN runs over), Passthrough's wireless link to the phone (TCP from the Mac's wireless listener port, to the phone and the private networks it can dial in from) and, with **Allow local network** on, the private networks the Mac is directly on (RFC 1918 and IPv6 ULA; a network claiming public or carrier-NAT addresses as local gets nothing for them). Everything else is dropped, IPv4 and IPv6, whatever the routing table says: routes are compared by length only, so a network that pushes routes more specific than the VPN's (DHCP option 121, "TunnelVision"; IPv6 route information; a netmask that makes public addresses "local", "LocalNet") would otherwise carry traffic in the clear while the VPN shows connected. The helper also looks for such routes every 20 s and says so in the VPN status. With the kill switch off, traffic falls through to the passthrough/Wi-Fi while the VPN is down. The helper retries with backoff; an auth failure or bad profile stops with the reason shown under the toggle.
* **Allow local network** (default on, part of the kill switch): printers, AirPlay and the remote shell's local and hotspot paths keep working. Off, only the VPN, the server, link-local traffic and Passthrough's own wireless link to the phone get out, so a VPN over a wireless passthrough still connects. With it on, a resolver on the local network can still be asked directly by apps that bypass the system's DNS settings.
* **If Passthrough crashes or is killed while the VPN is on**, the kill switch stays: the helper keeps the reject routes and pf rules while `/var/run/passthrough/vpn-wanted` exists, also across a helper crash (its startup sweep keeps them). The Mac stays offline until you reopen Passthrough, which reconnects the VPN (the servers' addresses are kept in `/var/run/passthrough`, so no DNS outside the tunnel is needed), or until you turn the VPN layer off. Quitting Passthrough normally turns the VPN off first. A restart of the Mac clears it (`/var/run` is emptied, and pf starts off).
* pf rules live in the anchor `com.apple/100.<PASSTHROUGH_ID>.killswitch`. macOS's `/etc/pf.conf` only evaluates anchors under `com.apple/*`, and replacing the main ruleset would discard Apple's and other tools' rules, so the kill switch attaches its own child anchor there (named to sort before Apple's own) and enables pf with a reference (`pfctl -E`, released with `pfctl -X`), so other pf users are undisturbed. `sudo pfctl -a 'com.apple/100.<PASSTHROUGH_ID>.killswitch' -s rules` shows the rules; it is empty once the VPN is off.
* Engines are signed on copy with your Team ID and the helper verifies that signature before executing them as root, since the app bundle sits in a user-writable location.
* OpenVPN credentials go to the engine over stdin (`--auth-user-pass /dev/stdin`), never to disk or the process list; the profile text is written to a root-only file under `/var/run/passthrough` for the duration of the session.

Rebuild the engines with `scripts/build-vpn-engines.sh` (needs `brew install go openssl@3 lzo lz4`); the OpenVPN build links OpenSSL, LZO and LZ4 statically so the binary depends only on system libraries. Licences are in `Vendor/VPNEngines/licenses`.

Prefer WireGuard when you control the endpoint (home router/Pi) and OpenVPN UDP for NordVPN; use the TCP 443 profile only on networks that block UDP.

Diagnostics: `PASSTHROUGH_NO_AUTOCONNECT=1` launches the app without taking over the network; `PASSTHROUGH_VPN_TEST=<file>` (plus `PASSTHROUGH_VPN_TEST_USER/PASS`) imports that profile as a temporary one and turns the VPN layer on, which is how the engines are exercised without clicking through the UI.

## Layout

```
protocol/                  Wire protocol spec and fixtures.json, read by both the Swift and Kotlin tests
Packages/PassthroughCore   Swift package:
  PassthroughCore            SOCKS5 server, control channel, pairing, stats, wireless dialer and multiplexer (the phone side)
  PhoneTransport             phone links (usbmuxd, adb, wireless), device watchers, local forwarder, control client (the Mac side)
  PassthroughUI              shared SwiftUI design layer
  VPNConfig                  OpenVPN allowlist, WireGuard .conf parser, NordVPN pinning (linked by the root helper)
  ShellHost                  Mac: login shells on a PTY, the shell listener (TLS and iroh), access keys, transcripts, the screen hand-over
  IrohTransport              iroh endpoints and streams (the built-in connection), for the Mac and iPhone apps only
  ScreenClient               iPhone: the screen stream's client (H.264 to sample buffers) and the Screen Sharing (RFB) viewer
  ScreenHost                 Mac: screen capture, the H.264 encoder, input events, and the flow control between them
  CPTY, CZlib, CResolv       small C shims (PTY spawn, zlib, resolver)
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
| `PhoneLink` (Swift) | `USBMuxLink`, `ADBLink`, `MuxLink` (wireless) | How the Mac opens a stream to a port on the phone |
| `DeviceWatcher` (Swift) | `USBMuxWatcher`, `ADBWatcher`, `WirelessWatcher` | How phones are found; `DeviceDirectory` merges them |
| `ControlConnection` / `LineBuffer` (Swift), `LineReader` (Kotlin) | shared by both ends | Control-channel framing |
| `ProxyHost` (iOS) | `ExtensionHost`, `InProcessHost` | Whether the proxy runs in the VPN extension or the app |
| `Egress` / `EgressProvider` (Kotlin) | `DefaultEgress`, `CellularEgressProvider` | Which network outbound connections leave on |
| `ByteStream` (Swift) | `ConnectionStream` (TCP/TLS), `IrohByteStream` | What carries a shell or screen connection |
| `ScreenVideoSource` (Swift) | `ScreenVideoStreamer` | What answers a phone's screen-stream request (the app supplies it: it holds the permissions) |
| `FrameCapturing` / `InputSink` (Swift) | `ScreenCapturer`, `InputInjector` | Where the stream's frames come from and where a phone's input goes (tests fake both) |

On the Mac, `SessionCoordinator` runs the passthrough link and owns two independent parts, `VPNLayer` and `KeepAwakeController`, which the views observe directly.

## Setup

### Mac (needed for either phone)

1. `brew install xcodegen`, then `xcodegen generate`. The `.xcodeproj` is generated and gitignored, so run this after cloning.
2. Copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`, set your Team ID (`DEVELOPMENT_TEAM = XXXXXXXXXX`), and regenerate. `Signing.xcconfig` is gitignored so your Team ID stays local.
3. The Mac app uses the data-protection keychain, which needs a provisioning profile: build once with `xcodebuild … -allowProvisioningUpdates -allowProvisioningDeviceRegistration` (or run it from Xcode) so your Mac is registered and the profile is created.
4. Bundle IDs default to `dev.dpatel.passthrough.*`. To use your own, set `PASSTHROUGH_ID = com.example.passthrough` in `Signing.xcconfig` and regenerate. The Apple targets' bundle IDs, the App Group, keychain services and the helper's launchd label derive from it; the Android app keeps `dev.dpatel.passthrough.android`. The iPhone's Network Extension can't be signed by a free (personal) team; if your Mac team is a free one, sign the iPhone app with a paid team via `DEVELOPMENT_TEAM[sdk=iphoneos*] = YYYYYYYYYY`.
5. For everyday use, build Release and install it in `/Applications`:
   ```sh
   xcodebuild -project Passthrough.xcodeproj -scheme PassthroughMac -configuration Release \
     -derivedDataPath build -allowProvisioningUpdates build
   ditto build/Build/Products/Release/Passthrough.app /Applications/Passthrough.app
   ```
   then open `/Applications/Passthrough.app`. On first connect macOS asks you to allow the helper under *System Settings ▸ General ▸ Login Items & Extensions ▸ Allow in the Background*. Release builds carry no `get-task-allow` entitlement, and a Release helper refuses any app that does. Running `PassthroughMac` from Xcode (Debug) is for development: a Debug app works only with a Debug helper, so don't run it while the Release app's helper is registered (moving the registration between them drops the tunnel).

The Mac app runs unsandboxed (it needs the usbmuxd and adb sockets) with hardened runtime, and installs no persistent network settings: everything lives in the dynamic store and vanishes when the tunnel stops.

### iPhone

1. Xcode creates the App IDs, the App Group (`group.dev.dpatel.passthrough`) and the Network Extension (packet tunnel) capability with automatic signing. If it complains, enable *Network Extensions* and *App Groups* for both iOS identifiers in the developer portal.
2. Run the `Passthrough` scheme on a real device and tap the power button. iOS asks once to add the VPN configuration.
3. Plug the iPhone into the Mac, trust the Mac if prompted, and flip the switch in the menu bar. The first time, it asks for the code shown by *Pair* on the phone.

### Android

1. On the Mac: `brew install android-platform-tools`.
2. Build and install the app with `./gradlew installDebug` in `android/` (JDK 25 and the Android SDK; see [android/README.md](android/README.md)), or open `android/` in Android Studio.
3. On the phone, enable Developer options (tap *Build number* seven times in *About phone*) and turn on *USB debugging*. The app warns you while it is off.
4. Plug the phone into the Mac and allow this Mac's USB debugging key when asked.
5. Tap the power button in Passthrough, then flip the switch in the Mac's menu bar and enter the code shown by *Pair your Mac*.

## Failure recovery

* The helper sweeps the system at every start: engine processes (tun2socks, `openvpn`, `wireguard-go`) a crashed helper left running, found by pid file and by executable path and ended only if they run from the root-only staging directory, leftover kill-switch or VPN routes, dummy `feth` interfaces, a disabled sleep setting, stale network-service entries and engine files from a crashed run are all removed before it accepts clients. Network-service entries are published as temporary values, so configd drops them by itself if the helper dies.
* OpenVPN pings the server every 10 s (whatever it pushes) so carrier NAT never drops the flow, and uses the server's own ping-restart (NordVPN: 180 s; 120 s if none is pushed). The timeout has to outlast the server's ping interval: OpenVPN pings are one-way, so an idle session hears from a NordVPN server only once a minute, and a shorter timeout restarts it every idle half minute. Network changes under the VPN restart the session straight away regardless.
* The helper checks the VPN session is alive: while data arrives it is; after a quiet spell it sends one DNS question through the VPN interface, and two unanswered probes in a row (about 30 s after the session died) restart it. When the phone under the passthrough moves between Wi-Fi and cellular its public address changes, so the Mac restarts the VPN session straight away.
* The kill switch blocks with reject routes one step more specific (/3) than the VPN's /2 routes, added fresh so the kernel really rejects (it ignores `-reject` on `route change`): blocked connections fail at once instead of hanging, and turning it on or off never leaves a moment without a route. A route someone else put at one of those /3 prefixes is replaced (and logged as a TunnelVision-style conflict); lifting the kill switch deletes only its own routes (to loopback). Its pf rules are stateless, so connections open before it engaged are held to them too.
* The VPN layer has a 60 s connect deadline; an engine that never establishes a session is restarted with backoff, and a fatal failure (rejected credentials, bad profile) stops retrying and shows why; the kill switch stays engaged until you turn the layer off. Endpoint addresses are cached so reconnects under the kill switch need no DNS.
* The Mac app keeps retrying the USB link (backoff capped at 30 s) for as long as a phone is attached, so starting the proxy on the phone later just works. Routes are removed before the loopback listener closes on disconnect.
* The phone's tunnel is registered with an on-demand "always connect" rule, so iOS relaunches the extension by itself if it is killed or after a reboot; stopping it from the app clears the rule. New connections tolerate up to 30 s without a viable path (tower handoff, radio waking) before failing, and existing ones simply resume if the path returns in time.
* On the phone, "Cellular only" now degrades gracefully: a path monitor tracks whether cellular data is actually usable, and while it isn't (radio asleep after a handoff, brief carrier outage) new connections use whatever network the phone has instead of failing with "network is down"; it switches back the moment cellular is viable, logging both transitions. Private, link-local and multicast destinations (home-LAN probes) are refused immediately rather than waiting on the radio. DNS aimed at a private address is the exception: Tailscale, for one, keeps sending lookups to the last Wi-Fi router the Mac saw, even with the Mac's Wi-Fi off, so the phone forwards those queries to its own network's DNS server (the carrier's, or its Wi-Fi's; 1.1.1.1 if it knows none) instead of letting every lookup fail.
* On the phone, a UDP peer whose socket fails or never becomes viable is replaced on the next packet; a client that never completes the SOCKS handshake is dropped after 20 s; sessions are capped.
* The phone reports whether its current network routes IPv6. When it doesn't (plenty of home Wi-Fi, some carriers), the helper turns the tunnel's IPv6 routes into reject routes, so apps fall back to IPv4 immediately instead of hanging on IPv6 connections tun2socks accepts but the phone can never make; they flip back when IPv6 returns. The engine runs in its own process (a verified root-only copy of the helper), ended outright on disconnect: its own shutdown can wait forever for a packet that no longer comes. The kernel frees its sockets and utun; the helper tidies routes and settings. If it somehow outlives that by 2 seconds it is killed, with its stack logged.
* If launchd is still running the helper from an old bundle location, the app re-registers it from its current location the next time nothing is connected.

## Verifying without a phone

The SOCKS server can run on the Mac for protocol testing:

```
cd Packages/PassthroughCore
swift test                       # handshake, auth, CONNECT, UDP framing, pairing, control, adb parsing, protocol fixtures
swift run passthrough-devserver  # then (the password is derived from the seeded token "dev-token"; the server prints it):
curl --socks5-hostname 127.0.0.1:7890 --proxy-user dev:v3V-xKHDFiTawQZR838xINHd9j0mPfGt9xDCG8D27Qo https://example.com
```

`passthrough-devserver` is for development only. It accepts a fixed credential (`dev` / `dev-token` unless given on the command line), allows local destinations (loopback, the LAN) that the phone refuses, and with `noauth` takes connections with no credential at all. Keep it on loopback and never leave it running.

With an Android phone or emulator running Passthrough (proxy started, *Pair* sheet open), an opt-in test pairs over adb and fetches a page through the phone:

```
PASSTHROUGH_ADB_SERIAL=emulator-5554 PASSTHROUGH_ADB_CODE=123456 swift test --filter AndroidEndToEndTests
```

`swift test` also covers the remote shell (listener, handshakes, sessions, iroh) and the screen: the stream's wire format, the hand-over, and a run of the real hardware H.264 encoder fed synthetic frames whose output is decoded and held to the two-frame limit (skipped on Macs without the hardware encoder, such as CI's). Against your own Screen Sharing, opt in with `PASSTHROUGH_LIVE_SCREEN=1 PASSTHROUGH_SCREEN_USER=… PASSTHROUGH_SCREEN_PASSWORD=… swift test --filter testLiveScreenSharing`.

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
* **The phone's screen view says "Slower…"**: it is on Screen Sharing because the Mac can't stream. Grant Screen Recording and Accessibility in the Mac's Remote shell settings, then reopen Passthrough on the Mac (with passthrough off: quitting drops it).
* **Three-finger swipes don't switch desktops**: the Mac's Mission Control shortcuts were changed or turned off (System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control).
* Diagnostics logs are in both apps' Settings.

## Known limits

* The Mac app needs macOS 14.5 and the iPhone app iOS 17.5, the floors of iroh-ffi's prebuilt library.
* The Mac app is Apple Silicon only: the prebuilt engine and iroh-ffi's prebuilt library have no Intel slice. Run `scripts/build-hev.sh` with `x86_64` flags to add Intel to the engine.
* SOCKS5 `UDP ASSOCIATE` (the standard UDP mode) is not offered because usbmuxd, adb and the wireless link carry TCP only; the UDP-in-TCP extension covers it.
* Android needs USB debugging left on while you use Passthrough, which also lets any Mac the phone has authorised run adb commands on it.
* The Android app has been tested on an Android 15 emulator, not yet across physical phones and manufacturers.
* Screen is iPhone only for now, and the stream shows the Mac's main display only. While the Mac is locked the stream may not show the login window; Screen Sharing can.
* The phone's app deliberately does not expose the proxy on Wi-Fi. If you ever want that, it is one flag (`loopbackOnly`), but then do it behind TLS.

## Contributing

Pull requests are welcome against the `dev` branch. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and the checklist, and [SECURITY.md](SECURITY.md) for how to report a vulnerability privately.

## Support

Passthrough is free and open source. If it saved your day (or your data plan), you can [buy me a coffee](https://buymeacoffee.com/dwepat). ☕

## Licence

Passthrough is released under the [MIT License](LICENSE). The vendored engines (hev-socks5-tunnel, lwIP, wireguard-go, OpenVPN) keep their own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
