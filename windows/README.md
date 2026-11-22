# Passthrough for Windows

A Windows PC as a full Passthrough computer:

- **Phones over the cable.** The tray app finds an iPhone or Android phone on USB, pairs with it and shows its status. It doesn't carry internet through the phone yet (see [Not yet](#not-yet)).
- **Remote access: this PC's shell and screen from your phones.** Shells (PowerShell, Windows PowerShell, Command Prompt, each WSL distro, Git Bash) open as you, never as administrator. The screen goes through Windows Remote Desktop, which Passthrough keeps closed to the network and relays itself. Phones reach the PC on the same network or Tailscale, and from anywhere through iroh.
- **Your computers: this PC reaching your Mac.** Once a phone hands this PC access to a Mac, the tray opens the Mac's shell in Windows Terminal and its screen in a window.
- **Sharing this PC with your Mac.** A phone gives the Mac access to this PC's shell and, once you allow it here, its screen.

```
windows/
  src/Passthrough.Core/            net10.0, all the logic, no Windows APIs
  src/Passthrough.Windows/         what only Windows does: ConPTY, TLS, DNS-SD, iroh, pipes, the firewall, Remote Desktop
  src/Passthrough.Service/         Remote access's background service, and its install, update, off and remove verbs
  src/Passthrough.App/             WinUI 3 tray app, unpackaged, x64
  src/Passthrough.Media/           Media Foundation decoding for a Mac's screen
  src/Passthrough.Term/            passthrough-term.exe: a shell on another computer, in a console
  native/iroh-bridge/              Rust: Passthrough's iroh endpoint as a C ABI
  tests/Passthrough.Core.Tests/    xUnit, any OS
  tests/Passthrough.Windows.Tests/ xUnit, Windows only
  tests/install-round-trip.ps1     installs and removes the service (changes the PC; CI runs it)
```

## What it needs

- **Windows 10 1809 or later, x64.** Snapdragon PCs run it emulated.
- **Windows 11 or Server 2022 for the same-network path.** Windows 10 has no TLS 1.3 server, so phones reach a Windows 10 PC through iroh only, which still works on the same network.
- **For the screen: Windows Pro, Enterprise or Education, and an account with a password.**
  - Windows Home has no Remote Desktop.
  - An account that signs in only with a PIN or Windows Hello needs a password added; Remote Desktop asks for the password, not the PIN.
  - Work (Entra-only) accounts aren't supported yet.
  - None of these limits apply to the shell.
