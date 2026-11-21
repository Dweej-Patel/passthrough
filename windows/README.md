# Passthrough for Windows

The Windows host, first stage: a tray app that finds a phone on the cable, pairs
with it and shows its live status. It does not carry internet yet. The stages
that follow are in the [roadmap](#roadmap) below.

```
windows/
  src/Passthrough.Core/            net10.0, all the logic, no Windows APIs
  src/Passthrough.Windows/         what only Windows does: ConPTY, iroh, pipes, the Service Control Manager, the firewall
  src/Passthrough.Service/         Remote access's background service, and its install, update, off and remove verbs
  src/Passthrough.App/             WinUI 3 tray app, unpackaged, x64
  native/iroh-bridge/              Rust: Passthrough's iroh endpoint as a C ABI
  tests/Passthrough.Core.Tests/    xUnit, any OS
  tests/Passthrough.Windows.Tests/ xUnit, Windows only
  tests/install-round-trip.ps1     installs and removes the service (changes the PC; CI runs it)
```

## Roadmap

The Windows host is built in seven projects, in this order; each gets its own
design and plan when it starts.

1. **Foundation** (this stage): the solution, Core and its tests, phones over USB, pairing, the control channel, the tray app.
2. **Remote shell from anywhere**: ConPTY sessions, the TLS listener, the built-in iroh endpoint, shell grants over the cable, session recording.
3. **Screen**: Desktop Duplication capture, H.264/HEVC through Media Foundation, input injection, sound and microphone.
4. **Internet through the phone**: a LocalSystem service, Wintun, hev-socks5-tunnel, routes and DNS, the SOCKS forwarder, top apps, the flow map.
5. **Wireless link**.
6. **VPN layer and kill switch**: WireGuard and OpenVPN, with the Windows Filtering Platform in place of pf.
7. **The rest**: keep-awake, notifications, terminals started on the PC shown on the phone, and anything still left.

## Build

On Windows 10 1809 or later, with the .NET 10 SDK:

```
dotnet build windows/src/Passthrough.App -c Release
```

Remote access from anywhere also needs `passthrough_iroh.dll`, Passthrough's
iroh endpoint, built from `windows/native/iroh-bridge` (Rust). Install Rust with
rustup (https://rustup.rs; it needs the MSVC build tools, which Visual Studio's
C++ workload installs), then:

```
windows/native/build-iroh-bridge.ps1
```

`rust-toolchain.toml` pins the compiler and `Cargo.lock` every crate (built with
`--locked`); the .NET build copies the DLL beside the app and the tests once it
exists. The bridge pins iroh 1.0.2, the version iroh-ffi 1.1.0 (the phones' and
the Mac's) locks.

The app is a plain exe, with no installer or MSIX:
`windows\src\Passthrough.App\bin\Release\net10.0-windows10.0.19041.0\win-x64\Passthrough.exe`.
Building the solution, or passing `-p:Platform=x64`, puts it under
`bin\x64\Release\...` instead.

The Windows App SDK ships beside the exe, but .NET does not: the PC that runs
it also needs the .NET 10 Desktop Runtime (x64). To copy the app to a PC
without it, publish it self-contained instead:

```
dotnet publish windows/src/Passthrough.App -c Release --self-contained
```

Remote access's background service can only be installed from a
self-contained build, because a service account can't use a .NET installed in
one user's profile. Build one folder with the app, the service and the iroh
bridge, and `files.json` (every file's size and SHA-256), with:

```
scripts/build-windows.ps1
```

It lands in `windows/artifacts/Passthrough` (about 320 MB). Run
`Passthrough.Service.exe --install` from there in an administrator's prompt
(the Remote access switch runs it for you once the service holds the phones,
later in stage 4): it copies exactly those files into `C:\Program Files\Passthrough`, makes
the service, its folders and firewall rules, and starts it. From then on Start
at login and the Start menu run the installed copy.

The SDK version comes from `global.json` at the repo root (10.0.100 or any
later 10.0 feature band). Packages come only from nuget.org
(`windows/nuget.config`), and each project's versions and content hashes are
pinned in its `packages.lock.json`; CI restores with `--locked-mode`, so a
build fails rather than pick up a package that changed. To change a package:
edit its version in the `.csproj`, run
`dotnet restore windows/Passthrough.Windows.sln --force-evaluate`, and commit
the updated `packages.lock.json` in the same PR.

To work on it in Visual Studio, use Visual Studio 2026 (18.0 or later) with
the WinUI application development workload, and open
`windows/Passthrough.Windows.sln`. Visual Studio 2022 can't target .NET 10.

## Test

```
dotnet test windows/tests/Passthrough.Core.Tests
```

This runs anywhere, macOS included: Core has no Windows dependency, and the
tests use fakes for sockets, processes and time. The app itself builds only on
Windows (WinUI 3).

```
dotnet test windows/tests/Passthrough.Windows.Tests
```

Windows only, and not as administrator: real sessions in the bundled
pseudoconsole (Microsoft.Windows.Console.ConPTY, whose `conpty.dll` and
`x64\OpenConsole.exe` are copied beside the app and the tests), the job object
that ends what a shell started, the shell catalog on this PC, and the session
manager over them (titles, questions, Claude Code's status). The iroh tests
need the bridge built first.

## First things to try on a real PC

The app has not been built or run yet; the Core tests are all that have run.
In this order:

1. **It builds.** Fix whatever the XAML compiler or NuGet restore reports; the
   package versions in `Passthrough.App.csproj` were restored on a Mac but never
   built against. The C# was compiled on a Mac with the XAML left out, so look
   first at the `x:Bind` code the XAML compiler generates.
2. **It starts, or says why not.** The log starts with a line naming the app,
   Windows and .NET versions, then where adb was found. Make startup fail (for
   example, rename `Assets\app.ico`): a message box should name the error and
   the process should end, so a second launch works once it is fixed. A crash
   inside native code never reaches the app and can't be shown this way.
3. **Apple Devices.** Install it from the Microsoft Store. Plug in an iPhone:
   it should appear in the flyout as "iPhone" with the start of its UDID.
   Uninstall Apple Devices, or stop Apple Mobile Device Service: with no
   Android phone paired or plugged in, the flyout should say to install or
   open it; either way, Android should keep working.
4. **adb.** Start with no `adb.exe` anywhere: with no iPhone paired or plugged
   in, the flyout should say to install platform-tools. Put `adb.exe` in one
   place the locator looks: within 30 seconds, without a restart, the app
   should find it and the log should name the path. Then try the other places
   one at a time (`ANDROID_HOME\platform-tools`,
   `ANDROID_SDK_ROOT\platform-tools`,
   `%LOCALAPPDATA%\Android\Sdk\platform-tools`, a `PATH` entry). adb is looked
   for again only when the watcher retries or restarts, not while it is
   tracking phones, so after each move turn Android support off and on in
   Settings (or restart the app), then check that the log names the new path.
5. **Secret store.** Pair a phone, quit, start again: it is still paired.
   In `%LOCALAPPDATA%\Passthrough\secrets`, check that only your user has
   access (Properties > Security) and that the `.bin` files are not readable
   text. Forget the phone in Settings: its file goes.
6. **Tray and flyout.** The icon appears; left-click opens the flyout above the
   taskbar at the right size, on a scaled display and on a second monitor;
   clicking the icon again closes it; clicking elsewhere hides it; right-click
   shows Settings... and Quit; a second launch does nothing. In Task Manager,
   Passthrough must not show the green Efficiency mode leaf. Known gap to check:
   the flyout goes to the monitor under the mouse, so opening it from the
   keyboard (Win+B, then Enter on the icon) with the mouse resting on another
   monitor may open it there; if so, place it by the icon's own rectangle
   (`Shell_NotifyIconGetRect`) instead.
7. **Pairing end to end** with an iPhone and with an Android phone: type the
   code (Enter works, and so does a pasted "123 456"), see Paired, see the
   status line and connection counts update, unplug and replug, and see it
   reconnect. Try it with both phones attached. With Passthrough closed on the
   phone, the row should say so while the PC keeps trying.
8. **Settings.** Android support off hides Android phones. Start at login adds
   and removes the `Passthrough` value under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`; move the exe and start
   it, and the value follows it. Paired phones lists every pairing, attached or
   not, with the phone's name once it has connected; Forget pairing asks first.
9. **A damaged settings file.** Quit, put a few bad characters at the end of
   `settings.json`, start again: the flyout should say it was reset and the
   file should be kept as `settings.json.bad`. Because the client id is still
   in the damaged text, paired phones should stay paired, also after quitting
   and starting once more. With the client id gone too, the flyout should say
   phones may need to pair again.
10. **Quit** ends the process within a few seconds, even with a phone attached.

Problems the app reports go to `%LOCALAPPDATA%\Passthrough\passthrough.log`
(moved to `passthrough.log.1` when it passes 1 MB).
