# Stage 0: Spikes

## Goal and done-when

Answer, with throwaway programs on real hardware, every question the master plan marks unproven, before any stage builds on a guess. Each spike lives in `Spikes/<Name>/` with a `README.md` that states the question, how to run it, and the answer (the house style of `Spikes/LinkProbe/README.md` and `Spikes/PcProbe/README.md`). Nothing in `windows/`, `Packages/`, `iOS/`, `macOS/` or `android/` changes, except spike 0.1, whose output is fixes to the stage-1 Windows app and to `windows/README.md`.

Done when:

1. Every subsection below has its **Answer** written into its spike's README, with the pass/fail line stated as passed or failed, and the consequence for later stages copied into that stage's plan file (the stage files under `docs/plans/windows-remote/`).
2. The owner's PC is back in the state it was in before: Remote Desktop on and open as the owner had it, no spike service, account, firewall rule, key or scheduled task left (each spike's *Undo* list has been run and checked).
3. `windows/README.md`'s "First things to try on a real PC" no longer says "The app has not been built or run yet".

## What exists today (verified, with path:line)

- **House style of a spike.** `Spikes/LinkProbe/README.md:1-7` opens with "(throwaway spike)" and one **Question** paragraph that says what design depends on the answer; then what the program does (`:9-21`), *Build and install* (`:23-35`), *Run* with numbered steps and a "Before you start" warning about what it disturbs and how to put it back (`:37-55`), *Reading it* as a table of observation → meaning (`:57-66`), and how to get logs out (`:68-78`). `Spikes/PcProbe/README.md:1-58` is the Windows variant: question, "It reads only and changes nothing" (`:8`), one run command (`:10-12`), *What it reads*, *Answers* as bold one-line findings each followed by its consequence, and "Still to read on other PCs" (`:57-58`).
- **Spikes are tracked in git** (`git ls-files Spikes` lists `Spikes/LinkProbe/*`); generated Xcode projects are ignored (`.gitignore`, last line `Spikes/*/*.xcodeproj/`). `Spikes/PcProbe/` is untracked on `windows-remote-spikes` and carries its own `.gitignore` (`bin/`, `obj/`).
- **PcProbe** is one file, `Spikes/PcProbe/Program.cs` (418 lines), `net10.0-windows`, no packages (`Spikes/PcProbe/PcProbe.csproj`). It already contains the pieces later spikes reuse: the X.224 request and the far-end owner lookup (`Program.cs:145-198`), the firewall rule listing through `HNetCfg.FwPolicy2` (`:202-223`), `QueryServiceStatusEx` (`:330-348`), reading the Remote Desktop certificate store (`:72-83`).
- **The stage-1 checklist** is `windows/README.md:62-120`, ten items, headed by "The app has not been built or run yet; the Core tests are all that have run" (`:64`). Item 1 warns the XAML was never compiled (`:67-70`).
- **The Windows app today**: `windows/src/Passthrough.App` (WinUI 3, unpackaged, x64, `Passthrough.App.csproj`), `windows/src/Passthrough.Core` (`net10.0`), tests in `windows/tests/Passthrough.Core.Tests`. No service, no ConPTY, no iroh, no TLS.
- **What the phones' iroh is**: iroh-ffi `1.1.0` on Apple (`Packages/PassthroughCore/Package.swift:25`, pinned in `Package.resolved`), `computer.iroh:iroh-android:1.1.0` on Android (`android/app/build.gradle.kts:69`). The Swift surface the bridge must cover is `Packages/PassthroughCore/Sources/IrohTransport/{IrohByteStream,IrohEndpoints,IrohShellDialer}.swift`. The shell's ALPN is `passthrough/shell/1` and the dialler writes `{"t":"hello"}` first (`protocol/README.md:346-365`).
- **A phone drops a grant without a 64-hex certificate hash** (`Packages/PassthroughCore/Sources/PassthroughCore/ControlServer.swift:234-237`, `android/.../core/ControlServer.kt:196`). So the PC needs a certificate from the first grant it sends (stage 3), before it has a TLS listener (stage 4). This is why spike 0.8 exists.
- **Measured on the owner's PC** (the brief, and `Spikes/PcProbe/README.md:24-55`): Windows 11 Pro build 26300, local administrator account, desktop, .NET 10 SDK in the user profile (`%LOCALAPPDATA%\Microsoft\dotnet`, 10.0.404), no Rust toolchain; Remote Desktop already on and open on every profile with a Terminal Services policy key present.

## Design

Common rules for every spike:

- **Folder**: `Spikes/<Name>/` with `README.md`, the program, and a `.gitignore` for build output. No shared code between spikes; copy what is needed from PcProbe.
- **README shape**: `# <Name> (throwaway spike)`; **Question** (one paragraph, ending with what it decides); *Build*; *Run* (numbered, with **Before you start** naming every system change and **Undo** naming how each is reversed); *Reading it* (observation → meaning); **Answers** (filled in after the run, each a bold finding plus its consequence); *Still to learn*.
- **System changes are scripted, named and reversible.** Every spike that changes the PC has `setup` and `undo` verbs (or `setup.ps1` / `undo.ps1`) and writes what it changed to `%ProgramData%\PassthroughSpike\<name>-state.json` before changing it. Everything a spike creates is named `PassthroughSpike…` (service, firewall rules, local account, key container, scheduled task) so `undo` can find it and a leftover is obvious. `undo` is idempotent and ends by printing what it verified.
- **Elevation**: only `setup`/`undo` run elevated (from an elevated PowerShell 7 window); the probe itself runs as the identity being tested.
- **Ports**: spikes never use 7893 or 3389 themselves. Relay: TCP 47389. Service TLS: TCP 47893. iroh: whatever UDP port iroh binds.
- **Which machine**: summarised in the table at the end of this section.

### 0.1 The stage-1 real-PC checklist

