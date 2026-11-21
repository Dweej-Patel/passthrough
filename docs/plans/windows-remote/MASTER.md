# Windows PCs as full peers: shell and screen, to and from a PC

## Context

Passthrough lets a phone (and, for the screen, another Mac) reach a **Mac's** shell and screen. The Windows app is at stage 1: it pairs with a phone over the cable and shows status. This plan makes a Windows PC a full peer:

- **PC as host**: its shell and screen from the iPhone/iPad and from the Mac (Android: shell now, screen later).
- **PC as viewer**: the Windows app opens a Mac's shell and screen.
- **Unattended**: the PC's screen must work locked, signed out after a reboot, with the display off or absent, and for UAC prompts.

Decisions made with the owner:

| Question | Decision |
|---|---|
| Screen path for a PC | **RDP first** (the host relays to its own Remote Desktop on loopback); Passthrough's own stream later |
| PC states to cover | Locked, signed out, display off / headless, UAC prompts |
| Mac ↔ PC | All four directions, shell and screen |
| Phones | iPhone/iPad now; Android gets the PC's shell now, any screen later |
| Mac ↔ PC trust | Both: a phone hands over access, and the two computers pair directly |
| Windows sign-in for RDP | Saved on the viewer, behind Face ID / Touch ID / Windows Hello |
| From anywhere (iroh) on Windows | From the first version, both roles |
| PC shell | Chooser; PowerShell 7 by default; never elevated |

It replaces stages 2 and 3 of `windows/README.md`'s roadmap and adds the viewer role. The plan was reviewed three times (security, implementation, UX); what those reviews changed is built in below, and what is still unproven is listed as a spike with a pass/fail line.

## 1. What it will feel like

House rules kept: a switch that can't turn on says why, with the fix; prompts come only when first needed; anything that lowers protection leaves a notice that stays; the viewer says what it is doing and moves to the better path by itself. Wording: short, second person, the device named ("this PC", "the iPhone"), no exclamation marks, says what to do next.

### Names

- **Remote access** is the PC's umbrella setting (the Mac's "Remote Shell" tab already holds Screen and more; renaming it to match is its own later PR).
- **Screen** is the feature everywhere, including the per-phone switch. "Remote Desktop" appears only where Windows itself is meant: the setup row, the sign-in sheet, refusals.
- **Your computers**, **Add a computer**. Once the kind is known: "this PC", "the PC", "the Mac", never "computer". The kind shows in the status line ("PC · Connected"); the avatar stays a letter on a colour.
- When the PC's own stream arrives later the two modes are named by what they do: *Take over* (locks the PC's screen; works locked or signed out) and *Share* (shows what is on its display).

### First run on the PC: ten moments, one password typed

