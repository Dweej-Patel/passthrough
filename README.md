<h1 align="center">Passthrough</h1>

<p align="center"><b>Your phone, working for your Mac.</b><br>
Internet over the cable, a Mac that stays awake while you're gone, its shell from anywhere, and a VPN with a kill switch.<br>
For iPhone and Android. No accounts, no Passthrough server.</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/images/iphone-mac-light.png">
    <img src="docs/images/iphone-mac-dark.png" width="250" alt="The iPhone app's Mac tab: the Mac staying awake with 3 hours 10 minutes left, a shell asking a question, and switches for Internet through this iPhone, Keep Mac awake and VPN">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/images/mac-panel-light.png">
    <img src="docs/images/mac-panel-dark.png" width="290" alt="The Mac's menu-bar panel: online through the iPhone with the VPN on, three switches with their status, and the route and live speeds below">
  </picture>
  &nbsp;
  <img src="docs/images/iphone-activity.png" width="250" alt="The Activity tab: shells finished, questions answered and connection drops, the Mac's battery as a line, and a timeline of what happened">
</p>

## What it does

| | |
|---|---|
| **Internet through your phone** | Plug in and the Mac goes online through the phone's own connection: no hotspot, nothing to configure. An optional wireless link carries the same traffic when you unplug. [More](docs/GUIDE.md#how-it-works) |
| **A Mac that stays awake** | Lid closed is fine. It still sleeps at your battery limit or when it runs hot, and the phone shows how long it has left. [More](docs/GUIDE.md#keep-mac-awake) |
| **Its shell, from anywhere** | A real terminal on your Mac from the phone: on the same Wi-Fi, over Tailscale, or from anywhere through a built-in end-to-end encrypted connection. Sessions survive disconnects and are recorded. On iPhone you can also see and control the screen. [More](docs/GUIDE.md#remote-shell) |
| **A VPN on top** | WireGuard or OpenVPN (NordVPN built in) with a kill switch, over the phone's connection or any other network. [More](docs/GUIDE.md#vpn-layer) |

## Your Mac from the phone

The phone apps open on your Mac: three switches, **Internet through this phone**, **Keep Mac awake** and **VPN**, its battery and how long it stays awake, and any shell waiting on you. A switch that can't turn on right now says why, with the fix.

<p align="center">
  <img src="docs/images/iphone-vpn-off.png" width="250" alt="Turning the VPN off from the phone asks first and names what changes">
  &nbsp;
  <img src="docs/images/android-mac.png" width="250" alt="The same Mac tab on Android">
</p>

* **Needs you**: when a shell goes quiet on a question, like Claude asking to make an edit, the phone shows it and opens the terminal right there.
* **Activity**: a timeline of what happened on the Mac, from the VPN reconnecting to a long-running shell finishing, with its battery as a line.
* **Without opening the app** (iPhone): turning Keep awake on starts a Live Activity that counts down the Mac's awake time in the Dynamic Island and on the Lock Screen; a widget, Control Center buttons and Shortcuts cover the rest.

## On the Mac

<p align="center">
  <img src="docs/images/mac-notice-notch.png" width="380" alt="A notice growing out of the notch: VPN turned off by iPhone, kill switch off too, with Turn back on">
  &nbsp;
  <img src="docs/images/mac-notice-capsule.png" width="380" alt="The same kind of notice as a capsule under the menu bar on a screen without a notch">
</p>
<p align="center">
  <img src="docs/images/mac-menubar.png" width="560" alt="The menu-bar icon's states: the phone alone, online, with a cup while awake and a lock while the VPN is on, an amber dot when a shell needs you, and an amber phone when something is wrong">
</p>

A menu-bar app with the same three switches; one that can't turn on says why and offers the fix. When the phone changes something, a notice grows out of the notch (or drops in under the menu bar on screens without one), and anything that lowers protection stays until someone at the Mac sees it. The icon says it all at a glance: online, awake, VPN on, a shell waiting on you, or something wrong. On first launch it asks what you want the phone to do and only asks for permissions when each one is first needed.

<p align="center"><img src="docs/images/mac-welcome.png" width="680" alt="First run: What should your phone do for this Mac? Four choices and what each one needs, now or later"></p>

## Safe by design

* **Pairing happens over the cable**, with a six-digit code shown on the phone. Keys never travel any other way.
* **The phone's shell keys need Face ID** (or the passcode / screen lock) every time the app opens.
* **Turning protection down asks first.** Turning things on from the phone is one tap; turning the VPN off needs Face ID, works only inside the app, and leaves a notice on the Mac. Each phone's permission to change Keep awake and the VPN can be turned off on the Mac.
* **The Mac's limits always win**: Keep awake still stops at the battery limit or when it runs hot, whoever asked.
* **No accounts, no Passthrough server.** "From anywhere" is end-to-end encrypted (iroh), through public relays or [your own](docs/GUIDE.md#self-hosting-a-relay).

Details in the [security model](docs/GUIDE.md#security-model) and [SECURITY.md](SECURITY.md).

## How it works

```
┌──────────── Mac ─────────────┐  USB or wireless   ┌──────────── Phone ─────────────┐
│ apps → utunN → tun2socks ────┼───────────────────▶│ SOCKS5 (loopback) → cellular   │
│          (root helper)       │ usbmuxd (iPhone)   │ iPhone: VPN extension          │
│ shell · keep awake · VPN     │ adb (Android)      │ Android: foreground service    │
│                              │ TLS / iroh (shell) │                                │
└──────────────────────────────┘                    └────────────────────────────────┘
```

The Mac routes its traffic into a tunnel that ends on the phone, and the phone opens each connection with its own network stack. The same pairing then carries everything else: the remote shell, the Mac's state, and your requests to change it. Both phone apps speak the [same protocol](protocol/README.md), so the Mac treats them alike.

## Get started

You build it yourself (there are no signed releases yet). You'll need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an Apple Developer account; for Android, JDK 25 and the Android SDK.

```sh
brew install xcodegen
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate && open Passthrough.xcodeproj
```

1. **Mac:** build the `PassthroughMac` scheme (Release for everyday use) and open it; allow the helper when macOS asks.
2. **iPhone:** run the `Passthrough` scheme on your phone and tap the power button. **Android:** `./gradlew installDebug` in `android/`, then turn on USB debugging.
3. Plug the phone in, flip the switch in the menu bar, and type the code the phone shows.

The [full setup](docs/GUIDE.md#setup) covers bundle IDs, signing, the wireless link and recovery.

## More

* [**The full guide**](docs/GUIDE.md): every feature in depth, setup, failure recovery, troubleshooting and known limits
* [Wire protocol](protocol/README.md) · [Android notes](android/README.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Released under the [MIT License](LICENSE).
