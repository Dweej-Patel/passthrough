# Passthrough for Windows

The Windows host, first stage: a tray app that finds a phone on the cable, pairs
with it and shows its live status. It does not carry internet yet. The design,
and the stages that follow, are in
[docs/superpowers/specs/2026-11-19-windows-host-design.md](../docs/superpowers/specs/2026-11-19-windows-host-design.md).

```
windows/
  src/Passthrough.Core/          net10.0, all the logic, no Windows APIs
  src/Passthrough.App/           WinUI 3 tray app, unpackaged, x64
  tests/Passthrough.Core.Tests/  xUnit
```

## Build

On Windows 10 1809 or later, with the .NET 10 SDK:

```
dotnet build windows/src/Passthrough.App -c Release
```

The app is a plain exe (`bin\x64\Release\...\Passthrough.exe`); there is no
installer or MSIX. Visual Studio 2022 with the ".NET desktop development"
workload also opens `windows/Passthrough.Windows.sln`.

## Test

```
dotnet test windows/tests/Passthrough.Core.Tests
```

This runs anywhere, macOS included: Core has no Windows dependency, and the
tests use fakes for sockets, processes and time. The app itself builds only on
Windows (WinUI 3).

## First things to try on a real PC

The app has not been built or run yet; the Core tests are all that have run.
In this order:

1. **It builds.** Fix whatever the XAML compiler or NuGet restore reports; the
   package versions in `Passthrough.App.csproj` were restored on a Mac but never
   built against.
2. **Apple Devices.** Install it from the Microsoft Store. Plug in an iPhone:
   it should appear in the flyout. Uninstall or stop Apple Devices: the flyout
   should say it is not found, and Android should keep working.
3. **adb.** Put `adb.exe` in each place the locator looks, one at a time
   (`ANDROID_HOME\platform-tools`, `ANDROID_SDK_ROOT\platform-tools`,
   `%LOCALAPPDATA%\Android\Sdk\platform-tools`, a `PATH` entry) and check the
   app finds it. With none present, the flyout should name the missing adb.
4. **Secret store.** Pair a phone, quit, start again: it is still paired.
   In `%LOCALAPPDATA%\Passthrough\secrets`, check that only your user has
   access (Properties > Security) and that the `.bin` files are not readable
   text. Forget the phone in Settings: its file goes.
5. **Tray and flyout.** The icon appears; left-click opens the flyout above the
   taskbar at the right size on a scaled display; clicking elsewhere hides it;
   right-click shows Settings... and Quit; a second launch does nothing.
6. **Pairing end to end** with an iPhone and with an Android phone: type the
   code, see Paired, see the status line and connection counts update, unplug
   and replug, and see it reconnect. Try it with both phones attached.
7. **Settings.** Android support off hides Android phones; Start at login adds
   and removes the `Passthrough` value under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`; Forget pairing asks first.

Problems the app reports go to `%LOCALAPPDATA%\Passthrough\passthrough.log`.
