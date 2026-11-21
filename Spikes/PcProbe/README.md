# PC Probe (throwaway spike)

Question: without an administrator, what can Passthrough learn about a PC
before it offers Remote access, and can an unprivileged program check that
the far end of a loopback connection to Remote Desktop is Windows' own
service? The answers become `RemoteDesktopProbe` and the setup rows.

It reads only and changes nothing.

```
dotnet run --project Spikes/PcProbe -c Release
```

## What it reads

Edition and build; the licence value that says whether this edition may host
Remote Desktop; how Remote Desktop is set (on, port, Network Level
Authentication, security layer, policy); the Remote Desktop service's state
and process; an X.224 connection request to `127.0.0.1` and the owner of that
connection's far end; the Remote Desktop certificate; Windows Firewall
profiles and the rules for the Remote Desktop port; the account's kind,
groups and the Hello-only setting; sleep settings; the shells installed.

## Answers, first PC (Windows 11 Pro build 26300, a local administrator account, a desktop)

* **The connection-owner check works without rights.** The row in the TCP
  table whose local port is the server's and whose remote port is ours names
  the process, and `QueryServiceStatusEx` on `TermService` names the same
  one, with no process opened. The service shares its process (type `0x30`).
* **Remote Desktop answers on loopback** and offers CredSSP (selected
  protocol 8), with Windows' own firewall rules as they were.
* **The certificate is readable by anyone**: `LocalMachine\Remote Desktop`,
  lifetime 183 days, so it is re-made about twice a year. No certificate is
  configured in the registry (`SSLCertificateSHA1Hash` absent), so the store
  is where to read it.
* **The licence value reads 1 on Pro** (`AllowRemoteConnections`). A Home PC
  still has to be read to confirm it says 0 there.
* **`ProductName` says "Windows 10 Pro" on Windows 11.** Use the build
  number (22000 or later), never the name.
* **This PC already had Remote Desktop on and open**: both "Remote Desktop -
  User Mode" rules enabled on every profile, by the owner's choice, and a
  policy key present. The plan's "refuse when open to the network" has to
  tell this apart from a Remote Desktop that Passthrough turned on itself.
* **The Hello-only setting reads 2 (on) for a local account**, which signs in
  with its password regardless. Read it together with the account kind; by
  itself it says nothing.
* **PowerShell 7 here is the Store package**: the only `pwsh.exe` is the
  alias in `%LOCALAPPDATA%\Microsoft\WindowsApps`, a folder the user can
  write to. The shell catalog has to resolve the package's real folder, not
  run the alias, and not conclude "not installed".
* **WSL lists `docker-desktop`** beside Ubuntu: the catalog has to leave out
  distros that aren't for people.
* **BitLocker's state needs an administrator** to read; the setup row can
  only be filled by the elevated step.
* Sleep: never on mains, no Modern Standby, no battery.

Still to read on other PCs: Windows Home, a Microsoft account with and
without a password, a laptop with Modern Standby.
