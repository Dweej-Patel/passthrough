# Changelog

What changed between builds, with anything you must do when you rebuild and
reinstall. There are no signed releases: everyone builds from source, so read
the **Before you rebuild** notes first. The Mac and phone apps update together.

## Unreleased

### Before you rebuild

* **Windows: Remote access now runs as a background service, and needs a
  self-contained build.** Build with `scripts/build-windows.ps1` and run
  `Passthrough.exe` from `windows/artifacts/Passthrough`. Turning Remote
  access on (or *Finish setup*, if you used it before) asks Windows for an
  administrator once: it installs the service into `C:\Program
  Files\Passthrough`, and from then on Start at login and the Start menu run
  the installed copy. The service has an identity of its own, so **plug each
  phone in once** afterwards; until then phones can't reach the PC's shell.
  Your phones' access, your relay and its token move into the service; this
  account's copies are deleted.
* **Windows: phones on the same network or Tailscale reach the PC directly**
  (Windows 11 and Server 2022; Windows 10 has no TLS 1.3 server, so phones use
  the built-in connection there). The service listens on TCP 7893, TLS 1.3
  only, with a key that can't leave the PC, and names itself on the network as
  the PC's host name. The firewall rule lets in the local subnet and the
  private and Tailscale ranges only.
* **Windows: the PC's screen, through Remote Desktop.** The Mac shows it in
  a window once a phone shares the PC with it. On the iPhone and iPad it is
  still behind a developer switch (docs/GUIDE.md, *A PC's screen*). Settings ▸ Remote access ▸ *Screen* sets it up
  behind one administrator prompt. If Remote Desktop was off, Passthrough turns
  it on blocked from the network (its own firewall rules, which a block makes
  win over any allow rule), with Network Level Authentication required. If you
  already use Remote Desktop open on your network, it is left exactly as it is,
  and Settings offers to close it to the network. Each phone gets a *Screen*
  box, off at first. The service relays only to Windows' own Remote Desktop
  (it checks who answers on the port), tells the phone which certificate to
  expect, refuses any connection that doesn't use Network Level
  Authentication, and caps quick sign-in attempts below Windows' own lockout.
  Removing Passthrough puts back every Remote Desktop setting it changed and
  nothing else.
* **Windows: Stay awake while plugged in**, and phones are told when the PC
  goes to sleep, shuts down or has Remote access turned off. A connected phone
  keeps the idle timer off for as long as it is connected and a minute after.
* **Windows: after `--update`, restart the tray app.** Quit Passthrough from
  the tray and open it from the Start menu. The service updates at once; the
  tray app runs the new build only once it is started again. Several fixes run
  inside the tray app: the taskbar, the hand-off after Turn on, quitting.
* **Windows: build from a folder only you can write to, on a PC with other
  accounts.** Setup copies the build folder into Program Files behind your
  administrator prompt, and it doesn't yet check who else can change that
  folder. `D:\` and other second drives let every account change files by
  default (windows/README.md, SECURITY.md).

* **Phone notifications now take their push key from the build, not from
  Settings.** The *Team ID*, *Key ID* and *Choose .p8* fields in
  *Settings › Remote Shell › Notifications* are gone. To keep notifications:
  put your APNs key in `Config/` (`*.p8` is gitignored), add
  `PASSTHROUGH_PUSH_KEY_FILE = Config/AuthKey_<Key ID>.p8` to
  `Config/Signing.xcconfig` (plus `PASSTHROUGH_PUSH_KEY_ID` if the file isn't
  named `AuthKey_<Key ID>.p8`), run `xcodegen generate`, and rebuild the Mac
  app. The team is `DEVELOPMENT_TEAM`, or `PASSTHROUGH_PUSH_TEAM_ID` if the
  key belongs to another team (the iPhone app's, when the Mac uses a free
  team). The build stops with an error if the file named is missing or isn't
  a key.
* Without that line the Mac app builds and runs as before but sends no
  notifications, and the Notifications section is hidden. The iPhone's widget
  and Live Activity still show a shell that needs you.
* The key is now inside `Passthrough.app`: don't give a built app to anyone
  else; let them build their own with their own key.
* **iPad support: update the iPhone, the iPad and the Mac together.** The
  iPhone now links an iPad over its Personal Hotspot only, and the iPad learns
  which network is the hotspot from those links, so an older build on either
  side gets this wrong (an older iPhone also links over a Wi-Fi network both
  share). There are no compatibility shims. The Mac needs the new build too,
  for an iPad on the cable, for `internetFrom` (which iPhone the iPad uses) and
  for `goodbye`. Both iOS targets now build for iPad (`TARGETED_DEVICE_FAMILY`
  1,2); run `xcodegen generate` before building. The iPad's tunnel extension
  links `Vendor/HevSocks5Tunnel/HevSocks5Tunnel.xcframework`, which is checked
  in (`scripts/build-hev.sh` rebuilds it with the macOS library).
* **Screen view: update the Mac and the phone together.** The screen
  stream's `hello` changed (it now says what to show) and the Mac no longer
  draws the pointer into the picture: an older phone on a new Mac would show
  no pointer, and an older Mac doesn't understand the new `hello`. No
  compatibility shims.

#### Setting up the push key, step by step (for a person or for Claude)

If Claude (or another coding agent) is doing the rebuild, it should follow
these steps as written and check each one before building.

1. **Find the key.** Look for an `AuthKey_<Key ID>.p8` file: first in `Config/`,
   then with `mdfind -name AuthKey_ | grep '\.p8$'`. Use only the file name to
   decide; never print the file's contents.
2. **No key anywhere?** Only the account owner can make one: at
   developer.apple.com › *Certificates, IDs & Profiles* › *Keys*, add a key with
   *Apple Push Notifications service (APNs)* and download it. Apple lets you
   download it only once, so keep a copy somewhere safe (a password manager).
   An agent should ask the person for the file, not make the key itself. If
   they don't want notifications, skip to step 5: the build works without them.
3. **Put it in place:** move it into `Config/` (for example
   `mv ~/Downloads/AuthKey_ABC123DEFG.p8 Config/`) and run
   `git check-ignore Config/AuthKey_ABC123DEFG.p8`, which must print the path
   (it is ignored, so it can't be committed).
4. **Name it in the config:** add
   `PASSTHROUGH_PUSH_KEY_FILE = Config/AuthKey_ABC123DEFG.p8` to
   `Config/Signing.xcconfig` (add `PASSTHROUGH_PUSH_KEY_ID = ABC123DEFG` too if
   the file isn't named `AuthKey_<Key ID>.p8`). `DEVELOPMENT_TEAM` there must be
   the team the key belongs to, or set `PASSTHROUGH_PUSH_TEAM_ID` to the
   key's team (it must be the team that signs the iPhone app).
5. **Regenerate and build:** `xcodegen generate`, then build the Mac app
   (Release for /Applications, as in docs/GUIDE.md › Setup). The build log
   says either `Bundled push key <Key ID> for team <Team ID>.` or
   `No PASSTHROUGH_PUSH_KEY_FILE: building without phone notifications.`
6. **Check the built app:**
   `ls build/Build/Products/Release/Passthrough.app/Contents/Resources | grep AuthKey_`
   shows the key when notifications are on.
7. **After installing:** open *Settings › Remote Shell › Notifications* on the
   Mac (it reads *Ready*), turn on *Settings › Notifications › Tell me when a
   shell needs me* on the iPhone, and click *Send Test Notification*.

### Added

* **Windows: one command for each job.** `scripts/windows.ps1 doctor | deps | build | install | update | reinstall | off | remove`.
  - `update` restarts the tray app by itself.
  - `doctor` changes nothing.
  - `-WhatIf` shows what a command would do.
  - It refuses to build or install from a folder another account on the PC can change, unless `-Force`. It builds into `%LOCALAPPDATA%\PassthroughBuild` (windows/README.md).
* **Windows: the tray and Settings, reorganised around what you use.**
  - The flyout's header follows Remote access, not the cable: off, reachable, needs a look (and why), or who is on the PC now.
  - Notices and anyone viewing the screen (with **Stop**) sit above two tabs, which the flyout remembers:
    - *This PC*: the phones on the cable and Stay awake;
    - *Remote · N*: who can reach the PC, who is on it now (each with **Stop**) and Your computers.
  - Settings has four pages: General, Remote access, Your computers and Advanced.
    - Each phone has one row: Screen, Share, Stop, Revoke… and Forget…. Before, a phone was listed once for its pairing and again for its access.
    - Computers with access get **Allow screen** and **Revoke…**.
  - The first Turn on can set up the screen in the same administrator prompt.
  - Quit asks first when phones have shells open or Remote access is on.
  - Notices:
    - a granted phone's notice offers **Not now** in place of **OK**;
    - Revoke from a notice asks first;
    - the Remote Desktop notice opens Settings;
    - Windows notifications say what happened.
  - Esc closes the flyout, and buttons name their phone or computer for Narrator.

* **A host tells a phone which computers it gave access to there**
  (`listComputers` / `computerList`, protocol/README.md *Computers*), and tells
  it again whenever that changes: what each may do now, what waits for the
  host's owner, and whether it is connected. A phone can take any of them back
  at any time. The PC answers in this build; the Mac and the iPhone's Share
  sheet use it in theirs.
* **The iPhone and iPad app knows a PC from a Mac.** A paired PC shows as a
  PC: its own words, only the rows a PC has (no Internet, Keep awake, VPN or
  Share screen), its Lock when it allows it, its own setup steps, why its
  shell can't start (nobody signed in, someone else signed in, Passthrough
  not open there, Shell off for this phone), and why it can't be reached
  when it said so (asleep, Remote access turned off, shut down). New shell
  becomes a split control when the computer lists several shells, and
  remembers the last one per computer. A PC's Screen row is dimmed: its
  screen comes in a later version, and the app never offers it the Mac's
  Screen Sharing login. The switcher is *Your computers*; "New session" is
  "New shell" everywhere. A Mac reads as before. Nothing to do when you
  rebuild.
* **Android knows a PC.** A paired Windows PC shows as a PC: its own words, only
  the rows a PC has (no Internet, Keep awake or VPN; Lock, and a dimmed Screen
  row saying Android can't show it), why a shell can't start (nobody signed in,
  Passthrough closed there, Shell off for this phone), why it went away (asleep,
  Remote access turned off, shut down), its own setup steps, and a split New
  shell that picks among its shells and remembers the last one. The switcher is
  *Your computers*. A Mac reads as before. Nothing to do when you rebuild.
* **A Windows tray app (first stage).** `windows/` holds a C# port of the host
  side: a tray flyout that lists the phones on the cable, pairs an iPhone or an
  Android phone with the six-digit code and shows its live status. An iPad is
  listed and marked as not supported yet. Each phone gets its own pairing,
  named after the phone; Settings lists them all,
  attached or not, and can forget any of them. When a phone can't be reached
  the row says why (for example that Passthrough isn't running on it) and the
  PC retries with the Mac's back-off. Failures go to a log in
  `%LOCALAPPDATA%\Passthrough`, and when starting fails with an error the app
  shows it and exits instead of staying invisible. It does not carry internet yet, and has no shell, screen, wireless
  link, VPN layer or keep-awake. The phones and the wire protocol are
  unchanged. iPhone needs Apple Devices from the Microsoft Store; Android needs
  platform-tools; the PC needs the .NET 10 Desktop Runtime. On Windows the
  iPhone link goes over loopback TCP, which the
  [guide](docs/GUIDE.md#windows) explains. The app has not been run on a real
  PC yet. Nothing to do for existing Mac or phone builds. See
  [windows/README.md](windows/README.md).

* **One Mac can see and control another's screen.** On the iPhone, open a
  Mac and tap *Share screen with a Mac*, pick your other Mac and confirm with
  Face ID. That Mac gets a screen-only pass and opens the screen from
  Passthrough's menu (*Other Macs*), on the local network or from anywhere
  over iroh, without the phone, after Touch ID or the password on that Mac.
  Controlling the screen means typing into any app on it, Terminal included,
  but the pass can't open Passthrough's shells, hide the shared Mac's
  display or end your phone's view of it, and the shared Mac shows a notice
  when a pass is made. Remove it in *Settings › Remote Shell* on the shared Mac (on
  the other Mac, removing it only forgets that Mac's copy). It stops working
  when the phone that shared it loses access or its Screen permission there.
  The other Mac also holds the shared Mac's relay token, if it has one. Both
  Macs and the iPhone need this build. Not on Android yet.

* Screen view, far away: the Mac now keeps as many frames in flight as fit in
  the round trip (it was two, so a phone 100 ms away got about 20 frames a
  second) and lowers its bitrate when frames start arriving late, then raises
  it again.
* Screen view: *Picture* in the desktops menu: *Sharp* (crisp text, 60 fps,
  as before), *Smooth* (crisp text at 120 fps on ProMotion iPhones and
  iPads) or *Fast* (120 fps, slightly softer text, keeps moving on a slow
  link). And with *Fit to this iPhone/iPad*, *Text size*: *Larger text*,
  *Default* or *More space*.
* Screen view: *Use Here*. When the Mac's screen is open on another device
  too, a banner says so; *Use Here* ends the view there (it shows "open on
  …" with its own *Use Here* to take it back) and gives this device the
  display made for it.
* Screen view: pinch and rotate reach the Mac app under your fingers (Maps,
  Photos, Preview, Safari's zoom), as from a Mac trackpad. With *Fit to this
  iPhone/iPad* they always do, and a three-finger double-tap zooms the view;
  on the Mac's own display pinch still zooms the view unless *Pinch and
  rotate go to …* is on. It uses an undocumented macOS event (as Mac Mouse
  Fix does), checked on macOS 27.
* Screen view: momentum scrolling. A two-finger scroll that ends moving
  carries on and slows like a Mac trackpad's; touching the screen stops it.
* Screen view: a spinner or streaming text alone, with no one touching the
  phone, goes at 15 frames a second, back to full speed at the first touch.
* Screen view: HEVC instead of H.264 where the phone decodes it (every
  supported iPhone and iPad): a little sharper for the same bits.
* Screen view, slow links: when the bitrate gets too low for the picture's
  size, the Mac sends a smaller picture (¾, then ½ each side) rather than a
  blurry full-size one, and the full size again once the link allows it.
  Keyframes, which are big whatever the bitrate, shrink with it.
* Screen view: the desktops menu says how you're connected (your network,
  directly, or through a relay), and the view says so once if it stays on a
  relay, the likeliest reason for lag.
* Screen view: the phone draws the Mac's pointer itself, so it moves the
  moment your finger does instead of a round trip later.
* Screen view: *Screen shape › Fit to this iPhone/iPad* (in the desktops
  menu). The Mac makes a display in the device's shape and resolution, turns
  with it, and mirrors its own displays onto it while you view, so the
  desktop fills the screen at a readable size, clear of the Dynamic Island
  and the view's controls. The default is still the
  Mac's own display, as before. It uses macOS's private virtual-display API
  (as Sidecar and DeskPad do); if that fails the view says so and shows the
  Mac's own display.

* Shell status: sessions say what Claude Code is doing (working, needs you,
  done); the widget and Live Activity show a shell that needs you.
* Notifications: a Mac tells the iPhone when a shell needs it or finishes a
  long task, through Apple's push service, sealed end to end.
* A long session's replay restores its terminal modes, so full-screen programs
  reattach on their own screen.
* iPad: **Internet through iPhone**. On the iPhone's Personal Hotspot, the
  iPad's traffic leaves from the iPhone's own network stack through
  Passthrough, not as hotspot data. Its tunnel holds every route and runs
  tun2socks to the link the iPhone dials in on; with the link down the iPad is
  offline on purpose, with **Use hotspot data instead**. It runs only on the
  iPhone's hotspot (known by its DNS server, or learned from a first working
  link), and steps aside within seconds anywhere else.
* iPad: pairs with its iPhone by a QR code (one-time, five minutes). On the
  iPhone: *iPhone* tab › *Paired devices* › **Pair › Scan an iPad's code**,
  then Face ID.
* iPad as the Mac's remote: it pairs over the cable and gets the shell and
  screen like a phone, but the Mac never routes through it. With an iPhone
  attached too, the Mac's panel offers **Pair iPad** (the Mac talks to one
  device at a time and the iPhone comes first). The Mac's panel says which
  iPhone the iPad gets its internet from, and *Phones with access* shows it
  as an iPad, under the name it goes by now. On iPad, Apple Pencil clicks and
  drags where it touches on the Mac's screen, and double-tap (or squeeze)
  right-clicks. On iPad the screen view
  fills the display under a floating bar, and a trackpad, mouse or hardware
  keyboard goes straight to the Mac.
* iPhone: *Sharing with* lists the Macs and iPads using it right now, and
  *Paired devices* lists both.
* Screen view: the iPhone or iPad as the Mac's microphone. A microphone
  button in the screen view sends your voice to the Mac, where it is a
  "Passthrough Microphone" input device that dictation and call apps can
  listen to. The device is an audio driver the Mac app carries: install it
  under Settings › Remote Shell › *Phone as microphone* (the root helper
  copies it into `/Library/Audio/Plug-Ins/HAL` after checking its signature,
  and the Mac's sound stops for a moment while its audio restarts). The
  microphone is on only while its button is, and goes off when the view
  closes or the app leaves the screen. While it is on, any app on the Mac
  that may use a microphone can hear it.

### Fixed (Windows, from the security and code review)

* Opening a shell on another computer from the tray put that computer's name
  on Windows Terminal's command line, where a `;` starts another command: a
  computer named that way could run a program on the PC. The name now reaches
  only the terminal's title, set from inside it.
* Removing Passthrough could leave Remote Desktop on and open to the network
  when Windows' own Remote Desktop rule was already on before setup.
* A view of the screen that was just starting could outlive Screen being
  turned off or Stop. A computer a phone revoked kept its shells running.
* A refused Remote Desktop attempt could write the end of the Windows account
  name to the service's log.
* An account removed from Remote access kept its tray app's link to the
  service until it restarted.
* The service and its libraries look up Windows' system libraries in System32
  only.
* After Turn on, the copy you started didn't hand over to the installed one.
* A shell that failed to start left its console process and handles behind.
  Closing a shell could, in rare timing, hang every shell.
* Quitting could skip ending phones' shells. Stopping the service could crash
  it.
* The taskbar is kept on top after a Remote Desktop resize, but no longer over
  a full-screen video or game.
* The notice for a computer given only the screen no longer says it was given
  the shell.

### Fixed (Windows, from the second review)

* One Windows account's phones could use up the 16 computers a PC lets in, for
  every account; the limit now counts one account's own. A phone already kept
  by an account an administrator turned off can't be taken by another, and a
  phone's id now reaches only its own account's tray app.
* Stop in the tray keeps that device's screen closed for 30 seconds, as Stop on
  a view already did.
* Settings showed a computer's screen as allowed while the phone that shared it
  had Screen off; it now says the screen is held back, and why.
* A phone waiting for its pairing code was hidden behind the Remote tab: the
  flyout now brings This PC forward, and the tab reads *This PC · Pair*.
* Quit and turn off Remote access quit anyway when the administrator prompt
  was declined; it now says so and asks again. After a restart the tab bar
  could show This PC over the Remote panel.
* *Use this phone* is hidden: it promised internet through the phone, which
  the PC doesn't do yet.
* `scripts/windows.ps1`: the build-folder check also counts permissions
  inherited into what the build creates and the owner of each folder, and runs
  again just before the administrator prompt. It needs PowerShell 7 (`pwsh`),
  refuses an `-Output` folder that holds other files (the build deletes it),
  builds before a clean reinstall removes anything, keeps your own changes to
  the lock files, and refuses `install` and `update` from a standard account
  (turn Remote access on from the tray app's Settings instead).
* `scripts/windows.ps1` run from a PowerShell that is itself elevated restarted
  the tray app as administrator, where it hosts no shells: phones connected but
  couldn't open one. It now starts the tray app as you, through Explorer, and
  `doctor` says when the tray app runs as administrator; the app logs why it
  doesn't link to the service then.

### Changed (Windows, from the second review)

* The flyout's header has **Turn on…** or **Fix…** when Remote access needs it,
  and says *This PC's screen is in use* while someone views it. Settings' page
  for the computers let in here is *Computers with access*; *Your computers*
  is what this PC reaches. *Stay awake on mains power*. **Open the log folder**
  in Settings' error box and on Advanced.

### Changed

* **CI builds and tests the Windows app.** A Windows job runs the Windows Core
  tests and builds the tray app, and the macOS job runs the same Core tests
  beside `swift test`, so they stay free of Windows APIs. The .NET SDK is
  pinned by `global.json` at the repo root (10.0.100 or a later 10.0 feature
  band), every package comes from nuget.org only (`windows/nuget.config`), and
  each Windows project's package versions and content hashes are pinned in its
  `packages.lock.json`, restored in locked mode. To change a package, see
  [windows/README.md](windows/README.md#build). Nothing changes in the apps.
* **The Windows Core reads the remote shell protocol.** A C# port of the shell
  envelope, its constants, the key proof and the iroh checks, tested against
  `protocol/fixtures.json`'s `shell` section like the Swift and Kotlin suites.
  The fixtures gain the list of error reasons and the `replaying`, `lock` and
  `viewing` lines. Nothing on the wire changes and the PC hosts no shell yet.
* **A host says what it is.** After `ready` the Mac now sends `host`: that
  it is a Mac, its macOS version, its one shell (your login shell), how its
  screen can be seen and what this phone may do. The protocol also gains what
  a Windows PC will need: a choice of shell in `open` (and each session says
  its shell), `signed_out`, `goingAway`, a Remote Desktop relay (`rdp`,
  `rdpReady` with the certificate to accept, `rdp_unavailable`, `try_later`,
  `screenEnded`), and `hostKind` on the grant over the cable, which the
  phones keep. Phones and the Mac read all of it; nothing you can see changes
  yet, and older phones and Macs ignore it (see
  [protocol/README.md](protocol/README.md#the-host)). Update phones and the
  Mac in any order.
* Windows: the PC can now send a shell grant over the cable and hear the
  phone's answer, but only on a channel whose pairing the phone has proved and
  whose far end a check has found to be Apple's or adb's own service. No check
  exists yet, so no grant goes out. The PC's `hello` now says it is a PC. The
  log filter also removes shell keys (as JSON escapes them too), secret JSON
  fields (the pairing code among them), `Bearer` headers, and any secret registered with it (the relay token, from the stage that loads one).
* Windows: the rules for when a phone is granted a shell key, granted again or
  left alone (one grant in flight per phone, re-granted only when what grants
  carry changes, a growing wait for a phone that doesn't answer, nothing for a
  revoked phone until it reconnects) are ported from the Mac with its tests.
  Nothing uses them yet.
* **Windows: every phone on the cable has its own channel, and an iPad pairs.**
  The PC now keeps a control channel open to each attached device, not only
  the phone in use, so two phones on two cables both pair and both show live
  status, and an iPad pairs with its code like a phone. *Use this phone* only
  marks which phone the PC will go online through; it no longer closes the
  other phone's channel, and it is never offered for an iPad. *Try again*
  works on any row that failed.
* Windows: each paired phone whose cable connection checks out is offered a
  shell key while Remote access has something to hand out, and the key is kept
  once the phone confirms it; an unanswered grant is tried again with the Mac's
  waits. Forgetting a pairing takes its shell access with it. Remote access
  doesn't exist yet, so nothing is granted.
* Windows: which peers may reach the shell (private, Tailscale and the PC's own
  IPv6 networks; Tailscale's range only through a tunnel) and how many
  connections may wait to prove a key (16 in all, 2 per address or network, 4
  kept for addresses that proved one lately) are ported from the Mac with its
  tests. Nothing listens yet.
* Windows: the terminal logic a session needs is ported from the Mac with its
  tests: the scrollback a late attach is replayed (with the modes a full-screen
  program turned on before it), the "needs you" question heuristic, program
  status (OSC 7501, which Claude Code speaks), and telling a terminal's own
  answers from typing. Nothing runs a shell yet.
* Windows: session recording is ported from the Mac with its tests: asciicast
  transcripts with resize events, read from the end within 8 MiB, capped at
  64 MiB with a marker, pruned by age and by a 2 GiB folder cap, never touching
  a session still recording. Session ids that Windows would read as a device
  name or a path are refused.
* Windows: the session manager is ported from the Mac with its tests, over a
  pseudo-terminal seam ConPTY will fill: sessions that outlive their phone, a
  replay on attach with takeover by generation, the eight-session cap, titles
  from the first echoed command, "needs you" questions, Claude Code status, and
  revoking a phone ending what it opened. Shells come only from the PC's own
  catalog. Still nothing starts a real shell.
* Windows: real shells. Passthrough.Windows runs a session's shell in Microsoft's
  bundled ConPTY (never the inbox one, which breaks Claude Code's status), in a
  kill-on-close job so ending it ends everything it started, with the account's
  own environment. The shell catalog lists PowerShell 7, Windows PowerShell,
  Command Prompt, each WSL distribution and Git Bash from fixed paths and the
  registry, never PATH. The pseudoconsole's own start-up modes never reach a
  phone. New Windows-only tests run real sessions, in CI too.
* Windows: Passthrough's own iroh endpoint, a small Rust library over iroh 1.0.2
  (the version the phones and the Mac use) with a C ABI the app calls: a stable
  id from a stored key, accepting and dialling shell connections, address
  validation with retries, direct or relayed paths, and clean closes. Handles
  can't be forged into memory, a panic never crosses into the app, and every
  wait ends when its object is closed. Not yet listening for phones.
* Windows: the remote shell protocol, ported from the Mac with its tests: the
  phones allowed a shell (kept in the secret store; taking access away holds
  even when the store can't be written), the key proof with its handshake
  limits, and each phone's connection: open (with the chosen shell), attach and
  take over, typing, resizes, history and transcripts, lock, and what a PC
  answers to what only a Mac does. A phone that stops reading is dropped at
  8 MiB.
* Windows: Remote access. Turn it on in Settings ▸ Remote access, plug a paired
  phone in once, and it can open PowerShell, Command Prompt, WSL or Git Bash on
  this PC from anywhere (over iroh, directly or through a relay) while
  Passthrough is open. Settings lists the phones with access, with Stop (end
  their shells) and Revoke. Grants go only over a cable whose far end is Apple's
  device service or your own adb; Passthrough refuses to host shells when it
  runs as administrator. Not yet: the phones' PC wording (they still say Mac),
  the PC's own listener on the network, and the screen.
* Windows: Settings ▸ Remote access also has Keep shell history (1 week, 30
  days, 1 year or Forever; 30 days at first, 2 GB at most), Delete shell
  history, your own relay with its token, and Reset this PC's identity (a new
  address; every phone loses its access until plugged in again). The history
  folder opens only for your Windows account, and a relay token never reaches
  the log.
* Remote shell: coming back to a session no longer plays it back from the
  top. The phone holds the Mac's replay until it is complete and draws it in
  one go, keeping what was on screen meanwhile, and says "Loading session…"
  when that takes more than a moment. A replay cut short (the connection
  dropped, another device took the session) draws what arrived. The Mac says
  where a replay begins (`replaying`), so output of a session still printing
  isn't drawn twice and a second replay replaces the first. Rebuild the Mac
  app too for that last part; a new phone on an older Mac works as before it.
  iPhone, iPad and Android. Not yet tried on devices.
* Screen view: the on-screen keyboard works as it does elsewhere on the iPhone
  and iPad. Holding delete goes on deleting (it deleted one character), and
  the keyboard's own dictation key is there. The view is a text input now:
  the keyboard edits a short record of what you typed, and each change is
  typed on the Mac. So a double space makes a period, a long hold on delete
  takes a word at a time, and Chinese, Japanese and similar keyboards send
  text once a candidate is chosen. A click, an arrow key, a shortcut or a
  paste makes it forget what you typed, so nothing the keyboard does later
  reaches back and changes other text on the Mac.
* Screen view on iPad: the floating bar can be slid aside when it covers the
  Mac's menu bar. The arrow at its right end (or a swipe to the right along
  it) slides the whole bar off the right edge and down below the menu bar,
  until only its first button shows, as an arrow pointing back; that arrow
  (or a swipe to the left) slides it back. The arrow is a red microphone
  while the Mac hears the iPad.
* Screen view: the Mac's sound on the iPhone or iPad. *Play …'s sound here*
  in the screen view's Display menu sends what the Mac's apps play (whatever
  the Mac's volume is set to; the Mac's own speakers aren't muted by it). It
  is compressed, about 128 kb/s, sent only while something plays, and left
  out when the picture is behind. Off until chosen, then remembered.
* Screen view: *Hide …'s display* is in the Display menu now, with the other
  display settings (it was under Desktops).
* Screen view: an **fn** key in the row above the keyboard, held on the Mac
  for as long as you hold it (for push-to-talk dictation apps on the Mac).
* Screen view: typing and pasting work in Windows App (RDP) and other apps
  that read keys rather than characters, such as virtual machines. Typing
  goes as the keys of the Mac's keyboard layout (it came out as `a` for every
  key in RDP), shortcuts press ⌘, ⇧, ⌥ and ⌃ as keys of their own (⌘V did
  nothing there), and text longer than 64 characters typed or dictated on the
  phone is pasted through the Mac's clipboard. Shortcuts take the keys of the
  Mac's layout too: on AZERTY the phone's ⌘A was ⌘Q, and on Dvorak ⌘V was ⌘K.
  A paste sent while earlier typing is still going in now pastes its own text,
  not the one after it. Emoji, and other characters no key on the Mac's
  layout types, still come out as `a` in RDP and virtual machines; with a
  Japanese, Chinese or other input method selected on the Mac, typing goes as
  characters as before, so the input method doesn't compose it again.

* *This iPhone* (*This iPad* on an iPad) is its own tab, *iPhone* (*iPad*),
  replacing the row on the Mac tab.
* Turning Passthrough off on the iPhone tells its Macs and iPads first
  (`goodbye`), so an iPad says so at once; a link that only drops is still held
  two minutes for a resume.
* iPhone: opening the app no longer resizes a shell in use in a terminal window
  on the Mac.
* The pairing code's countdown ticks (it could stay at 5:00), and the power
  button's ring and the status dots no longer slide left and right; they
  hold still under Reduce Motion (the spinner still turns).
