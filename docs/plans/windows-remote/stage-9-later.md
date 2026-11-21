# Stage 9: Later, outlined

Nine items, none scheduled. Each has a design sketch, what it depends on, what would move it up, and a rough size (in the master plan's terms: stages 3, 4, 6 and 8b are "big"; S is one or two PRs, M three to five, L a stage of its own).

## Goal and done-when

This file is done when each item below can be picked up and turned into its own stage plan without re-deriving its shape. Nothing here is built in this stage. Each item's own done-when is its last line.

## What exists today (verified, with path:line)

- The Mac's stream host, which the PC's own stream ports: `Packages/PassthroughCore/Sources/ScreenHost/ScreenVideoStreamer.swift` (acks pace it, newest capture only, idle slow-down to 15 fps after 1 s of changes under 3%, refine passes: `:7-33`, `:37-46`, `:69-70`); `StreamPacer.swift` (window 2–24 from the shortest round trip in 10 s, bitrate floor 1 Mb/s, cut at 100 ms lag, grow 15% every 0.5 s, size steps per quality: `:22-63`); `VideoEncoder.swift:49-59` (real-time, no reordering, Constrained High / HEVC Main, BT.709); `InputInjector.swift:7-23` (the `InputSink` seam: pointer, scroll, key, text, clipboard, function, gesture, releaseAll, clipboard change count); `ScreenViewers.swift`, `CursorWatch.swift`, `TypingPacer.swift`.
- The wire it speaks: `PassthroughCore/ScreenVideoWire.swift` (ported to C# in stage 8(b)); modifiers are command 1, shift 2, option 4, control 8 (`:214-221`); keys are X keysyms (`PassthroughCore/RFBKeys.swift:6-36`).
- The Mac's timeline and notices: `events`/`eventList` and `push` (`protocol/README.md:474-479`, `:506-512`); the notice is sealed with ChaCha20-Poly1305 and sent to APNs with the Mac's `.p8` key, which is compiled into the Mac build (`CHANGELOG.md:9-25`).
- Terminals on the Mac: `ShellHost/LocalTerminalServer.swift:6-16` (a 0600 Unix socket, user checked), `LocalTerminalAccess.swift:6-31` (hook/new/list only while sharing is on; attach by one-time token), `TerminalHook.swift:5-14` (fail-open lines in the shell's startup file), the wire in `PassthroughCore/LocalTerminalWire.swift`.
- Windows today: the app is x64 only (`windows/src/Passthrough.App/Passthrough.App.csproj:8-10`), unsigned, built from source (`windows/README.md:27-46`); the PC's name everywhere is `Environment.MachineName` (`windows/src/Passthrough.App/App.xaml.cs:96`); the old roadmap's stage 3 (Desktop Duplication, Media Foundation, input injection, sound) and stage 7 (terminals on the PC, notifications) are what this file outlines (`windows/README.md:21`, `:25`).
- Android has a shell client and replay (`android/app/src/main/java/dev/dpatel/passthrough/core/ShellReplay.kt`) and no screen viewer of any kind.

## Design

### 1. The PC's own screen stream

**Sketch.** The PC answers `screenVideo` the way a Mac does, so every existing viewer (iPhone, iPad, the Mac's window, the PC's window from stage 8) works unchanged, and `host.screens` gains `video`.

- *Capture*: **Windows.Graphics.Capture** as the default (`GraphicsCaptureItem` for a monitor through `IGraphicsCaptureItemInterop.CreateForMonitor`, a free-threaded frame pool, cursor capture off, the yellow border off where Windows allows it), because it delivers GPU textures with dirty regions and survives mode changes. **Desktop Duplication** (`IDXGIOutputDuplication`) is the fallback for Windows 10 before 1903 and the only choice for the secure desktop (below), since it is what a SYSTEM process can run on the Winlogon desktop. Both feed one interface: `ICaptureSource { event Frame(texture, dirtyFraction, time); Size; Stop() }`.
- *Encode*: a hardware encoder transform found with `MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, HARDWARE)` for H.264, and HEVC when the viewer offers it. These are asynchronous transforms (event-driven), unlike stage 8's decoders. Settings through `ICodecAPI`: low-latency mode, no B-frames, `CODECAPI_AVEncCommonRateControlMode` = low-delay VBR or CBR, bitrate set live from the pacer (`CODECAPI_AVEncCommonMeanBitRate`), forced keyframes (`CODECAPI_AVEncVideoForceKeyFrame`), BT.709 video range in the VUI. BGRA → NV12 on the GPU with the video processor. Output is Annex B: converted to the wire's length-prefixed units, parameter sets lifted into `format`. Software fallback: Microsoft's H.264 encoder transform, capped at 30 fps.
- *Pacing*: `StreamPacer` and `ScreenVideoStreamer` ported to Core over `ICaptureSource`, `IVideoEncoder` and `IInputSink`, with the Swift tests (`ScreenHostTests`). The same limits on what waits for the network, the same per-sender payload caps, `TypingPacer` for text.
- *Input*: `SendInput`. Pointer as absolute, virtual-desk-normalised moves; buttons; wheel from the wire's stream pixels converted to wheel deltas (120 per ~100 px, the inverse of stage 8's `ScrollScale`), fine-grained. `text` as `KEYEVENTF_UNICODE` pairs, paced. `clipboard` and `copy` through the clipboard with a sequence-number check (`GetClipboardSequenceNumber`) so only what that copy produced is returned, and the history exclusion formats set on what a viewer pastes.
- *Keysym → virtual key*: specials by table (Return, Tab, arrows, F1–F12 …); a character through `VkKeyScanEx` on the active layout, pressed with the Shift/AltGr it needs; one that no key types goes as Unicode. Each modifier's own key is pressed around the key, as the Mac does (`protocol/README.md:689-692`).
- *What ⌘ means on Windows*: the wire's `command` bit is **Ctrl** by default (⌘C, ⌘V, ⌘Z, ⌘T are what the viewer's user means), `option` is Alt, `control` is Ctrl as well, and the Windows key is reached by the viewers' existing ⊞ key (the master plan's key row), sent as a keysym (Super_L, 0xFFEB). This matches "⌘ acts as Ctrl by default, switchable to ⌘ = ⊞" for the RDP view, so both PC screens feel the same; the switch is the viewer's and travels as which bit it sets. `function` is ignored. `gesture`: magnify → Ctrl+wheel; rotate ignored.
- *Cursor*: position at 60 Hz from `GetCursorInfo`, shape from `GetIconInfo` + `GetDIBits` when the handle changes (looked at 10 times a second), encoded as PNG; monochrome and masked cursors rendered to RGBA first. Same messages as the Mac's.
- *Sound and microphone*: WASAPI loopback of the default output, encoded AAC-LC 48 kHz stereo with the Media Foundation AAC encoder (excluding this process, so a viewer's voice isn't sent back: process-loopback exclusion on Windows 10 2004+). A microphone device needs a virtual audio driver, which needs a signed driver: not offered (`microphoneState` 2).