- **Question**: does the stage-1 app build and behave as `windows/README.md:62-120` says, on a real PC? Everything after this assumes it does.
- **Program**: none new. The app as it is.
- **Steps**: from a normal (not elevated) terminal at the repo root, `dotnet build windows/src/Passthrough.App -c Release`, then run the ten items in order. Fix what fails in `windows/` as found (XAML compiler errors first, per item 1), one commit per fix. Items 3 and 4 install software: Apple Devices (Microsoft Store) and platform-tools (unzip anywhere). Item 8 writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Passthrough`.
- **Undo**: turn *Start at login* off in Settings (removes the Run value); delete `%LOCALAPPDATA%\Passthrough` if the pairing made here should not persist; Apple Devices and platform-tools may stay (stage 3 needs them).
- **Pass**: all ten items behave as written, or the README is corrected to what is true and the gap is listed under a new "Known gaps" heading there.
- **What each outcome changes**: a failing item is a bug fixed now, not carried. The known gap in item 6 (flyout on the wrong monitor from the keyboard, `windows/README.md:99-103`) is fixed here if seen, since stage 5's flyout states build on it. If WinUI 3 unpackaged cannot do something the checklist assumes (tray, flyout placement), stage 3's UI PRs are re-planned before they start.
- **Needs**: the owner's PC, an iPhone and an Android phone with the current phone apps, a USB cable each, a second monitor for item 6 if one is to hand. One person.
- **Time**: half a day if it builds on the first few tries; one day otherwise.
- **Output**: a PR against `dev` (see *Pull requests*), not a `Spikes/` folder.

### 0.2 What this PC can do (PcProbe, done)

- **Question**: `Spikes/PcProbe/README.md:3-6`.
- **Answers recorded** (first PC; `Spikes/PcProbe/README.md:24-55`), each with where it lands:

  | Finding | Lands in |
  |---|---|
  | The connection-owner check works unprivileged: TCP-table row (local port = server's, remote port = ours) + `QueryServiceStatusEx(TermService)`, no process opened; the service shares its process (type `0x30`) | Stage 5 relay; spike 0.4 repeats it under the service account |
  | Remote Desktop answers on loopback and selects CredSSP (protocol 8) | Stage 5; the viewer must do NLA (stage 6) |
  | The certificate is in `LocalMachine\Remote Desktop`, readable by anyone, 183-day lifetime; `SSLCertificateSHA1Hash` absent, so read the store | `rdpReady.certSHA256` (stage 1), read per relay, never cached across a renewal |
  | Licence value `AllowRemoteConnections` reads 1 on Pro | `host.rdp` `edition` (stage 1); Home still unread |
  | `ProductName` says "Windows 10 Pro" on Windows 11 | `host.os` is built from the build number (≥ 22000 → "Windows 11") and `EditionID` |
  | Remote Desktop was already on and open, by the owner's choice, with a policy key | Stage 5 must record "was on before Passthrough" at install and treat *open by the owner* differently from *opened behind our back*; see Open questions |
  | Hello-only reads 2 for a local account that signs in with a password | The *Your account* row reads account kind first |
  | PowerShell 7 is the Store package; the only `pwsh.exe` is the user-writable alias | Stage 3 catalog resolves the package's install folder (`Get-AppxPackage`-equivalent API), never the alias |
  | WSL lists `docker-desktop` | Catalog filter |
  | BitLocker state needs an administrator | That setup row is filled by the elevated step only |
  | Sleep: never on mains, no Modern Standby, no battery | Nothing learned about `sleepAfter` on a laptop yet |

- **Still to read on other PCs** (same program, no changes): **Windows Home** (expect licence value 0, `fDenyTSConnections` 1, nothing listening on the port: confirm all three, and whether `TermService` exists at all); **a Microsoft account with a password** (what `NetUserGetInfo` level 24 returns for `principalName`, which becomes `host.user`); **a Microsoft account made password-less** (Hello-only 2, and whether there is any password Remote Desktop accepts); **a laptop with Modern Standby** (`powercfg /a` wording, sleep timeouts on battery); **an Entra-joined work PC** if one can be borrowed (`dsregcmd` lines, `NetUserGetInfo` 2221); **Windows 10 22H2** (build 19045: confirm the TLS 1.3 line reads false).
- **How to carry it to a PC without the SDK**: `dotnet publish Spikes/PcProbe -c Release -r win-x64 --self-contained -p:PublishSingleFile=true`, copy the one exe, run it in a normal terminal, paste the output into the README under a new "Answers, <PC>" heading. The output masks the Microsoft-account name (`Program.cs:257-261`) but prints group names, shell paths and certificate hash prefixes: read it before committing.
- **Pass**: not a pass/fail spike. It is finished when Home and one Microsoft-account PC have been read.
- **What each outcome changes**: if Home shows `TermService` present and answering on loopback (unexpected), the *Screen* row's Home wording stands on the licence value alone. If a password-less Microsoft account turns out to be common among the PCs to hand (two or more of those read), stage 9 (the PC's own stream) moves ahead of stage 7, as the master plan says under stage 9.
- **Needs**: each other PC for five minutes; a Windows Home VM serves for Home (see 0.3).
- **Time**: done for the first PC; 15 minutes per further PC.

### 0.3 The Remote Desktop relay

- **Question**: with Windows' own Remote Desktop firewall rules off **and Passthrough's block rules on**, can a plain TCP relay on the PC carry a stock Remote Desktop client to `127.0.0.1` in every state the plan must cover, while the port stays closed from the LAN? And what exactly happens to the console session, to the tray app and to its shells, in each state?
- **Program**: `Spikes/RdpRelay/`, C# console, `net10.0-windows`, one `Program.cs` of about 250 lines, no packages. Verbs:
  - `setup` (elevated): writes the state file, then changes the firewall (below).
  - `relay` (not elevated): listens on `0.0.0.0:47389` and `[::]:47389`; for each connection dials `127.0.0.1:<PortNumber from the registry>`, runs PcProbe's owner check on that connection (copied from `Spikes/PcProbe/Program.cs:177-198`) and refuses if the far end is not `TermService`'s process, then copies bytes both ways and closes both when either ends. Prints one line per connection: time, client address, owner verdict, seconds, bytes each way. The relay itself is the "30 lines"; the rest is setup, undo and the check.
  - `status`: prints the same firewall and Remote Desktop lines PcProbe prints, so before/after can be diffed.
  - `undo` (elevated).
- **This PC already has Remote Desktop on and open, and that is the owner's own setup.** `setup` therefore saves and `undo` restores exactly what was there:
  1. `setup` writes `%ProgramData%\PassthroughSpike\rdprelay-state.json`: for every inbound rule whose local ports include the Remote Desktop port or whose group is "Remote Desktop" (TCP, UDP and Shadow rules): name, group, profiles, enabled; the three profiles' `FirewallEnabled`; `fDenyTSConnections`, `UserAuthentication`, `SecurityLayer`, `PortNumber`; the values under the Terminal Services policy key; the members of *Remote Desktop Users*.
  2. As a second, coarse backup: `netsh advfirewall export "%ProgramData%\PassthroughSpike\firewall-before.wfw"`. Used only if the state file is lost; importing it would also undo any unrelated firewall change made meanwhile.
  3. Disables (does not delete) every enabled rule in the "Remote Desktop" group.
  4. Adds `PassthroughSpike RDP block TCP` and `PassthroughSpike RDP block UDP`: inbound, block, the Remote Desktop port, every profile, any remote address.
  5. Adds `PassthroughSpike relay`: inbound, allow, TCP 47389, every profile, remote address `LocalSubnet`, program = the spike's exe.
  6. Registers a scheduled task `PassthroughSpike undo` that runs `RdpRelay.exe undo` as SYSTEM four hours later, and at next start-up if that time was missed: a dead-man switch, because the owner may be relying on Remote Desktop to reach this PC and the test list includes a reboot.
  7. Does **not** touch `fDenyTSConnections`, NLA, the policy key or group membership (all already as needed here). If any of them is not as needed (on another PC), `setup` stops and says so instead of changing it.
  - `undo`: removes the three `PassthroughSpike` rules; re-enables exactly the rules the state file lists as enabled and leaves the others as found; deletes the scheduled task; removes the local test account if `setup-account` made one; prints `status` and a line-by-line comparison against the state file, ending "restored" or naming each difference. Then deletes the state file (keeps the `.wfw` until the README's answers are written).
- **Steps** (PC = the owner's PC; Mac on the same LAN with stock FreeRDP 3: `brew install freerdp`):
  1. PC, elevated: `RdpRelay setup`. PC, normal terminal: `RdpRelay relay`.
  2. **Closed from the LAN.** From the Mac: `nc -vz -G 3 <pc-ipv4> 3389` and the same to the PC's IPv6 address must both fail; `sudo nmap -sU -p 3389 <pc>` must not say `open`; `sdl-freerdp /v:<pc>:3389` must fail to connect. Then `nc -vz <pc> 47389` must succeed.
  3. **Through the relay**, for each state below: `sdl-freerdp /v:<pc>:47389 /u:<account> /cert:ignore /sec:nla /dynamic-resolution` (password typed at the prompt, never on the command line). Record for each: connected or not and the client's error text; seconds from Enter to first picture; what the PC's physical screen shows during and after; whether the marker processes survived. Marker processes, started in the console session before each run: the stage-1 `Passthrough.exe` (tray), and a PowerShell window running `while(1){Get-Date -Format o | Add-Content $env:TEMP\ptspike-alive.txt; sleep 1}` (a gap in the file is a pause; a new session id in `query session` is a move).

     | # | State at the PC | What to record beyond connect/time |
     |---|---|---|
     | a | Same account signed in, in use, unlocked | Does the session **move** (same session id, console goes to the lock screen) or is a new one made? Markers alive? After disconnecting and signing in at the PC again: same session, markers alive, tray icon present? |
     | b | Same account signed in, **locked** | Same questions |
     | c | **Another account** signed in at the console (`PassthroughSpike` local test account, made by `RdpRelay setup-account`, elevated; `undo` deletes it and its profile) | The exact words shown to the remote user and to the person at the PC; what happens on no answer (timeout length, who wins); whether the other account's session survives |
     | d | **Signed out after `shutdown /r /t 0`**, nobody signed in since boot | Time to first picture; does the tray app start in the new session (Start at login on); with BitLocker off |
     | e | A **UAC prompt** showing (run an installer in the remote session) | Is the secure desktop visible and usable over the relay |
     | f | **Display off**: monitor powered off; then monitor cable unplugged | Connects? Resolution offered |
     | g | Remote session left idle, then **taken back at the PC** by signing in there | What the client sees (error code and text: this becomes "Someone signed in at …") |
     | h | **Wrong password** three times | Client error each time; the relay's log shows three short connections (it cannot see the failure: confirm the only signal is duration and byte counts); the account's bad-password count (`net user <name>`), to set the cap below Windows' lockout |
     | i | **Microsoft account** | Only if a PC or VM with one is to hand: which user-name form NLA accepts (`MicrosoftAccount\name@host`, the bare address, the local alias) |
     | j | PC **asleep** (if this desktop can sleep at all) | Nothing answers: confirm, and how long the Mac's connect takes to fail |
  4. With the relay still running, turn Windows Firewall **off** for the Private profile (Settings; put it back on straight after): confirm port 3389 is now reachable from the Mac. This is the situation stage 5 must detect; note what an unprivileged `HNetCfg.FwPolicy2` read shows in that moment.
  5. PC, elevated: `RdpRelay undo`. From the Mac: `nc -vz <pc> 3389` succeeds again (the owner's state), `nc -vz <pc> 47389` fails.
- **Pass**: states a, b, d, e, f connect through the relay; c and g behave in a way that can be described in one sentence each; in step 2 the Remote Desktop port is unreachable over IPv4, IPv6 and UDP while the relay works; after `undo`, `status` matches the state file. **Fail** if the block rules also stop the relay's own loopback dial, or if any of a, b, d cannot be reached.
- **What each outcome changes**:
  - Block rules stop loopback → stage 5 cannot use block rules; it falls back to "Windows' rules off plus the listener bound to loopback only", which needs its own check that nothing re-enables the rules (weaker, and the "exposed" detection becomes the main defence). Recorded as a correction to the master plan's *Remote Desktop relay* section.
  - (a)/(b): if the tray app or its ConPTY children die when the session moves, stage 3's sessions cannot live in the tray app as planned; shells move into a per-session helper started by the service (stage 4 grows). If they survive (expected: the session is disconnected and reconnected, not ended), the plan stands and the phone wording "stays locked afterwards" is confirmed.
  - (c): the measured words and timeout replace "(exact behaviour confirmed by spike)" in the master plan's *Another account signed in* row, and decide whether the phone shows **Cancel** only or also a countdown.
  - (d): the measured time sets the "Windows is starting your session" thresholds (5 s / 20 s) in the phone's connecting phases.
  - (e): if the secure desktop is not shown, "UAC prompts" comes out of the covered states and the guide says so.
  - (h): sets the relay's cap (master plan: 4 opens per grant in 10 minutes) against the PC's actual lockout threshold, and confirms "an open that lasted over 30 seconds doesn't count" is a usable rule.
  - (i): fixes the form of `host.user` (stage 1) for Microsoft accounts.
  - Step 4: says whether "firewall off" can be read without rights (it can for the profile switches per PcProbe; this confirms the port really opens).
- **Needs**: the owner's PC (elevated twice), the Mac on the same network, one person at each or one person moving between them; a Windows Home VM is not needed here. For (i), a PC or VM signed in with a Microsoft account. The owner must not need Remote Desktop into this PC during the run.
- **Time**: one day, including the reboot runs.

### 0.4 A service account with privileges stripped

- **Question**: can a Windows service that runs as its own virtual account, holding **only** `SeChangeNotifyPrivilege` and a restricted service SID, do everything `PassthroughService` must do? If one item needs impersonation or SYSTEM, the service's design changes before stage 4 starts.
- **Program**: `Spikes/ServiceAccount/`, C# worker service, `net10.0-windows`, one `Program.cs` of about 450 lines plus `setup.ps1` / `undo.ps1` (about 40 lines each). Package: `Microsoft.Extensions.Hosting.WindowsServices` only. The service runs a fixed list of checks at start and on a named-pipe command `run`, and appends one line per check (`PASS`/`FAIL`, detail) to `%ProgramData%\PassthroughSpike\service.log`. A second verb, `ServiceAccount.exe client`, run as the signed-in user, connects to the pipe and prints the log.
- **Setup** (elevated, `setup.ps1`):
  1. `New-Item %ProgramData%\PassthroughSpike` with an ACL at creation: Administrators full, `NT SERVICE\PassthroughSpike` modify, Users read on `service.log` only.
  2. Copy the published exe to `%ProgramFiles%\PassthroughSpike\`.
  3. `sc.exe create PassthroughSpike binPath= "\"%ProgramFiles%\PassthroughSpike\ServiceAccount.exe\" service" obj= "NT SERVICE\PassthroughSpike" start= auto`
  4. `sc.exe sidtype PassthroughSpike restricted`
  5. `sc.exe privs PassthroughSpike SeChangeNotifyPrivilege`
  6. `sc.exe failure PassthroughSpike reset= 86400 actions= restart/5000/restart/5000//`
  7. Firewall: `PassthroughSpike service TLS`, inbound allow TCP 47893, `LocalSubnet`, bound to the service (`-Service PassthroughSpike`).
  8. `sc.exe start PassthroughSpike`.
