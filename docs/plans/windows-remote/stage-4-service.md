# Stage 4: The service

## Goal and done-when

A Windows service, `PassthroughService`, takes over everything that faces the network: the handshake limits, the key proof, the access store, the iroh endpoint, and a new TLS 1.3 listener on port 7893 with DNS-SD for the same network and Tailscale. It starts at boot, so a signed-out PC answers. It never runs a shell: shells stay in the tray app (one per signed-in account), which the service reaches over a named pipe. Install, update, turn off and remove each sit behind one UAC prompt. The service holds a power request while a phone is connected, offers *Stay awake while plugged in*, and tells phones why it is going away.

Done when:

1. Everything stage 3 did still works (shell from iPhone and Android over iroh, direct and relayed; reattach after a dropped connection; revoke and forget end live connections; no key in any log).
2. A phone on the same Wi-Fi, and one on Tailscale, connects over TLS 1.3 on port 7893 after its next cable connection; a phone that has not been plugged in since the update keeps working over the built-in connection with its old key.
3. After `shutdown /r` with nobody signed in, a phone connects and `open` is answered `signed_out`.
4. A second Windows account's program cannot read the pipe, cannot create it first, and cannot register or list the first account's phones; a client in session 0 or an elevated client is refused.
5. `--install`, `--update`, `--off` and `--remove` each run behind one prompt, and `--remove` leaves no service, rule, folder, registry value or Start menu entry behind.
6. The pipe tests (version mismatch, tray crash mid-attach, back-pressure, wrong account) and the CI install round trip pass on `windows-latest`.

## What exists today (verified, with path:line)

The tree on `windows-remote-spikes` holds stage 1 of the Windows host only. Stages 1 to 3 of the master plan are not in it, so everything this stage takes from them is listed under *Interfaces ▸ consumes* as an assumption about their plans.

- **Projects**: `windows/src/Passthrough.Core` (net10.0, no Windows APIs), `windows/src/Passthrough.App` (WinUI 3, unpackaged, x64) and `windows/tests/Passthrough.Core.Tests` (`windows/README.md:8-12`; `Passthrough.App.csproj:4,10,21-23`). No `Passthrough.Windows`, `Passthrough.Service` or `native/` yet. `.github/workflows/ci.yml` has no Windows or `dotnet` job.
- **Single instance**: `App.OnLaunched` takes `Local\Passthrough.App`, a per-session mutex, and a second launch exits (`App.xaml.cs:57-65`). One tray app per signed-in session is therefore already the rule.
- **Startup order**: log line, settings in `%LOCALAPPDATA%\Passthrough\settings.json`, `RepairStartAtLogin()`, `DpapiSecretStore` in `…\secrets`, watchers, `HostSession`, tray icon, flyout, `StartAsync` (`App.xaml.cs:67-110`). A failed start shows a message box and exits (`App.xaml.cs:119-126`).
- **Quit** has no dialog: `Quit()` calls `ShutDownAsync()`, which waits 3 s for the session and exits (`App.xaml.cs:160-202`).
- **Start at login**: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `Passthrough`, the quoted path of the running exe (`StartupRegistration.cs:12-13,18-30`; `StartAtLogin.cs:10`). At every launch an enabled entry that points at another exe is re-pointed at the running one (`StartupRegistration.cs:33-39`; `StartAtLogin.cs:25-26`; `App.xaml.cs:129-139`). After this stage that rule would move the entry away from the installed copy whenever a build is run from elsewhere, so it changes (below).
- **Secrets**: `DpapiSecretStore` writes one file per slot, `ProtectedData.Protect(…, DataProtectionScope.CurrentUser)`, temp file then `File.Move` (`DpapiSecretStore.cs:34-44`), in a folder whose ACL is one full-control rule for the current user, inheritance cut (`DpapiSecretStore.cs:93-104`). File name and contents come from Core's `SecretFile` (`SecretFile.cs:15-20`); the interface is `ISecretStore` (`ISecretStore.cs:4-16`).
- **Log**: `%LOCALAPPDATA%\Passthrough\passthrough.log` through Core's `LogBook` (`LogFile.cs:7-12`; `AppFolder.cs:6-7`). `LogText.Redact` knows only 43-character tokens (`LogText.cs:12-14`); the master plan has stage 3 teach it 44-character keys and relay tokens.
- **The manifest** asks for no execution level, so the app runs as invoker (`windows/src/Passthrough.App/app.manifest`).
- **The host's name** given to `HostSession` is `Environment.MachineName` (`App.xaml.cs:96`), the NetBIOS name: upper case, at most 15 characters.
- **Control envelope** already carries the grant's fields: `shellGrant`, `shellGranted`, `certSHA256`, `shellKey`, `shellPort`, `addresses`, `macName`, `irohID`, `irohRelay`, `relayToken`, `grantID` (`ControlEnvelope.cs:20-21,56-68`).
- **The .NET runtime**: the app is framework-dependent unless published with `--self-contained` (`windows/README.md:40-46`). The owner's PC has .NET only in the user profile (BRIEF), which a service account cannot use.

What this stage ports, on the Mac:

- **Framing to copy**: `LocalTerminalWire`: one byte of kind, a big-endian UInt32 length, the payload; 1 MiB payload limit; output chunks of 65 536; a parser that skips kinds it does not know (`LocalTerminalWire.swift:7-9,12-14,99-105,130-152`).
- **Certificate**: `CertificateDER` writes a v3 certificate with a 16-byte serial whose first byte is forced positive with no leading zero, `ecdsa-with-SHA256`, issuer and subject `CN` as a UTF8String, UTCTime validity from one day back to 20 × 365 days ahead, a P-256 `SubjectPublicKeyInfo`, no extensions (`MacIdentity.swift:101-120,150-156`); common name "Passthrough Mac" (`MacIdentity.swift:83`); the pin is lowercase hex SHA-256 of the DER (`MacIdentity.swift:16-20`). Only a missing identity is replaced; any other key-store error is thrown, because a new one changes what every phone pins (`MacIdentity.swift:31-42`).
- **TLS parameters**: TLS 1.3 minimum, the local identity, TCP no-delay, keepalive with 10 s idle (`WirelessListener.swift:140-152`). No ALPN.
- **Accept path**: the peer's address, then the address it arrived on, then `peerAllowed`, `arrivalAllowed`, a limiter slot, and only then the handshake (`ShellListener.swift:295-311`); a connection whose arrival address is not yet known waits for it (`ShellListener.swift:313-345`). The listener advertises `_passthrough-sh._tcp` under the default instance name, the computer's name (`ShellListener.swift:232`), and phones dial the browse result whose name equals the grant's `macName` (`ShellCredentials.swift:36-38`).
- **Gate**: slot before stream (`ShellListener.swift:484-496`), challenge, 4096-byte proof line, two keys always checked (`ShellListener.swift:524-583`), `ready` then `macInfo`, state, sessions (`ShellListener.swift:733-745`), `disconnect(phoneID:)` closing connections and then the sessions that phone opened (`ShellListener.swift:619-626`), 8 MiB send backlog (`ShellListener.swift:681,1266-1272`).
- **Limiter**: 16 slots, 2 per host, 4 kept for addresses proven in the last 30 days, at most 256 remembered, a file store written off the queue (`HandshakeLimiter.swift:15-22,98-110,196-247`); over iroh, 8 for relayed attempts under one bucket (`IrohShellListener.swift:20-22`).
- **Address policy**: ranges and the overlay rule (`ShellProtocol.swift:457-577`; `protocol/README.md:819-835`). The Mac's definition of a tunnel is "point-to-point and named `utun…`" (`ShellProtocol.swift:491-493`), which has no meaning on Windows. On-link prefixes leave out point-to-point and loopback interfaces and prefixes longer than /64 (`LocalAddresses.swift:79-85`).
- **Access store**: `ShellPhone` and `ShellAccessStore`: one JSON list per secret slot (`shell.phones`, `shell.screenPasses`), answered from memory, `previousKey` kept until the phone proves the new key, a pairing slot that must match, revocation that fails closed (`ShellAccessStore.swift:7-45,65-66,135-170,306-323,386-421`).
- **What changes a grant**: certificate hash, port, host name, iroh id, relay, token (`MacSessionPolicy.swift:54-56`); the name is cut to 64 characters on the phone (`ControlServer.swift:245`).

## Design

### 1. Projects

| Project | Target | Holds |
|---|---|---|
| `Passthrough.Core` | net10.0 | New folders `Pipe/` (framing, codec, the two proxies), `Setup/` (the step engine and plans, behind interfaces), `Shell/Identity/CertificateDer`, `Shell/AdapterFacts` (pure tunnel classification), `Shell/AccessDirectory`, `Shell/GoingAway`. No Windows API. |
| `Passthrough.Windows` (new) | net10.0-windows | P/Invoke and COM only: named pipes, token reads, service control, CNG key, `SslStream` listener, DNS-SD, `GetAdaptersAddresses`, power requests, firewall, registry, file security. Referenced by the service and the app. |
| `Passthrough.Service` (new) | net10.0-windows, win-x64, console exe `Passthrough.Service.exe` | The service host and the elevated verbs. No WinUI. |
| `Passthrough.App` | unchanged target | Pipe client, hand-over, UI changes. |
| `Passthrough.Windows.Tests` (new) | net10.0-windows | Tests that need Windows; run on `windows-latest` only. |

`Passthrough.Service.exe` has no hosting package: `Passthrough.Windows/ServiceHost.cs` calls `StartServiceCtrlDispatcher` and `RegisterServiceCtrlHandlerEx` itself, because `ServiceBase` does not deliver `SERVICE_CONTROL_PRESHUTDOWN`, which section 5 needs.

**One build layout.** `scripts/build-windows.ps1` publishes the app self-contained for win-x64 into `windows/artifacts/Passthrough/`, with `Passthrough.Service.exe`, its files and the iroh bridge beside `Passthrough.exe`, and writes `files.json` there: every file's relative path, size and SHA-256. Install copies exactly the files `files.json` lists.

### 2. The service's identity and registration