**The two modes, named in the UI as the master plan says:**
- **Take over**: today's Remote Desktop relay. Locks the PC's screen; works locked or signed out.
- **Share**: this stream. Shows what is on the PC's display, to whoever is there too.
The viewer's Display menu offers whichever the PC reports in `host.screens`; with both, **Share** is the default when someone is signed in and at the PC, **Take over** otherwise.

**The lock screen and UAC, and why they need a SYSTEM helper.** The tray app runs as the user on the default desktop. The lock screen, the sign-in screen and UAC's consent prompt are on the Winlogon (secure) desktop, where a user process can neither capture nor inject. Seeing and typing there needs a process running as SYSTEM in that session, attached to that desktop (`OpenInputDesktop`/`SetThreadDesktop`), using Desktop Duplication, started by a service with `CreateProcessAsUser` and a SYSTEM token for the session. That **conflicts with the service the master plan builds**: `PassthroughService` runs under its own account with only the change-notify privilege and a restricted SID precisely so a compromise of the network-facing code can't become SYSTEM. Launching a SYSTEM process needs `SeTcbPrivilege`/`SeAssignPrimaryTokenPrivilege`, which that service must not hold. So the helper cannot be a child of it. The shape that keeps both: a **second, tiny LocalSystem service** (`PassthroughDesktopHelper`) that listens on nothing, is installed by the same elevated step, and starts a per-session capture helper only on a request arriving over a pipe whose client it verifies to be the network service's SID; the helper streams frames back and accepts input only while a view the network service authorised is open, and injects nothing on the secure desktop except while the owner has turned on "Let phones type at the lock screen and administrator prompts". It is the largest new privileged surface in the whole plan and gets its own design and review. Until it exists, **Share** shows a card over the secure desktop: "*Office-PC* is showing its lock screen. Use Take over to sign in."