- **Undo** (elevated, `undo.ps1`): `sc.exe stop`, then `ServiceAccount.exe cleanup` is **not** enough because the key lives in the service account's store, so the service deletes its own key and certificate on the pipe command `cleanup` first; then `sc.exe delete PassthroughSpike`; remove the firewall rule; delete `%ProgramFiles%\PassthroughSpike`, `%ProgramData%\PassthroughSpike` and the service profile folder under `C:\Windows\ServiceProfiles\PassthroughSpike` if one was made; end by listing `sc.exe query PassthroughSpike` (expects 1060) and `Get-NetFirewallRule -DisplayName 'PassthroughSpike*'` (expects none).
- **Checks the service runs**, each one line in the log:

  | # | Check | How |
  |---|---|---|
  | 1 | Token is what was asked for | `GetTokenInformation`: privileges list is exactly `SeChangeNotifyPrivilege`; the service SID is present and the token is write-restricted; `SeImpersonatePrivilege` absent |
  | 2 | Persisted P-256 key | `CngKey.Create(ECDsaP256, "PassthroughSpike-tls", ExportPolicy = None)` in the Microsoft Software Key Storage Provider, in the service account's own store (not machine keys); make a self-signed certificate over it; log its SHA-256 |
  | 3 | TLS 1.3 server with that key | `SslStream` server on 47893, `EnabledSslProtocols = Tls13`, no renegotiation, client certificate not requested. The Mac connects with a 40-line Swift script (`Spikes/ServiceAccount/PinnedClient.swift`, run with `swift PinnedClient.swift <pc> <sha256>`) that uses `NWConnection` with minimum TLS 1.3 and a verify block that accepts only that SHA-256: the same Network.framework stack and the same kind of pin as the iPhone's client. Pass: handshake completes, negotiated version 1.3, a line echoes both ways; with a wrong hash the script refuses |
  | 4 | The key survives a reboot with nobody signed in | `shutdown /r /t 0`; before anyone signs in, run check 3 from the Mac again; same certificate hash |
  | 5 | DPAPI under the service account | `ProtectedData.Protect/Unprotect(CurrentUser)` round trip of 32 bytes, across a service restart and across the reboot in check 4. Also confirm a normal user process **cannot** unprotect the blob (run `client unprotect`, expect failure) |
  | 6 | DNS-SD | `DnsServiceRegister` of `PassthroughSpike._passthrough-spike._tcp.local` on 47893; the Mac sees it with `dns-sd -B _passthrough-spike._tcp` and resolves it; deregistered on stop |
  | 7 | Power request | `PowerCreateRequest` + `PowerSetRequest(PowerRequestSystemRequired)`; `powercfg /requests` (elevated) lists the service; cleared on `PowerClearRequest` |
  | 8 | Connection-owner check | PcProbe's check (`Spikes/PcProbe/Program.cs:145-198`) from inside the service: dial `127.0.0.1:<rdp port>`, find the row, `QueryServiceStatusEx(TermService)` |
  | 9 | Remote Desktop certificate hash | open `LocalMachine\Remote Desktop` read-only, SHA-256 of the newest certificate's `RawData` |
  | 10 | Named pipe, service side | create `\\.\pipe\PassthroughSpike` with `FILE_FLAG_FIRST_PIPE_INSTANCE`, `PIPE_REJECT_REMOTE_CLIENTS` and an explicit ACL (Authenticated Users read/write, no network logon); on connect, learn the client's account SID, session id and elevation **without impersonation privilege**: `ImpersonateNamedPipeClient` (expected to yield an identification-level token) then `OpenThreadToken` + `GetTokenInformation(TokenUser, TokenSessionId, TokenElevationType)`, then `RevertToSelf`. Log what it read; refuse session 0 and elevated clients |
  | 11 | Named pipe, client side | `client` opens the pipe with `SECURITY_IDENTIFICATION`, reads the pipe's owner with `GetSecurityInfo` and requires it to be the service's SID (`S-1-5-80-…` computed from the service name) before writing anything. Then, with the service stopped, a squatter (`client squat`, as the user) creates the same pipe name: the real client must refuse it |
  | 12 | It cannot read the user | the service tries to list `C:\Users\<owner>\` and to open the user's `%LOCALAPPDATA%\Passthrough\secrets`: both must fail with access denied |
  | 13 | Its own folder | create, write and re-read a file in `%ProgramData%\PassthroughSpike` (write-restricted tokens can only write where the service SID is granted: this confirms the ACL from setup is the right one) |
- **Pass**: checks 1 to 13 all `PASS` with the token of check 1. **Fail** on any item that needs a privilege beyond change-notify.
- **What each outcome changes**:
  - Check 2 or 4 fails (a write-restricted virtual account cannot persist a CNG key) → try, in order: the same with `sidtype unrestricted` (keeps the stripped privileges, loses write restriction: stage 4 states the weaker containment in `SECURITY.md`); then a key in the machine store with an ACL naming only the service SID. The first that passes becomes stage 4's design.
  - Check 3 fails with a persisted key but would pass with an ephemeral one → not acceptable (Windows' TLS runs outside the process); stage 4 moves TLS termination in-process with a managed TLS 1.3 stack, which is a new dependency and its own decision for the owner.
  - Check 5 fails → the service's secrets are sealed with a key held in its CNG store (check 2) instead of DPAPI.
  - Check 6 fails → DNS-SD is registered by the tray app on the service's behalf (works only while someone is signed in; the *On this network* row says so), or by a second, less restricted helper.
  - Check 7 fails → *Stay awake* is done by the tray app while signed in, and by a power-plan change in the elevated step otherwise.
  - Check 10 fails (no token at identification level) → the pipe protocol authenticates the tray app another way: the client sends a proof the service can verify from a per-account secret written at install into the user's profile by the elevated step. Stage 4's pipe PR is re-planned.
  - Check 12 passing is required for the master plan's statement "the service account can't read the user's profile".
- **Needs**: the owner's PC (elevated for setup and undo, one reboot), the Mac on the same network. One person.
- **Time**: one and a half days.

### 0.5 The iroh bridge

- **Question**: can a small Rust library of our own, over the `iroh` crate at the version the phones' iroh-ffi 1.1.0 is built from, loaded by .NET through a C ABI, accept from and dial the existing Mac app, directly and through a relay? And what does the build cost (toolchain, size, time)?
- **Program**: `Spikes/IrohBridge/`:
  - `bridge/` (Rust, `cdylib`, about 250 lines in `src/lib.rs`): exports `ptb_endpoint_new(secret_key, relay_url, relay_token, alpn) -> handle`, `ptb_endpoint_id`, `ptb_accept(handle) -> stream`, `ptb_connect(handle, endpoint_id, relay_url, addrs) -> stream`, `ptb_read`, `ptb_write`, `ptb_finish`, `ptb_close(handle) -> code`, `ptb_path(stream) -> 0 direct / 1 relay / 2 unknown`. Every export wraps its body in `catch_unwind` and returns a code; handles are table indices with a generation; buffers are caller-owned. `rust-toolchain.toml` and `Cargo.lock` committed; built with `cargo build --release --locked`.
  - `Probe/` (C# console, about 200 lines): loads the dll by full path with `NativeLibrary.Load`, verbs `listen` and `dial <endpoint id> [relay]`. `listen` prints its endpoint id and relay, accepts on ALPN `passthrough/shell/1`, reads one line, expects `{"t":"hello"}`, writes `{"t":"challenge","nonce":"<32 random bytes, base64>"}`, prints the path, closes. `dial` opens a stream, writes `{"t":"hello"}`, prints the first line it gets back and the path.
  - `MacDial/` (Swift package executable, about 60 lines, depends on `Packages/PassthroughCore`'s `IrohTransport` product by relative path): dials an endpoint id with `IrohShellDialer` (`Packages/PassthroughCore/Sources/IrohTransport/IrohShellDialer.swift`) exactly as the iPhone does, writes `hello`, prints the reply and `path(of:)`.
- **Before you start** (system changes on the PC):
  - Rust: `winget install Rustlang.Rustup` then `rustup toolchain install` as `rust-toolchain.toml` says; installs under the user profile. Undo: `rustup self uninstall`.
  - The MSVC linker: Visual Studio Build Tools with the "Desktop development with C++" workload (several GB, machine-wide). Undo: Visual Studio Installer ▸ Uninstall. If the owner would rather not install it on this PC, build the dll on a GitHub-hosted `windows-latest` runner from a throwaway branch and download the artifact; this also previews stage 3's CI build.
  - Windows asks to allow the probe through the firewall on first `listen` (a per-program rule made by the consent prompt). Undo: delete the rule named after the exe in Windows Defender Firewall ▸ Allowed apps.
- **Steps**:
  1. Find the crate version: read iroh-ffi 1.1.0's `Cargo.toml` for its `iroh` dependency; pin that exact version in `bridge/Cargo.toml`. Record it in the README.
  2. Build; record the dll's size and clean build time.
  3. **PC dials Mac, same LAN.** On the Mac, Remote shell on with the built-in connection on; copy its endpoint id and relay from the Mac app's Remote Shell settings. PC: `Probe dial <id> <relay>`. Expect a `challenge` line (the Mac's listener answering, `protocol/README.md:357-365`) and path `direct`.
  4. **Mac dials PC, same LAN.** PC: `Probe listen`. Mac: `swift run MacDial <pc id> <relay>`. Expect the `challenge` and `direct`.
  5. **Through a relay.** Put the PC on another network (the phone's hotspot) or block UDP between them, and repeat 3 and 4; expect `relay`, then note whether it becomes `direct`. Repeat once with the owner's own relay and token if one is set up, to prove the token path.
  6. **Closing.** End each side first in turn; record the code `ptb_close`/`ptb_read` returns, to replace the string matching in `IrohByteStream.isCleanClose`.
  7. Kill the probe mid-stream ten times while the Mac is connected: no crash on the Mac, and the next `listen` works.
- **Pass**: steps 3, 4 and 5 succeed in both directions with the path reported correctly; a clean close and an abort are told apart by code; the dll builds from clean with `--locked`. **Fail** if the crate at the matching version cannot interoperate with iroh-ffi 1.1.0's wire, or cannot be built for `x86_64-pc-windows-msvc`.
- **What each outcome changes**:
  - Pass → stage 3's bridge PR starts from this ABI; the measured size goes into `CONTRIBUTING.md`'s size note; the toolchain steps go into `windows/README.md`.
  - Version mismatch only → pin the phones and the bridge to a common newer iroh in one PR before stage 3 (phones first: iroh-ffi and iroh-android move together).
  - Cannot build or interoperate → fall back to loading iroh-ffi's own C library on Windows if it ships one for the target; if not, "From anywhere" on Windows leaves the first version and stage 3 leads with the TLS listener, which pulls the service (stage 4) ahead of the shell. This reverses a decision made with the owner ("From anywhere (iroh) on Windows: from the first version"), so it goes to the owner.
- **Needs**: the owner's PC with the toolchain, the Mac with the current Mac app, a second network (phone hotspot) for step 5. One person.
- **Time**: two days, most of it the first build and the relay runs.

### 0.6 FreeRDP on an iPhone

- **Question**: can FreeRDP 3, built static with OpenSSL only, run inside an iOS app over a transport we supply (no socket of its own), complete NLA against a default Windows 11 host, decode with the phone's hardware H.264 decoder, and feel usable on a phone-grade link, at a binary size we accept?
- **Program**: `Spikes/FreeRdpProbe/`:
  - `build.sh` (about 150 lines): fetches FreeRDP at a pinned 3.x commit and OpenSSL 3 LTS at a pinned release, checks archive hashes, builds static libraries for `iphoneos` arm64 and `iphonesimulator` arm64 with CMake, channels and codecs cut to the hardened list in the master plan (*Remote Desktop engine*), output under `Spikes/FreeRdpProbe/build/` (ignored).
  - `App/` (XcodeGen `project.yml`, about 600 lines of Swift and a 150-line C shim): a text field for host and port, user name and password fields, a Metal or `CALayer` view. The shim installs FreeRDP's transport-layer I/O callbacks so that every read and write goes through a ring buffer filled and drained by an `NWConnection` owned by Swift (the stand-in for Passthrough's authenticated stream), with an event FreeRDP waits on. Frames are copied from FreeRDP's GDI surface to the view on a display link. An overlay shows: security protocol negotiated, codec in use (from the RDPGFX capability and surface commands seen), whether VideoToolbox decoded the last frame, frames per second, bytes in and out.
- **Before you start**: needs spike 0.3's relay running on the PC (`RdpRelay setup` + `relay`), so the phone reaches Remote Desktop through port 47389 exactly as the product will; the Mac with Xcode signed in to the team; the iPhone registered. Nothing on the phone but the app; undo by deleting it. `RdpRelay undo` afterwards as in 0.3.
- **Steps**:
  1. `./build.sh`; record library sizes per slice and the build time.
  2. Build and install the app; record the `.app` size and compare with an empty app built from the same project with the libraries unlinked (the difference is the cost).
  3. Phone on the PC's Wi-Fi: connect to `<pc>:47389`. Confirm from the overlay: NLA (CredSSP) completed **through the hook** (set a breakpoint or a counter proving FreeRDP opened no socket), first picture time.
  4. Codec: with a default Windows 11 Pro host (no group policy changes), record what the server sends (AVC420, AVC444, or RemoteFX/Planar/ClearCodec only). If AVC is not offered by default, record which host policy would turn it on and stop: the product must not depend on host policy.
  5. Feel and data: on the phone, Settings ▸ Developer ▸ Network Link Conditioner, profile **LTE**, then **3G**. Ten minutes each of: typing in Notepad, scrolling a browser, dragging a window. Record frames per second, input-to-picture delay by eye and by a 240 fps recording of a key press, megabytes per ten minutes. If the owner has Tailscale on both, repeat once on real cellular.
  6. Rotate the phone and send a display-control resize; confirm the session resizes without reconnecting.
  7. Leave it connected for 30 minutes with a clock running in the remote session; record memory at 1, 10 and 30 minutes (Xcode's gauge).
  8. Wrong password, then a disconnect forced at the PC (0.3's state g): record the error codes FreeRDP reports for each, for the wording table.
- **Pass/fail lines** (from the master plan): **NLA completes over the hook**, with no socket opened by FreeRDP; **the hardware H.264 decoder is used with a default Windows 11 host**; **binary size** added is recorded and at most 12 MB to the iOS app's zip (the iroh addition was 6.1 MB, `CONTRIBUTING.md:32`; the owner may move this line, see Open questions); **feel and data use**: at LTE, at least 20 fps while scrolling and under 150 MB for the ten-minute script.
- **What each outcome changes**:
  - The hook cannot carry NLA → stage 6 uses a loopback socket pair inside the app as the bridge (the master plan rules this out: "No loopback socket"), which needs the owner's agreement, or stage 9 (the PC's own stream) is pulled forward.
  - No hardware decode with a default host → the fallback the master plan asks to be written before stage 6: **accept software decode** if step 5's numbers still pass on an iPhone two generations old, otherwise **pull the PC's own stream (stage 9) ahead of stage 6**. Written into `stage-6` before it starts.
  - Size over the line → trim (drop codecs proven unused in step 4) and re-measure once; if still over, the owner decides.
  - Memory grows in step 7 → stage 6 gets a leak hunt as its own PR before the flag comes off.
  - Step 8's codes fill stage 6's error-to-sentence map.
- **Needs**: the Mac (Xcode, CMake), an iPhone, the owner's PC with 0.3 set up, optionally Tailscale. One person; the feel test wants the owner's own judgement for ten minutes.
- **Time**: four days: one for the build script, two for the shim and view, one for measurements. The longest spike; start it as soon as 0.3 has passed.

### 0.7 ConPTY: inbox or bundled

- **Question**: do the escape sequences Passthrough depends on (OSC 52 clipboard, OSC 7501 program status and its query, a DCS string) pass through ConPTY unchanged and **in order relative to the text around them**, with Windows' inbox ConPTY on this build and with the bundled `Microsoft.Windows.Console.ConPTY` package? Which is hosted, and does Claude Code's status work?
- **Program**: `Spikes/ConPtyProbe/`, C# console, `net10.0-windows`, about 350 lines. One package: `Microsoft.Windows.Console.ConPTY` (its `conpty.dll` and `OpenConsole.exe` copied beside the exe). Verbs:
  - `emit`: the child. Writes, with a marker before and after each: `A`, `ESC ] 52 ; c ; <base64 "hello"> BEL`, `B`, `ESC ] 7501 ; state=working:msg=<base64> ESC \`, `C`, `ESC ] 7501 ; ? ESC \` followed by `ESC [ c`, then reads stdin for two seconds and prints in hex what came back, `D`, `ESC P 1 $ r 0 m ESC \` (a DCS), `E`, then 200 lines of numbered text with an OSC 7501 report between lines 100 and 101, `F`.
  - `host inbox|bundled [-- command…]`: creates the pseudoconsole (`kernel32!CreatePseudoConsole`, or `conpty.dll!ConptyCreatePseudoConsole` from the package), starts the command (default: itself with `emit`) inside a kill-on-close job object with an environment from `CreateEnvironmentBlock` plus `TERM_PROGRAM=Passthrough`, records every output byte to `out-<mode>.bin`, and when it sees the `7501 ; ?` query writes the Mac's answer (`protocol/README.md:504`) into the input. Prints a report: for each sequence, *intact* / *altered (shown)* / *missing*, and whether its position between its two markers was kept. Also polls the job's process list once a second and prints when the child has left.
  - `host … -- wsl.exe -d <distro> -- bash -lc "<the same emits with printf>"`: the same through WSL.
- **Steps** (owner's PC, not elevated, nothing installed beyond the package restore):
  1. `host inbox`, `host bundled`; keep both reports and the `.bin` files.
  2. Both again with `-- pwsh.exe -NoLogo` and a `emit` typed by hand, to see the shell's own redraw around the sequences.
  3. Both with WSL (Ubuntu). Note that the WSL processes are not in the job (expected).
  4. Resize the pseudoconsole (`ResizePseudoConsole`) while the 200 lines print; check no line is lost and the OSC between 100 and 101 keeps its place.
  5. By hand in each mode, through a minimal pass-through to the real console: start Claude Code (2.1.295 or later) and watch for its `7501 ; ?` and its reports in the `.bin`; open vim, type, resize, quit; confirm the alternate screen and cursor come back.
  6. Close the host window with a child still running: confirm the job kills it (Task Manager).
  7. Check the package's binaries carry Microsoft's signature: `Get-AuthenticodeSignature conpty.dll, OpenConsole.exe` (the master plan requires this at build time).
- **Pass**: with at least one of the two modes, OSC 52, OSC 7501 (report, query and the answer written back) and the DCS arrive intact and between their markers, through PowerShell and through WSL, and survive a resize. **Fail** if neither mode passes OSC 7501.
- **What each outcome changes**:
  - Bundled passes, inbox does not (expected on older builds) → bundle, as the master plan says; record the package version and size for `THIRD_PARTY_NOTICES.md`.
  - Both pass on build 26300 → still bundle (other PCs run older inbox versions); the README records that inbox works from this build so the bundle can go one day.
  - OSC 7501 fails in both → program status comes out of the PC's first version; "Program status (Claude Code)" in the master plan's table becomes "the question heuristic only", and stage 3's done-when loses "Claude Code status works".
  - Order not kept (a sequence arrives before text that preceded it) → stage 3's session manager must not use the sequence's stream position for anything (the question heuristic reads the screen, so it is unaffected); the transcript note says replays may differ.
  - Step 6 fails → stage 3 kills the process tree itself on close.
- **Needs**: the owner's PC alone; WSL with Ubuntu (present); Claude Code installed in either shell. One person.
- **Time**: one day.

### 0.8 Moving keys between the user's store and the service's

- **Question**: stage 3 runs in the tray app as the user; stage 4 moves the listener's secrets to the service account. (a) Can raw secrets (phones' shell keys, the iroh secret key) be handed over the pipe and re-sealed under the service account with nothing left readable by the user? (b) Can a P-256 TLS private key **made in the user's store in stage 3** be imported into the service account's store in stage 4 as a named, persisted, **non-exportable** key, so the certificate hash phones pinned does not change? The master plan assumes (b) is not done ("the service makes its own TLS key … phones are re-granted on their next cable connection"); a pass here removes that re-grant.
- **Why it matters now**: a grant must carry a certificate hash from the first one stage 3 sends (*What exists today*, last-but-one bullet), so stage 3 has to make a certificate anyway.
- **Program**: no new folder. Two more pipe commands in `Spikes/ServiceAccount/` (about 120 lines), run after 0.4 has passed:
  - `client handover`: as the user, creates `PassthroughSpike-user-tls` (P-256, CNG, user store, `ExportPolicy = AllowPlaintextExport` once), a self-signed certificate over it, 32 random bytes sealed with user DPAPI. Exports the key as PKCS#8, sends key, certificate and the unsealed 32 bytes over the pipe, then deletes its own key (`CngKey.Delete`) and the DPAPI blob, and zeroes the buffers.
  - Service side: `CngKey.Import` of the PKCS#8 into a named persisted key with `ExportPolicy = None`; seals the 32 bytes with its DPAPI; serves TLS on 47893 with the **imported** key and the **same** certificate.
- **Steps**: `client handover`; from the Mac, `swift PinnedClient.swift <pc> <hash of the certificate the user made>` succeeds; reboot; succeeds again before sign-in; as the user, try to open the service's key by name (must fail) and the old user key (must be gone); in the service, try to export the imported key (must fail).
- **Undo**: 0.4's `undo.ps1` (the service deletes both keys on `cleanup`); `client cleanup` deletes any user key left by a failed run.
- **Pass**: the Mac's pinned client accepts the service with the certificate made by the user, across a reboot; the imported key is not exportable; the user holds no copy.
- **What each outcome changes**:
  - Pass → correction to the master plan, stage 4: the TLS key and certificate are handed over with the access store and the iroh key; **no re-grant**, and the built-in path's "meanwhile" caveat disappears. Stage 3 makes the certificate (exportable once, user store) and puts its hash in grants.
  - Fail on import-as-non-exportable → stage 4 stays as the master plan has it (new key, re-grant), and stage 3's certificate is a placeholder whose hash phones pin but never see used; the stage-3 plan must say what `certSHA256` it sends (a self-made certificate kept only for the hash).
  - (a) failing is not expected; if it does, the hand-over is done by the elevated step instead of over the pipe.
- **Needs**: the owner's PC with 0.4 installed, the Mac. One person.
- **Time**: half a day on top of 0.4.

### Where each spike can run

| Spike | Owner's PC alone | Also needs | Elevated / system change on the PC |
|---|---|---|---|
| 0.1 checklist | yes, with the phones | iPhone, Android phone | none (installs Apple Devices, platform-tools) |
| 0.2 PcProbe | done here | **a Windows Home VM**, a Microsoft-account PC, a Modern Standby laptop, optionally an Entra PC and a Windows 10 PC | none |
| 0.3 relay | no | **the Mac** (stock FreeRDP); a second Windows account (made and removed by the spike); a Microsoft-account PC for state i | firewall rules, a scheduled task, a local account: all saved and restored |
| 0.4 service account | no | **the Mac** (pinned TLS client, DNS-SD browse) | a service, a firewall rule, a folder, one reboot |
| 0.5 iroh bridge | no | **the Mac** (current Mac app), a second network (phone hotspot) | Rust toolchain and MSVC build tools (or built on a CI runner) |
| 0.6 FreeRDP on iPhone | no | **the Mac** (Xcode), **an iPhone**, 0.3's relay on the PC | as 0.3 |
| 0.7 ConPTY | **yes** | nothing | none |
| 0.8 key hand-over | no | **the Mac** (same client as 0.4) | as 0.4 |

A **second PC** is needed only for 0.2's other readings and 0.3's state i; a **Windows Home VM** only for 0.2. The Home VM can run under Hyper-V on the owner's PC (it is Pro) or under a hypervisor on the Mac if it is Apple Silicon and an ARM Home image is used; installed from Microsoft's multi-edition image choosing Home, left unactivated, deleted afterwards.

### Order

1. **0.1** first (the master plan says so; and stage 1's CI job builds the app).
2. Then, in parallel where hands allow: **0.7** (PC alone), **0.3** (PC + Mac), **0.2**'s remaining PCs as they come to hand.
3. **0.4**, then **0.8** on the same install; undo once both are done.
4. **0.5** (after deciding where Rust is built).
5. **0.6** once 0.3 has passed (it needs the relay); it is the longest, so begin its `build.sh` on the Mac while 0.4 runs on the PC.

Total: about eleven working days end to end, about seven if the Mac-side work for 0.6 runs alongside the PC-side spikes.

## Pull requests, in order

Titles follow the repo's style (`<area>: <what changed, in plain words>`). Every one is against `dev` and leaves it working: spikes add only `Spikes/<Name>/`.

1. **Windows host: first run on a real PC, and what it changed**
   Scope: fixes found by 0.1; `windows/README.md` checklist rewritten to what was observed (drop "has not been built or run yet"; add "Known gaps" if any). Files: under `windows/` only. Tests: a Core test for each fix that touches Core. Docs: `windows/README.md`, `CHANGELOG.md` (Unreleased ▸ Windows). Verify by hand: the ten items. Leaves out: any new feature.
2. **Spike: what a PC can tell us before Remote access (PcProbe)**
   Scope: `Spikes/PcProbe/` as it stands plus the answers from the other PCs. Tests: none (throwaway). Verify: `dotnet run --project Spikes/PcProbe -c Release` prints every section. Leaves out: any change to `windows/`.
3. **Spike: ConPTY, inbox against bundled (ConPtyProbe)**: `Spikes/ConPtyProbe/` and its answers.
4. **Spike: a relay to Remote Desktop on loopback (RdpRelay)**: `Spikes/RdpRelay/` and its answers, including the state table as measured. The README's *Undo* section is checked off in the PR description.
5. **Spike: the service account with only change-notify, and handing keys to it (ServiceAccount)**: `Spikes/ServiceAccount/` with 0.4's and 0.8's answers.
6. **Spike: our own iroh bridge on Windows (IrohBridge)**: `Spikes/IrohBridge/` and its answers; `target/` ignored.
7. **Spike: FreeRDP in an iOS app over our own transport (FreeRdpProbe)**: `Spikes/FreeRdpProbe/` (script, shim, app; no binaries committed) and its answers.
8. **Windows plan: what the spikes changed**
   Scope: `windows/README.md` roadmap replaced by the master plan's stage list as amended by the answers; nothing else. This is where a failed pass line becomes visible in the repo.

No spike is added to CI (`.github/workflows/ci.yml` builds none of `Spikes/`, and should not).

## Interfaces

### This stage defines (others depend on these): name, shape, owner

Facts, not code. Each is the *Answers* section of a spike README; the owner of each is the stage that consumes it.

| Answer | Shape | Consumed by |
|---|---|---|
| Block rules and loopback (0.3) | yes/no + rule definitions that worked | Stage 5 install and "exposed" check |
| Session behaviour per state (0.3 a–j) | table: state → what happens, words shown, times, client error codes | Stage 1 (`host.console` values), stage 2 and 6 wording, stage 5 flyout states |
| Form of `host.user` for each account kind (0.2, 0.3 i) | string format per kind | Stage 1 |
| Service account capabilities (0.4) | 13 × PASS/FAIL + the `sc` commands that produced the token | Stage 4 |
| Key hand-over (0.8) | pass/fail + the CNG calls used | Stages 3 and 4 |
| Bridge ABI and iroh crate version (0.5) | export list, close codes, crate version, dll size | Stage 3, stage 8 |
| FreeRDP build recipe, hook design, codec, size, error codes (0.6) | `build.sh` flags, shim outline, numbers | Stage 6, stage 7c |
| ConPTY choice and sequence table (0.7) | inbox/bundled + per-sequence result | Stage 3 |

### This stage consumes (from which stage)

Nothing. 0.6 consumes 0.3; 0.8 consumes 0.4.

## Tests

- **Automated**: none added, except Core tests for any Core fix in PR 1. Spikes are not built by CI.
- **Fixtures added**: none.
- **Real-hardware checklist items**: each spike's *Run* steps are the checklist; PR 1 rewrites `windows/README.md`'s. After all spikes, on the owner's PC: `Get-NetFirewallRule -DisplayName 'PassthroughSpike*'` returns nothing; `sc.exe query PassthroughSpike` returns 1060; `Get-LocalUser PassthroughSpike` fails; `schtasks /query /tn "PassthroughSpike undo"` fails; `RdpRelay status` matches the saved state; from the Mac, port 3389 on the PC is reachable again as before.

## Security considerations for this stage

- **0.3 changes a machine-wide defence the owner set up on purpose.** Hence the state file, the coarse export, the dead-man task, and an `undo` that restores rule by rule. During the run the PC is *less* exposed than before (Remote Desktop closed to the LAN) except for the relay port, which is allowed from the local subnet only and forwards to Remote Desktop's own NLA; the relay adds no authentication, so it runs only while someone is at the test and is never left running.
- **0.3 and 0.6 type a real Windows password** into FreeRDP on the Mac and into a spike app on the phone. Use the owner's account only on the owner's devices; never put it on a command line or in a README; the spike app stores nothing.
- **The test account** (`PassthroughSpike`) gets a random password printed once by `setup-account`, is not an administrator, is added to *Remote Desktop Users* only for state c, and is deleted with its profile by `undo`.
- **0.4 leaves a listening service** on 47893 until undone: local subnet only, and it serves an echo. Undo the same day.
- **0.5's probe accepts from the internet** on the iroh endpoint while `listen` runs. It reads one line and closes; run it only for the test.
- **Spike output is committed.** Before each PR: no account names, no full certificate hashes, no endpoint ids, no relay tokens, no host names in the READMEs (PcProbe's `Mask` covers one of these; the rest is by reading).
- **0.6 vendors nothing**: FreeRDP and OpenSSL are fetched by script and built locally; no binary enters the repo in this stage.

## UX states and strings for this stage

None ship. The spikes *measure* what these master-plan strings depend on, and the measured facts are written next to them in the consuming stage's plan: the *Another account signed in* row (0.3 c), the connecting phases' 5 s and 20 s thresholds (0.3 d), "stays locked when you leave" (0.3 a, b), "Someone signed in at *Office-PC*, so this view ended." (0.3 g), the Home sentence (0.2).

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| The owner is locked out of their own Remote Desktop by a half-finished 0.3 | The scheduled `undo` four hours on and at next boot; `undo` is idempotent; the `.wfw` export as a last resort |
| `undo` restores the wrong thing because the owner changed rules mid-spike | Restore is per rule from the state file, and only rules the spike itself disabled are touched |
| A spike is left installed | Everything is named `PassthroughSpike…`; the final checklist under *Tests* |
| 0.6 runs long (FreeRDP's iOS build) | Time-boxed to four days; if `build.sh` is not producing a linking library by the end of day two, stop and record that as the answer, which triggers the stage-9 fallback discussion |
| No Windows Home machine to hand | An unactivated Home VM under Hyper-V on the owner's PC |
| No Microsoft-account PC to hand | The same VM, signed in with a throwaway Microsoft account; otherwise `host.user`'s format for that kind stays a stated assumption in stage 1 and is confirmed in stage 5 |
| Installing MSVC build tools on the owner's PC is unwelcome | Build the bridge on a GitHub-hosted runner (0.5, *Before you start*) |
| A spike passes on build 26300 (an Insider build) and fails on release Windows 11 | 0.3, 0.4 and 0.7 are each repeated once in the Home/Pro VM at the current release build before their PR merges; differences go in the README |

## Decisions made here

1. **Eight spikes, numbered 0.1 to 0.8**, with key hand-over (0.8) as its own question but sharing 0.4's program. Reason: it needs the same service install, and its answer changes two stages.
2. **The relay spike disables the owner's Remote Desktop rules rather than leaving them and testing "around" them.** Reason: the pass line is "closed from the LAN", which cannot be shown with the rules on; the save/restore makes it safe.
3. **A dead-man scheduled task** for 0.3. Reason: a reboot is part of the test and the owner's remote access depends on the state being put back.
4. **`setup` refuses to turn Remote Desktop or NLA on** in the spike; it only tests a PC where they are already on. Reason: turning them on is stage 5's design; the spike should not pre-empt how.
5. **The pinned-TLS client for 0.4 is a Swift script on the Mac**, not an iPhone build. Reason: same Network.framework TLS stack and pin logic as the phone, a tenth of the effort; the iPhone itself is exercised in stage 4's checklist.
6. **0.5 tests against the real Mac app** (PC dials Mac) and a Swift dialler built on `IrohTransport` (Mac dials PC), not Rust on both ends. Reason: the risk is interoperation with iroh-ffi 1.1.0, which Rust-to-Rust would not show.
7. **0.6 uses the Network Link Conditioner for "cellular"**, real cellular only if Tailscale is already on both. Reason: repeatable, and needs no path from the mobile network to the PC before the product exists.
8. **A numeric size line for 0.6** (12 MB added to the iOS zip). Reason: the master plan asks for a pass/fail line on size but gives no number; twice the iroh cost is a line the owner can move.
9. **One PR per spike**, plus one for 0.1's fixes and one for the roadmap. Reason: `CONTRIBUTING.md:12-13` (one thing per PR); a spike's README is reviewable alone.
10. **Spikes are repeated once on a release-build VM** before merging. Reason: the owner's PC runs an Insider build (26300).

## Corrections to the master plan

1. **Stage 3 needs a certificate hash before stage 4 makes a TLS key.** Phones discard a `shellGrant` whose `certSHA256` is not 64 hex digits (`ControlServer.swift:234-237`, `ControlServer.kt:196`). The master plan's stage 3 ("no listener on the network yet … iroh only") does not say where that hash comes from. Spike 0.8 is added to settle it; either way stage 3 must make a certificate.
2. **The spike list omits key hand-over.** The master plan's stage 4 describes the hand-over and a re-grant but lists no spike for it; 0.8 fills that.
3. **"Relay: … with Remote Desktop's rules off" assumes Passthrough owns those rules.** On the owner's PC they were on by the owner's choice. The spike (and stage 5) must save and restore them, and stage 5 needs a rule for "Remote Desktop was already open when Passthrough was installed" (see Open questions 1).
4. **"FreeRDP 3.33.x"**: the spike pins a commit, not a minor series; the version actually built is recorded in the README and carried to stage 6.
5. **The master plan's spike list says "driven by stock FreeRDP from another machine" without saying which.** It is the Mac (the only other machine certain to be to hand).

## Open questions for the owner (each with a recommended default)

1. **On a PC where Remote Desktop was already on and open before Passthrough (this one), what should stage 5 do?** Options: (a) refuse to relay until the owner lets Passthrough close it, as for any exposed PC; (b) relay anyway, with a notice that stays ("Remote Desktop is open to your network by your own setting"), and never add block rules; (c) offer both at setup. **Recommended: (c), defaulting to (b)**: Passthrough must not silently close a door the owner opened, and must not pretend it is closed. The spike does not need the answer; stage 5 does.
2. **May the spikes install Visual Studio Build Tools (C++) and Rust on this PC**, or should the bridge be built on a GitHub-hosted runner? **Recommended: the runner for the first build, local install only if iteration proves too slow.**
3. **Is a four-hour window without Remote Desktop into this PC acceptable for 0.3**, and is the dead-man task (runs as SYSTEM once) acceptable? **Recommended: yes to both; pick a day the PC is not needed remotely.**
4. **Size line for the Remote Desktop engine on iOS**: 12 MB added to the zip. **Recommended: accept 12 MB; discuss above that.**
5. **A throwaway Microsoft account and an unactivated Windows Home VM for readings**: acceptable? **Recommended: yes; both deleted afterwards.**
6. **If 0.5 fails outright**, "from anywhere on Windows from the first version" cannot hold. **Recommended default: ship the local path first (service pulled forward) rather than hold everything for iroh.** Asked only if the spike fails.