| Property | Value |
|---|---|
| Service name | `PassthroughService` |
| Display name | `Passthrough Remote Access` |
| Description | `Lets phones you have allowed reach this PC. Turn it off in Passthrough's settings.` |
| Type | `SERVICE_WIN32_OWN_PROCESS` (0x10) |
| Start type | `SERVICE_AUTO_START` (2), not delayed: a restarted PC should answer as soon as the network is up |
| Error control | `SERVICE_ERROR_NORMAL` |
| Account | the virtual account `NT SERVICE\PassthroughService`, no password |
| Service SID | `S-1-5-80-4278898763-3377807445-3347082863-1725487610-3689323215` (SHA-1 of the upper-cased name in UTF-16LE, five little-endian DWORDs; `Core/Setup/ServiceSid.For(name)` computes it, tested against TrustedInstaller's known SID) |
| SID type | `SERVICE_SID_TYPE_RESTRICTED` (3): a write-restricted token |
| Required privileges | `SeChangeNotifyPrivilege` only (`SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO`, multi-string `SeChangeNotifyPrivilege\0\0`) |
| Dependencies | `Tcpip\0KeyIso\0\0`. Not `Dnscache`: a PC with it disabled must still start the service; DNS-SD is retried instead. |
| Binary path | `"C:\Program Files\Passthrough\<folder>\Passthrough.Service.exe" --service`, always quoted |
| Recovery | `SERVICE_FAILURE_ACTIONS`: reset period 86 400 s; actions restart after 5 000 ms, restart after 30 000 ms, then none. `SERVICE_CONFIG_FAILURE_ACTIONS_FLAG` false, so only a crash counts. No command, no reboot message. |
| Pre-shutdown | `SERVICE_CONFIG_PRESHUTDOWN_INFO` 5 000 ms |
| Controls accepted | stop, pre-shutdown, power event, session change |
| Service DACL | `D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)` plus `(A;;RPLCLO;;;<SID>)` for each allowed account: query, interrogate and start, never stop or change |

The service does these things with that token and nothing more: bind TCP 7893 and iroh's UDP socket, create the pipe, read `HKLM`, read and write its own folders, use DPAPI and a CNG key in its own profile (`C:\Windows\ServiceProfiles\PassthroughService`), register a DNS-SD name, create power requests, read the adapter list. With no `SeImpersonatePrivilege`, `ImpersonateNamedPipeClient` yields an identification-level token, which is all section 4 reads.

At start the service: refuses to run if `HKLM\SOFTWARE\Passthrough\Enabled` is not 1 (exit code 1, `SERVICE_STOPPED`); checks `%ProgramData%\Passthrough` has the owner and DACL section 3 sets, and stops with a logged reason if not; opens the log; loads the access directory; creates the pipe; starts iroh if it has a key (section 6); starts the TLS listener (section 7); reports `SERVICE_RUNNING`. Listener failures never stop the service: they become setup-row states.

### 3. The elevated verbs

`Passthrough.Service.exe` run without `--service` is the only elevated code. The verbs:

| Verb | Does |
|---|---|
| `--install` | Everything below; also what **Turn on** runs after `--off`, and safe to run again (it repairs). |
| `--update` | Stop, replace, start, then every install step again, so an install made by an older build gains rules and settings a newer one needs. |
| `--off` | `Enabled=0`, stop the service, start type disabled, firewall rules disabled. Files, store and state stay. |
| `--remove` | Undo everything, in reverse. |
| `--configure <what>` | One machine-wide setting: `allow` (add the asking account), `disallow <SID>`, `relay` (URL and token read from the result pipe, never the command line), `reset-identity`. |

They take no path arguments: the source is the folder the elevated exe runs from, the destination is computed. The one extra argument on every verb is `--report <32 hex>`, the name of the result pipe.

**How the tray app launches it and learns the result**

1. The tray app creates `\\.\pipe\Passthrough.Setup.<32 hex from RandomNumberGenerator>`: inbound-and-outbound, byte mode, one instance, first-instance-only, remote clients rejected, DACL `D:P(A;;GA;;;<the user's SID>)(A;;GA;;;BA)(A;;GA;;;SY)`.
2. `ShellExecuteEx`, verb `runas`, file `<AppContext.BaseDirectory>\Passthrough.Service.exe`, parameters `--install --report <hex>` (plus `--screen` in stage 5), `SW_HIDE`, `SEE_MASK_NOCLOSEPROCESS`. `ERROR_CANCELLED` (1223) means the prompt was declined: "Nothing was changed."
3. The elevated process checks its own token is elevated and in Administrators, takes the mutex `Global\Passthrough.Setup` (a second run exits with `busy`), and opens the pipe with `SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS`, so the unelevated end cannot use its identity.
4. **Who asked** is taken from the pipe, not from an argument: `GetNamedPipeServerProcessId`, then that process's token user and session id. This matters when a standard user types an administrator's password: the elevated process then runs as the administrator, and its own SID is not the account to allow. A server in session 0 is refused.
5. The elevated process writes one JSON line per step, `{"step":"copy","state":"running|done|skipped|failed","detail":"…"}`, and a last line `{"result":"ok|failed|declined","failedStep":"…","error":"…","undone":true,"installFolder":"…","build":"…"}`. Exit code: 0 ok, 2 failed and undone, 3 failed and not fully undone, 4 refused before changing anything.
6. The tray app waits on the process handle (limit 120 s), logs every line, and shows the failing step's sentence on the *Background service* row. A process that exits with no last line is "failed, see the log".

**The step engine.** `Core/Setup/SetupPlan` is an ordered list of `ISetupStep { string Id; StepResult Apply(SetupContext); void Undo(SetupContext); }` over interfaces `IServiceControl`, `IFirewallRules`, `IMachineRegistry`, `ISecuredFiles`, `IShortcuts`. A step is idempotent: `Apply` on a machine already in the wanted state returns `skipped`. When a step fails, every step that returned `done` in this run is undone in reverse order; steps that were `skipped` are not. Each step that changes something Windows already had writes the prior value into `install.json` before changing it.

**`--install`, step by step**

| # | Step | What it does | Undo |
|---|---|---|---|
| 1 | `check` | Elevated; Windows build 17763 or later; `files.json` present and every file it lists present with the listed hash; the layout is self-contained (`coreclr.dll` is listed). A framework-dependent layout is refused: see the string in *UX states*. | nothing changed |
| 2 | `data-folder` | `CreateDirectory` on `%ProgramData%\Passthrough` with the security descriptor in the call: `O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;<service SID>)`. Then `store\` with the service's ACE widened to modify (`0x1301bf`), and `logs\` the same plus `(A;OICI;0x1200a9;;;<SID>)` for each allowed account. **If it already exists**: open it with `FILE_FLAG_OPEN_REPARSE_POINT`; refuse a reparse point; read the owner; accept only Administrators, SYSTEM or the service SID (any signed-in user can create a folder under ProgramData, so one owned by a user is treated as planted); then re-apply the DACL and check every child has an accepted owner. Anything else is refused and nothing is deleted. | delete the folder only if this run created it |
| 3 | `state` | Write `install.json` (below) with `stateVersion`, and the asking account in `allowedAccounts` (at most 4). | restore the earlier file, or delete |
| 4 | `stage` | Create `%ProgramFiles%\Passthrough` if missing, descriptor `O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1200a9;;;<service SID>)`; a pre-existing one is checked as in step 2. Create a fresh child `<build>-<8 random hex>`, never reusing a name. For each file in `files.json`: open the source denying writers, read it whole, hash it, compare with the manifest, write the destination from the same bytes. | delete the new folder |
| 5 | `verify` | Re-read every destination file and compare its hash. When the running exe carries an Authenticode signature, also require `WinVerifyTrust` to pass for every `.exe` and `.dll` with the same signer. Unsigned builds skip that and rely on the hashes (master plan, known limit 8). | as 4 |
| 6 | `service` | `CreateService` with section 2's values, or `ChangeServiceConfig` when it exists; then `ChangeServiceConfig2` for description, SID type, required privileges, failure actions, failure flag, pre-shutdown; then `SetServiceObjectSecurity`. | delete the service if this run created it, else restore the earlier binary path and start type |
| 7 | `firewall` | The rules below. | remove them |
| 8 | `public-state` | `HKLM\SOFTWARE\Passthrough` (administrators write, everyone reads): `InstallFolder`, `Build`, `PipeProtocol`, `Enabled=1`. | restore or delete the key |
| 9 | `shortcut` | `%ProgramData%\Microsoft\Windows\Start Menu\Programs\Passthrough.lnk` to the installed `Passthrough.exe`, so every account can find it. | delete it |
| 10 | `start` | `StartService`; wait up to 20 s for `SERVICE_RUNNING`; then open the pipe once and read `Welcome` as a liveness check. A service that stops reports its exit code and the last log line. | stop it |
| 11 | `tidy` | Delete install folders other than the current one. A folder still in use (another account's tray app runs from it) is queued with `MoveFileEx(…, MOVEFILE_DELAY_UNTIL_REBOOT)` and listed in `install.json` `staleFolders`. | none |

**Start at login and moving the tray app** are done by the tray app itself, unelevated, when the result is `ok`: the elevated process may be running as another account, whose `HKCU` is not the asking user's. The tray app writes the Run value as `StartAtLogin.Command(<InstallFolder>\Passthrough.exe)`, starts that copy with `--handoff <pid>`, and quits; the new copy waits for the old pid to exit before taking the mutex. The repair rule changes: while `HKLM\SOFTWARE\Passthrough\InstallFolder` is set, `RepairAtLaunch` re-points an enabled entry only at the installed copy, and a copy run from elsewhere never takes the entry. Other accounts get the same at their first launch from the Start menu: Start at login is turned on when that account first uses Remote access, and the *Start at login* switch still turns it off.

**`install.json`** (`%ProgramData%\Passthrough\install.json`; the service can read it and cannot write it):

```json
{ "stateVersion": 1, "installedAt": 1795564800, "build": "0.9.0+abc1234",
  "installFolder": "C:\\Program Files\\Passthrough\\0.9.0-1f3a9c20",
  "allowedAccounts": ["S-1-5-21-…-1001"],
  "created": { "dataFolder": true, "programFolder": true, "service": true, "shortcut": true },
  "firewallRules": ["Passthrough Remote Access (TCP-In)", "Passthrough Remote Access (UDP-In)"],
  "staleFolders": [],
  "relay": { "url": null },
  "rdp": null }