**No monitor attached.** A headless or lid-closed PC has no output to capture. Options, in order of preference: (1) nothing new: use **Take over**, which needs no display; (2) an **Indirect Display Driver** (a user-mode virtual monitor, the way `ScreenVideoStreamer`'s device fit makes a display in the viewer's shape: `protocol/README.md:661-670`), which also gives a real fit-to-device mode, but is a driver that must be signed (attestation-signed at least) and installed by the elevated step; (3) telling the owner to fit an HDMI dummy plug. Recommended: (1) in the first version of the stream, (2) only after signed releases exist.

- **Depends on**: stage 4 (service, pipe, `ISessionHost`), stage 8(b) (`ScreenVideoWire` in C#, `Passthrough.Media`, `JitterBuffer`), stage 6's `ScreenBackend` seam (the phone already has the video backend); the SYSTEM helper additionally on the elevated install step and on signing.
- **Moves up if**: the first spike shows many PCs that Remote Desktop can't serve (Windows Home, accounts with no password, work accounts), since this is their only screen; or the owner wants to share a screen with someone sitting at the PC, which Take over can't do.
- **Size**: L for Share while signed in and unlocked (capture, encoder, pacer port, input, cursor, sound). The SYSTEM helper is another L and a security review. The virtual display is M plus driver signing.
- **Done when**: the iPhone and the stage 8 window show a signed-in PC through `screenVideo` with the Mac's pacing behaviour, on Windows Home.

### 2. Wake-on-LAN from a computer on the same network

**Sketch.** A sleeping PC can't answer; another Passthrough computer on its network can wake it. The PC, while awake, tells its phones and computers how: `host` gains `wake: {"mac":"aa:bb:…","broadcast":"192.168.1.255"}` for each wired or Wi-Fi adapter that has wake enabled (read from the adapter's power settings), stored with the credential. A viewer that can't reach the PC and holds wake details asks a computer it *can* reach: a new shell message `wake` with `host` (the sleeping PC's id as that computer knows it), answered `woke` or `error`. The asked computer sends the magic packet (UDP 9, 6×FF then 16×MAC) to the stored broadcast address only, only for a host it itself holds a credential for, at most once a minute per host. The phone on the same Wi-Fi can send the packet itself with no helper. Shown as **Wake** next to **Try again** in the "went to sleep" state.

Limits to say: Modern Standby laptops and most Wi-Fi adapters don't wake on a magic packet; it needs the option on in firmware and in the adapter; it never crosses routers.

- **Depends on**: stage 1(b)'s `host` and going-away reasons, stage 4's power work, stage 7 (two computers knowing each other).
- **Moves up if**: the owner's PCs sleep by policy and *Stay awake* isn't acceptable.
- **Size**: S on each platform (M in total with fixtures and the setup row "This PC can be woken by your other computers").
- **Done when**: a sleeping desktop on Ethernet is woken from the phone through the Mac, and the phone's page reconnects by itself.

### 3. The Android screen viewer (stream first, then Remote Desktop)

**Sketch.** *Stream first*, because it needs no third-party engine: a Kotlin port of `ScreenVideoWire` and `ScreenVideoClient` on the stage 8 fixtures; `MediaCodec` in low-latency mode (`KEY_LOW_LATENCY`, Android 11+) decoding to a `SurfaceView`, acking from `OnFrameRenderedListener`, HEVC offered when a hardware decoder is listed; the pointer drawn as a view; touch modes, the key row and the keyboard as the iPhone has them; copy and paste on tap. That gives Android the Mac's screen, and a PC's once item 1 exists. *Then Remote Desktop*: FreeRDP built for Android (it has an Android target) with the same hardening and transport hook as stage 6, behind the same backend seam on Android, plus a login store on the Android Keystore with a biometric-bound key.

- **Depends on**: stage 8(b)'s fixtures (stream); stage 6 and its build script (Remote Desktop); stage 2's Android host-kind work.
- **Moves up if**: the owner or a user depends on an Android phone for a PC's screen; the stream half moves with item 1.
- **Size**: L for the stream viewer; L again for Remote Desktop.
- **Done when**: an Android phone shows and controls a Mac's screen at 60 fps on cellular; then a PC's through the relay.