1. Open the app. One card, as the Mac's welcome: "Reach this PC from your phone", and *what it needs*: one administrator prompt now; your phone plugged in once; your Windows password, on the phone, the first time you open the screen.
2. Settings ▸ **Remote access** (a settings page, not the flyout, which closes when the UAC prompt takes focus). Two ticked boxes: *Use this PC's shell*, *See and control its screen*. Under the second: "Uses Windows Remote Desktop, kept closed to the network. While a phone is in, this PC's own screen shows the lock screen, and stays locked afterwards." One button, **Turn on**.
3. One UAC prompt does everything (a standard user reads "Windows will ask for an administrator's password").
4. Setup rows fill in and stay in Settings ▸ Remote access (done / needed / optional / problem, as the Mac's). Only a failing row shows a button:
   - *Background service*: "Running." / "Didn't start: *reason*." **Try again**
   - *On this network*: "Phones on your Wi-Fi or Tailscale reach this PC directly." / "Needs Windows 11. Phones use the built-in connection instead."
   - *From anywhere*: "Ready, through *relay*." / "The relay isn't answering. Phones on this network still work." **Relay settings**
   - *Screen*: "Remote Desktop is on, for Passthrough only." / "Windows Home has no Remote Desktop. The shell works; the screen needs Windows Pro." / "Remote Desktop was turned off in Windows Settings." **Turn on** / "Remote Desktop is open to the network. Passthrough won't relay to it until that is closed." **Close it**
   - *Your account*: "*name* can sign in with its password." / "This account signs in with a PIN or Windows Hello only. Remote Desktop needs its password: add one, or sign in to this PC with it once." **Open sign-in options** / "Work accounts aren't supported yet."
   - *Staying reachable* (optional): "This PC sleeps after 30 minutes. A sleeping PC can't answer." **Stay awake while plugged in**
5. "Now plug in your phone." The Apple Devices or adb hint appears here only if missing (existing `WatcherHints`).
6. On the phone: Trust, open Passthrough, **Pair**. The phone's setup steps get a PC variant (today they say "Turn on Remote shell on your Mac" and talk about sharing): for a PC the button reads **Turn on the cable link**, and the iOS prompt is explained: "iOS asks to add a VPN configuration. That is how the cable link works; no traffic is sent through it for a PC."
7. Type the six digits in the flyout (exists).
8. A notice that stays, in the flyout: "*iPhone* can now open shells on this PC. Let it see the screen too? Windows still asks for your password." **Allow screen** · **Not now**. (So the Screen switch is never a hidden step.)
9. On the phone the PC appears. **See and control the screen**; type the password (the account name is pre-filled).
10. Live.

Per-phone **Shell** and **Screen** switches, *Stop*, *Revoke* and "May share access with other computers" (off) live in Settings ▸ Remote access ▸ *Phones with access*; the flyout shows one summary row that opens it.

### The phone, with a PC

- **Its page** shows only what a PC has: how it's reached, shells, the screen. Keep awake and VPN rows are absent, not disabled.
- **New shell** is a split control: tap opens the default (captioned "PowerShell"), the chevron opens the list that PC reports (PowerShell, Windows PowerShell, Command Prompt, each WSL distro, Git Bash), footed "Shells open as you, never as administrator." Session rows show the kind: "Ubuntu · running · 4m". The last choice is remembered per computer.
- **Screen, first time**: "Sign in to *Office-PC*". "Windows asks for your account's password, not your PIN. Passthrough passes it to Windows and keeps it on this iPhone behind Face ID." Field: "Password for *name@outlook.com*" (sent by the PC; "Use a different account" underneath). *Remember* on. After that it is one tap.
- **Before taking a PC someone is using** (the PC reports its console is active and was used in the last two minutes): "Someone is using *Office-PC* right now. Connecting locks its screen and they lose their place." **Connect anyway** · **Not now** (default).
- **While connecting**, each phase says what it is: "Reaching *Office-PC*…" → "Signing in to Windows…" → after 5 s "Windows is starting your session. After a restart this can take a minute." → after 20 s "Windows isn't answering at sign-in. This happens on some Windows 11 versions." **Try again**.
- **Shape**: the session takes the phone's shape and turns with it (debounced; never resized for the keyboard). The Display menu offers *Fit to this iPhone* or *Standard (16:10)* and text size, remembered per computer, because some Windows dialogs need the room. The same menu says "Through Windows Remote Desktop · direct"; the bar shows only "via relay" when that is so.
- **Keys**: the row is esc, tab, ctrl, alt, ⊞ (tap arms it for the next key, double-tap opens Start), arrows, copy, paste. A *Windows* menu replaces *Desktops*: Ctrl+Alt+Del, Start, Task View, Alt+Tab, Show desktop, Close window, Delete, F1–F12, Lock. No Sign out there (it would end the shells). Three-finger swipes: left/right between virtual desktops, up Task View, down Show desktop. Hardware keyboard: ⌘ acts as Ctrl by default, switchable to ⌘ = ⊞.
- **Copy and paste** keep today's rule (only on tap, text only, two minutes on the phone). *Copy from PC* sends **Ctrl+Insert**, not Ctrl+C, which would interrupt a console program with nothing selected; paste sends Shift+Insert.
- **Leaving and coming back**: returning from the background reconnects into the same Windows session by itself. If the view ended because someone signed in at the PC, it says so ("Someone signed in at *Office-PC*, so this view ended.") and offers **Try again** only: it never fights the person at the PC.
- While reconnecting the last picture stays, dimmed.

### State tables (every state has a sentence and, where there is one, a fix)

**The phone's page for a PC**

| State | Shown | Action |
|---|---|---|
| Connected | "Reachable · On this network / From anywhere, directly / through a relay" | shells, **New shell**, **See and control the screen** |
| Connecting / redialling | "Connecting to *Office-PC*…" / "Reconnecting…" | **Try again** after 30 s |
| Can't reach, cause unknown | "Can't reach *Office-PC*. It may be asleep, off, or offline. Last heard 14:02." | **Try again** |
| The PC said it was going to sleep | "*Office-PC* went to sleep at 14:02. It sleeps after 30 minutes; turn on Stay awake in Passthrough on the PC." | **Try again** |
| The PC said Remote access was turned off | "Remote access was turned off on *Office-PC* at 14:02. Turn it on there." | **Try again** |
| No relay, away | "Can't reach *Office-PC* from here. The relay isn't answering; it works on the PC's own network or Tailscale." | **Try again** |
| Access revoked | "*Office-PC* no longer lets this iPhone in. Plug it into the PC to get access again." | |
| Paired, no access yet | "Paired. Turn on Remote access on *Office-PC*, then plug this iPhone in once." | steps |
| Shell: nobody signed in | "Sign in to *Office-PC* to use its shell." | **Open the screen** where there is one |
| Shell: someone else signed in | "Someone else is signed in to *Office-PC*. Its shell starts when you sign in." | **Open the screen** |
| Shell: Passthrough closed there | "Passthrough isn't open on *Office-PC*. Open it there." | **Open the screen** |
| Shell switch off | "*Office-PC* doesn't let this iPhone open shells. Turn on Shell for it in Passthrough's settings on the PC." | |
| Screen switch off | "Screen is off for this iPhone. On *Office-PC*, open Passthrough's settings and turn on Screen for it." | |
| Remote Desktop off | "Remote Desktop is off on *Office-PC*. Turn it on in Passthrough's settings there." | |
| Windows Home | "*Office-PC* runs Windows Home, which has no Remote Desktop. The shell works." | row dimmed |
| Account has no password | "Your account on *Office-PC* has no password Remote Desktop can use. Add one on the PC." | |
| App too old | "Update Passthrough on this iPhone to see a PC's screen." (the PC sends this text to old apps) | |

**The screen view on a PC** (beyond the connecting phases above)

| State | Shown | Action |
|---|---|---|
| Live, first time | "*Office-PC*'s own screen is locked while you're here, and stays locked when you leave." | |
| Another account signed in | "Someone else is signed in to *Office-PC*. Windows is asking them to let you in." (exact behaviour confirmed by spike) | **Cancel** |
| Wrong password | sheet again: "Windows didn't accept that password. If you changed it, type the new one." Saved login forgotten. | retype |
| Too many tries from this phone | "Too many sign-ins from this iPhone. Try again in 10 minutes." | |
| Account locked by Windows | "Windows has locked this account after too many wrong passwords. Wait, or unlock it at the PC." | |
| Password expired | "Windows wants a new password for this account. Change it at the PC." | |
| Account may not sign in remotely | "This account isn't allowed to sign in through Remote Desktop. Allow it in Passthrough's settings on *Office-PC*." | |
| The PC isn't the one remembered | "This isn't the Remote Desktop *Office-PC* told us to expect, so nothing was sent." (hard stop, no continue) | **Done** |
| Taken over at the PC | "Someone signed in at *Office-PC*, so this view ended." | **Try again** |
| Screen turned off mid-view / stopped from the PC | "*Office-PC* turned Screen off for this iPhone." / "This view was stopped from *Office-PC*." | **Done** / **Try again** |
| Connection lost | last picture dimmed, "Reconnecting…", then "The connection to *Office-PC* was lost." | **Try again** |

**The PC's flyout and tray icon**

| State | Header (two lines) | Tray | Action |
|---|---|---|---|
| Off | "Remote access is off" / "Phones can't reach this PC" | plain | **Turn on…** |
| On, idle | "This PC is reachable" / "On this network and from anywhere" | tinted; "Passthrough · reachable" | |
| Something failing | "Remote access needs a look" / the first failing row | amber | **Fix** |
| A phone has shells | "*iPhone* has 2 shells open" | dot | **Stop** |
| A view just ended | notice that stays until seen at next unlock: "*iPhone* used this PC's screen, 14:02 to 14:20. Your windows may have moved." | amber dot | **OK** |
| Access first granted | "*iPhone* can now open shells on this PC." | amber dot | **Allow screen** · **Revoke** |
| A shell is asking | "*PowerShell* is asking" | amber dot | **Open here** (later) |
| Service stopped / older than the app | "Remote access isn't running" / "Finish the update" | amber | **Start it** / **Update** (one prompt) |
| Your computers | a row each: "MacBook · Connected · 1 shell open" | | **Screen**, **New shell ▾**, sessions with **Open** / **End** |

**Quit** with Remote access on asks: "Quit Passthrough? 2 shells end. This PC's screen stays reachable by your phones until you turn Remote access off." **Quit** · **Quit and turn off Remote access** · **Cancel**.

### Mac and PC together

**Add a computer** (same sheet on both; A is where you sit, B the other):
1. A: "Open Passthrough on the other computer and choose Add a computer there too. Both need to be on this network." After 10 s empty: "Nothing found yet. Check both are on the same Wi-Fi, not a guest network." Always: "Not on the same network? Use your phone: open one computer there and tap Share with another computer."
2. A lists B by name and kind. Pick it.
3. Each computer asks its own owner what it will allow, default off: "What may *MacBook* do on this PC? ☐ Open shells ☐ See the screen." Each side's choice is its own and can be changed later; neither can ask for more on the other's behalf.
4. **Each computer shows six digits and a field for the other's.** Type A's on B and B's on A. Both must be right; a wrong one ends it on both ("Those digits don't match. Nothing was shared.") and three failures close the sheet. No yes/no question anywhere, so there is nothing to click blind.
5. Both: "Done. *Office-PC* is under Your computers." A notice stays on each: "*MacBook* can now open shells on this PC and see its screen." **Revoke**.

**Or from the phone**, away from one of them: *Share with another computer* (today's *Share screen with a Mac*), choice *Screen only* / *Shell and screen* ("It can run commands as you on *X*."). Offered only for a phone the host's owner has allowed to share (a switch on the host, off by default).

**Using it**: the other computer sits under *Your computers* in the Mac's menu panel and the PC's flyout with **Screen**, **New shell ▾** and its running sessions (**Open** / **End**, since closing a terminal window leaves the session running).
- *Shell* opens in your default terminal (the Mac opens whatever handles `.command`; the PC a new Windows Terminal tab, or the console host without it), titled "*MacBook* · zsh".
- *Screen* asks Touch ID or Windows Hello, then opens a window whose subtitle says "Keys go to *Office-PC*".
- Keys, Mac viewing a PC: ⌘ → Ctrl, ⌥ → Alt, ⌃ → Ctrl; ⌘Tab, ⌘\` and ⌃⌘F stay local; a *Windows* menu in the menu bar has Send Ctrl+Alt+Del and the rest.
- Keys, PC viewing a Mac: Alt → ⌘, Win → ⌥, Ctrl → ⌃ (Win can't be ⌘: Windows keeps Win+L; Ctrl can't be ⌘: Ctrl+C must still interrupt in the Mac's terminals), with a setting "Ctrl acts as ⌘".
- Settings ▸ Remote access ▸ *Computers with access* (per-computer **Shell**, **Screen**, **Revoke…**: "Its shells and any view of the screen close.") and *Other computers* (what this one can reach, **Remove**).

### Accessibility (must-haves)

iOS: the chooser is an accessibility action on New shell; connection phases are announced; the takeover prompt's default is the safe choice. Windows: every switch has an automation name; setup rows are a live region; state is never colour alone; high-contrast brushes; the flyout opens with Enter and closes with Esc; code tiles read as digits. macOS: every toolbar action is also in the menu bar. Keys are named in words for VoiceOver and Narrator ("Windows key").

### After the must-haves (ranked, each its own small PR)

Remember per computer (shape, text size, touch mode, shell) · last picture dimmed while reconnecting · the other computer as a Windows Terminal profile · widget and switcher state for PCs · "PC needs you" when a UAC prompt is waiting · Restart from the Windows menu with its warning · a display name for the PC in place of `DESKTOP-7K2L9QF`.

## 2. Architecture

### On the PC

```
 phone / Mac ──TLS 1.3 :7893 (LAN, Tailscale)──┐
             ──iroh (from anywhere)────────────┤
                                               ▼
        PassthroughService   (starts at boot; its own service account, privileges stripped)
        handshake limits · key proof · access store · screen relay ──▶ 127.0.0.1 (Remote Desktop)
                                               │ named pipe
                                               ▼
        Passthrough.exe      (tray app, one per signed-in account)
        ConPTY sessions · recording · cable pairing and grants · UI · viewer windows
```

- **Why a service**: only something running before sign-in can answer a signed-out PC. It never runs a shell.
- **Why shells stay in the tray app**: they must run as you, in your session. With the owning account not signed in, the service answers `open` with `signed_out`; the screen still works, and signing in through it starts the tray app (Remote access turns Start at login on), which connects and brings the shells up.
- **Projects** (`windows/`): `Passthrough.Core` (portable logic, no Windows APIs; gains `Shell/`, `Client/`, `Trust/`), `Passthrough.Windows` (new: ConPTY, `SslStream`, DNS-SD, pipes, iroh P/Invoke, power, Remote Desktop checks), `Passthrough.Service` (new: worker service, and the only elevated code: `--install`, `--remove`, `--update`), `Passthrough.App` (tray), `Passthrough.Term` (new: `passthrough-term.exe`), `native/iroh-bridge` (new, Rust).

### The contract between service and tray app (defined in the first shell PR, asynchronous from day one, in-process until the service exists)

`ISessionHost`, per Windows account, what a connection needs: a cached `Sessions` snapshot with a change event; `OpenAsync(connId, phoneId, label, shellId?, cols, rows)`; `AttachAsync` returning a generation; `Detach`, `Input`, `Resize`, `Close`, `SetViewing`; events `Output`, `Replayed`, `Ended`, `Detached(generation)`; `HistoryAsync`, `TranscriptAsync` (chunked; transcripts stay in the user's profile, which the service can't read); `HostState` (signed in, shells, locked, console in use, battery) with a change event; `Lock()`; `SavePassAsync`. Availability: when the pipe drops, the service sends `detached` for every attached session, pushes `host` with `signedIn:false`, and answers `open` with `signed_out`.

`IAccessAdmin`, the tray UI's view of the service: list phones and computers with who is connected and viewing; add a key from a cable grant; set Shell / Screen / may-share; revoke; disconnect; the grant's contents (certificate hash, port, addresses, iroh id, relay); setup-row status. Machine-wide settings (on/off, relay and token, identity reset, who may use the service) change only through the elevated step.

Pipe rules: a version handshake on connect (the app and service update separately; a mismatch drives the "Finish the update" row); `connId` replaces object identity; a bounded send queue per connection (a slow phone is dropped at 8 MB as today; a full pipe drops that phone, never stalls a shell); replies stay in request order; the old key keeps working until the phone proves the new one (`previousKey`), across the hand-off.

### Core: ports of what the Mac has (pure logic, tested with fakes on any OS)

Port, don't redesign; each maps to a Swift type in `Packages/PassthroughCore/Sources`:

- `PassthroughCore/ShellProtocol.swift` → `Shell/ShellEnvelope` (C# has none today), constants, `ShellAddressPolicy`
- `ShellHost/ShellListener.swift` (`ShellGate`, `ShellConnection`, `ScreenViewLimit`) → same names over a `Stream`, same ordering rules (`busy` requests; after `ready`: `macInfo`, `host`, `macState`, `sessions`; the 1 s `macState` reply; screen-only checked before everything)
- `ShellHost/IrohShellListener.swift`, `LocalAddresses.swift`, `PhoneTransport/HandshakeLimiter.swift` (+ `FileProvenAddressStore`) → same
- `ShellHost/ShellSessionManager.swift`, `ScrollbackBuffer`, `TerminalModes`, `TerminalReports`, `ProgramStatus`, `ShellQuestion` → `Shell/Sessions/*` over `IPty`
- `ShellHost/TranscriptStore.swift`, `ShellReplay` → `Shell/TranscriptStore` (asciicast v2, same caps, retention and pruning)
- `ShellHost/ShellAccessStore.swift`, `ScreenPassStore.swift` → `Shell/AccessStore` (records as one JSON blob per secret slot, as the Mac; keyed by Windows account and phone id)
- `PassthroughCore/MacSessionPolicy.swift` (`ShellGrantLedger`) + the grant in `SessionCoordinator.swift:545-573` → `Session/ShellGrantLedger`; `ControlClient` gains send and `shellGranted` handling (the fields are already in `ControlEnvelope.cs`)
- `ShellHost/ShellReach.swift`, `PassthroughCore/Splice.swift`, the `screen` hand-off (`ShellListener.swift:1134-1209`) → `Shell/ShellReach`, `Shell/Splice`, `Shell/ScreenRelay`
- Viewer role: `PassthroughCore/ShellClient.swift`, `ShellCredentials.swift`, `ScreenVideoWire.swift`, `ScreenClient/ScreenVideoClient.swift`, and the client helpers (`ShellEndedSessions`, `UTF8Repair`, `TerminalPaste`) → `Client/*`

Changes to existing Windows code: `HostSession` opens grant channels to every paired device, iPads included (today only the active phone, and an iPad is "Pairs once Remote shell is available"); `ForgetAsyncCore` and `PairedPhone.List` cover shell access; `LogText.Redact` learns 44-character keys and relay tokens **before** anything new logs; the single-instance mutex stays per session.

**What a PC does with the Mac's other features** (each stated, none silently missing):

| Mac feature | On a PC in this plan |
|---|---|
| `macState` | sent with `battery`, `charging`, `locked`, `control:false` |
| Keep awake, VPN from the phone | not offered (`setAwake`/`setVPN` → `not_allowed`); *Stay awake* is a PC setting |
| Lock from the phone | supported (the tray app locks the session) |
| Activity timeline | later; `events` answers an empty list so the tab isn't an error |
| "Needs you" notifications (APNs) | later; `pushState on:false`. The in-app "needs you" card still works. Said in the guide. |
| Program status (Claude Code) | in, if the ConPTY spike shows OSC 7501 survives; otherwise the question heuristic only |
| Terminals on this computer, `origin` | later (roadmap stage 7) |
| Curtain, Use Here | not applicable: Remote Desktop locks the console itself |
| Relay URL and token, reset identity, history window and retention | in |
| Wireless-link identity | later; it will reuse the service's identity |

### Windows-specific pieces

- **ConPTY**: bundle `Microsoft.Windows.Console.ConPTY` (MIT), checked at build to carry Microsoft's signature, so OSC 52/7501 behave the same on every Windows build. Each session in a kill-on-close job object. Environment from `CreateEnvironmentBlock`, never inherited, plus `TERM_PROGRAM=Passthrough`. "The program left" by polling the job's process list; WSL processes are outside it, so WSL falls back to "the prompt came back", and revoking can't promise to end what runs inside WSL (said in the docs). The app **refuses to host shells when it is itself elevated** (UAC off, started as administrator) and says why.
- **Shell chooser**: ids from the network are looked up in a catalog built on the PC, each a fixed absolute path and fixed arguments found under Program Files, System32 and the registry (never `PATH`); WSL distros from the registry's list, names validated. Nothing from the wire reaches a command line.
- **TLS listener** (stage 4): `SslStream`, TLS 1.3 only, no renegotiation; a named, non-exportable, persisted P-256 key in the service account's store (Windows' TLS runs outside the process; an in-memory key can't serve). Address policy and a limiter slot are taken before any TLS object exists. Windows 11 / Server 2022 only; on Windows 10 the built-in path still works.
- **Address policy on Windows**: a "tunnel interface" (for the Tailscale ranges) is a non-hardware adapter of virtual or tunnel type; never WWAN, Ethernet, Wi-Fi or a Hyper-V/WSL switch. With fixtures.
- **Discovery**: `_passthrough-sh._tcp` through Windows' DNS-SD API; the instance name must equal the granted host name (phones match on it), and the grant uses one source for that name or every phone is re-keyed.
- **iroh**: `native/iroh-bridge`, our own Rust library over the `iroh` crate pinned to the phones' version, C ABI covering exactly what `IrohTransport/*.swift` uses. Every export catches panics and returns a code; handles are generation-checked table ids, not pointers; buffers are caller-owned; a numeric close code replaces the string matching in `IrohByteStream.isCleanClose`. Loaded by full path. Fuzzed. `rust-toolchain.toml` and `Cargo.lock` committed, `cargo build --locked`, `cargo deny`/`audit` in CI; built in CI and by a script, not committed (it is first-party source). x64 now; Snapdragon PCs run the app emulated.
- **Install** (`Passthrough.Service.exe --install`, launched elevated once; WinUI never runs elevated): takes no path arguments; copies the app, service and native files to a fresh administrator-only folder under Program Files, verifies the copies (their signature when the build is signed), re-points Start at login; registers the service under its own account with **only the change-notify privilege** and a restricted service SID (so a compromise can't take the usual impersonation route to SYSTEM), quoted path, recovery limited to two restarts then stop with a notice; creates `%ProgramData%\Passthrough` with its ACL at creation and refuses a pre-existing folder owned by anyone else; adds the firewall rules; records which accounts may use the service; and, with consent, sets up Remote Desktop (below). `--remove` undoes all of it; `--update` is stop, replace, start behind one prompt.
- **Firewall**: inbound TCP 7893 bound to the service, every profile (home Wi-Fi is often Public), remote addresses limited to the local subnet and the address policy's ranges; iroh's UDP bound to the service, open.
- **Pipe security**: the service creates it first-instance-only with an explicit ACL, refusing remote clients; the tray app connects at identification level and checks the pipe's owner is the service's SID before sending anything (so a squatter gets nothing while the service is down). The service knows a client only by its token's account and session; it refuses session 0 and elevated clients. Stated honestly: any program running as the same Windows account could be the session host; that is code running as you, outside the threat model as on the Mac.
- **Shared PCs**: every record is keyed by (account from the pipe token, phone id), never by a field in a message; an id another account owns is refused; every answer is filtered by the caller's account. A phone reaches only the tray app of the account that granted it.
- **Cable grants need a real peer**: before proving anything on the control channel, the app checks who owns the far end of its connection: for iPhones the process must be Apple Mobile Device Service (asked of the Service Control Manager), for adb the owner must be the current user. Otherwise it pairs but refuses to grant shell access. (Today's documented exposure, a local program standing in on port 27015, would otherwise become a shell as another account.)
- **Secrets**: phones' and computers' keys, the TLS key and the iroh key live with the service (DPAPI under the service account plus the folder ACL; machine-scope DPAPI would let any local program decrypt). Cable pairing tokens and transcripts stay with the user. Credentials **to** other computers are wrapped with a Windows Hello-bound key; a PC without Hello (a PIN is enough) can't hold them, as an Android phone without a screen lock can't.

### The Remote Desktop relay

- **Closed to the network, and checked, not assumed**: the install turns Remote Desktop on through the API that leaves Windows' firewall exception alone, requires Network Level Authentication on the host, adds only the consenting account to Remote Desktop Users, and adds Passthrough's own **block** rules for the Remote Desktop port (TCP and UDP, every profile). Before every relay and on a timer the service re-checks: Windows Firewall on for every profile, the block rules present, NLA required. Anything else (firewall off, a third-party firewall, policy re-opening it) and it refuses with `rdp_unavailable` `exposed`, and the PC shows a notice that stays. Passthrough records that it turned Remote Desktop on, and removing Passthrough puts it back; turning Remote access off says plainly that Remote Desktop stays on, blocked, until removal.
- **The right far end**: dial `127.0.0.1` only, port read from Windows' setting each time; then find *this connection* in the TCP table and require its owner to be the Remote Desktop service's process (asked of the Service Control Manager, no process opening); fail closed on any error.
- **The right certificate, with no prompt**: with `rdpReady` the service sends the SHA-256 of the certificate Remote Desktop is configured to present. The viewer accepts only that one. So there is no trust-on-first-use, no "certificate changed" dialog to click through when Windows re-makes it, and a stand-in gets nothing: a mismatch is a hard stop before any credential leaves.
- **Guessing**: the relay can't see a sign-in fail (it carries encrypted bytes), so it limits what it can see: `rdp` opens per grant are capped below Windows' own lockout (4 in 10 minutes; one that lasted over 30 seconds doesn't count), with a global cap. Windows' lockout policy is the backstop. Every relay is logged with the phone and time, since Windows' own log shows only 127.0.0.1.
- **Who may use it**: phones with the Screen switch, and computers whose screen scope was set at this PC. A screen-only pass (`viewer.` id) is refused, as the Mac refuses a pass its Screen Sharing login.
- **Stated honestly**: Screen plus the Windows password is *more* than shell access (UAC prompts, the lock screen, any account that may sign in remotely, administrators always); the password does reach Windows on the PC; a compromised service could act as a shell for every signed-in account that uses it.

### Protocol changes (fixtures first; three suites: Swift, Kotlin, C#)

No version bump; everything is an optional field or a message old peers ignore or answer `bad_request`.

- **`host`**: a new message right after `ready` (never before: an unknown type there ends the handshake on deployed clients), on every connection, sent again when it changes: `kind` (`mac`, `windows`), `os`, `user` (the granting account's sign-in name), `signedIn`, `console` (`active`, `locked`, `signedOut`, `otherUser`) with `idleSeconds`, `shells` (`id`, `name`, `default`), `screens` (`video`, `rfb`, `rdp`), `rdp` (`ready`, or `off`, `edition`, `account`, `service`, `exposed`), `sleepAfter`. Not carried on `macInfo`, which is sometimes not sent at all and is sent once. `shellGrant` and stored credentials gain optional `hostKind`, so a new PC is never shown as a Mac before its first connection.
- **Going away**: the host says why on live connections (`sleeping`, `turned_off`, `shutting_down`), so the phone can say "went to sleep" only when it knows.
- **Shell**: `open` gains `shell`; new error `signed_out`.
- **Relay**: `rdp` → `rdpReady` (`certSHA256`), then raw bytes as `screen`; errors `screen_not_allowed`, `too_many_screens`, `rdp_unavailable` (+ `detail`), `try_later`.
- **What a PC answers to Mac-only requests** (in fixtures, one test each): `setAwake`/`setVPN` → `not_allowed`; `events` → empty `eventList`; `push` → `pushState on:false`; `screenVideo` → `screen_not_allowed` or `screen_video_unavailable`; `screen` → `screen_unavailable` with the message "Update Passthrough on this phone to see this PC's screen."; `screenGrant` → `bad_request`; `lock`, `viewing` supported. Known and documented: an iPhone app from before the phone work will ask for "your Mac's" login when Screen is tapped on a PC, then fail; the phone work ends it.
- **Computers**: `viewer.` ids stay screen-only for good. A computer's access is a new id prefix `computer.`, minted only by the host, via `computerGrant`/`computerPass` with `scopes` (`shell`, `screen`). The credential is bound to the computer's own identity key (its proof adds a signature over the nonce), so a copied credential isn't enough. It carries who granted it: removing that phone removes it and drops its connections; a cap per phone; no onward grants. A computer gets no `setAwake`/`setVPN`. A received credential may replace one for the same host only when certificate and iroh id match.
- **Direct pairing** (section "Computers", specified in its own stage): `_passthrough-pair._tcp` only while the sheet is open, same subnet or link-local only, behind the handshake limiter; TLS; commit-then-reveal P-256 exchange; two six-digit codes derived from the whole transcript, which includes the certificate each side actually saw on this connection; each code typed on the other computer; single-shot, three failures close the sheet; fixed test vectors with their expected digits in `fixtures.json`. Scopes are each owner's local choice, not part of the exchange.
- Fix the README where it disagrees with the code on pacing (window "2 to 16" vs 24). `SECURITY.md`'s rule "a shell only to a device paired over the cable" is rewritten to cover computers.

### Viewers

- **A backend seam, in its own PR before any RDP**: `ScreenModel.swift` (iOS) holds two concrete clients and its public surface, the canvas callbacks and the key row use `RFBClient` types. Move those to neutral types and extract `ScreenBackend`: events (image frame, sample buffer, **shared pixel surface with dirty rectangles**, pointer shape, clipboard, needs sign-in, ended), input (pointer, scroll, key as keysym + modifiers, text, clipboard, copy, resize), capability flags that decide which menus show. Behaviour unchanged. The Mac's `RemoteScreenWindow` has only the stream today and no image path; it gets the same seam and a surface path.
- **Remote Desktop engine** (one Swift package target shared by iOS and macOS): FreeRDP 3.33.x + OpenSSL 3 LTS (both Apache-2.0), vendored as an xcframework with device, simulator and Mac slices (`scripts/build-freerdp.sh`, pinned by commit and archive hash, committed to `Vendor/` per convention, a stated rebuild deadline after any upstream advisory, size recorded in CONTRIBUTING), linked into the two apps only.
  - Runs over our authenticated connection through FreeRDP's transport-layer hook, via a blocking bridge (a ring buffer and an event FreeRDP waits on, cancellable, with a backlog limit) since FreeRDP's loop is synchronous and our streams are not. No loopback socket.
  - Frames land on a shared BGRA surface presented on the display link; pointer shapes converted; resize through display control.
  - Hardened: NLA only, no fallback to weaker security; static channels only, no add-in loading; no drive, printer, smartcard, serial, USB, RemoteApp or clipboard files; clipboard is Unicode text, size-capped, only on tap; RemoteFX, NSCodec and the legacy caches off. FreeRDP had many client-side memory bugs a server can trigger, and this runs in the app that holds the keys to every Mac: on the Mac it runs in a sandboxed helper process; on iOS the build stays minimal and current.
  - Shortcuts as scancodes (keysym → scancode inside the backend), text as Unicode.
  - Sign-in and licence errors mapped to the sentences in the state table.
- **Windows login store**: generalise `ScreenLoginStore.swift` (user-presence, this-device-only Keychain item) to be keyed by host and account; forgotten on a refused sign-in.
- **Host-aware UI**: profiles store the host kind; wording, rows and the tab title follow it. About 350 strings across iOS, the widgets and Live Activity, macOS and Android (which keeps strings in code) name the Mac; each platform is its own PR. Android decodes `host` and shows the PC with its shells; no screen.
- **Mac → another computer's shell**: `passthrough-term remote <computer>`, a new mode bridged by the app's `ShellClient`, with raw mode, resize and reattach.
- **Windows viewer**: `Client/ShellClient` + `passthrough-term.exe` (raw VT input, UTF-8, Ctrl+C/Ctrl+Break passed through, resizes from console window events, modes restored on exit and crash, a current-user-only pipe with a one-time token); a screen window decoding the Mac's stream with Media Foundation (H.264 by default, HEVC only when a decoder is present, frame sizes checked first), acking each frame when presented, drawing the pointer from the cursor messages, keys mapped to keysyms, IME text, per-monitor DPI, a low-latency swap chain; then sound and microphone.

## 3. Order of work

Every PR goes against `dev`, leaves it working, and carries its docs and changelog ("Works now / Not yet").

**0. Spikes** (`Spikes/<name>/` with a README holding the answer; thrown away). First: run stage 1's ten-item real-PC checklist and fix `windows/README.md`.
- *What this PC can do*: edition, Remote Desktop licence value, account kind, Hello-only setting, on every PC to hand.
- *Relay*: a 30-line TCP relay to loopback with Remote Desktop's rules off **and our block rules on**, driven by stock FreeRDP from another machine: same account signed in (do the tray app and its shells survive the session moving and coming back?), another account signed in (what exactly is asked, and what silence means), locked, after reboot, UAC, Microsoft account, display off. **Pass**: reachable through the relay in every state, closed from the LAN.
- *Service account with privileges stripped*: persisted P-256 key, TLS 1.3 to the iPhone's pinned client, survives reboot, DPAPI, DNS-SD, power request, the connection-owner check, reading the Remote Desktop certificate's hash, pipe peer checks. **Pass**: all of it without impersonation rights.
- *iroh bridge*: PC and Mac dial each other, direct and through a relay.
- *FreeRDP on an iPhone*: static build, OpenSSL only, through an in-process transport layer. **Pass/fail lines**: NLA completes over the hook; the hardware H.264 decoder is used with a default Windows 11 host; binary size; feel and data use on cellular. Fallback written before stage 6: accept software decode, or pull the PC's own stream forward.
- *ConPTY*, inbox against bundled: OSC 52, OSC 7501, a DCS, their order against surrounding text; Claude Code, vim, resize, WSL.

**1. Protocol groundwork.** (a) Windows CI job (`windows-latest`: tests, app, service and bridge builds; `dotnet test` also on the macOS job for cross-implementation loopback tests). NuGet lock files and source mapping. (b) `host`, `shell`, `signed_out`, `rdp`, going-away reasons and the PC's answer table, in fixtures, README and all three envelopes (both existing suites fail on an unmodelled field, so this is real work). (c) `computer.` ids, `computerGrant`/`computerPass`. *Done when*: three suites pass on the same fixtures, and today's phone builds still work against today's Mac.

**2. Phones know a PC** (needs only stage 1; must land before stage 3 is usable). iOS, Android, then widgets: host kind in profiles, wording, the PC page and its states, the split New shell, the PC setup steps. *Done when*: a Mac and a PC sit side by side in the switcher with the right words, and an older phone build still works against both.

**3. The PC's shell, from anywhere** (in the tray app; no listener on the network yet, because that needs the elevated install: iroh only). PRs: grant plumbing in `ControlClient` + redaction → `HostSession` grant channels, iPad pairing, forget revokes → Core ports with fakes → ConPTY, jobs, catalog → iroh bridge and its listener → wire-up (switch, cable grants with the peer check, per-phone Shell switch, Stop) → recording and history → relay settings, reset identity. *Done when*: shell from iPhone and Android, direct and via relay; a session survives a dropped connection and a relaunch; revoke and forget end live connections; an iPad pairs; Claude Code status works; the log holds no key.

**4. The service.** PRs: skeleton, install/remove/update, pipe with version handshake → access store and iroh move behind `ISessionHost`/`IAccessAdmin` (the access store and iroh key are handed over on first connect and the user's copies deleted; the service makes its own TLS key, so the grant's contents change and phones are re-granted on their next cable connection while the built-in path keeps working meanwhile) → TLS listener, DNS-SD, firewall: same network and Tailscale → power requests, Stay awake, going-away reasons. *Done when*: everything from stage 3 still works, plus the local path; `signed_out` after a reboot; another account's pipe client is refused.

**5. The Remote Desktop relay on the PC.** Probe and setup rows → the relay with its checks and caps → the "open to the network" detection and notice → flyout states, quit dialog, after-view notice. *Done when*: stock FreeRDP reaches the PC only through the relay in every state from the spike, and the port is closed from the LAN.

**6. The PC's screen on iPhone and iPad.** Seam → vendored engine and build → backend behind a debug flag → sign-in sheet and store → keys, Windows menu, gestures, copy/paste → shape and text size → every refusal's wording, takeover prompt → flag off. *Done when*: the screen-state list below passes on cellular, 30 minutes of use shows no memory growth, and measured frame rate and data use are in the PR. This is the main use case.

**7. Mac ↔ PC**, four tracks that ship separately: (a) computer access and the phone hand-over; (b) direct pairing, with its protocol section and vectors; (c) the Mac's screen window on a PC (seam, surface path, sandboxed engine, key mapping, menu); (d) `passthrough-term remote` and *Your computers* in the menu panel.

**8. The PC as viewer.** (a) `ShellClient`, iroh dialing, `passthrough-term.exe`, Hello-wrapped credentials, *Your computers* in the flyout; (b) the Mac screen window: video, input, clipboard; (c) sound and microphone.

**9. Later, outlined only.** The PC's own stream (Desktop Duplication + hardware encoder; the only screen for Windows Home and password-less accounts; seeing the lock screen and UAC that way needs a SYSTEM helper, its own design). It moves up if the first spike shows many PCs Remote Desktop can't serve. Also: Wake-on-LAN, Android screen viewer, timeline and notifications from a PC, terminals on the PC shown on phones, Authenticode-signed releases, a stricter split where the tray app verifies each phone itself.

Relative size: stages 3, 4, 6 and 8b are the big ones. The three places most likely to run long: the service/tray split (4), embedding FreeRDP (6), and the Windows screen viewer (8b).

## 4. Known limits, said plainly in the docs

- The PC's screen needs Windows Pro or better and an account with a password; work (Entra-only) accounts aren't supported yet. The shell has neither limit.
- It depends on Windows Firewall being in charge; with another firewall managing the PC, Passthrough refuses to relay rather than guess.
- A PC with a BitLocker PIN at start-up can't be reached after a reboot until someone types it.
- One person at a time: connecting to the screen locks it for whoever is there, and it stays locked.
- The local path needs Windows 11; Windows 10 is reached through the built-in connection only.
- Shells need the owning account signed in (locked is fine); after a reboot, sign in through the screen first.
- A PC sends no notifications and has no timeline yet.
- You build it yourself and builds aren't signed: a program already running as you could alter the files before you approve the administrator prompt.

## 5. Docs per stage

Every stage: `CHANGELOG.md`, `docs/GUIDE.md` §Windows. Stage 1: `protocol/README.md`, `CONTRIBUTING.md` (three suites, a Windows line in the checklist). Stage 2: `README.md` and guide wording. Stage 3: `windows/README.md` roadmap, build steps (Rust) and real-PC checklist; `SECURITY.md`; `THIRD_PARTY_NOTICES.md` (ConPTY, iroh crates). Stages 4–5: `SECURITY.md` threat model (the service and what a compromise of it means, the pipe, the install step, machine-wide Remote Desktop state, shared-PC cases, the 27015 note restated), guide known limits. Stage 6: notices for FreeRDP and OpenSSL, CONTRIBUTING's vendored list and size note. Stage 7: protocol *Computers*, `SECURITY.md` (hand-over rule, direct pairing).

## 6. Verification

- **Automated**: `dotnet test windows/tests/Passthrough.Core.Tests` (suites mirroring `ShellHostTests`: gate, connection ordering, limiter, address policy incl. Windows tunnel fixtures, access store incl. cross-account refusal, grant ledger, transcripts, relay hand-off incl. bytes before `rdpReady` closing the connection, the PC's answer table, pairing vectors, hand-over of keys to the service); pipe tests (version mismatch, tray crash mid-attach, back-pressure, wrong account); the C# host against the Swift `ShellClient` and the reverse on the macOS CI job; `swift test`; `./gradlew testDebugUnitTest lintDebug`; fuzzing of the bridge.
- **Real-PC checklist in `windows/README.md`**: clean install to a live screen in the ten moments above; each setup row's failure shows its fix; shell on Wi-Fi, Tailscale, cellular direct and relay; chooser lists what is installed; quit dialog; update with a version mismatch.
- **Screen states, each from the phone on cellular**: in use at the PC (the prompt), signed in and idle, locked, signed out after `shutdown /r`, monitor off, lid closed on mains, a UAC prompt, another account signed in, wrong password, password changed, too many tries, Screen switch off mid-view, Remote Desktop turned off in Settings, Windows Home, a sleeping PC, taken back at the PC, return from background.
- **Security checks**: the Remote Desktop port unreachable from another machine (IPv4, IPv6, UDP) while reachable through the phone; with Windows Firewall turned off the relay refuses and the notice appears; a second Windows account can't read the pipe, squat it, or register another account's phone; a program on port 27015 gets no shell grant; the service account can't read the user's profile and holds no impersonation right; a chooser id from the wire can't reach a command line; mismatched pairing digits share nothing; logs hold no key, token or password.
- **Hardware-only, as written checklists**: Modern Standby and sleep, a Public-profile network, a shared PC with two accounts, BitLocker PIN, Windows 10.