```

`rdp` is stage 5's. The relay token is not here: it is a secret and lives in the store (section 6).

**Firewall rules** (`HNetCfg.FwPolicy2`, `INetFwRule3`; COM is the source of truth, the `netsh` line is the same rule for checking by hand)

| Property | TCP rule | UDP rule |
|---|---|---|
| Name | `Passthrough Remote Access (TCP-In)` | `Passthrough Remote Access (UDP-In)` |
| Grouping | `Passthrough` | `Passthrough` |
| Direction, Action | in, allow | in, allow |
| Protocol | 6 | 17 |
| LocalPorts | `7893` | `*` (iroh binds an ephemeral port) |
| ApplicationName | the installed `Passthrough.Service.exe` | same |
| ServiceName | `PassthroughService` | `PassthroughService` |
| Profiles | all (`0x7FFFFFFF`): home Wi-Fi is often Public | all |
| RemoteAddresses | `LocalSubnet,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,fc00::/7,fe80::/10` | `*` |
| EdgeTraversal | off | off |
| Added when | Windows build 20348 or later only | always |

```
netsh advfirewall firewall add rule name="Passthrough Remote Access (TCP-In)" dir=in action=allow protocol=TCP localport=7893 program="C:\Program Files\Passthrough\<folder>\Passthrough.Service.exe" service=PassthroughService profile=any remoteip=LocalSubnet,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,fc00::/7,fe80::/10 edge=no
netsh advfirewall firewall add rule name="Passthrough Remote Access (UDP-In)" dir=in action=allow protocol=UDP program="C:\Program Files\Passthrough\<folder>\Passthrough.Service.exe" service=PassthroughService profile=any edge=no
```

The remote-address list is `ShellAddressPolicy`'s ranges (`ShellProtocol.swift:555-576`), with `LocalSubnet` covering a global IPv6 neighbour on the PC's own /64. The firewall is the outer door only; the listener applies the full policy again per connection. Before adding, every rule in the `Passthrough` group with these names is removed, so a re-run or an update (whose program path changes) leaves exactly two.

**`--update`**: check; mark `HKLM\…\Updating=1` (volatile key); stop the service (wait 20 s); steps 4 to 5 into a new folder; step 6 re-points the binary path; steps 7 to 9; clear `Updating`; step 10; step 11. If the new service does not start, the binary path, rules, shortcut and registry go back to the old folder, the old service is started, and the new folder is deleted. The tray app that asked then re-points its own Run value and hands off to the new copy, as after install.

**`--off`**: `Enabled=0` first (so the service knows why it is stopping, section 9); stop; start type `SERVICE_DISABLED`; both rules `Enabled=false`. `--install` reverses each.

**`--remove`**, in this order, each step continuing past a failure and reporting it: `Enabled=0`; stop and delete the service; remove every rule in the `Passthrough` group; stage 5's Remote Desktop restore; delete the shortcut; delete `HKLM\SOFTWARE\Passthrough`; delete `%ProgramData%\Passthrough` (store, logs, state); delete the service's CNG key (the service does this itself on a `--remove` stop, because only its account can open it: control code 200, sent before the stop); delete `%ProgramFiles%\Passthrough`, queuing what is in use for the next restart; delete `C:\Windows\ServiceProfiles\PassthroughService` if empty of anything but DPAPI and key folders. The tray app then removes its Run value if it pointed into the install folder, and says the phones' access is gone.

### 4. The pipe

**Name**: `\\.\pipe\PassthroughService`.

**Creation** (service, `CreateNamedPipeW`, not the .NET helper, so every flag is explicit):

- `dwOpenMode`: `PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED`, plus `FILE_FLAG_FIRST_PIPE_INSTANCE` on the first instance.
- `dwPipeMode`: `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS`.
- `nMaxInstances` 8; buffers 65 536 each way.
- Security descriptor: `O:<service SID>D:P(D;;GA;;;NU)(A;;GA;;;<service SID>)(A;;GA;;;SY)(A;;0x12019b;;;IU)`. `0x12019b` is read data, write data, read and write extended attributes, read and write attributes, read control and synchronize. It leaves out `0x4`, which on a pipe is `FILE_CREATE_PIPE_INSTANCE`, so a client can never add an instance of its own.
- If the first instance fails with `ERROR_ACCESS_DENIED` or `ERROR_PIPE_BUSY`, another program holds the name: the service logs it, sets the *Background service* row to a problem, and tries again every 5 s. It never opens a pipe it did not create first.

**Connecting** (tray app, `CreateFileW`, then the handle wrapped in a `NamedPipeClientStream`):

- Desired access `FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE`. Not `GENERIC_WRITE`, which maps to a mask that includes `0x4` and would be denied.
- Flags `FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`.
- `ERROR_FILE_NOT_FOUND`: the service is not running. `ERROR_PIPE_BUSY`: retry in 250 ms. Otherwise retry after 0.5, 1, 2, then every 5 s, for as long as `Enabled=1`.

**Mutual checks, before either side sends a frame**

The tray app, on the open handle: (1) `GetSecurityInfo(SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION)` must return the service SID. A program running as a user cannot set that owner, so a squatter that created the name while the service was down is caught here. (2) `GetNamedPipeServerProcessId` must equal `QueryServiceStatusEx(PassthroughService).dwProcessId` with the state running. Either failing: close, log once, show "Another program is answering for Passthrough's service." and keep retrying.

The service, per connection: `ImpersonateNamedPipeClient`, `OpenThreadToken(TOKEN_QUERY, openAsSelf: true)`, `RevertToSelf`, then from the token: user SID, session id, `TokenElevation`, integrity level. Refused, with a `Refused` frame and a close:

| Condition | `reason` |
|---|---|
| session id 0 | `session0` |
| elevated, or integrity High or above | `elevated` |
| integrity below Medium | `low_integrity` |
| SID not in `allowedAccounts` | `not_allowed` |
| that SID already has a live client that answers a ping within 2 s | `already_connected` |
| eight instances busy | `busy` |

The account and session a client is known by come only from this token. No frame carries an account. Stated as the master plan states it: any program running as an allowed account, at Medium integrity, can be that account's session host.

**Framing** (as `LocalTerminalWire.swift:7-9`): one byte of kind, a big-endian UInt32 length, the payload. Longest payload 1 048 576 bytes; a longer length closes the connection. A kind a side does not know is skipped. Payloads are UTF-8 JSON unless marked binary. Binary layouts use big-endian integers; `session` is a length byte and that many UTF-8 bytes.

**Version handshake**

| Kind | Name | Direction | Payload |
|---|---|---|---|
| `0x01` | `Hello` | tray → service, first frame, within 5 s | `{"proto":1,"minProto":1,"build":"0.9.0+abc1234","pid":4321}` |
| `0x02` | `Welcome` | service → tray | `{"proto":1,"build":"…","account":"S-1-5-21-…","session":2,"installFolder":"…"}` |
| `0x03` | `Refused` | service → tray, then close | `{"reason":"version","proto":1,"minProto":1,"build":"…"}` |

The protocol used is the lower of the two `proto` values; it is acceptable when it is at least both `minProto` values. Otherwise `Refused` `version`. `proto` goes up by one whenever a frame's meaning or layout changes; a new optional JSON field or a new kind does not need it. The tray app shows *Finish the update* when it is refused for `version`, or when it runs from outside `installFolder` and its `build` differs from the service's.

**Frames for `ISessionHost`** (the service asks, the tray app answers and reports)

| Kind | Name | Dir | Payload |
|---|---|---|---|
| `0x40` | `Open` | S→T | `{"id":7,"conn":12,"phone":"…","label":"…","shell":"pwsh"?,"cols":80,"rows":24}` |
| `0x41` | `Attach` | S→T | `{"id":8,"conn":12,"session":"…","cols":80,"rows":24}` |
| `0x42` | `Detach` | S→T | `{"conn":12}` |
| `0x43` | `Input` | S→T | binary: `conn` u32, `session`, bytes |
| `0x44` | `Resize` | S→T | binary: `conn` u32, `session`, `cols` u16, `rows` u16 |
| `0x45` | `Close` | S→T | `{"id":9,"session":"…"}` |
| `0x46` | `SetViewing` | S→T | `{"conn":12,"on":true}` |
| `0x47` | `History` | S→T | `{"id":10}` |
| `0x48` | `Transcript` | S→T | `{"id":11,"session":"…"}` |
| `0x49` | `Lock` | S→T | `{"id":12}` |
| `0x4A` | `SavePass` | S→T | `{"id":13,"pass":{…}}` |
| `0x4B` | `ConnClosed` | S→T | `{"conn":12}`: that phone connection is gone; forget it |
| `0x4C` | `PhoneGone` | S→T | `{"phone":"…"}`: revoked; end the sessions it opened (as `ShellListener.swift:619-626`) |
| `0x10` | `Reply` | T→S | `{"id":7,"session":"…"}`, `{"id":8,"generation":3}`, `{"id":10,"history":[…]}`, `{"id":9}`, or `{"id":7,"error":"too_many_sessions"}` with a `ShellError` raw value |
| `0x11` | `Sessions` | T→S | `{"sessions":[ShellSessionInfo…]}`: the whole list, sent on connect and on every change |
| `0x12` | `HostState` | T→S | `{"locked":false,"idleSeconds":14,"battery":0.8,"charging":true,"shells":[{"id":"pwsh","name":"PowerShell","default":true}],"user":"…"}`, on connect and on change |
| `0x13` | `Output` | T→S | binary: `conn` u32, `session`, bytes (at most 65 536 a frame) |
| `0x14` | `Replaying` | T→S | binary: `conn` u32, `session` |
| `0x15` | `Replayed` | T→S | binary: `conn` u32, `session` |
| `0x16` | `Ended` | T→S | binary: `conn` u32, `session`, `exitStatus` i32 |
| `0x17` | `Detached` | T→S | binary: `conn` u32, `session`, `generation` u64 |
| `0x18` | `TranscriptChunk` | T→S | binary: `id` u32, `flags` u8 (1 last, 2 failed), asciicast bytes (at most 262 144) |
| `0x19` | `DropConn` | T→S | `{"conn":12}`: the tray app's queue for it overflowed; close that phone |
| `0x1E`/`0x4E` | `Ping` | both | empty |
| `0x1F`/`0x4F` | `Pong` | both | empty |

**Frames for `IAccessAdmin`** (the tray app asks)

| Kind | Name | Dir | Payload |
|---|---|---|---|
| `0x20` | `Admin` | T→S | `{"id":3,"op":"…",…}` |
| `0x50` | `AdminReply` | S→T | `{"id":3,…}` or `{"id":3,"error":"…"}` |
| `0x51` | `AdminEvent` | S→T | `{"what":"access|connections|setup|notice",…}`: the new snapshot of that thing |

| `op` | Fields | Reply |
|---|---|---|
| `list` | | `{"devices":[{"phone":"…","label":"…","kind":"phone|viewer|computer","pairingSlot":"…","shell":true,"screen":false,"mayShare":false,"grantedAt":…,"connections":1,"viewing":false,"path":"tls|iroh|relay"}]}` |
| `grantInfo` | | `{"certSHA256":"…","port":7893,"addresses":["…"],"hostName":"…","irohID":"…"?,"irohRelay":"…"?,"relayToken":"…"?}` |
| `addKey` | `phone`, `label`, `pairingSlot`, `key` (base64, 32 bytes) | `{}`; errors `not_yours`, `store_failed`, `bad_request` |
| `setShell`, `setScreen`, `setMayShare` | `phone`, `on` | `{}`; `unknown`, `store_failed` (a failed "off" still holds in memory, as `ShellAccessStore.swift:248-267`) |
| `revoke` | `phone` | `{"removed":["…"]}` |
| `revokeSlot` | `pairingSlot` | `{"removed":[…]}` |
| `relabel` | `pairingSlot`, `label` | `{}` |
| `disconnect` | `phone`, `what`: `all` or `screen` | `{}` |
| `setup` | | `{"rows":[{"id":"service|network|anywhere|awake","state":"done|needed|optional|problem","code":"…","detail":"…"}]}` |
| `setStayAwake` | `on` | `{}` |
| `handOver` | section 6 | section 6 |

Every `op` acts only on records of the caller's account. A `phone` another account owns answers `unknown` for reads and changes, and `not_yours` for `addKey`. Relay URL and token, identity reset and the allowed accounts are not ops: they go through `--configure`.

**Correlation, order, bounds**

- `id` is a u32 chosen by the asking side, counting up from 1 per pipe connection; ids of the two directions are separate.
- The pipe is one ordered byte stream, so frames arrive in the order sent. The tray app runs the requests that name one `conn` one at a time and answers them in order. Requests for different `conn`s, and requests with no `conn`, may be answered in any order; the `id` says which. The service's `ShellConnection` still holds a phone's later lines until an `open` is answered (`ShellListener.swift:703-706`), so a phone sees its replies in request order exactly as on the Mac.
- Reply limits: `Open` 15 s, everything else 5 s. A late `Open` is answered to the phone as `bad_request` (what the Mac answers when a shell cannot start, `ShellListener.swift:1251-1255`), and the service sends `Close` for the session if a reply arrives afterwards. Three timeouts in a row drop the pipe connection.
- Each side has one writer task fed by a queue, so no caller ever waits on the pipe.
  - Tray → service: at most 8 MiB queued per `conn` and 16 MiB in all. Past the per-`conn` limit the tray app detaches that `conn`, discards its queued frames and sends `DropConn`. Past the total, the service is not reading: the tray app closes the pipe and reconnects. The ConPTY reader never blocks.
  - Service: it never stops reading the pipe. An `Output` frame is cut into `output` lines of 16 384 raw bytes (`RemoteShell.outputChunk`, `ShellProtocol.swift:24`) and put on that phone's send queue, which closes the phone at 8 MiB as today (`ShellListener.swift:681,1266-1272`) and then sends `ConnClosed`.
  - Service → tray: 4 MiB queued in all. Past it the tray app is not reading: the service drops the pipe connection.
- `Ping` after 10 s without a frame from the other side; no frame for 30 s drops the connection.

**What happens when**

| Event | Service | Tray app | Phones |
|---|---|---|---|
| Tray app crashes or quits (pipe read fails) | For that account: fails every pending request; sends `detached` with the stored generation to every phone attached to a session; sends an empty `sessions`; pushes `host`; answers `open` with `signed_out` from now on. Connections stay open. | Its sessions die with it (kill-on-close jobs, stage 3). | "Passthrough isn't open on *Office-PC*." |
| Tray app comes back | New `Welcome`; takes `Sessions` and `HostState`; pushes `host` and `sessions` to that account's phones. | Sends both snapshots first. | Shells available again; no reconnect needed. |
| Service restarts or crashes | Every phone connection is lost. On start, waits for tray apps. | Sees the pipe fail; keeps its sessions running, detaches every `conn`; reconnects with back-off; sends its snapshots. | Reconnect, attach, get the scrollback. |
| Fast user switching | Nothing changes: a disconnected session's tray app stays connected and keeps serving. | | Shells keep working while the account's session is in the background. |
| Two accounts signed in | One link per account SID. A proved phone is bound to the account that owns its record and only ever reaches that account's link. | | |
| A Windows session ends (`WTS_SESSION_LOGOFF`) | The pipe fails as in the first row; additionally `host` says the account is signed out. | | "Sign in to *Office-PC* to use its shell." |
| Session 0 or elevated client | `Refused`, close, one log line per minute at most. | An elevated tray app shows "Passthrough can't host shells when it runs as administrator." (stage 3's refusal, now also the pipe's). | |

### 5. `signed_out` and `host`

The service keeps, per allowed account: whether a tray app is linked, and whether the account has a Windows session. The second comes from the session id in each client's token, cleared by `SERVICE_CONTROL_SESSIONCHANGE` with `WTS_SESSION_LOGOFF` for that id. `open`, `attach`, `history`, `transcript`, `lock`, `close` without a link answer `signed_out` (`history` answers an empty list). `host.signedIn` is the session fact, not the link fact, so the phone can tell "nobody signed in" from "Passthrough isn't open" (see *Corrections*).

### 6. The access store in the service

**Files**

```
%ProgramData%\Passthrough\
  install.json              elevated step writes; service reads
  store\                    service modify; SYSTEM and Administrators full; nobody else
    <sha256(slot)>.bin      one per slot, SecretFile layout, DPAPI
    tls.cer                 the certificate, DER (public)
    proven-tls.json         HandshakeLimiter's proven addresses, TLS listener
    proven-iroh.json        the same, iroh listener
    settings.json           {"stayAwake":false,"irohKey":"none|adopted|generated","irohGranted":false}
  logs\service.log, service.log.1, setup.log