### 4. Timeline and notifications from a PC

**Sketch.** *Timeline*: a C# port of the Mac's event log (`MacEventLog`) in the tray app, fed by what the PC already knows: shells opened and ended, a program asking and being answered, power (sleep, wake, plugged, on battery from `SystemEvents.PowerModeChanged` and the power-setting notifications), the link, Stay awake. Stored per user, 7 days, 500 newest; `events` then answers a real `eventList` in place of the empty one. Battery samples every 5 minutes and at each plug change.

*Notifications*: the Mac sends APNs itself with a key compiled into the build. A PC build has no Apple key and the owner's `.p8` shouldn't be copied to a second machine by default. Two routes: (a) **the owner's key on the PC too**: the same `.p8`, key id and team id entered once in Settings, stored with the service; the PC then does exactly what the Mac does (HTTP/2 to APNs, token auth with ES256, the sealed `PushNotice`); (b) **through a paired Mac**: the PC hands the sealed notice to a Mac it knows (item needs stage 7), which sends it. Recommended: (a), stated as "copy your push key to this PC", because (b) fails whenever the Mac is asleep. Android phones get the same notice through the app's existing foreground connection, not a push service.

- **Depends on**: stage 3 (sessions, program status surviving ConPTY), stage 4 (who holds the key: the tray app, since notices are about the user's sessions).
- **Moves up if**: Claude Code on a PC is a main use (the "needs you" notice is the point of it).
- **Size**: M (timeline) + M (notifications).
- **Done when**: the phone's timeline tab shows a PC's day, and a blocked Claude Code session on the PC raises a Time Sensitive notice.

### 5. Terminals on the PC shown on phones

**Sketch.** The Windows counterpart of `LocalTerminalServer` and `TerminalHook`. Stage 8 already ships `passthrough-term.exe`, its per-user pipe, `TermWire` (the Mac's frame format and kind numbers) and `TermAccess` (tokens); this adds the Mac's modes to the same pipe:
- `attach` with a token: **Open here** in the flyout shows a phone's session in a Windows Terminal tab beside the phone (the flyout row the master plan already reserves: "*PowerShell* is asking" → **Open here**). The session's ConPTY gains a second viewer; sizes follow whoever typed last, and a terminal's own answers to queries are dropped from any viewer but the one followed, as `protocol/README.md:408-420` describes.
- `new` and `hook`: a shell started in a terminal window becomes a session (`origin` `mac` on the wire today: add `pc`, or rename to `host`, fixtures first). The hook on Windows is one of: a **Windows Terminal profile** "Passthrough" whose command line is `passthrough-term.exe new` (explicit, safe, the recommended first step, and it is the master plan's "the other computer as a Windows Terminal profile" mechanism turned inwards); a guarded block in the PowerShell profile (`$PROFILE`) written to fail open like the Mac's (`TerminalHook.swift:8-13`); `cmd.exe` has no safe equivalent and is left out. "Show new terminals on my phones" stays off by default and is the same trade the Mac states (`LocalTerminalAccess.swift:8-12`).
- The session's shell runs inside the tray app's job with the environment the terminal passed, never elevated: a terminal that is itself elevated is refused ("An administrator terminal can't be shared.").

- **Depends on**: stage 3 (ConPTY sessions and viewers), stage 8(a) (the tool and pipe).
- **Moves up if**: the owner works at the PC and wants to pick the same shell up on the phone, the Mac's most used shell feature.
- **Size**: M for Open here; M for new/profile; S for the PowerShell hook.
- **Done when**: a Claude Code session started in a Windows Terminal tab is listed on the iPhone and can be answered there.

### 6. Authenticode-signed releases

**Sketch.** Today everyone builds from source and nothing is signed, so the elevated install step can only compare the files it copies with themselves. With a code-signing certificate (an OV/EV certificate or Azure Trusted Signing; the private key in the signing service or an HSM, never in the repo or a CI secret that a PR can read), a release workflow on tags builds, signs every exe and dll (the app, service, tool, bridge, and the bundled ConPTY which keeps Microsoft's signature) with a timestamp, and publishes a zip with its hashes.

What that unlocks:
- **Install step**: `--install` and `--update` verify each copied file's signature and that the signer is the release's (pinned by certificate subject and issuer, checked with `WinVerifyTrust` plus the signer's identity) before registering the service; the known limit "a program already running as you could alter the files before you approve the prompt" goes for signed builds. The UAC prompt shows a verified publisher in place of "Unknown publisher".
- **Pipe checks**: the service can require that the tray app connecting to it is a signed Passthrough binary (process image → signature), not just "some process of that account"; the tray app can require the same of `passthrough-term.exe` and of the service. That narrows "any program running as the same Windows account could be the session host" to programs that can inject into a signed process.
- **SmartScreen** stops warning once the certificate has reputation; **driver work** (item 1's virtual display) becomes possible at all.
- Source builds keep working unsigned, with the checks off and a line in the log saying so.

- **Depends on**: stage 4's install step; a certificate and its cost (the owner's decision).
- **Moves up if**: anyone but the owner installs it, or item 1's SYSTEM helper is built (a SYSTEM service from unsigned files is hard to defend).
- **Size**: M (workflow, verification code, docs) plus the paperwork.
- **Done when**: a downloaded release installs with a named publisher and refuses to install after one byte of the service exe is changed.

### 7. The stricter split: the tray app verifies each phone itself

**Sketch.** In the master plan the service checks a phone's key proof and then speaks for it to the tray app, so a compromised service could act as any phone to every signed-in account's shells (stated honestly there). The stricter split makes the shell end-to-end between phone and tray app: the tray app holds the per-phone keys (or a second key per phone made at grant time), and after the service's handshake the phone and the tray app run a second challenge and proof through the service, deriving a session key (HKDF over both nonces and the key); every shell line is then sealed (ChaCha20-Poly1305, a counter nonce per direction) so the service relays bytes it can neither read nor forge. The service still does everything that must work signed out: limits, the first proof, the Remote Desktop relay, `host`.

It is a protocol change (a new `seal` capability in `host`, phones that know it use it, fixtures and three suites) and it needs the grant to hand the phone the tray app's half, so phones are re-granted once.

- **Depends on**: stage 4 in production long enough to know the pipe's shape is right.
- **Moves up if**: a security review, or use on shared PCs, makes "a service compromise is a shell as every user" unacceptable; or item 1's SYSTEM helper raises the stakes of the service.
- **Size**: L (protocol, three clients, migration).
- **Done when**: a debug service that tampers with or injects a shell line is detected by the tray app and the phone, and the connection closes.

### 8. arm64 Windows builds

**Sketch.** The app is x64 only and Snapdragon PCs run it emulated (master plan "iroh"). Native arm64 needs: `win-arm64` added to the app, service and tool (`Platforms`, `RuntimeIdentifier`); the Windows App SDK and H.NotifyIcon both ship arm64; the iroh bridge built for `aarch64-pc-windows-msvc` in CI; the bundled ConPTY package's arm64 binaries; the install step picking the machine's architecture (and refusing a mismatched service: an x64 service on arm64 works emulated, but the two must match the native library they load). Media Foundation, WASAPI and D3D11 are the same APIs; hardware H.264/HEVC decode and encode on Qualcomm's drivers need the real-hardware checklist run again. CI gets a `windows-11-arm` job.

- **Depends on**: stage 3's bridge build script; a Snapdragon PC to test on.
- **Moves up if**: the owner or a user has one; emulated video decode in stage 8(b) proves too slow there.
- **Size**: S to build, M with the checklist.
- **Done when**: the stage 3, 5 and 8 checklists pass on a Snapdragon PC with nothing emulated.

### 9. A display name for the PC

**Sketch.** `DESKTOP-7K2L9QF` is what phones show. One text field in Settings ▸ Remote access, "This PC's name" (up to 64 characters, one line, the rule `ScreenPass.cleanName` already applies to names: `ShellProtocol.swift:316-320`). The hard part is that the name is also an identifier: the DNS-SD instance name must equal the granted host name because phones match on it, and the grant must use one source for it or every phone is re-keyed (master plan "Discovery"). So: the display name is stored machine-wide by the service (changed through the elevated step, like the other machine-wide settings, or allowed to the owning account through `IAccessAdmin`: a choice for its plan); `host` carries it on every connection and phones update the stored name from it (never the key or pin); the DNS-SD instance is re-registered under the new name and, for 30 days, also under the old one, so a phone that hasn't connected since still finds the PC on the network; computers' stored credentials update the same way. The control channel's `clientName` (`App.xaml.cs:96`) follows it.

- **Depends on**: stage 1(b)'s `host`, stage 4's DNS-SD registration.
- **Moves up if**: more than one PC is in use (two `DESKTOP-…` names side by side), which makes it the cheapest visible improvement here.
- **Size**: S.
- **Done when**: renaming the PC in Settings changes its name on a connected phone within a second and on a disconnected one at its next connection, with no re-pairing.

## Pull requests, in order

None are scheduled. Suggested order if nothing changes the priorities: **9** (display name, S) → **5** (Open here, then the profile) → **4** (timeline, then notifications) → **2** (Wake-on-LAN) → **6** (signed releases) → **1** (Share, signed in; then the helper) → **3** (Android stream, then Remote Desktop) → **8** (arm64, when hardware is to hand) → **7** (stricter split). Each item becomes a stage plan of its own in the BRIEF's format before any code; items 1, 6 and 7 get a security review first.

## Interfaces

### This stage defines (others depend on these)

Nothing is built, so these are reservations a later plan must honour or change on purpose:
- `host.screens` value `video` for a PC (item 1); `host.wake` and messages `wake`/`woke` (item 2); `host.seal` (item 7); `origin` beyond `mac` (item 5).
- Mode names in every viewer's UI: **Take over** and **Share**.
- The service name `PassthroughDesktopHelper` and the rule that the network service never holds a privilege that can start it.
- `ICaptureSource`, `IVideoEncoder`, `IInputSink` as the seams for the ported streamer.

### This stage consumes

- Stage 1: `host`, fixtures in three suites. Stage 3: ConPTY sessions with viewers, the bridge. Stage 4: the service, pipe, install step, DNS-SD, power. Stage 5: the relay (**Take over**). Stage 6: the phone's backend seam, the FreeRDP build. Stage 7: computers knowing each other. Stage 8: `ScreenVideoWire` and `JitterBuffer` in C#, `Passthrough.Media`, `passthrough-term.exe`, `TermWire`, `TermAccess`.

## Tests

Per item, when planned: Core suites with fakes for everything portable (the pacer and streamer ports against the Swift cases; the keysym → virtual key table; the wake packet's bytes and the once-a-minute rule; the event log; the sealed-line framing with tamper cases; name change rules), fixtures first for every wire change, and a real-hardware list per item (item 1: integrated and discrete GPUs, a 4K display, a laptop on battery, lid closed; item 2: Ethernet and Wi-Fi adapters, Modern Standby; item 8: a Snapdragon PC).

## Security considerations for this stage

- **Item 1's helper** is SYSTEM code driven by a network-facing path: the largest risk in the plan. It must be a separate service, accept requests only from the network service's SID, capture and inject only during an authorised view, default to no typing on the secure desktop, and ship only from signed builds.
- **Share** shows the screen to a viewer with no Windows password involved (as the Mac's stream needs no Mac password): the per-phone Screen switch is the whole consent, and a notice that stays is shown at the PC while it is viewed. There is no curtain on Windows without a driver; say so.
- **Injected input** from a medium-integrity process can't reach elevated windows (UIPI); that is a feature, and the UI says "This window belongs to an administrator program. Use Take over."
- **Wake-on-LAN** makes a computer send a packet on request: only for hosts it holds credentials for, to a stored broadcast address, rate-limited, so it can't be turned into a scanner.
- **A push key on the PC** is a second copy of the owner's Apple key: stored with the user's secrets, never logged, optional.
- **The hook in the PowerShell profile** edits a file the user's shell runs: fail open, marked begin and end lines, removed on switch-off and uninstall.
- **Signing** moves trust to the certificate: its key must not be reachable from pull-request CI.
- **The display name** comes from the owner but is shown on other devices and put on command lines by viewers (stage 8 cleans it there); cleaned and length-limited at the source too.

## UX states and strings for this stage

Given by the master plan: **Take over** ("locks the PC's screen; works locked or signed out"), **Share** ("shows what is on its display"). Proposed here, to be settled in each item's plan:
- Share over the secure desktop: "*Office-PC* is showing its lock screen. Use Take over to sign in."
- Share, elevated window: "This window belongs to an administrator program. Use Take over."
- At the PC while shared: "*iPhone* is viewing this PC's screen." **Stop**
- Wake: **Wake**; "Asked *MacBook* to wake *Office-PC*…"; "*Office-PC* didn't wake. It may be off, or not set to wake from the network."
- Setup row: "This PC can be woken by your other computers." / "This PC's network adapter doesn't wake it from sleep."
- Terminals: "Show new terminals on my phones"; "An administrator terminal can't be shared."
- Name: "This PC's name", "Phones and other computers show this name."

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| Hardware encoders differ widely (rate control, keyframe forcing, latency) | a spike per vendor (Intel, AMD, NVIDIA, Qualcomm) before the plan; the software encoder as a floor |
| The SYSTEM helper widens the attack surface more than it is worth | ship Share without it first; decide with data on how often people need the lock screen when Take over exists |
| No way to hide the PC's screen while shared | stated; a virtual display driver could later give a private display |
| Wake-on-LAN rarely works on laptops | the setup row says so per adapter; never promised |
| Copying the APNs key to a PC | optional; the alternative through a Mac is written down |
| FreeRDP on Android repeats stage 6's cost | stream viewer first; Remote Desktop only if PCs without item 1 matter on Android |
| A renamed PC is lost by phones that match on the old name | both names advertised for 30 days; `host` carries the new one |
| The stricter split forces every phone to be re-granted | done once, with the old path kept until each phone has the new key |

## Decisions made here

1. **Windows.Graphics.Capture by default, Desktop Duplication for old builds and the secure desktop.**
2. **The wire's ⌘ is Ctrl on a PC**, matching the Remote Desktop view's default.
3. **The SYSTEM helper is a separate LocalSystem service, never a child of the network service**, and is not part of the first version of Share.
4. **Headless PCs use Take over**; a virtual display driver waits for signed releases.
5. **No microphone device on a PC host** (it needs a driver).
6. **Wake packets are sent only for known hosts, to a stored broadcast address, once a minute.**
7. **Android gets the stream viewer before Remote Desktop.**
8. **Notifications use the owner's own push key on the PC**, not a relay through a Mac.
9. **Terminals on the PC start with Open here and a Windows Terminal profile; the PowerShell profile hook comes last; no `cmd.exe` hook.**
10. **Unsigned source builds keep working after signed releases exist.**
11. **A renamed PC advertises both names for 30 days.**
12. **Suggested order: 9, 5, 4, 2, 6, 1, 3, 8, 7.**

## Corrections to the master plan

1. The master plan says seeing the lock screen and UAC through the PC's own stream "needs a SYSTEM helper, its own design". It should also say that this helper **cannot be started by `PassthroughService`** as designed (no privilege to do so, on purpose), so it means a second service and a second elevated install surface.
2. Stage 9's list in the master plan omits **arm64 builds** and **a display name for the PC**; the first is mentioned only under iroh ("Snapdragon PCs run the app emulated") and the second only under "After the must-haves". Both are outlined here.
3. "The PC's own stream … the only screen for Windows Home and password-less accounts": true only for a PC that is **signed in and unlocked** until the helper exists. A Windows Home PC at its lock screen or after a reboot has no screen in this plan until then. The known limits should say so.
4. The old roadmap in `windows/README.md:21` promises "sound and microphone" for the PC's screen; a microphone device on Windows needs a signed driver and is not planned.
5. With **Share**, a PC can finally show its screen to another PC (stage 8's window decodes it), which closes the gap noted in stage 8's corrections.

## Open questions for the owner (each with a recommended default)

1. **Is the SYSTEM helper wanted at all**, given Take over already covers the lock screen and UAC on Windows Pro? Default: no, until Windows Home users need it.
2. **Buy a code-signing certificate** (or use Azure Trusted Signing)? Default: yes before anyone else installs it, and before any SYSTEM helper or driver.
3. **Put your Apple push key on the PC** for notifications, or route through a Mac? Default: the key on the PC, optional.
4. **A virtual display driver** for headless PCs and a private, phone-shaped display? Default: not until releases are signed.
5. **On a PC, should ⌘ from a viewer mean Ctrl** (with ⊞ on its own key)? Default: yes, as in the Remote Desktop view.
6. **Which comes first after the must-haves**: the order suggested is display name, terminals on the PC, timeline and notifications, Wake-on-LAN, signing, the PC's own stream, Android's screen, arm64, the stricter split. Default: that order; the PC's own stream jumps to the front if the spike finds many PCs Remote Desktop can't serve.
7. **Who may rename the PC**: an administrator only, or the account that owns Remote access? Default: the owning account, without a prompt.