- **For iPhones: Apple Devices** (Microsoft Store), which brings Apple Mobile Device Service.
- **For Android: platform-tools** (`adb.exe`), found in `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `%LOCALAPPDATA%\Android\Sdk` or `PATH`.
- **For Your computers: Windows Hello** (a PIN is enough). Access to your other computers is kept behind it. A PC without Hello can't hold it.

## Build

You build Passthrough yourself, and builds aren't signed. Install:

- the .NET 10 SDK (`global.json` takes 10.0.100 or any later 10.0 feature band);
- Rust through rustup (https://rustup.rs), which needs the MSVC build tools from Visual Studio's C++ workload.

Then, from the repo root in PowerShell:

```
windows/native/build-iroh-bridge.ps1
scripts/build-windows.ps1
```

The first command builds `passthrough_iroh.dll`, Passthrough's iroh endpoint, from `windows/native/iroh-bridge`.
- `rust-toolchain.toml` pins the compiler, and `Cargo.lock` pins every crate (built `--locked`).
- The bridge pins iroh 1.0.2, the version the phones and the Mac use.

The second command builds one self-contained folder: the tray app, the service, `passthrough-term.exe`, the iroh bridge, the bundled pseudoconsole, and `files.json` (every file's size and SHA-256).
- The output is `windows/artifacts/Passthrough` (about 420 MB), and the script prints the build's name, for example `2026.11.22.1808+bf22927`.
- It must be self-contained, because the service's account can't use a .NET installed in one user's profile.

Packages come only from nuget.org (`windows/nuget.config`). Each project's versions and content hashes are pinned in its `packages.lock.json`, and CI restores with `--locked-mode`. To change a package:
1. Edit its version in the `.csproj`.
2. Run `dotnet restore windows/Passthrough.Windows.sln --force-evaluate`.
3. Commit the updated lock file in the same PR.

To work in Visual Studio, use Visual Studio 2026 (18.0 or later) with the WinUI application development workload, and open `windows/Passthrough.Windows.sln`. Visual Studio 2022 can't target .NET 10.

> **Build where only you can write.** Setup copies whatever is in the build folder into `C:\Program Files` after you approve an administrator prompt. A second drive such as `D:\` lets every account on the PC change files by default. On a PC with other accounts, build from a folder under your own profile, for example `%USERPROFILE%\src\passthrough`, until setup checks this itself (SECURITY.md).

## Install

1. **Open the app.** Run `Passthrough.exe` from `windows/artifacts/Passthrough`. It sits in the tray: left-click opens the flyout, and right-click shows Settings… and Quit.
2. **Turn Remote access on.** Go to Settings ▸ Remote access and switch on *Use this PC's shell from your phones*. Windows asks for an administrator once. That one step:
   - copies the build into a new folder under `C:\Program Files\Passthrough`;
   - installs the background service *Passthrough Remote Access*, which runs before anyone signs in, under its own account with almost no privileges;
   - creates `C:\ProgramData\Passthrough`;
   - adds the firewall rules;
   - points Start at login and the Start menu at the installed copy.

   The copy you started then hands over to the installed one and quits.
3. **Plug each phone in once.** Unlock it, trust the PC, open Passthrough and pair with the six-digit code shown in the flyout. A phone that is paired and plugged in while Remote access is on gets shell access. Its row in Settings ▸ Remote access ▸ *Phones* then has *Screen*, *Share*, **Stop** and **Revoke…**.
4. **Set up the screen (optional).** In Settings ▸ Remote access ▸ *Screen, through Remote Desktop*, choose **Set up…**. Windows asks for an administrator once more. Passthrough then:
   - adds its own firewall rules that block Remote Desktop's port (TCP and UDP, every network profile);
   - requires Network Level Authentication;
   - adds your account to Remote Desktop Users if it needs to be;
   - turns Remote Desktop on.

   If Remote Desktop was already open to your network, Passthrough leaves it as it was; the row says so and offers **Close it to the network**.
5. **Allow the screen for a phone.** When a phone first gets access, a notice in the flyout offers **Allow screen**. You can also tick *Screen* in the phone's row under Settings ▸ Remote access ▸ *Phones*. On the phone, the first time it opens the screen, type your Windows password. The phone keeps it behind Face ID.

Each Windows account that turns Remote access on is added to the accounts the service serves. A phone only ever reaches the account that granted it.

### Update

Rebuild with `scripts/build-windows.ps1`, then in an administrator's prompt:

```
windows\artifacts\Passthrough\Passthrough.Service.exe --update
```

From Git Bash, write the path with forward slashes: `/d/…/Passthrough.Service.exe --update`. The update:
- stops the service;
- copies the new build into a fresh folder and checks every file against `files.json`;
- starts the service again.

It refuses a program or data folder that someone other than an administrator has changed. It doesn't yet check who can change the build folder: see the note under [Build](#build). Afterwards, quit Passthrough from the tray and open it from the Start menu, so the tray app runs the new build too.

### Turn off and remove

Both commands run from the installed launcher, in an administrator's prompt.

- **Turn off:** switch Remote access off in Settings. That runs `"C:\Program Files\Passthrough\Passthrough.Service.exe" --off`. Phones can't reach the PC until you turn it on again. The files, the phones' access and the settings stay.
- **Remove:** `"C:\Program Files\Passthrough\Passthrough.Service.exe" --remove` undoes everything, in reverse:
  - the service and its key;
  - the firewall rules;
  - the data folder, and the program folder when they're Passthrough's;
  - Remote Desktop as it was before Screen was set up. Passthrough turns it off again if it turned it on, and removes your account from Remote Desktop Users if it added it.

The other verbs are what Settings runs for you (`--configure screen`, `screen-close`, `screen-open`, `relay`, `reset-identity`, `allow`). Each asks for an administrator.

## Using it

**The flyout.** At the top, always in view:
- a header saying what Remote access is doing: off, reachable, needs a look (with why), or who is on the PC now ("*iPhone* has 2 shells open");
- notices that wait for you, each with its button: **Allow screen** / **Not now** for a phone or computer given access, **Revoke…** (asks first) / **OK** for a computer let in, and **Open Settings** when Remote Desktop was found open to the network;
- anyone viewing the screen, with **Stop**.

Below that, two tabs, and the flyout remembers which one you left open:
- **This PC:** the phones on the cable, with the pairing code box when one needs it, and *Stay awake while plugged in*.
- **Remote** (*Remote · 2* while two devices are on the PC):
  - a line saying who can reach this PC, which opens Settings ▸ Remote access;
  - *On this PC now*: each phone or computer connected, with shells open or viewing, and **Stop**, which ends its shells and any view and keeps its access;
  - *Your computers* (below).

The tray icon gets an amber dot, and Windows shows a notification titled with what happened, when a notice needs you. Esc closes the flyout.

**Quit** asks first when phones have shells open or Remote access is on: **Quit**, **Quit and turn off Remote access**, or **Cancel**. Quitting ends the phones' shells; the screen stays reachable while Remote access is on.

**Settings** has four pages:
- **General:** *Start at login*, *Android support*.
- **Remote access:**
  - *Use this PC's shell from your phones* turns Remote access on or off, with a line saying how phones reach the PC. The first time, *Set up the screen too* (ticked) sets up Remote Desktop behind the same administrator prompt. Where the screen can't be set up (Windows Home, another firewall), Remote access still turns on and the line says why.
  - *Screen, through Remote Desktop*: its state in one sentence, and the one button that fixes it: **Set up…**, **Turn on**, **Close it**, **Require it** or **Try again**.
  - *Stay awake while plugged in*: a PC that sleeps can't answer. While a phone is connected the PC stays awake anyway.
  - *Phones*: one row per phone paired with this PC. Each row has *Screen* (may see the screen), *Share* (may give your other computers access here), **Stop**, **Revoke…** (takes its access away; it stays paired) and **Forget…** (forgets the pairing and the access).
- **Your computers:** *Computers with access*, the computers a phone gave access to this PC. Each has **Allow screen** while its screen waits for you (**Turn off screen** once it may see it) and **Revoke…**.
- **Advanced:**
  - *Keep shell history*: what phones' shells showed, kept for you to look back at. Only your Windows account can open it. You can also delete it.
  - *Relay*: your own iroh relay and its token, or empty for the public relays.
  - *This PC's identity* ▸ **Reset…**: gives the PC a new identity, and every phone loses its access with the old one. Plug each phone in again to give it access.

**On the phone, a PC shows as a PC:**
- **New shell** lists its shells.
- The screen takes the phone's shape and turns with it.
- The key row has Windows keys, and a Windows menu has Ctrl+Alt+Del, Start, Task View and more.

While a phone views the screen, the PC's own screen shows the lock screen, and it stays locked afterwards.

**Your computers** (the flyout's Remote tab) lists the computers a phone handed this PC access to. Windows Hello asks first.
- **New shell** opens the other computer's shell in a new Windows Terminal tab, or a console window without Windows Terminal.
- **Remove…** forgets this PC's copy of that computer, after asking. Use it for a computer you no longer use, or one that changed its keys: a phone can then share it again.
- **Screen** opens a Mac's screen in a window. The keys go to the Mac: Alt acts as ⌘, Ctrl as ⌃ and the Windows key as ⌥. A setting swaps Alt and Ctrl, so Ctrl acts as ⌘. Alt+Tab, Alt+F4, screenshots and the media keys stay with this PC.

The PC's own logs:
- the tray app: `%LOCALAPPDATA%\Passthrough\passthrough.log`;
- the service: `C:\ProgramData\Passthrough\logs\service.log`;
- setup: `C:\ProgramData\Passthrough\logs\setup.log`.

The logs never hold keys, tokens or passwords, and they name accounts only by the end of their SID.

## Not yet

- Internet through the phone, the wireless link, and the VPN layer.
- Sound and the microphone, both ways.
- Pairing two computers directly. Today a phone hands one computer access to the other.
- `passthrough-term remote` from a Mac's terminal.
- A question before taking a PC someone is using.
- Notifications and the activity timeline from a PC.
- Android viewing a screen. Android phones get the PC's shell.

## Test

```
dotnet test windows/tests/Passthrough.Core.Tests
```

This runs anywhere, macOS included. Core has no Windows dependency, and the tests use fakes for sockets, processes and time.

```
dotnet test windows/tests/Passthrough.Windows.Tests
```

This is Windows only, and must not run as administrator. It covers:
- real sessions in the bundled pseudoconsole: Microsoft.Windows.Console.ConPTY, whose `conpty.dll` and `x64\OpenConsole.exe` are copied beside the app and the tests;
- the job object that ends what a shell started;
- the shell catalog on this PC;
- the iroh bridge (build it first);
- the pipes;
- setup's file checks.

`tests/install-round-trip.ps1` installs and removes the service for real. CI runs it on a fresh Windows runner. Don't run it on a PC you use.

## Checking it on a real PC

In this order, from a clean PC.

1. **Install.** Build, open the app, turn Remote access on: one administrator prompt, and the app hands over to the installed copy. `service.log` says `service: started` with the build, then `tls: listening on port 7893` (Windows 11) and `iroh: shell listener started`.
2. **Pair and grant.** Plug in an iPhone, then an Android phone. Pair each one. Each one's row under Settings ▸ Remote access ▸ *Phones* shows *Screen* and *Share*. Unplug both.
3. **Shell.** On the phone, open a shell on Wi-Fi, on Tailscale and on cellular, which goes through the relay. Check that:
   - the New shell list matches what's installed;
   - a session survives a dropped connection;
   - **Stop** in Settings ends it;
   - **Revoke** ends the phone's connections and refuses it after.
4. **Screen setup.** Choose **Set up…**. The row says "Remote Desktop is on, for Passthrough only."
   - From another machine, port 3389 must not answer, on IPv4, IPv6 or UDP.
   - Turn Windows Firewall off for one profile: the row and a notice say Remote Desktop is open to the network, and the phone is refused. Turn it back on.
5. **Screen.** Allow screen for the phone and open it. Type the password.
   - Turn the phone: the session takes the new shape, and the taskbar stays along the bottom.
   - Close the view, then check that the PC's own taskbar is still there.
   - Try it locked, signed out after a restart, with the monitor off, and with a UAC prompt up.
6. **Share with a Mac.** On the phone, share this PC with your Mac.
   - The PC shows "*iPhone* gave *MacBook* access to this PC's shell. Let it see the screen too?"
   - Allow it. The Mac opens a PC window. **Revoke…** in Settings ▸ Your computers ends it.
7. **Your computers.** Share your Mac with this PC from the phone. Then, in the flyout's Remote tab, choose *Show your computers*:
   - Windows Hello asks first;
   - **New shell** opens a Windows Terminal tab titled with the Mac's name;
   - **Screen** shows the Mac.
8. **Update and remove.**
   - `--update` keeps every phone's access.
   - `--remove` leaves no service, no firewall rule and no `C:\ProgramData\Passthrough`, and leaves Remote Desktop as it was before step 4.