```

**Protection**: `ServiceSecretStore`, the same code path as `DpapiSecretStore` with two differences: `ProtectedData.Protect(…, entropy: "Passthrough.Service.store.v1"u8, DataProtectionScope.CurrentUser)` run as the service account, so only that account's DPAPI keys open it; and the write is flushed to disk (`FileStream.Flush(true)`) before the rename. Machine scope is not used: any local program could decrypt it (master plan). The folder ACL is the second lock.

**Slots**

| Slot | Holds |
|---|---|
| `shell.phones.<account SID>` | `{"v":1,"account":"<SID>","phones":[record…]}` |
| `shell.screenPasses.<account SID>` | the same shape, for `viewer.` and later `computer.` records |
| `iroh.key` | the endpoint's secret key, base64 |
| `relay.token` | the relay's token |

A blob whose inner `account` differs from the SID in its slot name is ignored and logged.

**Record** (a port of `ShellPhone`, `ShellAccessStore.swift:7-45`): `phoneID`, `label`, `pairingSlot`, `key` (base64), `previousKey`?, `grantedAt` (Unix seconds), `shell`? (stage 3's per-phone switch; absent means on), `screen`? (absent means off), `mayShare`? (absent means off), `screenOnly`?, `grantedBy`?, `viewerOf`?. There is no `control`: a PC answers `setAwake` and `setVPN` with `not_allowed`.

**`AccessDirectory`** (Core): one `AccessStore` (stage 3's port of `ShellAccessStore`) per account SID, each over its own two slots, so every fail-closed rule of the Mac's store holds per account unchanged; plus an index, phone id → owning account SID, rebuilt from the stores at start (every `shell.phones.*` slot `Slots()` lists) and updated under one lock with every write.

- **Keyed by (account SID, phone id).** The SID is the pipe client's token SID for admin ops and the index's answer for a handshake.
- **Cross-account refusal**: `addKey` or a handed-over record whose phone id the index gives to another account is refused (`not_yours`), and nothing is written. Within one account the Mac's rules apply: a different `pairingSlot` is refused, a `viewer.` or `computer.` id can never be claimed by a phone (`ShellAccessStore.swift:142-158`).
- **Handshake**: `shellKeys(phoneID)` asks the index for the owner, then that store's `candidateKeys` from memory (`ShellAccessStore.swift:306-309`): at most two keys, and the gate always checks two (`ShellListener.swift:566-583`), so an unknown phone costs the same as a wrong key. The connection is bound to (owner SID, phone id) for its whole life.
- **`previousKey`**: `addKey` for a phone that already has a record keeps `earlier.previousKey ?? earlier.key` as `previousKey` (`ShellAccessStore.swift:159-162`); `keyConfirmed` drops it once the phone proves the current key (`ShellAccessStore.swift:316-323`). Handed-over records keep both keys as they were.
- **Revoke**: the record and everything it granted go from memory first; the service closes that phone's connections, sends `PhoneGone` to the owner's tray app, and pushes an `AdminEvent`. `allowedAccounts` losing an account (through `--configure disallow`) closes its phones' connections but keeps its records until `--remove` or until the account is allowed again.

**Hand-over from stage 3** (first connect of a tray app whose own secret store still has shell records)

Assumed stage-3 names in the user's `ISecretStore`: `shell.phones`, `shell.screenPasses`, `iroh.key`; and the proven-address file in `%LOCALAPPDATA%\Passthrough`. Stage 3's plan owns those names; this section follows whatever it chose.

1. After `Welcome`, if the user's store has any of those slots, the tray app sends `Admin` `handOver`: `{"phones":[record…],"passes":[record…],"irohKey":"…"?,"proven":{"<address>":<unix seconds>}?}`. If it has none it sends `handOver` with empty lists, which is how the service learns no key is coming.
2. The service, under the directory's lock, for each record: same phone id and same `key` already stored for this account → `kept`; stored with a different key → the service's copy stays (`kept`); owned by another account → `refused`; otherwise stored as given (`taken`). The iroh key is adopted only while `settings.json` says `irohKey: none` and `irohGranted: false`; then `irohKey` becomes `adopted`. With no key offered and `irohKey: none`, the service makes its own (`generated`). `irohGranted` turns true the first time `grantInfo` returns an iroh id. So the first account to connect decides the endpoint's identity; a second account's different key is ignored and its phones reach the PC again after their next cable connection. The proven addresses are merged into `proven-iroh.json` (newest date wins, the 256 cap applies).
3. The service writes the slots and `settings.json` to disk, then answers `{"taken":[…],"kept":[…],"refused":[…],"irohAdopted":true}`. It starts the iroh endpoint when it first has a key.
4. On that answer, and only then, the tray app deletes its three slots and the proven-address file, reads each back to confirm it is gone, and logs one line. Until every one is gone it tries again at each launch.

Idempotence and failures:

| Case | Outcome |
|---|---|
| Tray app dies after step 3, before step 4 | Next connect sends the same records; all come back `kept`; the copies are deleted then. |
| Service cannot write its store | `error: store_failed`; the tray app keeps its copies and the *Background service* row shows the hand-over problem with **Try again**. Phones cannot connect meanwhile (nothing listens with those keys). |
| Service's stored list is unreadable | As the Mac: not overwritten; `store_failed`. |
| A record is `refused` | The tray app deletes its copy anyway and shows the notice in *UX states*. |
| The user's copy cannot be deleted | The keys already lived there; logged, retried at every launch, and the row says so. |
| An older build is run afterwards | It finds no records; its phones need the cable again. Stated in the changelog. |

**What phones experience.** A phone that has not been plugged in since the update: its shell key is unchanged and, when the key was adopted, so is the PC's iroh id, so the built-in connection keeps working with no action. The TLS path is new: the certificate hash, port, addresses and host name come from the service through `grantInfo`, so the grant's contents (`MacSessionPolicy.swift:54-56`) differ from what stage 3's ledger recorded, and the phone is granted again at its next cable connection. That grant has a new shell key; the old one stays as `previousKey` until the phone proves the new one. After it, the phone uses the same network or Tailscale directly.

### 7. The TLS listener

**The key.** `CngKey.Create(CngAlgorithm.ECDsaP256, "Passthrough.Service.TLS.v1", new CngKeyCreationParameters { Provider = CngProvider.MicrosoftSoftwareKeyStorageProvider, ExportPolicy = CngExportPolicies.None, KeyUsage = CngKeyUsages.Signing })`, with no machine-key option, so it is the service account's own key, persisted in its profile and not exportable. Windows' TLS runs in another process and reads the key by name; an in-memory key cannot serve.

**Load or create** (`Passthrough.Windows/ServiceIdentity`), following `MacIdentity.loadOrCreate` (`MacIdentity.swift:31-42`):

1. `CngKey.Exists` false and no `tls.cer`: create the key, build the certificate, write `tls.cer`.
2. Key exists and `tls.cer` parses and its public key equals the key's: use them.
3. Key exists, `tls.cer` missing or not matching: build a new certificate for the existing key (the pin changes; phones are granted again over the cable).
4. `CngKey.Open` fails for any reason other than "not found": throw. The key is never replaced over an error, because a new one changes what every phone pins. The *On this network* row shows it.

**The certificate.** `Core/Shell/Identity/CertificateDer`, a port of `CertificateDER` (`MacIdentity.swift:101-157`), byte for byte the same shape:

```
Certificate ::= SEQUENCE {
  tbs SEQUENCE {
    [0] { INTEGER 2 }                                   -- v3
    INTEGER serial                                      -- 16 random bytes; byte 0: &= 0x7F, |= 0x40
    SEQUENCE { OID 1.2.840.10045.4.3.2 }                -- ecdsa-with-SHA256, no parameters
    SEQUENCE { SET { SEQUENCE { OID 2.5.4.3, UTF8String "Passthrough PC" } } }   -- issuer
    SEQUENCE { UTCTime now - 86400 s, UTCTime now + 20*365*86400 s }             -- "yyMMddHHmmssZ"
    SEQUENCE { SET { SEQUENCE { OID 2.5.4.3, UTF8String "Passthrough PC" } } }   -- subject
    SEQUENCE { SEQUENCE { OID 1.2.840.10045.2.1, OID 1.2.840.10045.3.1.7 },
               BIT STRING 00 || 04 || X || Y } }
  SEQUENCE { OID 1.2.840.10045.4.3.2 }
  BIT STRING 00 || ECDSA signature, DER (r, s) }
```

`Tbs(publicPoint, commonName, serial, now)` and `Certificate(tbs, signature)` are pure. The signature is `ECDsaCng.SignData(tbs, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)`. The pin is lowercase hex SHA-256 of the DER. `CertificateRequest.CreateSelfSigned` is not used: it writes a different name encoding and time form, and the task is one shape on both hosts.

At start: `new X509Certificate2(tls.cer).CopyWithPrivateKey(new ECDsaCng(key))`. If the service-account spike shows Windows' TLS wants the certificate in a store, it is added to the service account's `CurrentUser\My` with the key's name and loaded from there; nothing else changes.

**`SslStream` options**

```csharp
new SslServerAuthenticationOptions {
    ServerCertificateContext = SslStreamCertificateContext.Create(certificate, additionalCertificates: null, offline: true),
    EnabledSslProtocols = SslProtocols.Tls13,
    ClientCertificateRequired = false,
    AllowRenegotiation = false,
    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
    EncryptionPolicy = EncryptionPolicy.RequireEncryption,
}
```

No ALPN (the Mac sets none, `WirelessListener.swift:140-152`).

**Socket**: one dual-mode IPv6 socket bound to `[::]:7893`, `ExclusiveAddressUse = true` (so no other program can bind a more specific address on the port), backlog 64. Accepted sockets: `NoDelay = true`, keepalive on, `TcpKeepAliveTime = 10`. Port in use: the listener retries every 30 s and the row says which.

**Accept loop** (a port of `ShellListener.accept`, `ShellListener.swift:295-311`). For each accepted socket, synchronously, in this order, before any `NetworkStream` or `SslStream` exists:

1. The gate is stopped → close.
2. `host` = the remote address, an IPv4-mapped one unwrapped, an IPv6 link-local one with its `%scope`. `local` = the socket's local address the same way. On Windows it is known as soon as the socket is accepted, so the Mac's `awaitArrival` (`ShellListener.swift:313-345`) has no counterpart; if reading it throws, `local` is unknown.
3. `ShellAddressPolicy.IsAllowedPeer(host, addresses, onLinkPrefixes)` false → close.
4. `ShellAddressPolicy.ArrivedOnItsNetwork(host, local, addresses)` false → close. An overlay peer with `local` unknown is refused (`ShellProtocol.swift:518-524`).
5. `gate.Admit(host, abandon: close)` returns nothing → close. This is the limiter slot (`HandshakeLimiter.swift:98-110`), with `proven-tls.json` as its store.
6. Hand the socket to a task: `SslStream.AuthenticateAsServerAsync(options, token)` where the token is cancelled when the slot's 10 s run out; then `gate.RunHandshake(admission, stream, expectHello: false)` (`ShellListener.swift:506-509`). A failed TLS handshake releases the slot.

Refused sockets are closed with linger 0. Refusals are logged without the address, at most one line a minute per reason. `addresses` and `onLinkPrefixes` come from a snapshot refreshed on `NotifyUnicastIpAddressChange` and at most every 2 s on demand, so a flood of connections does not list adapters each time.

**Windows 10.** Windows' TLS serves 1.3 only from build 20348 (`Spikes/PcProbe/Program.cs:25`). Below it the listener is not started, the TCP rule is not added, DNS-SD is not registered, and `grantInfo` returns the certificate hash and port with an empty `addresses`, so phones never dial it. The key and certificate are still made: a grant needs a pin. The row says "Needs Windows 11. Phones use the built-in connection instead."

**DNS-SD** (`dnsapi.dll`)

- `DnsServiceConstructInstance("<instance>._passthrough-sh._tcp.local", "<host>.local", null, null, 7893, 0, 0, 0, null, null)`, then `DnsServiceRegister` with `DNS_SERVICE_REGISTER_REQUEST { Version = DNS_QUERY_REQUEST_VERSION1, InterfaceIndex = 0, pServiceInstance, pRegisterCompletionCallback, unicastEnabled = FALSE }`. It returns `DNS_REQUEST_PENDING`; the callback carries the status and the instance as registered. `DnsServiceDeRegister` at stop, before sleep and before a name change.
- **Instance-name rule**: the instance name is exactly the `hostName` that `grantInfo` returns, because phones dial the browse result whose name equals the grant's name (`ShellCredentials.swift:36-38`). There is one source: `Passthrough.Windows/HostName.Current()`, `GetComputerNameEx(ComputerNamePhysicalDnsHostname)`, cut to 63 UTF-8 bytes on a character boundary. The tray app never computes it; it puts `grantInfo.hostName` in the grant's `macName`. `Environment.MachineName` (`App.xaml.cs:96`) stays only as the control channel's own name.
- If the callback's instance name differs from the one asked for (Windows renamed it after a conflict), the service deregisters and the row says phones find the PC by address.
- A registration failure (the DNS client service off, or refused to the service's token) is retried every 60 s and never stops the listener.
- A changed host name (checked at resume and every 10 minutes) re-registers; because the name is part of the grant, phones are granted again at the next cable connection, as on the Mac.

**`ILocalAddresses` on Windows.** `GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER)`, and `GetIfEntry2` per adapter for its flags, turned into pure facts:

```csharp
public sealed record AdapterFacts(string Id, string Name, int IfType, bool Up, bool HardwareInterface, bool ConnectorPresent,
                                  IReadOnlyList<(string Address, int PrefixLength, bool Preferred)> Addresses);
```

`Core/Shell/AdapterPolicy` decides, with no Windows call:

- **Tunnel interface**: `IfType` is 53 (`IF_TYPE_PROP_VIRTUAL`, what Wintun and WireGuard adapters report, so Tailscale, NetBird and Headscale clients) or 131 (`IF_TYPE_TUNNEL`), and `HardwareInterface` is false, and `ConnectorPresent` is false. Never type 6 (Ethernet, which is also what Hyper-V and WSL switches and TAP adapters report), 71 (Wi-Fi), 243 or 244 (WWAN), 24 (loopback). `LocalAddress.IsOverlayTunnel` is "on a tunnel interface and in an overlay range", replacing the Mac's "point-to-point `utun`" test (`ShellProtocol.swift:491-493`).
- **On-link prefixes**: global IPv6 addresses on adapters that are up, not tunnels, not loopback, with a prefix of /64 or shorter (`LocalAddresses.swift:79-85`).
- **Advertised addresses** (the grant and `macInfo`): `ShellAddressPolicy.Advertisable` (`ShellProtocol.swift:544-553`) over the preferred addresses of adapters that are up and are either hardware or tunnels, at most 16 (`IrohInfo.maxAddresses`, `ShellProtocol.swift:165`). That leaves out Hyper-V and WSL switch addresses, which are in private ranges but which no phone can reach.

Fixtures in `windows/tests/Passthrough.Core.Tests/Fixtures/adapters/`: Wi-Fi with Tailscale; Ethernet with a Hyper-V default switch and a WSL switch; a WWAN adapter holding a 100.64/10 address (the carrier's, not a tunnel); a TAP adapter holding one (not a tunnel); a Wintun adapter that is down.

### 8. iroh in the service

Stage 3's bridge and `IrohShellListener` port move unchanged into the service process, loaded by full path from the install folder. The endpoint's key is the `iroh.key` slot; the relay URL is `install.json` `relay.url` and the token the `relay.token` slot. Relay settings and *Reset identity* in the tray app's settings now launch `--configure relay` and `--configure reset-identity` (one prompt each); the service re-reads on control code 201. Reset identity deletes `iroh.key`, the TLS key and `tls.cer`, makes new ones, and every phone needs the cable again, as stage 3 already says for its own reset.

### 9. Power and going away

**While a phone is connected.** `PowerCreateRequest` with a `REASON_CONTEXT` of `POWER_REQUEST_CONTEXT_SIMPLE_STRING`, "A phone is connected to this PC through Passthrough."; `PowerSetRequest(handle, PowerRequestSystemRequired)` while at least one proved connection (shell or screen relay) is open, and for 60 s after the last one closes; `PowerClearRequest` then. Never `PowerRequestDisplayRequired`. The request is visible in `powercfg /requests` under the service's name.

**Stay awake while plugged in.** `settings.json` `stayAwake`, changed by the `setStayAwake` op (no prompt: it is not a security setting and any allowed account may change it). While it is on and the PC is on mains (`GetSystemPowerStatus().ACLineStatus == 1`, re-read on `PBT_APMPOWERSTATUSCHANGE`), the service holds a second request, "Stay awake while plugged in is on in Passthrough." Nothing in the power plan is edited, so there is nothing to restore.

**The row's facts.** Sleep-after for mains and battery from `PowerGetActiveScheme` and `PowerReadACValueIndex` / `PowerReadDCValueIndex` on the sleep subgroup and idle setting (`Spikes/PcProbe/Program.cs:107-119`), re-read every 60 s; whether a battery is present (`Program.cs:325-328`). `host.sleepAfter` is the value for the current power source, 0 when Stay awake holds on mains.

**Going away** (the message itself is stage 1's; this is when the service sends it). `gate.GoingAway(reason)` writes the message to every proved shell connection, waits for the writes up to the limit, then closes every connection. A connection that is a raw relay gets no message (it carries someone else's bytes) and is closed.

| Signal | Reason | Limit |
|---|---|---|
| `SERVICE_CONTROL_POWEREVENT`, `PBT_APMSUSPEND` | `sleeping` | 1.5 s (Windows gives about 2 s); DNS-SD is deregistered first |
| `SERVICE_CONTROL_PRESHUTDOWN` | `shutting_down` | 2 s, then a normal stop |
| `SERVICE_CONTROL_STOP` with `Enabled=0` (set by `--off` and `--remove` before the stop) | `turned_off` | 2 s |
| `SERVICE_CONTROL_STOP` with `Updating=1`, or any other stop | none: the phone reconnects | |
| `PBT_APMRESUMEAUTOMATIC` | | refresh addresses, re-register DNS-SD, tell iroh the network changed, re-read the power source |

**What cannot be prevented or told.** A power request stops the idle timer only. It does not stop sleep chosen by a person (Start menu, power button, closing the lid), hibernation at low battery, a restart for updates, or a Modern Standby PC on battery, which Windows lets sleep a few minutes after the screen goes off whatever is requested. A Modern Standby PC sends no suspend event, so it gives no `sleeping`. A shutdown with Fast Startup on reaches services as a suspend, so the phone is told `sleeping` for it. Power loss, a crash and a lost network give no message at all; the phone says "It may be asleep, off, or offline."

### 10. Logging

- `%ProgramData%\Passthrough\logs\service.log`, Core's `LogBook` as the app uses it (`LogFile.cs:7-12`): 1 MB, then `service.log.1`. The elevated verbs write `setup.log` in the same folder: every step, its result, every undo.
- ACL: the service modifies; SYSTEM and Administrators full; each allowed account reads, so the owner can open it from Settings without a prompt.
- Every line passes `LogText.Redact`. Beyond that, by construction: no key, proof, nonce, relay token or certificate bytes is ever formatted into a message; a phone is its label and the first 8 characters of its id; an account is the last part of its SID ("account …-1001"), never its name; a peer's address is not logged for refused connections.
- A test feeds a full handshake, a grant, a hand-over and a relay-token change through a fake log and asserts no secret's base64 or hex appears.

### 11. Setup rows after this stage

Shown in Settings ▸ Remote access. *Screen* and *Your account* arrive in stage 5.

| Row | State and text | Source |
|---|---|---|
| Background service | done: "Running." | pipe linked and `Welcome` read |
| | problem: "Didn't start: *reason*." **Try again** | `QueryServiceStatusEx`: stopped, with its exit code mapped (1069 "Windows wouldn't sign the service in"; the pipe held by another program; the data folder's owner wrong; other codes shown as a number), or the last `--install` result |
| | problem: "Remote access isn't running." **Start it** | service stopped, start type automatic; `StartService` from the tray app, no prompt |
| | needed: "Finish the update." **Update** | `Refused` `version`, or the running app's build differs from the service's and it runs from outside the install folder |
| | problem: "Couldn't move this PC's phone list into the service: *reason*." **Try again** | `handOver` error |
| | problem: "Remote access on this PC is set up for another account. An administrator can add yours." **Add this account** | `Refused` `not_allowed` |
| On this network | done: "Phones on your Wi-Fi or Tailscale reach this PC directly." | listener bound and DNS-SD registered under the host name |
| | done: "Phones on your Wi-Fi or Tailscale reach this PC by its address." | listener bound, DNS-SD failed or renamed |
| | optional: "Needs Windows 11. Phones use the built-in connection instead." | build below 20348 |
| | problem: "Port 7893 is in use by another program. Phones use the built-in connection instead." | bind failed |
| | problem: "This PC's key couldn't be opened (*code*). Phones use the built-in connection instead." | section 7, case 4 |
| From anywhere | done: "Ready, through *relay*." | iroh endpoint up, home relay known |
| | problem: "The relay isn't answering. Phones on this network still work." **Relay settings** | endpoint up, no relay for 30 s |
| Staying reachable (optional) | "This PC sleeps after 30 minutes. A sleeping PC can't answer." **Stay awake while plugged in** | section 9's facts |
| | done: "Stays awake while plugged in." | `stayAwake` on and on mains |
| | "On battery this PC sleeps after 10 minutes." | `stayAwake` on, on battery |

### 12. How the tray app's UI changes from stage 3

- **The switch.** Stage 3's Remote access switch turned the in-process host on with no prompt. It becomes the master plan's sheet (moment 2): the ticked box *Use this PC's shell*, a line "Windows will ask for an administrator once.", and **Turn on**, which launches `--install`. A standard user reads "Windows will ask for an administrator's password". Turning it off launches `--off` after the confirmation in *UX states*. A declined prompt changes nothing and says so.
- **Someone who used stage 3.** Remote access shows "Remote access needs one more step" with "It now runs as a background service, so this PC answers before you sign in. Windows will ask for an administrator once." **Finish setup**. Until then phones cannot connect: the in-process host is gone from the app (see *Decisions*).
- **Phones with access** reads from `list` and `AdminEvent`s instead of the local store; Shell, Stop, Revoke call the ops. Forget pairing (`HostSession.ForgetAsyncCore`, stage 3) calls `revokeSlot`.
- **Quit** asks when Remote access is on (wording in *UX states*). **Quit and turn off Remote access** launches `--off` first and quits only if it succeeded.
- **Finish the update** and **Service stopped**: the flyout header and tray icon follow the master plan's table row "Service stopped / older than the app"; both buttons act from the flyout except that **Update** opens Settings first, because the flyout closes when the prompt takes focus.
- **Relay settings** and **Reset identity** each cost one prompt, and the page says so beside the button.
- **Open the service's log** joins *Open the log* in Settings.
- An elevated tray app says why it will not connect.

### 13. Threading

- Service: one serial scheduler ("the gate's queue") owns the gate, every `ShellConnection` and the account links, as the Mac's single queue does (`ShellListener.swift:26-27,392-396`). Pipe readers, the TLS accept loop, TLS handshakes, store writes and COM calls run on the thread pool and post results to it. Nothing on the gate's queue waits on disk, the pipe, COM or DPAPI.
- The service control handler returns at once for everything but suspend and pre-shutdown, where it blocks for the limits in section 9.
- Tray app: the pipe client has its own reader and writer tasks; `ISessionHost` requests are dispatched to stage 3's session manager on its loop; UI updates go through the dispatcher queue as today.

## Pull requests, in order

Titles follow the repo's style (`git log`: "Windows host, foundation: …").

### PR 1. Windows service: a background service that installs, updates and removes behind one administrator prompt

- **Scope**: `Passthrough.Windows` and `Passthrough.Service` projects; `ServiceHost`; the step engine and the install, update, off, remove and configure plans; `ServiceSid`; `install.json` and the `HKLM` values; the result pipe; firewall rules (UDP only: nothing listens on TCP yet); `scripts/build-windows.ps1` and `files.json`; the Windows CI job gains the service build, `Passthrough.Windows.Tests` and the install round trip. The service starts, logs, and does nothing else. In the app: the *Background service* row and its buttons, shown only when the environment variable `PASSTHROUGH_SERVICE_PREVIEW=1` is set; the Start at login repair rule; `--handoff`.
- **Files**: `windows/src/Passthrough.Windows/**`, `windows/src/Passthrough.Service/**`, `windows/src/Passthrough.Core/Setup/**`, `windows/tests/Passthrough.Windows.Tests/**`, `windows/src/Passthrough.App/Platform/{ElevatedSetup,StartupRegistration}.cs`, `Passthrough.Core/Desktop/StartAtLogin.cs`, `SettingsWindow.xaml(.cs)`, `scripts/build-windows.ps1`, `.github/workflows/ci.yml`, the solution.
- **Tests**: step engine (order, idempotence, undo from a failure at every step, prior state recorded before change) with fakes; `ServiceSid` vectors; SDDL strings parse and deny what they should (Windows tests); Start at login rules with an install folder; the CI round trip.
- **Docs**: `windows/README.md` (projects, build script, self-contained requirement, checklist items 1 to 6 below), `SECURITY.md` (the install step, what an unsigned build means for it), `CHANGELOG.md` (not yet: preview only).
- **By hand**: set the variable; **Set up**; approve; `sc qc`, `sc qsidtype`, `sc qprivs`, `sc qfailure` show section 2's values; folders have the listed owners and ACLs; `--remove` leaves nothing; decline the prompt; run as a standard user with an administrator's password and check the standard user is the allowed account.
- **Leaves out**: the pipe, any phone traffic.

### PR 2. Windows service: the pipe between the service and the tray app, with a version handshake

- **Scope**: `Core/Pipe/` (framing, parser, codec for every frame in section 4, `PipeSessionHostServer`/`Client`, `PipeAccessAdminServer`/`Client`, queues and limits, ping); `Passthrough.Windows` pipe creation, client open, both sides' checks; the service accepts clients and answers `Welcome`/`Refused` and `setup`; the app connects (preview variable), shows *Running* or *Finish the update*; `--update`'s UI.
- **Files**: `windows/src/Passthrough.Core/Pipe/**`, `Passthrough.Windows/Pipes/**`, `Passthrough.Service/TrayLinks.cs`, `Passthrough.App/Service/ServiceLink.cs`, tests.
- **Tests**: every pipe test in *Tests* below, against fake peers over in-memory streams; Windows tests of the real pipe's flags, DACL, owner check and squatting.
- **Docs**: `SECURITY.md` (the pipe, who can be a session host), `windows/README.md` checklist item 7.
- **By hand**: connect from a second account not in the list (refused); from an elevated prompt (refused); run a newer app build against an older service and see *Finish the update*, then **Update**.
- **Leaves out**: the service still holds no phones.

### PR 3. Windows service: phones connect to the service; the access list and the built-in connection move into it

- **Scope**: `AccessDirectory`, `ServiceSecretStore`; the gate, `ShellConnection`s and the iroh listener hosted in the service with `ISessionHost` proxied over the pipe; `signed_out` and the session tracking; hand-over; `IAccessAdmin` ops; power request while connected (it belongs with connections); the app's in-process host removed, its switch, *Phones with access*, quit dialog, relay settings, reset identity and forget re-pointed; the preview variable removed.
- **Files**: `Passthrough.Core/Shell/AccessDirectory.cs`, `Passthrough.Service/**`, `Passthrough.Windows/{ServiceSecretStore,PowerRequests}.cs`, `Passthrough.App/**` (view model, settings, flyout, App.xaml.cs quit path), tests.
- **Tests**: access directory (cross-account refusal, per-account filtering, `previousKey` across hand-over, index rebuilt at start), hand-over table above case by case, `signed_out`, tray crash mid-attach end to end with a fake phone, redaction test; the existing Swift `ShellClient` against the C# host on the macOS CI job, now through the in-memory pipe.
- **Docs**: `CHANGELOG.md` ("Before you rebuild": publish self-contained; Remote access needs one administrator prompt; phones keep working over the built-in connection), `docs/GUIDE.md` §Windows, `SECURITY.md` threat model (what a compromised service can do; shared PCs), `windows/README.md` roadmap and checklist items 8 to 12.
- **By hand**: update from a stage-3 build with a phone granted and not plugged in: it connects over iroh; `%LOCALAPPDATA%\Passthrough\secrets` no longer holds the shell slots; restart with nobody signed in and see `signed_out`; second account; quit dialog.
- **Leaves out**: the TLS listener (phones use iroh only, as in stage 3).

### PR 4. Windows service: phones on the same network or Tailscale reach the PC directly

- **Scope**: `CertificateDer`, `ServiceIdentity`, the listener and accept path, `AdapterFacts`/`AdapterPolicy` and `ILocalAddresses`, `HostName`, DNS-SD, the TCP firewall rule (added by `--install` and `--update`; an existing install shows *Finish the update*), `grantInfo` returning real addresses, the *On this network* row.
- **Files**: `Passthrough.Core/Shell/{Identity/CertificateDer,AdapterFacts,AdapterPolicy}.cs`, `Passthrough.Windows/{ServiceIdentity,TlsListener,DnsSd,LocalAddresses,HostName}.cs`, fixtures, tests; a Swift test in `Packages/PassthroughCore/Tests` asserting the same certificate vector.
- **Tests**: certificate vector (fixed point, serial and time give fixed DER, the same hex in the Swift and C# suites); the certificate parses, verifies with its own key, and has no extensions; adapter fixtures; accept-path order with a fake socket source (nothing TLS is constructed for a refused peer; overlay peer on a LAN address refused; limiter full); on Windows, a loopback TLS 1.3 handshake with a persisted key and a client that pins the hash.
- **Docs**: `protocol/README.md` (address policy: the Windows tunnel definition, and that a second host now listens), `CHANGELOG.md`, guide (Windows 11 for the local path), checklist items 13 to 17.
- **By hand**: plug the phone in once; Wi-Fi off and on; Tailscale only; from another PC `Test-NetConnection <pc> -Port 7893` succeeds on the LAN and a connection from outside the listed ranges is dropped by the firewall; the phone finds the PC with addresses hidden (DNS-SD).
- **Leaves out**: Stay awake, going-away.

### PR 5. Windows service: Stay awake while plugged in, and phones are told when the PC sleeps, shuts down or is turned off

- **Scope**: the second power request and its setting; the sleep facts and row; the power, pre-shutdown and stop handlers; `gate.GoingAway`; `host.sleepAfter`.
- **Files**: `Passthrough.Core/Shell/GoingAway.cs`, `Passthrough.Windows/{PowerRequests,PowerFacts}.cs`, `Passthrough.Service/Controls.cs`, settings UI, tests.
- **Tests**: `GoingAway` writes then closes, within its limit, skipping relays (fake streams, fake time); the reason chosen for each control and registry state; Stay awake follows the power source.
- **Docs**: guide (what Stay awake can and cannot do), `CHANGELOG.md`, checklist items 18 to 21.
- **By hand**: `powercfg /requests` with and without a phone; sleep from the Start menu and read the phone's page; `shutdown /s`; turn Remote access off.
- **Leaves out**: Wake-on-LAN (later in the master plan).

## Interfaces

### This stage defines (others depend on these)

| Name | Shape | Owner |
|---|---|---|
| Pipe protocol 1 | Section 4: name, security, framing, every frame | `Passthrough.Core/Pipe`, this stage |
| `IAccessAdmin` over the pipe | The op table in section 4; stage 5 adds ops and `AdminEvent` kinds without a `proto` bump | this stage |
| `SetupPlan`, `ISetupStep`, `SetupContext` | Section 3; stage 5 appends Remote Desktop steps and a restore step | this stage |
| `install.json`, `HKLM\SOFTWARE\Passthrough` | Section 3; `rdp` is reserved for stage 5 | this stage |
| Elevated launch | `ElevatedSetup.RunAsync(verb, flags) → SetupResult` in the app; result-pipe lines | this stage |
| `AccessDirectory` | `Keys(phoneId)`, `Owner(phoneId)`, per-account `AccessStore`; screen and scope reads for stage 5 and 7 | this stage |
| `ServiceIdentity` | key name, `tls.cer`, `CertificateDer` | this stage; the wireless-link identity will reuse it (master plan) |
| `ILocalAddresses` (Windows), `AdapterPolicy` | Section 7 | this stage |
| `HostName.Current()` | the one source of the host's name | this stage |
| Session tracking | per account: linked, has a session, session id; `SERVICE_CONTROL_SESSIONCHANGE` events | this stage; stage 5 builds `host.console` on it |
| `gate.GoingAway(reason)` | Section 9 | this stage |
| Setup rows | ids `service`, `network`, `anywhere`, `awake`, with `code` values | this stage |

### This stage consumes

| From | What | Assumed shape (to be checked against that stage's plan) |
|---|---|---|
| Stage 1 | `host` message, `signed_out`, going-away message and reasons, the PC's answer table | as the master plan's *Protocol changes*; fixtures exist |
| Stage 1 | Windows CI job | exists; this stage adds projects to it |
| Stage 3 | `ISessionHost` | `Sessions` + `SessionsChanged`; `Task<string> OpenAsync(uint conn, string phoneId, string label, string? shellId, int cols, int rows)`; `Task<ulong> AttachAsync(uint conn, string session, int cols, int rows)`; `Detach(conn)`, `Input(conn, session, bytes)`, `Resize(conn, session, cols, rows)`, `Task CloseAsync(session)`, `SetViewing(conn, on)`; events `Output`, `Replaying`, `Replayed`, `Ended`, `Detached(generation)`; `Task<IReadOnlyList<ShellHistoryEntry>> HistoryAsync()`; `IAsyncEnumerable<ReadOnlyMemory<byte>> TranscriptAsync(session)`; `HostState` + change event; `Lock()`; `Task<bool> SavePassAsync(pass)`. Each maps to one frame in section 4. |
| Stage 3 | `IAccessAdmin` in-process | the same operations as the op table |
| Stage 3 | Core ports | `ShellGate`, `ShellConnection`, `ScreenViewLimit`, `HandshakeLimiter` + `FileProvenAddressStore`, `ShellAddressPolicy` (with a platform-neutral "is a tunnel" input), `AccessStore`, `ShellReach`, `IrohShellListener`, `ShellGrantLedger` |
| Stage 3 | iroh bridge | the native library and its C# wrapper, loadable from any process by full path |
| Stage 3 | Secret slot names in the user's store | `shell.phones`, `shell.screenPasses`, `iroh.key` |
| Stage 3 | `LogText.Redact` knowing 44-character keys and relay tokens | master plan |
| Stage 0 | The service-account spike's answers | every item passes without impersonation rights |

## Tests

**`Passthrough.Core.Tests` (any OS)**

- *Pipe framing*: round trip of every frame; a frame split across reads; unknown kind skipped; a length over 1 MiB closes; binary layouts byte for byte against fixed vectors.
- *Pipe handshake*: equal versions; app newer within range; `minProto` above the peer's `proto` gives `Refused` `version` both ways; no `Hello` in 5 s closes; a frame before `Welcome` closes.
- *Pipe peers* (fake `IPipePeer` with SID, session, elevation, integrity): session 0, elevated, low integrity, not allowed, already connected, replaced when the first does not answer a ping.
- *Tray crash mid-attach*: a fake phone attaches; the fake tray app's stream is cut after `Attach` and before `Reply`; the phone gets an error for the attach, then `detached` for what it had, an empty `sessions`, `host`; `open` answers `signed_out`; the tray app returns and `open` works.
- *Back-pressure*: a phone that never reads is closed at 8 MiB while a second phone's output keeps flowing and the pipe reader never waits; a tray-side queue over 8 MiB for one `conn` sends `DropConn` and keeps the others; a service that never reads makes the tray side close at 16 MiB.
- *Order*: `open`, `resize`, `input` from one phone arrive at the fake host in order; replies for one `conn` come back in order while another `conn`'s slow `Open` is pending.
- *Wrong account*: account B's ops never see or change A's phones; `addKey` for A's phone id from B gives `not_yours`; a frame cannot name an account.
- *Access directory* and *hand-over*: as PR 3.
- *Setup engine*: as PR 1.
- *Certificate*, *adapter policy*, *accept order*, *going away*, *redaction*: as PRs 3 to 5.

**`Passthrough.Windows.Tests` (`windows-latest`)**: real pipe flags and DACL; a client handle cannot create an instance; a pipe pre-created by the test under the service's name makes the service-side create fail and the client-side owner check fail; token reads at identification level; `ServiceSecretStore` round trip and unreadable-by-another-entropy; CNG key create, reopen, non-exportable; TLS 1.3 loopback; `GetAdaptersAddresses` returns facts; SDDL for folders.

**CI install round trip (`windows-latest`, which runs elevated)**: build the layout; `--install`; assert service configuration, folder owners and DACLs, rules, registry, shortcut; open the pipe as the runner's account; `--update` from a second layout; `--off`; `--install` again; `--remove`; assert nothing is left.

**Cross-implementation (macOS job)**: the Swift `ShellClient` against the C# host through an in-memory pipe pair, and the certificate vector in both suites.

**Fixtures added**: `windows/tests/Passthrough.Core.Tests/Fixtures/adapters/*.json`; pipe frame vectors; the certificate vector. None in `protocol/fixtures.json`: the pipe never leaves the PC.

**Real-PC checklist (added to `windows/README.md`)**

1. Clean PC, self-contained build: **Turn on**, one prompt, every row fills in.
2. A framework-dependent build refuses with the sentence that says what to do.
3. Standard user with an administrator's password: the standard user is the allowed account; Start at login is theirs.
4. `C:\ProgramData\Passthrough` created beforehand by a standard user: install refuses and deletes nothing.
5. `sc qc`, `qsidtype`, `qprivs`, `qfailure` match section 2; Process Explorer shows the service's token with one privilege and a write-restricted flag.
6. Kill the service twice: it restarts twice; the third time the row says it is not running and **Start it** works without a prompt.
7. Second account, not allowed: refused, **Add this account** works after a prompt. A program in the second account cannot open the first's phone list, and creating the pipe's name before the service starts is caught by the app.
8. Update from a stage-3 build with a granted phone: it connects without the cable; the user's secret folder no longer holds shell slots.
9. `shutdown /r`, nobody signs in: the phone connects and says "Sign in to *Office-PC* to use its shell."
10. Sign in: shells work with no action on the phone.
11. Fast user switching to a second account: the first account's phone still has its shells.
12. Quit with shells open: the dialog; each of its three buttons.
13. After one cable connection: the phone uses Wi-Fi directly; turn Wi-Fi off on the phone and it moves to the built-in connection and back.
14. Tailscale only (phone on cellular with Tailscale): direct.
15. A PC on a network Windows calls Public: still reachable on the LAN.
16. From another machine outside the listed ranges (a routed address): port 7893 does not answer.
17. Windows 10: the row says it needs Windows 11; the built-in connection works.
18. `powercfg /requests` lists the request only while a phone is connected (and for a minute after).
19. Stay awake while plugged in: the PC outlasts its sleep timer on mains; unplug a laptop and it sleeps.
20. Sleep from the Start menu, shut down, and turn Remote access off: the phone's page says which, each time.
21. A Modern Standby laptop: note what the phone sees; the guide's limit matches.
22. `--remove`: no service, rules, folders, registry key, shortcut or Run value; `certutil -user -key` under the service account is not needed because the key went with the service's own stop.
23. The service's log and `setup.log` hold no key, token or account name.

## Security considerations for this stage

- **The elevated step is the only code that runs as an administrator**, and it trusts the folder it was started from. With unsigned builds, a program already running as the user can change those files before the prompt is approved (master plan, known limit 8). What the step does defend: it copies from bytes it has hashed, never follows a reparse point at either root, never reuses a folder, and refuses data folders it does not own.
- **The asking account comes from a process token**, not an argument, so a program cannot name another account to be allowed.
- **A compromised service** holds every phone's key, the TLS key and the iroh key, and can ask every linked tray app to open shells: it can act as a shell for every signed-in account that uses it. It cannot read user profiles, cannot impersonate (no privilege), cannot write outside the objects that name its SID (write-restricted token), cannot change `install.json`, the allowed accounts or its own binaries.
- **The pipe**: first instance only; no client can create an instance; remote clients refused twice (flag and deny ACE); the client proves the server by owner SID and process id before sending anything, so a squatter learns nothing; the server knows a client only by its token.
- **Shared PCs**: records are keyed by the token's SID; every answer is filtered by it; a phone id belongs to one account; a phone reaches one account's tray app only. Any program running as an allowed account can be its session host and can add keys for it: that is code running as that user, outside the model, as on the Mac.
- **Before proof**: address policy and a limiter slot before any TLS object; TLS 1.3 only, no renegotiation; the firewall rule's scope is a second, coarser copy of the policy.
- **Secrets at rest**: DPAPI under the service account plus an ACL; not machine scope. The TLS key cannot be exported. The relay token never appears on a command line or in `install.json`.
- **Hand-over** moves keys from a place only the user could read to a place only the service can; the user's copies are deleted only after the service has them on disk.
- **The 27015 note** (`docs/GUIDE.md:85`) stands: stage 3's peer check on the cable is what keeps a stand-in from getting a grant; the service adds nothing to that exposure and removes none.

## UX states and strings for this stage

Setup rows: the table in section 11. Flyout and tray: the master plan's table, rows *Off*, *On, idle*, *Something failing*, *A phone has shells*, *Service stopped / older than the app*. New or stage-specific strings:

| Where | Text | Actions |
|---|---|---|
| Turn-on sheet | "Windows will ask for an administrator once." / standard user: "Windows will ask for an administrator's password." | **Turn on** |
| Prompt declined | "Nothing was changed." | |
| Framework-dependent build | "This build needs .NET installed for every account, which a background service can't count on. Build it with scripts/build-windows.ps1, then turn Remote access on from that copy." | |
| Data folder refused | "C:\ProgramData\Passthrough already exists and wasn't made by Passthrough. Remove or rename it, then try again." | **Try again** |
| Install failed | "Setting up stopped at *step*: *reason*. What it had changed was put back." (or "Some of it could not be put back; see the log.") | **Try again** · **Open the log** |
| After stage 3 | "Remote access needs one more step" / "It now runs as a background service, so this PC answers before you sign in. Windows will ask for an administrator once." | **Finish setup** |
| Turn off | "Turn off Remote access? Phones can't reach this PC until you turn it on again. Windows will ask for an administrator." | **Turn off** · **Cancel** |
| Quit, Remote access on (this stage) | "Quit Passthrough? 2 shells end. Phones can't open shells on this PC until you open Passthrough again." (stage 5 replaces the second sentence with the master plan's) | **Quit** · **Quit and turn off Remote access** · **Cancel** |
| Quit, no shells | "Quit Passthrough? Phones can't open shells on this PC until you open it again." | same |
| Stand-in on the pipe | "Another program is answering for Passthrough's service. Restart this PC; if it comes back, see the log." | **Open the log** |
| Elevated tray app | "Passthrough can't host shells when it runs as administrator. Close it and open it normally." | |
| Phone owned by another account | "*iPhone* already has access through another account on this PC, so it wasn't added here. Remove it there first." | |
| Hand-over refused a record | "*iPhone* already has access through another account on this PC, so it wasn't kept here." | **OK** |
| Relay settings, reset identity | "Changing this asks for an administrator." | |
| After reset identity | stage 3's sentence (every phone needs the cable again) | |
| Remove (Settings ▸ Remote access ▸ *Remove the background service…*) | "Remove Passthrough's background service? Every phone's access to this PC is deleted. Pairings stay." | **Remove** · **Cancel** |

Accessibility: rows are a live region and state is a word as well as a colour (master plan); every new button has an automation name; the sheet's default button is **Cancel** for Turn off and Remove.

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| A write-restricted token breaks DPAPI, the CNG key, DNS-SD or power requests | The stage-0 service-account spike, item by item. Fallback, decided here: `SERVICE_SID_TYPE_UNRESTRICTED` with the same single privilege; record which item forced it. |
| Windows' TLS will not use a key in a virtual account's profile | Same spike; fallback is the certificate in the account's `CurrentUser\My`. |
| `DnsServiceRegister` refused to the service | Not needed for function: phones dial the grant's addresses. The row says "by its address". |
| The service/tray split runs long (master plan's first named risk) | The pipe protocol and both proxies land in PR 2 against fakes before any phone traffic moves; PR 3 changes hosting only. |
| A slow or hung tray app stalls phones | Bounded queues both ways, ping, reply limits, the service never blocking on the pipe; the back-pressure tests. |
| Hand-over loses keys | Service writes and flushes before answering; the user's copies are deleted only after; every interruption case is a test. |
| A second account's different iroh key | First connect wins; the second account's phones need the cable once. Said in the guide. |
| The install leaves a half-configured machine | Per-step undo, tested from a failure at every step, and the CI round trip. |
| Self-contained layout grows the build | Measured in PR 1 and recorded in `CONTRIBUTING.md` as the Mac's sizes are. |
| The pipe name is squatted while the service is down | First-instance-only on the service; owner and process checks on the client; checklist item 7. |
| Session facts are wrong after a service restart mid-session | The service learns sessions from clients' tokens as they reconnect; until a tray app connects, that account reads as not signed in, which is the safe answer. |
| Fast Startup shutdown reported as sleep | Documented; no fix. |

## Decisions made here

1. **Virtual account `NT SERVICE\PassthroughService`, restricted SID, one privilege.** It needs no password, has its own profile for DPAPI and the key, and its SID is known before the service exists, so folders and the pipe can name it.
2. **Automatic start, not delayed; depends on `Tcpip` and `KeyIso` only.** A restarted PC should answer quickly; a disabled DNS client must not stop it.
3. **Five verbs, not three.** On/off and machine-wide settings need `--off` and `--configure` (see *Corrections*).
4. **The asking account is read from the result pipe's server process.**
5. **The tray app writes its own Start at login entry and hands off to the installed copy.** The elevated process may be another user.
6. **Self-contained only.** A service account cannot use a .NET that lives in one user's profile, as on the owner's PC.
7. **A fresh install folder per build; rules and the service path follow it.** "A fresh folder" from the master plan, applied to updates too.
8. **`HKLM\SOFTWARE\Passthrough` for what everyone may read, `install.json` for what only administrators and the service may.**
9. **Allowed accounts may start the service without a prompt; nobody but an administrator may stop or change it.** Starting something an administrator installed and left enabled is harmless, and it makes **Start it** one click.
10. **Pipe ACL names interactive users, and the token check decides.** A pipe's security is fixed by its first instance, and the allowed list changes.
11. **Explicit access masks on both ends** so no client holds the create-instance right.
12. **One phone id, one account** per PC, as the master plan says; the first to register it keeps it.
13. **The first connecting account's iroh key is adopted; later ones are ignored.**
14. **The in-process host is removed from the app in PR 3.** Two hosting paths would double what can go wrong with keys; the in-process composition lives on in tests.
15. **`host.signedIn` is the Windows session, not the pipe link** (see *Corrections*).
16. **Stay awake is a power request, not a change to the power plan**, and needs no prompt.
17. **No going-away reason for an update or a plain stop.** The phone should just reconnect.
18. **The firewall's TCP rule is added only where the listener can run.**
19. **Advertised addresses leave out virtual switches.**
20. **Own service host, no hosting package**, to receive pre-shutdown and keep dependencies down.
21. **Logs are readable by allowed accounts**, because they are redacted and the owner needs them without a prompt.
22. **`--remove` deletes the store.** Leaving keys behind after removal would be a surprise; pairings (the user's) stay.

## Corrections to the master plan

1. **Elevated verbs.** The plan names `--install`, `--remove`, `--update` as the only elevated code, and also says on/off, relay and token, identity reset and who may use the service change only through the elevated step. Those need `--off` and `--configure`.
2. **Start at login cannot be re-pointed by the install** when a standard user supplies an administrator's password: the elevated process has a different `HKCU`. The tray app does it.
3. **"Signed in" on a pipe drop.** The plan says a dropped pipe pushes `host` with `signedIn:false`. Its phone table has three different states (nobody signed in; someone else signed in; Passthrough not open). For the phone to tell them apart, `signedIn` must stay true while the account's Windows session exists, with `open` answering `signed_out`; the phone reads `signed_out` with `signedIn:true` as "Passthrough isn't open". Stage 1's fixtures and stage 2's page should use that rule, or add a field.
4. **A framework-dependent build cannot be installed.** The plan does not say the layout must be self-contained; the owner's PC shows it must.
5. **"A restricted service SID"** makes the token write-restricted, which is more than the plan's sentence suggests (it is why every folder, the pipe and the log name the service SID explicitly). It depends on the spike; the fallback is in *Risks*.
6. **Stage 3's certificate hash.** Stage 3 has no TLS listener, yet a grant must carry `certSHA256` (`ScreenPass.isUsable`, `ShellProtocol.swift:341-347`, and the phone's credential both require it). Whatever stage 3 sends there changes in this stage, which is consistent with the plan's "phones are re-granted on their next cable connection"; stage 3's plan should say what it sends.
7. **Removing the service's key** has to be done by the service itself; the elevated step cannot open another account's CNG key.

## Open questions for the owner (each with a recommended default)

1. **If the spike shows the restricted SID breaks one of DPAPI, the key, DNS-SD or power requests, fall back to an unrestricted service SID?** Recommended: yes, keeping the single privilege and the virtual account.
2. **May an allowed account start the stopped service without a prompt?** Recommended: yes.
3. **May any allowed account switch Stay awake while plugged in without a prompt?** Recommended: yes.
4. **A shared Start menu shortcut for every account on the PC?** Recommended: yes; without it a second account has no way to find the installed copy.
5. **On removal, delete every phone's access and the service's keys?** Recommended: yes, with the confirmation shown.
6. **One phone for two accounts on the same PC: keep the master plan's refusal?** Recommended: keep it.
7. **Up to how many accounts may use the service?** Recommended: 4.
