# Stage 5: The Remote Desktop relay on the PC

## Goal and done-when

The service relays an allowed phone's connection to this PC's own Remote Desktop on `127.0.0.1`, after checking that the far end is Windows' Remote Desktop service, and tells the viewer which certificate to expect. Passthrough can turn Remote Desktop on closed to the network, checks continuously that it stays closed, and treats a Remote Desktop the owner already runs open as the owner's own choice. The PC shows what it can do as setup rows, reports it in `host`, and tells the person at the PC afterwards that the screen was used. No viewer ships in this stage (stage 6); the relay is driven by a stock FreeRDP client through a small probe tool.

Done when:

1. Stock FreeRDP on another machine reaches the PC through the relay in every state in the checklist below (in use, idle, locked, signed out after a restart, monitor off, lid closed on mains, a UAC prompt, another account signed in).
2. On a PC where Passthrough turned Remote Desktop on, the Remote Desktop port does not answer from another machine over IPv4, IPv6 or UDP, while the relay works.
3. On the owner's PC, where Remote Desktop was already on and open, setup changes nothing about it, the relay works, `exposed` never fires, and removal leaves Remote Desktop exactly as it was.
4. Turning Windows Firewall off on a PC in the closed mode makes the next relay answer `rdp_unavailable` `exposed` and puts the notice up; turning it on again clears both.
5. A `viewer.` id is refused, a phone without Screen gets `screen_not_allowed`, a fifth quick open in ten minutes gets `try_later`.
6. `--remove` restores every Remote Desktop setting Passthrough changed and nothing it did not.

## What exists today (verified, with path:line)

Stage 4's service, pipe, step engine and `install.json` are assumed as its plan defines them (`stage-4-service.md`). In the tree today:

- **The hand-off to port.** A `screen` request on the Mac: access check, then a view from `ScreenViewLimit`, then `screen()` (`ShellListener.swift:924-927`). `screen()` marks the connection busy, leaves any session, asks `screenSharingVerified` off the queue with a 5 s limit, and answers `screen_unavailable` if the check is unset, false or late (`ShellListener.swift:1134-1163`). `dialScreen` dials loopback with the same 5 s limit (`ShellListener.swift:1166-1193`). `relayScreen` closes the connection if the phone sent anything after asking, builds a `Splice` with `endTogether`, reports the viewer, sends `screenReady`, and starts the splice only once that line is written (`ShellListener.swift:1195-1209`). A request that fails leaves the connection a shell connection and frees its view (`ShellListener.swift:844-853`). Closing ends the splice, reports the viewer gone and frees the view (`ShellListener.swift:781-808`).
- **Caps**: 2 views a phone, 4 in all, shared by both listeners (`ShellListener.swift:351-381`; `ShellProtocol.swift:19-20`).
- **Screen-only ids**: an id with the `viewer.` prefix is screen-only whatever else is known (`ShellListener.swift:585-589`; `ShellProtocol.swift:311-314`), and a screen-only connection may send only `screenVideo`, `ping` and `pong`: anything else, so also `screen`, is refused `screen_only` (`ShellListener.swift:859-863`).
- **Ending a phone's views** without touching its shell connections: `disconnectScreen` (`ShellListener.swift:628-632`).
- **Splice**: two pumps of up to 256 KiB, failure taken from reads and writes only, a half-close passed on before it counts, and with `endTogether` either end finishing closes both (`Splice.swift:24-27,46-81`).
- **Protocol text for `screen`**: `protocol/README.md:549-564`. `protocol/fixtures.json` has no `host`, `rdp` or `rdpReady` yet (stage 1 adds them).
- **Measured on the owner's PC** (`Spikes/PcProbe/README.md:24-55`, source `Spikes/PcProbe/Program.cs`):
  - Edition and build from the registry; `ProductName` reads "Windows 10 Pro" on Windows 11 (`Program.cs:18-25`; README:38-39).
  - Licence value `TerminalServices-RemoteConnectionManager-AllowRemoteConnections` through `SLGetWindowsInformationDWORD`: 1 on Pro; Home not yet read (`Program.cs:28-32`; README:36-37).
  - `fDenyTSConnections`, `PortNumber`, `UserAuthentication`, `SecurityLayer`, `SSLCertificateSHA1Hash`, and the policy key, all readable unprivileged (`Program.cs:41-57`). No certificate is configured, so the store is where to read it (README:32-35).
  - `TermService` state and process id through `QueryServiceStatusEx`, unprivileged; the service type is `0x30` (`Program.cs:61-66,330-348`; README:26-29).
  - Remote Desktop answers an X.224 request on loopback and selects protocol 8, CredSSP (`Program.cs:145-166`; README:30-31).
  - The owner of the far end of a loopback connection: the TCP-table row whose local port is the server's and remote port is ours (`Program.cs:168-198`), equal to `TermService`'s process, with no process opened.
  - The certificate in `LocalMachine\Remote Desktop`, readable by anyone, 183 days (`Program.cs:72-83`).
  - Firewall profiles and the rules for the port through `HNetCfg.FwPolicy2` (`Program.cs:202-223`). **Both "Remote Desktop - User Mode" rules were enabled on every profile, by the owner's choice, and a Terminal Services policy key is present** (README:40-43).
  - Account kind from `NetUserGetInfo` level 24 (`Program.cs:227-240`); local groups (`Program.cs:242-255`); the Hello-only value, which reads 2 for a local account that signs in with its password (`Program.cs:94-97`; README:44-46).
  - Sleep settings and battery (`Program.cs:107-127`).
  - BitLocker's state needs an administrator (README:53-54).

## Design

### 1. `RemoteDesktopProbe`

`Passthrough.Windows/RemoteDesktopProbe` reads; `Passthrough.Core/Screen/RemoteDesktopFacts` is the plain record it fills; `Passthrough.Core/Screen/RemoteDesktopVerdict.From(facts, state)` turns facts into rows and `host.rdp`, with no Windows call, so every case is a test on any OS.

| Fact | Source | Elevation | Read by |
|---|---|---|---|
| Build number, UBR | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` `CurrentBuildNumber`, `UBR`. **Never `ProductName`.** | no | service |
| Edition id | same key, `EditionID`; shown in the log only | no | service |
| May host Remote Desktop | `SLGetWindowsInformationDWORD("TerminalServices-RemoteConnectionManager-AllowRemoteConnections")`. 1 = yes, 0 = no. If the call fails: no when `EditionID` is `Core`, `CoreN`, `CoreSingleLanguage` or `CoreCountrySpecific`, otherwise unknown and treated as yes. | no | service |
| Remote Desktop on (local) | `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server` `fDenyTSConnections` (0 = on) | no | service |
| Policy | `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services` values `fDenyTSConnections`, `UserAuthentication`. **The key being present means nothing; only these values do.** | no | service |
| Port | `…\WinStations\RDP-Tcp` `PortNumber`, default 3389 | no | service, before every relay |
| NLA required | `RDP-Tcp` `UserAuthentication` (1), overridden by the policy value | no | service |
| Security layer | `RDP-Tcp` `SecurityLayer` | no | service |
| Configured certificate | `RDP-Tcp` `SSLCertificateSHA1Hash` (20 bytes) | no | service |
| Certificate | `LocalMachine\Remote Desktop` store, or `LocalMachine\My` for a configured one | no | service |
| Remote Desktop service | `QueryServiceStatusEx("TermService")`: state, process id; `QueryServiceConfig` start type | no | service |
| Firewall on, per profile | `HNetCfg.FwPolicy2.FirewallEnabled[1, 2, 4]` | no | service |
| Rules for the port | `FwPolicy2.Rules`: inbound, enabled, protocol, ports, profiles, action, remote addresses, `SecureFlags` | no | service |
| Group Policy rules for the port | `HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall\FirewallRules` (each value one rule as text) | no | service |
| Local rules applied | `HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall\{DomainProfile,StandardProfile,PublicProfile}` `AllowLocalPolicyMerge` (0 = ignored) | no | service |
| Who manages the firewall | `FwPolicy2.LocalPolicyModifyState`; `HNetCfg.FwProducts.Count` (a registered third-party firewall) | no | service |
| Account kind | `NetUserGetInfo` level 24: local; internet identity (a Microsoft account) with its sign-in name; error 2221 = not a local account. Then `NetGetAadJoinInformation` and `NetGetJoinInformation` for Entra-only or domain. | no | **tray app**, for its own account |
| Hello-only setting | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device` `DevicePasswordLessBuildVersion` (2 = on). **Used only when the account is a Microsoft account**: it reads 2 for a local account that signs in with its password. | no | tray app |
| In Remote Desktop Users or Administrators | `NetUserGetLocalGroups` with indirect membership, groups matched by SID (`S-1-5-32-555`, `S-1-5-32-544`), never by name (they are translated) | no | tray app |
| Account lockout threshold | `NetUserModalsGet` level 3 | no; if refused, the elevated step reads it | service |
| Remote sign-in rights | `LsaEnumerateAccountsWithUserRight` for `SeRemoteInteractiveLogonRight` and `SeDenyRemoteInteractiveLogonRight` | **yes** | elevated step, recorded |
| BitLocker asks for a PIN at start | WMI `root\CIMV2\Security\MicrosoftVolumeEncryption`, `Win32_EncryptableVolume` for the system drive: `GetProtectionStatus`, `GetKeyProtectors` (types 4, 5, 6) | **yes** | elevated step, recorded with the date |
| Sleep, battery | stage 4 | no | service |

The tray app sends its own account's facts in `HostState` (new optional fields `accountKind`, `signInName`, `helloOnly`, `inRemoteDesktopUsers`, `administrator`). The service uses them for wording and for `host.user` only, never to allow anything.

The loopback X.224 probe (`Program.cs:145-175`) is not on a timer: it runs during setup and when the *Screen* row's **Check again** is pressed, because each run leaves an entry in Windows' own log.

**From facts to the *Screen* row and `host.rdp`** (first match wins)

| Condition | `host.rdp` | Row |
|---|---|---|
| Edition may not host | `edition` | "Windows Home has no Remote Desktop. The shell works; the screen needs Windows Pro." |
| Policy turns Remote Desktop off | `off` | problem: "Remote Desktop is turned off by a policy on this PC. Passthrough can't change that; the shell still works." |
| Screen not set up (no `rdp` in `install.json`, or this account has not consented) | `off` | needed: "Not set up." **Set up…** |
| Remote Desktop off now, and Passthrough or the owner had it on | `off` | problem: "Remote Desktop was turned off in Windows Settings." **Turn on** |
| Mode *closed* and the exposure check fails | `exposed` | problem: "Remote Desktop is open to the network. Passthrough won't relay to it until that is closed." + reason line. **Close it** |
| `TermService` not running or disabled, or (mode *closed*) NLA not required | `service` | problem: "Remote Desktop isn't answering on this PC." **Try again** (starts the service through the elevated step when it is disabled) |
| The granting account is a work account (not local, Entra-joined, no domain) | `account` | see *Your account* |
| Otherwise, mode *closed* | `ready` | done: "Remote Desktop is on, for Passthrough only." |
| Otherwise, mode *owner's* | `ready` | done: "Remote Desktop is on. It was open to your network before Passthrough and still is." |
| Otherwise, mode *policy* | `ready` | done: "Remote Desktop is turned on by a policy on this PC. Passthrough uses it as it is." |

`host.screens` contains `rdp` exactly when `host.rdp` is `ready`. `host.rdp` is computed per phone, because `account` depends on who granted it.

***Your account* row** (the tray app's account)

| Condition | Row |
|---|---|
| Local account | done: "*name* can sign in with its password." |
| Microsoft account, Hello-only off | done: the same, with the sign-in name |
| Microsoft account, Hello-only on, and no relay for this account has yet lasted over 30 seconds | needed: "This account signs in with a PIN or Windows Hello only. Remote Desktop needs its password: add one, or sign in to this PC with it once." **Open sign-in options** (`ms-settings:signinoptions`). `host.rdp` stays `ready`: Passthrough cannot know, and Windows will say. |
| The same, after such a relay | done |
| Work account | problem: "Work accounts aren't supported yet." |
| Not in Remote Desktop Users or Administrators | problem: "This account isn't allowed to sign in through Remote Desktop." **Allow it** (elevated) |

A BitLocker start-up PIN adds a line under *Staying reachable*: "This PC asks for a BitLocker PIN when it starts. After a restart it can't be reached until someone types it." (as read on *date*).

### 2. The elevated Remote Desktop setup

Run by `--install --screen` (the second ticked box on the turn-on sheet) and by `--configure screen` later; steps appended to stage 4's plan. Each records what was there before it changes anything, in `install.json`:

```json
"rdp": { "mode": "closed|owner|policy", "setUpAt": 1795564800,
  "consentedBy": ["S-1-5-21-…-1001"],
  "prior": { "fDenyTSConnections": 1, "userAuthentication": 0, "termServiceStart": 3 },
  "weTurnedOn": true, "weSetNla": true, "weChangedStart": false,
  "addedToRemoteDesktopUsers": ["S-1-5-21-…-1001"],
  "blockRules": ["Passthrough: keep Remote Desktop closed (TCP-In)", "Passthrough: keep Remote Desktop closed (UDP-In)"],
  "blockedPort": 3389,
  "remoteRights": { "allowed": ["S-1-5-32-544","S-1-5-32-555"], "denied": [] },
  "bitlockerPin": false, "readAt": 1795564800 }
```

**The calls**

| Step | Call | Fallback | Undo |
|---|---|---|---|
| `rdp-on` | WMI, `winmgmts:{impersonationLevel=impersonate,authenticationLevel=pktPrivacy}!\\.\root\CIMV2\TerminalServices`, `Win32_TerminalServiceSetting.SetAllowTSConnections(AllowTSConnections: 1, ModifyFirewallException: 0)`. The second argument is what leaves Windows' firewall exception alone. Through late-bound COM, as the spike reads the firewall (`Program.cs:204-205`), so no package is added. | set `fDenyTSConnections = 0` in the registry, which also touches no rule | `SetAllowTSConnections(0, 0)`, only when `weTurnedOn` |
| `rdp-nla` | `Win32_TSGeneralSetting` where `TerminalName='RDP-Tcp'`, `SetUserAuthenticationRequired(1)` | `UserAuthentication = 1` in `RDP-Tcp` | restore `prior.userAuthentication`, only when `weSetNla` |
| `rdp-service` | if `TermService` is disabled: `ChangeServiceConfig` to demand start; then `StartService` | | restore the start type, only when `weChangedStart` |
| `rdp-users` | if the consenting account is in neither Administrators nor Remote Desktop Users: `NetLocalGroupAddMembers(null, <name of S-1-5-32-555 from LookupAccountSid>, 0, {sid}, 1)`. Error 1378 (already a member) counts as "not added by us". | | `NetLocalGroupDelMembers` for the SIDs in `addedToRemoteDesktopUsers` only |
| `rdp-block` | two `HNetCfg.FWRule` objects, below | | remove both by name |
| `rdp-facts` | the two elevated reads in section 1 | | none |

**Block rules**

| Property | TCP | UDP |
|---|---|---|
| Name | `Passthrough: keep Remote Desktop closed (TCP-In)` | `… (UDP-In)` |
| Grouping | `Passthrough` | `Passthrough` |
| Direction, Action | in, **block** | in, block |
| Protocol | 6 | 17 |
| LocalPorts | the port read now | the same |
| Profiles | all | all |
| Local and remote addresses | `*` | `*` |
| Program, service | none: whatever listens there is blocked | none |

A block rule wins over any allow rule in Windows Firewall, so Windows' own "Remote Desktop" rules are never edited. Windows Firewall does not filter loopback, which is why the relay still reaches the port; the stage-0 relay spike's pass line is exactly this.

**The three starting situations.** The elevated step decides the mode once, from what it finds before it changes anything, and writes it down.

**A. Remote Desktop is off** (`fDenyTSConnections = 1`, no policy value). Mode **closed**.

- Pre-check, before turning anything on: Windows Firewall on for all three profiles, no registered third-party firewall, `LocalPolicyModifyState` ok, `AllowLocalPolicyMerge` not 0 anywhere. If any fails, Passthrough cannot promise "closed", so it does not turn Remote Desktop on, and says which: see *UX states* ("…can't keep Remote Desktop closed…"). The sentence also gives the owner the other path: turn Remote Desktop on in Windows Settings themselves, which makes situation B.
- Then, in this order: `rdp-block` (the port is blocked before it opens), `rdp-nla`, `rdp-users`, `rdp-service`, `rdp-on`. `weTurnedOn: true`.
- Also mode *closed*: Remote Desktop already on (`fDenyTSConnections = 0`) but with no enabled inbound allow rule for its port in any profile and the firewall in charge. Nothing could reach it, so blocking breaks nothing. `weTurnedOn: false`, so removal never turns it off.

**B. Remote Desktop is already on and open, by the owner's choice** (as on the owner's PC: `fDenyTSConnections = 0` and at least one enabled inbound allow rule covers the port in some profile, or the firewall is off or managed by something else). Mode **owner**.

Decision: **leave it exactly as the owner set it, relay anyway, say so once, and offer to close it.** No block rules, no change to NLA, nothing turned on.

- *Why not refuse*: the point of "closed to the network" is that Passthrough must never be the reason a PC has a password-guessable door on its network. Here it is not the reason: anyone on that network can already reach Remote Desktop directly, and a relay to loopback adds nothing they lack. Refusing would take the main feature from the owners who know Remote Desktop best, for no gain.
- *Why not close it for them*: block rules would silently break the Remote Desktop they use today. That is damage, and it would look like a Windows fault.
- *What still protects the relay*: the far-end check and the certificate hash do not depend on the port being closed, and the viewer only ever signs in with NLA whatever the host allows.
- `exposed` never fires in this mode. The continuous check reads only what the relay needs (on, port, service). The firewall state is the owner's.
- The one-time note stays in Settings and as a flyout notice until answered: wording in *UX states*. **Close it to the network** (one prompt) adds the block rules, sets NLA, and switches the mode to *closed* with `weSetNla` recorded. The *Screen* row then offers **Let other Remote Desktop apps in again** (one prompt), which removes the block rules, restores NLA and returns to *owner*. Both directions are exact because Windows' own rules were never touched.
- `rdp-users` still runs (with consent) if the account needs it; that is the only change, and removal undoes it.

**C. Remote Desktop is set by Group Policy** (the policy key has a `fDenyTSConnections` value).

- Policy value 1: it is off and Passthrough cannot turn it on. No setup; the row says so; `host.rdp` is `off`.
- Policy value 0: mode **policy**. Treated as B: nothing about Remote Desktop or the firewall is changed, the relay works, `exposed` never fires. The row names the policy, not "your organisation": a home owner may have set it with the policy editor.
- A policy `UserAuthentication` value, or `AllowLocalPolicyMerge = 0`, on a PC otherwise in situation A, is the pre-check failing: Passthrough's rules or settings would not take effect.

**Changing sides later, in mode *closed***

- The owner re-enables Remote Desktop's rules in Windows Settings: the block rules still win, so the port stays closed and the check passes. The row offers **Let other Remote Desktop apps in…** as above.
- The block rules are removed, or a policy re-opens the port: `exposed`. The notice offers **Close it** and **Leave it open** (to mode *owner*, one prompt, with a confirmation). So `exposed` can always be ended by an explicit choice, in either direction.

**Turning Remote access off** (`--off`) leaves all of this as it is and says: "Remote Desktop stays on, blocked from the network, until you remove Passthrough." (mode *closed*) or "Remote Desktop stays as you had it." (the others).

**Restore on `--remove`**: remove the block rules; remove from Remote Desktop Users only the SIDs Passthrough added; restore NLA only when `weSetNla`; restore the service's start type only when `weChangedStart`; turn Remote Desktop off only when `weTurnedOn` **and** no enabled allow rule for the port exists now (if one does, the owner has since chosen to use Remote Desktop: it is left on and the result says so). Each line is reported.

### 3. The continuous exposure check

`Core/Screen/ExposureCheck.Evaluate(facts, rdpState) → Closed | Open(reasons) | OwnersChoice | Unknown`, fed by the probe in the service.

**When**: before every relay (a result at most 2 s old is reused); every 60 s; and within 1 s of a change notification (`RegNotifyChangeKeyValue`, subtree) on the Terminal Server key, the Terminal Services policy key, `HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy` and `HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall`. A read takes a few COM and registry calls; its budget before a relay is 500 ms, after which the answer is `Unknown`.

**What counts as open to the network**

| Mode | Open when any of these holds |
|---|---|
| *closed* | (1) Windows Firewall is off for any of the three profiles (not only the active one: a network can change profile at any moment). (2) Either block rule is missing, disabled, not `block`, not inbound, not on every profile, has a program, service or address limit, or its port is not the port Remote Desktop uses now. (3) `AllowLocalPolicyMerge` is 0 for a profile, so local rules are ignored. (4) A third-party firewall is registered (`FwProducts.Count > 0`) or `LocalPolicyModifyState` is not ok: Windows Firewall is not in charge. (5) An enabled allow rule for the port, local or from policy, carries `SecureFlags` that let it override block rules. (6) NLA is no longer required. (7) Any read failed (`Unknown` is treated as open). |
| *owner*, *policy* | never. The result is `OwnersChoice`. |

In every mode, separately from exposure: Remote Desktop off, the service not running, or the edition, give `off`, `service`, `edition` as section 1 lists.

**Third-party firewalls.** One that registers with Windows is detected and, in mode *closed*, means refusal: Passthrough will not guess what another product allows. One that does not register cannot be seen; the guide's known limit says the screen depends on Windows Firewall being in charge. The owner of such a PC can choose **Leave it open** if they run Remote Desktop by their own choice.

**What happens**

- A relay request: `error` `rdp_unavailable`, `detail` `exposed`. The connection stays a shell connection.
- Relays already running are not cut: cutting them closes nothing and takes the owner's session away mid-work. New ones are refused.
- `host` is pushed with `rdp: exposed` to every connected phone of every account.
- An `AdminEvent` `notice` of kind `exposed` goes to every linked tray app and stays until the check passes or the owner chooses. The reason line is the first failing item.
- One log line when it starts and one when it ends, with the reason code.

### 4. The relay

`Core/Shell/ScreenRelay`, used by `ShellConnection` for the `rdp` request, over three interfaces so it is tested with fakes:

```csharp
public interface IRemoteDesktopGate {            // Passthrough.Windows, in the service
    ValueTask<RelayVerdict> CheckAsync(string accountSid, string phoneId, CancellationToken ct);   // Ready(port) | Unavailable(detail)
    ValueTask<Stream?> DialAsync(int port, CancellationToken ct);                                  // 127.0.0.1 only; checks the far end
    ValueTask<string?> CertificateSha256Async(CancellationToken ct);                               // lowercase hex, or null
}
public interface IRelayLimiter { bool TryOpen(GrantKey key, out RelayTicket ticket); void Closed(RelayTicket ticket); }
public interface IRelayLog { void Opened(RelayRecord record); void Closed(RelayRecord record); }
```

**State machine** (one per connection; everything on the gate's queue; a port of `ShellListener.swift:924-927,1134-1209`)

```
Shell ──rdp──▶ Checking ──ready──▶ Dialing ──connected──▶ Verifying ──ok──▶ Relaying ──either end ends──▶ Closed
   ▲              │ fail              │ fail                  │ fail
   └──────────────┴──── error, resume ┴───────────────────────┘
```

On an `rdp` line, in this order:

1. A screen-only connection (`viewer.` id) → `error` `screen_only`. This is the existing first check in `handle` (`ShellListener.swift:859-863`); `rdp` is not on its short list, and a test pins that.
2. Not allowed the screen → `screen_not_allowed`. Allowed means: a phone record with `screen: true`, or a `computer.` record whose scopes, as set at this PC, include `screen`; and the granting account is in `rdp.consentedBy`.
3. `IRelayLimiter.TryOpen` fails → `try_later`.
4. `takeScreenView()` fails → `too_many_screens` (2 a phone, 4 in all, shared with any other screen path).
5. **Checking**: `busy = true`; leave any session (`manager.detach`, as `ShellListener.swift:1136-1138`). `CheckAsync` with a 5 s limit: the exposure check, the facts of section 1, the port read from the registry now. Not ready → `rdp_unavailable` with `detail` (`off`, `edition`, `account`, `service`, `exposed`), then `resume()`, which frees the view and the ticket.
6. **Dialing**: `DialAsync(port)`, 5 s limit (`ShellListener.swift:1193`). A TCP connection to `127.0.0.1` and nothing else; `NoDelay` on.
7. **Verifying**, inside `DialAsync`, before any byte is passed either way: the connection-owner check.
   - Our socket's local port is *p*. `GetExtendedTcpTable(AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS)`; find the row with local address `127.0.0.1`, local port = the Remote Desktop port, remote address `127.0.0.1`, remote port = *p* (the spike matched ports only, `Program.cs:187-194`; the port adds the addresses). Its owning process id is the far end.
   - `OpenSCManager(SC_MANAGER_CONNECT)`, `OpenService("TermService", SERVICE_QUERY_STATUS)`, `QueryServiceStatusEx`: state running, and its process id (`Program.cs:330-348`). No process is opened.
   - The two ids must be equal. The row is looked for up to three times, 50 ms apart. Row not found, service not running, ids differ, or any call failing → close the dial, `rdp_unavailable` `service`, and a warning in the log: "what answers on Remote Desktop's port is not Remote Desktop".
8. **The certificate**: `CertificateSha256Async`.
   - `SSLCertificateSHA1Hash` set → the certificate with that thumbprint in `LocalMachine\My`.
   - Otherwise the certificates in `LocalMachine\Remote Desktop` that are within their dates: exactly one → that one.
   - More than one (Windows is renewing; it re-makes the certificate about twice a year) → ask Remote Desktop itself: a second loopback connection, owner-checked the same way, sends the X.224 request asking for TLS (`Program.cs:151-157`), starts a TLS handshake that accepts any certificate, reads the one presented, and closes. That hash is used and remembered until the store's contents change.
   - None, or anything failing → `rdp_unavailable` `service`.
   The value is the lowercase hex SHA-256 of the certificate's DER bytes.
9. The phone must have sent nothing since `rdp`: if the inbox is not empty, close the dial and the connection (`ShellListener.swift:1196-1200`).
10. Report the viewer (`screenViewer(…, viewing: true)`), write `{"t":"rdpReady","certSHA256":"…"}`, and only when that write completes start the splice (`ShellListener.swift:1205-1208`): `Core/Shell/Splice` with `endTogether`, a port of `Splice.swift`: two pumps with 256 KiB buffers from the pool, failure from reads and writes, a half-close passed on (`Socket.Shutdown(Send)`) before both are closed. **Relaying**: no more lines are read on this connection.
11. **Closed** (either end ends, the phone is revoked, Screen is turned off for it, **Stop**, the service stops): close both, report the viewer gone, free the view, `IRelayLimiter.Closed`, `IRelayLog.Closed`.

The relay has no idle limit and no maximum length: Remote Desktop keeps its own connection alive. It works the same over TLS and over iroh, because it sits in `ShellConnection`. It needs no tray app and no signed-in account.

**Who may use it**

| Id | Rule |
|---|---|
| a phone | its Screen switch on, granted by an account that consented to Screen |
| `computer.…` | its `screen` scope set at this PC (stage 7), same consent |
| `viewer.…` | never: `screen_only`, as the Mac refuses a pass its Screen Sharing login |

**Open-rate caps** (`Core/Screen/RelayRateLimit`, monotonic time from `TimeProvider`, in memory)

- An *open* is counted from the moment `rdpReady` is written. Its length is from then until the splice closes.
- Per grant (account SID, id): at most `cap` counted opens in any 10 minutes. An open stops counting once it has lasted over 30 seconds: a counted open is one that started in the last 10 minutes and either ended within 30 seconds or is still running and younger than 30 seconds. A session that works is therefore free; quick failures, which is what guessing looks like from here, add up.
- `cap` = 4, or `max(1, threshold − 1)` when Windows' account lockout threshold is between 1 and 4, so the relay's cap is always below Windows' own.
- In all: 12 counted opens in 10 minutes across every grant.
- Requests refused before `rdpReady` are not counted (they reached nothing).
- Over the cap → `try_later`. The caps reset when the service restarts; Windows' lockout is the backstop.

**The per-relay log line** (Windows' own log shows only `127.0.0.1`)

```
screen: "Jane's iPhone" (3f9a1c20) account …-1001 opened a view over tls
screen: "Jane's iPhone" (3f9a1c20) account …-1001 view ended after 18m02s; 41.2 MB out, 1.1 MB in; ended by the phone
```

`over` is `tls`, `iroh` or `iroh relay`; `ended by` is `the phone`, `Remote Desktop`, `Stop`, `Screen turned off`, `revoked`, `the service stopping`. The last 200 are also kept in `store\relays.json` (label, short id, account SID, start, end, how it ended) for the after-view notice and the *Phones with access* list's "last used".

### 5. Console state, and the notices at the PC

**`host.console` and `idleSeconds`**, for the account G that granted the phone:

| Value | When |
|---|---|
| `signedOut` | G has no Windows session, and no other account's session is on the console |
| `otherUser` | another account's session is on the console (in use or locked) and G's is not |
| `active` | G's session is the console session and is unlocked; `idleSeconds` is included when known |
| `locked` | G has a session that is locked, disconnected, or currently a Remote Desktop session |

Where each fact comes from:

| Fact | From the service | From the tray app |
|---|---|---|
| Which session is on the console | `WTSGetActiveConsoleSessionId()` (needs no rights) | |
| Sessions starting, ending, moving, locking | `SERVICE_CONTROL_SESSIONCHANGE`: console connect and disconnect, remote connect and disconnect, logon, logoff, lock, unlock, each with a session id | |
| Which account a session belongs to | the SID and session id in a linked tray app's token (stage 4); otherwise `WTSQuerySessionInformation` for the user name, best effort (it may be refused to the service's account; then that session is "another account") | |
| Locked | the lock and unlock events above | `WTSRegisterSessionNotification` on its message window; sent in `HostState.locked`, and used in preference when linked |
| `idleSeconds` | not available: input time is per session and readable only inside it | `GetLastInputInfo`, sent in `HostState` every 15 s while a phone of this account is connected, and at once when it crosses 120 s either way |

After a service restart the events before it are unknown: the service starts from `WTSEnumerateSessions` if it is allowed to, and from the linked tray apps otherwise. An unknown state is reported as `locked`, never `active`, so a phone never skips the takeover question it should ask.

The takeover question itself is the phone's (stage 6): it asks when `console` is `active` and `idleSeconds` is under 120.

**The after-view notice.** When a relay closes, the service makes a notice for the account whose phone it was: "*iPhone* used this PC's screen, 14:02 to 14:20. Your windows may have moved."

- Views by the same phone less than 5 minutes apart are one notice with the first start and the last end.
- It is delivered as an `AdminEvent` `notice` to that account's tray app; if none is linked (signed out, or the app is closed), it waits in `store\notices.json` (at most 20 an account, oldest dropped) and is delivered when one links.
- The tray app shows it the next time its session is unlocked on the console: the amber dot, and the notice at the top of the flyout until **OK**. While the view is still running the tray app is inside the Remote Desktop session the phone is looking at, and shows nothing.
- When the person at the PC unlocks during a view, Windows ends the phone's session; the relay closes; the notice is there as they arrive, with the end time a few seconds old.
- Someone else's account sees nothing: it would name another person's phone.
- A view of under 10 seconds makes no notice (a failed sign-in moves no windows) but is logged.

### 6. The per-phone Screen switch, and the PC's states

**The switch** is `setScreen` (stage 4's op) in Settings ▸ Remote access ▸ *Phones with access*, next to Shell. Off by default, kept when the phone is granted again (as `ShellAccessStore.swift:163-165`).

- It can turn on only when the *Screen* row is done and this account consented. Otherwise it is disabled and the line under it says why with the fix: "Set up Screen first." **Set up…**, or the row's own sentence.
- Turning it off calls `disconnect(phone, screen)` first (as `disconnectScreen`, `ShellListener.swift:628-632`), so its views end at once; its shells stay.
- A second account on the PC must consent once through a prompt (`--configure screen`, which adds it to `consentedBy` and, if needed, Remote Desktop Users) before any of its phones can have the switch on.

**The "Allow screen" notice.** When `addKey` adds a phone that had no record (not a renewed key), the service raises a `granted` notice for that account. It stays until answered.

- Screen available: "*iPhone* can now open shells on this PC. Let it see the screen too? Windows still asks for your password." **Allow screen** · **Not now**. **Allow screen** is `setScreen(on)`.
- Screen not available (Home, not set up, a problem row): "*iPhone* can now open shells on this PC." **OK**, and the *Screen* row carries the fix.

**Flyout and tray**, added to stage 4's states:

| State | Header | Tray | Action |
|---|---|---|---|
| Access first granted | the notice above | amber dot | **Allow screen** · **Not now** |
| A view just ended | "*iPhone* used this PC's screen, 14:02 to 14:20. Your windows may have moved." | amber dot | **OK** |
| Open to the network (mode *closed*) | "Remote access needs a look" / "Remote Desktop is open to the network" | amber | **Fix** (opens Settings; the row has **Close it** · **Leave it open**) |
| Already open, first time (mode *owner*) | the one-time note | amber dot | **OK** · **Close it to the network** |
| Phones with access, a phone viewing | "Viewing the screen" beside the phone | | **Stop** (ends the view; `disconnect(phone, screen)`) |

**Quit** now reads as the master plan has it: "Quit Passthrough? 2 shells end. This PC's screen stays reachable by your phones until you turn Remote access off." **Quit** · **Quit and turn off Remote access** · **Cancel**. With Screen not set up, stage 4's sentence stays.

### 7. Which account a relay may sign in as

The relay carries encrypted bytes. It cannot see which account signs in, and Windows decides who may: members of Remote Desktop Users and, always, administrators.

- **What Passthrough controls**: it adds only consenting accounts to Remote Desktop Users, and only an account in `consentedBy` can give a phone the Screen switch. A consent is one administrator prompt, so an administrator has agreed each time an account's phones can reach the screen.
- **What it does not control**: a phone with Screen, whoever granted it, reaches Windows' sign-in. Anyone holding that phone and the password of *any* account allowed to sign in remotely, an administrator's included, can sign in as that account. Passthrough does not remove administrators from Windows' remote sign-in right: that is a machine-wide policy other tools rely on.
- **What it says**: the turn-on sheet's line under the Screen box, and `SECURITY.md`, state this as the master plan does: Screen plus a Windows password is more than shell access. `host.user` and the phone's pre-filled name are the granting account's sign-in name (the `name` for a local account, the principal name for a Microsoft account, from `NetUserGetInfo` level 24).
- **What it records**: during a relay, session events (a logon or a remote connect) are logged with the session's account where the service can read it, so the log shows "a session for account …-500 connected while *iPhone* had a view". No relay is cut on that basis in this stage (see *Open questions*).

## Pull requests, in order

All Screen UI in PRs 1 to 4 is shown only with `PASSTHROUGH_SCREEN_PREVIEW=1`; until PR 5 `host.rdp` is `off` and `rdp` answers `rdp_unavailable` `off` without the variable set on the service's side (`HKLM\SOFTWARE\Passthrough\ScreenPreview`, written by the elevated step when the variable is set). So `dev` never shows half a feature.

### PR 1. Windows screen: what this PC can do for Remote Desktop, as setup rows

- **Scope**: `RemoteDesktopFacts`, `RemoteDesktopVerdict`, `RemoteDesktopProbe`, the tray app's account facts in `HostState`, the *Screen* and *Your account* rows (read-only), the BitLocker and remote-rights reads in the elevated step.
- **Files**: `windows/src/Passthrough.Core/Screen/{RemoteDesktopFacts,RemoteDesktopVerdict}.cs`, `Passthrough.Windows/RemoteDesktopProbe.cs`, `Passthrough.Core/Pipe` (optional `HostState` fields, a `screen` and `account` row), settings UI, `Fixtures/rdp-facts/*.json`, tests.
- **Tests**: the verdict table from fixture facts: the owner's PC (on, open, policy key present with no values), a clean Pro PC, Home (licence 0, and the edition fallback), policy off, policy on, a Microsoft account with Hello-only on and off, a local account with Hello-only reading 2, a work account; `ProductName` is never read (the facts record has no such field).
- **Docs**: `windows/README.md` (what the probe reads), nothing user-facing yet.
- **By hand**: on the owner's PC the rows read as situation B; `Spikes/PcProbe` output agrees with the facts logged.
- **Leaves out**: any change to the PC.

### PR 2. Windows screen: Passthrough sets Remote Desktop up, closed to the network, and puts it back

- **Scope**: the setup steps, the three situations and the mode, `install.json` `rdp`, restore in `--remove`, `--configure screen`, **Close it to the network** / **Let other Remote Desktop apps in again**, the turn-on sheet's second box.
- **Files**: `Passthrough.Core/Setup/RemoteDesktopPlan.cs`, `Passthrough.Windows/{TerminalServices,LocalGroups,FirewallRules}.cs`, `Passthrough.Service/Verbs`, settings UI, tests.
- **Tests**: with fakes of WMI, registry, groups and firewall: each situation picks its mode; the order in A (block before on); the pre-check failures change nothing; B and C change nothing but the group; restore is exact for every combination of the `we…` flags; restore leaves Remote Desktop on when an allow rule appeared since; a failure at each step undoes the earlier ones.
- **Docs**: `SECURITY.md` (machine-wide Remote Desktop state; what removal restores), guide.
- **By hand**: a clean Pro VM (A): from another machine `Test-NetConnection <pc> -Port 3389` fails over IPv4 and IPv6 while `mstsc /v:127.0.0.1` on the PC itself reaches the sign-in; the owner's PC (B): nothing changes, `mstsc` from the LAN still works; `--remove` on both and compare `reg query`, `netsh advfirewall firewall show rule`, `net localgroup` with before.
- **Leaves out**: the relay.

### PR 3. Windows screen: the relay to Remote Desktop, with its checks and caps

- **Scope**: `ScreenRelay`, `Splice`, `IRemoteDesktopGate` and its Windows implementation (exposure check, dial, owner check, certificate), `RelayRateLimit`, the relay log and `relays.json`, the `rdp` request in `ShellConnection`, `host.rdp`/`host.screens`, `windows/tools/RelayProbe` and the debug-only test credential.
- **Files**: `Passthrough.Core/Shell/{ScreenRelay,Splice}.cs`, `Passthrough.Core/Screen/{ExposureCheck,RelayRateLimit,RelayLog}.cs`, `Passthrough.Windows/{RemoteDesktopGate,TcpOwner,RemoteDesktopCertificate}.cs`, `windows/tools/RelayProbe/**`, tests.
- **Tests**: the list under *Tests*.
- **Docs**: `protocol/README.md` (the `rdp` section's host behaviour: order of refusals, what `detail` means, the caps), `windows/README.md` (RelayProbe and the screen-state checklist).
- **By hand**: the screen-state checklist, with the preview variable.
- **Leaves out**: the notice and the owner's choices when exposed (the request is refused; nothing is shown yet).

### PR 4. Windows screen: a notice when Remote Desktop is open to the network, and the choice to close it or leave it

- **Scope**: registry watchers and the timer, the `exposed` notice, **Close it**, **Leave it open**, the one-time note in mode *owner*, `host` pushed on change.
- **Files**: `Passthrough.Windows/RegistryWatch.cs`, `Passthrough.Service/ExposureMonitor.cs`, flyout and settings, tests.
- **Tests**: `ExposureCheck` reason by reason from fixtures (firewall off in a profile that is not active; rule missing, disabled, wrong port, limited; local rules ignored; third-party firewall; override-block rule; NLA off; a read failing); never open in modes *owner* and *policy*; a running relay survives while a new one is refused.
- **Docs**: guide (known limit: Windows Firewall must be in charge), `SECURITY.md`.
- **By hand**: turn the firewall off for Public while on a Private network: the notice appears within a second or two and the probe gets `exposed`; delete a block rule; **Close it**; **Leave it open** and back.
- **Leaves out**: per-phone UI.

### PR 5. Windows screen: a Screen switch for each phone, "Allow screen" when one is added, and a note after the screen was used

- **Scope**: the switch and its reasons, the `granted` and after-view notices, `notices.json`, console state in `host`, `idleSeconds` from the tray app, the flyout and tray states, the quit dialog's sentence, **Stop** for a view, the preview variable removed.
- **Files**: `Passthrough.Core/Screen/{ConsoleState,Notices}.cs`, `Passthrough.Windows/{Sessions,IdleTime}.cs`, `Passthrough.App/**`, tests.
- **Tests**: console state from event sequences (boot to sign-in screen; G signs in; locks; another account switches in; G's session becomes remote during a relay; service restart with and without a linked tray app; unknown is never `active`); notice merging, waiting and delivery; the switch's disabled reasons; turning it off ends a relay.
- **Docs**: `CHANGELOG.md` ("Works now: Remote Desktop set up and relayed, closed to the network. Not yet: seeing it from a phone"), `docs/GUIDE.md` §Windows (what the screen needs, the known limits, what removal restores), `SECURITY.md` (the relay's checks; what Screen plus a password allows), `windows/README.md` checklist.
- **By hand**: the ten moments up to moment 8; the after-view notice after a RelayProbe session, signed in and after a restart.
- **Leaves out**: the phone's viewer (stage 6).

## Interfaces

### This stage defines (others depend on these)

| Name | Shape | Owner |
|---|---|---|
| Host behaviour for `rdp` | the order of refusals and `detail` values in section 4; `rdpReady.certSHA256` is lowercase hex SHA-256 of the DER certificate Remote Desktop presents | this stage; stage 6's viewer accepts only that certificate |
| `host.rdp`, `host.screens`, `host.console`, `idleSeconds`, `host.user` on a PC | the tables in sections 1 and 5 | this stage; stage 2's page and stage 6's prompts read them |
| `IRemoteDesktopGate`, `IRelayLimiter`, `IRelayLog` | section 4 | this stage |
| `ExposureCheck`, modes *closed* / *owner* / *policy* | sections 2 and 3 | this stage |
| `install.json` `rdp` | section 2 | this stage |
| New `IAccessAdmin` pieces | rows `screen`, `account`; `AdminEvent` notices `granted`, `viewEnded`, `exposed`, `alreadyOpen`; op `ackNotice {id}` | this stage, on stage 4's pipe without a `proto` bump |
| `windows/tools/RelayProbe` | a dev tool that proves a key, sends `rdp`, and listens locally for a stock client | this stage; stage 6 uses it to tell host faults from viewer faults |
| "A relay for this account lasted over 30 s" | per-account flag in `store\settings.json`, used by the *Your account* row | this stage |

### This stage consumes

| From | What |
|---|---|
| Stage 0 | The relay spike's answers: reachable through a relay in every state with block rules on; what Windows asks another signed-in account; whether the tray app's shells survive the session moving |
| Stage 1 | `host` and its fields; `rdp`, `rdpReady`, `screen_not_allowed`, `too_many_screens`, `rdp_unavailable` + `detail`, `try_later` in fixtures and `ShellEnvelope` |
| Stage 3 | `ShellConnection`, `ScreenViewLimit`, `ShellGate.disconnectScreen`, the per-phone record |
| Stage 4 | the service, the pipe and `IAccessAdmin`, `SetupPlan` and the elevated launch, `install.json`, `AccessDirectory`, session tracking, the gate's queue, logging rules |
| Stage 7 (later) | `computer.` records and their `screen` scope; until then no such record exists and the rule in section 4 is tested with a hand-made one |

## Tests

**`Passthrough.Core.Tests` (any OS)**

*Relay hand-off*, with a fake Remote Desktop listener (a loopback `TcpListener` that records what it receives and can speak first), a fake `IRemoteDesktopGate` and a fake phone:

- `rdp` → `rdpReady` with the gate's hash, then bytes pass unchanged both ways, including the listener's bytes sent before the phone sends any.
- **Bytes from the phone before `rdpReady` close the connection** and nothing reaches the listener.
- Nothing is written to the listener before the owner check has passed (the fake gate delays it).
- Not ready → `rdp_unavailable` with each `detail`; the connection still answers `list` afterwards; the view and the ticket are free.
- Check slower than 5 s, dial slower than 5 s, dial refused → `rdp_unavailable` `service`.
- Owner mismatch, owner unknown, certificate unknown → `rdp_unavailable` `service`, dial closed.
- `viewer.` id → `screen_only`; phone without Screen → `screen_not_allowed`; account without consent → `screen_not_allowed`; a `computer.` record without the `screen` scope → `screen_not_allowed`, with it → relayed.
- Third view for one phone, fifth in all → `too_many_screens`.
- Either end closing closes the other; Screen turned off mid-relay closes it and leaves the phone's shell connection; revoke closes both.
- The same over the iroh listener's stream type.

*Rate limit* (fake time): four opens that each end within 30 s, the fifth is `try_later`; after 10 minutes from the first, one more is allowed; an open that lasts 31 s frees its place while still running; a refused request does not count; the lockout threshold lowers the cap; the global cap.

*Splice*: half-close passed on; `endTogether`; a write failure closes both; counts.

*Verdict*, *exposure*, *setup plan and restore*, *console state*, *notices*: as the PRs list.

*The PC's answer table* (stage 1's, re-run with Screen set up): `screen` → `screen_unavailable` with its message; `screenVideo` → `screen_not_allowed` or `screen_video_unavailable`.

**`Passthrough.Windows.Tests` (`windows-latest`)**: the TCP-table lookup finds the owner of a loopback connection the test made (its own process) and reports no row for a closed one; `QueryServiceStatusEx("TermService")` returns without rights; reading `LocalMachine\Remote Desktop` does not throw when the store is absent; the firewall COM reads work unelevated; adding and removing the two block rules (the runner is elevated) leaves the rule list as it was.

**Fixtures added**: `windows/tests/Passthrough.Core.Tests/Fixtures/rdp-facts/{owner-pc,clean-pro,home,policy-off,policy-on,third-party-firewall,msa-hello-only,work-account}.json`; firewall rule sets for each exposure reason. `protocol/fixtures.json`: nothing new beyond stage 1's, unless stage 1 left the `detail` values out, in which case they are added there first.

**Real-PC checklist** (`windows/README.md`; "the probe" is `RelayProbe` on another machine with the debug test credential, then `xfreerdp /v:127.0.0.1:13389 /u:<name> /sec:nla /cert:fingerprint:sha256:<the hash RelayProbe printed>`)

*Setup, each on a fresh snapshot*

1. Remote Desktop off (A): after **Turn on**, the row reads "on, for Passthrough only"; the probe reaches the sign-in; from the other machine the port does not answer on IPv4, IPv6 or UDP.
2. The owner's PC (B): nothing about Remote Desktop changes (compare `reg query` and the rule list); the one-time note; `mstsc` from the LAN still works; the probe works; **Close it to the network** then closes it, and **Let other Remote Desktop apps in again** restores it exactly.
3. Policy on, policy off (C), set with the policy editor.
4. Windows Firewall off before setup: refused with the sentence, nothing turned on.
5. Windows Home: the row; the shell works.
6. `--remove` after each of 1 to 3: Remote Desktop, NLA, the group and the rules are as before.

*Screen states, each through the probe* (the master plan's list)

7. In use at the PC: the console locks; `host.console` was `active` with a small `idleSeconds`.
8. Signed in and idle; locked.
9. Signed out after `shutdown /r`: the probe signs in; the tray app starts and connects; shells appear.
10. Monitor off; a laptop with the lid closed on mains.
11. A UAC prompt inside the session is shown and can be answered.
12. Another account signed in at the console: note exactly what Windows asks and what silence does (the spike's answer), and that `host.console` was `otherUser`.
13. Wrong password, three times: FreeRDP's error; the fifth quick try gets `try_later`. A changed password.
14. Screen switch off mid-view: the view ends at once; the shell connection stays.
15. Remote Desktop turned off in Windows Settings mid-use: the row and `host.rdp: off`.
16. A sleeping PC: no answer; after waking, the probe works.
17. Taken back at the PC (sign in at the console during a view): the view ends; the after-view notice is there.
18. Reconnect after closing FreeRDP: the same Windows session.

*Checks*

19. With the firewall turned off for one profile (mode *closed*): `exposed`, the notice, and both end when it is turned on.
20. A program listening on the Remote Desktop port with Remote Desktop's service stopped: the probe gets `rdp_unavailable` `service` and the log says why.
21. The hash RelayProbe prints equals the certificate `xfreerdp` shows; with a wrong `/cert:` value FreeRDP stops before sending a password.
22. A `viewer.` credential made by hand is refused.
23. The service's log names each relay with the phone and times, and Windows' Security log shows `127.0.0.1` for the same sign-in.
24. Two accounts: the second cannot give its phone Screen until it has consented; its notices never name the first account's phone.

Hardware-only, written down but not gating: a BitLocker start-up PIN (the line appears; after a restart nothing answers until it is typed), Modern Standby, a Public-profile network.

## Security considerations for this stage

- **Passthrough never makes a PC more exposed than it found it.** Where it turns Remote Desktop on, the port is blocked before it opens and checked from then on; where the owner already had it open, nothing is opened further and nothing is claimed to be closed.
- **`exposed` means "Passthrough said closed and can no longer vouch for it"**, never "the owner uses Remote Desktop". Every read failing counts as exposed in the closed mode.
- **The far end**: `127.0.0.1` only, the port read each time, the connection's owner compared with the Remote Desktop service's process through the Service Control Manager, no process opened, and failing closed. A program that takes the port while Remote Desktop is off gets no bytes.
- **The certificate**: the viewer is told which one to expect and accepts no other, so there is no first-use trust and no dialog to click through. A wrong answer here is a refused view, never a leaked password.
- **Guessing**: the relay sees no sign-in result, so it caps what it can see, below Windows' own lockout, and logs every relay with the phone's name.
- **The elevated setup** records before it changes and restores only what it changed; it never edits Windows' own firewall rules and never turns the firewall on or off.
- **Stated plainly in `SECURITY.md`**: Screen plus a Windows password is more than shell access (UAC prompts, the lock screen, any account allowed to sign in remotely, administrators always); the password reaches Windows on the PC; in the owner's and policy modes Remote Desktop's exposure to the network is whatever the owner or the policy set; a firewall that does not register with Windows cannot be seen.
- **The debug test credential** is made by the tray app through the ordinary `addKey`, in debug builds only: it adds nothing to the service that a program running as the user could not already do.
- **Notices** go only to the account whose phone it was.

## UX states and strings for this stage

Rows: section 1. Flyout and tray: section 6. Other strings:

| Where | Text | Actions |
|---|---|---|
| Turn-on sheet, under *See and control its screen* | the master plan's: "Uses Windows Remote Desktop, kept closed to the network. While a phone is in, this PC's own screen shows the lock screen, and stays locked afterwards." | |
| The same, situation B | "Uses Windows Remote Desktop, which is already on and open to your network on this PC. Passthrough leaves that as it is." | |
| The same, policy on | "Uses Windows Remote Desktop, which a policy on this PC turns on." | |
| Under it, always | "A phone with Screen reaches Windows' sign-in. With an account's password it can do whatever that account can, an administrator's included." | |
| Pre-check failed: firewall off | "Windows Firewall is off, so Passthrough can't keep Remote Desktop closed to the network. Turn the firewall on and try again. If you want Remote Desktop open anyway, turn it on yourself in Windows Settings." | **Open Windows Security** · **Try again** |
| Pre-check failed: another firewall | "Another firewall manages this PC, so Passthrough can't check that Remote Desktop stays closed. If you use Remote Desktop yourself, turn it on in Windows Settings and Passthrough will use it." | **Try again** |
| Pre-check failed: policy | "This PC's firewall policy ignores rules Passthrough adds, so it can't keep Remote Desktop closed." | |
| One-time note, mode *owner* | "Remote Desktop was already on and open to your network on this PC. Passthrough leaves that as it is: other devices on your network can still reach it, as before. Phones you allow get to it through Passthrough." | **OK** · **Close it to the network** |
| Confirm *Close it to the network* | "Only Passthrough will reach Remote Desktop. Other Remote Desktop apps on your network stop working until you open it again here." | **Close it** · **Cancel** |
| Exposed notice | "Remote Desktop on this PC is open to the network. Passthrough has stopped relaying to it." + one of: "Windows Firewall is off for *Public* networks." / "Passthrough's blocking rules were removed or changed." / "Another firewall is managing this PC, so Passthrough can't check." / "Network Level Authentication was turned off." / "This PC's firewall policy ignores Passthrough's rules." / "Passthrough couldn't read the firewall's settings." | **Close it** (rules and NLA; for the firewall being off: **Open Windows Security**) · **Leave it open** |
| Confirm *Leave it open* | "Leave Remote Desktop open to your network? Anyone on it can reach this PC's sign-in, as with any PC that has Remote Desktop on. Passthrough will relay to it and stop checking." | **Leave it open** · **Cancel** |
| Turn off Remote access | stage 4's question plus "Remote Desktop stays on, blocked from the network, until you remove Passthrough." / "Remote Desktop stays as you had it." | |
| Removal result | "Remote Desktop was turned off again." / "Remote Desktop was left on: its Windows rules are enabled, so it looks like you use it." / "Remote Desktop was left as you had it." | |
| Screen switch disabled | "Set up Screen first." / the *Screen* row's sentence / "An administrator has to allow Screen for your account once." | **Set up…** / **Allow it** |
| Phones with access | "Viewing the screen" | **Stop** |
| After Stop | (on the phone, stage 6: "This view was stopped from *Office-PC*.") | |

The phone's sentences for each `host.rdp` value and each error are stage 2's and stage 6's, from the master plan's tables. For a policy that turns Remote Desktop off the phone shows its `off` sentence ("Turn it on in Passthrough's settings there"), and the PC's row gives the true reason.

Accessibility: both confirmations default to **Cancel**; notices are announced once; the reason line is text, not an icon.

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| Block rules do not stop loopback being reached, or do | The stage-0 relay spike's pass line; checklist item 1. |
| `FwPolicy2.Rules` leaves out policy rules | The policy rules are read from the registry as well; fixtures for both. |
| The certificate picked from the store is not the one presented, at renewal | The TLS peek on ambiguity; checklist item 21; a wrong pick fails safe. |
| The service's account may not query sessions | Events and tray tokens are the primary source; unknown reads as `locked`. Checked on a real PC in PR 5. |
| WMI's Terminal Services namespace is unavailable or slow | The registry fallback for both settings. |
| A Home PC's licence value is not 0 | The edition fallback; README's open measurement closed on the first Home PC, before PR 1 merges. |
| A Microsoft account with no usable password looks ready | Said on the *Your account* row; Windows' refusal is mapped by the viewer; the row turns done after the first real session. |
| The owner's PC is misread as "policy" because the policy key exists | Only the two values count; the owner's PC is a fixture. If the owner's key does hold `fDenyTSConnections = 0`, the mode is *policy*, which behaves as *owner*. |
| Another account at the console is asked by Windows and the phone waits | Stage 0's spike says what happens; the phone's wording is stage 6's. The PC does nothing here. |
| Rate caps lock the owner out after their own typos | An open that lasts 30 s stops counting; four tries in ten minutes is below Windows' default lockout; the phone says when to try again. |
| Registry watchers miss a change | The 60 s timer and the fresh check before every relay. |
| An unregistered third-party firewall opens the port | Cannot be detected; a stated limit. |

## Decisions made here

1. **Three modes, decided once by the elevated step: *closed*, *owner*, *policy*.** The master plan's single rule cannot tell the owner's PC from a breach.
2. **Already on and open: leave it, relay anyway, say so once, offer to close.** Reasons in section 2.
3. **`exposed` exists only in mode *closed*.**
4. **"Already on" with no allow rule enabled is mode *closed*** and never turned off at removal.
5. **Windows' own firewall rules are never edited; closing is done with block rules.** That is what makes every change exactly reversible.
6. **Passthrough does not turn Windows Firewall on.** **Close it** fixes Passthrough's rules and NLA; a firewall that is off is the owner's to turn on, and the notice opens the right page.
7. **With the firewall off and Remote Desktop off, setup refuses** rather than turn on something it cannot keep closed.
8. **NLA is set only when Passthrough is responsible for the door** (mode *closed*). The viewer uses NLA regardless.
9. **Running relays are not cut when exposure appears.**
10. **Account facts come from the tray app, machine facts from the service**, and the tray app's are never used to allow anything.
11. **A Microsoft account with Hello-only on reports `ready`**, with the row marked needed until a session works.
12. **The certificate comes from the store, with a TLS peek only when the store is ambiguous.**
13. **The owner check matches addresses as well as ports**, and retries the table lookup briefly.
14. **Caps: 4 in 10 minutes per grant (lower when Windows' threshold is lower), 12 in all, counted from `rdpReady`, in memory.**
15. **View caps stay 2 a phone and 4 in all**, so a reconnect is never refused by its own lingering connection.
16. **An unknown console state is `locked`.**
17. **After-view notices merge within 5 minutes, skip views under 10 seconds, and go only to the granting account.**
18. **A second account consents through one prompt before its phones can have Screen.**
19. **The "Allow screen" notice has Allow screen · Not now**; Revoke stays in *Phones with access* (see *Corrections*).
20. **A debug-only test credential and `RelayProbe`** make the done-when testable before any viewer exists.
21. **No relay is cut because of which account signed in** (section 7).
22. **WMI through late-bound COM**, adding no package.

## Corrections to the master plan

1. **"Anything else … and it refuses with `exposed`"** is right only where Passthrough turned Remote Desktop on or the owner asked it to close it. On the owner's own PC it would refuse forever. The three modes replace it.
2. **"Requires Network Level Authentication on the host"** applies in mode *closed* only; changing it on a PC whose owner runs Remote Desktop could break their other clients.
3. **"Removing Passthrough puts it back"** needs one exception: if the owner has since enabled Windows' Remote Desktop rules, turning it off would take away something they now use. It is left on and the result says so.
4. **The check needs two things the plan does not list**: local firewall rules can be ignored by policy (`AllowLocalPolicyMerge`), and an allow rule can be flagged to override block rules.
5. **The access-granted notice has two versions** in the plan (moment 8: Allow screen · Not now; the flyout table: Allow screen · Revoke). This plan uses the first.
6. **`host.rdp` has no value for "off by policy"**; `off` is sent, and the phone's fix sentence is then not quite true. A `detail` on `host.rdp`, or a `policy` value, would fix it in stage 1's fixtures.
7. **The service cannot say on a relay connection why it ended** (it carries Remote Desktop's bytes). "Screen turned off" and "stopped from the PC" have to be told apart by the viewer asking again, or by a message on its shell connection; stage 6 should pick one.
8. **BitLocker and remote sign-in rights can only be read by the elevated step**, so those lines are as old as the last prompt; they carry a date.
9. **`idleSeconds` cannot come from the service.** With the granting account's tray app not running, `console: active` is sent without it, and the phone should then ask the takeover question.

## Open questions for the owner (each with a recommended default)

1. **Remote Desktop already on and open: leave it open and relay, with a one-time note and an offer to close?** Recommended: yes, as designed. The alternative is to ask at setup with "close it" pre-selected.
2. **When exposure appears in the closed mode, cut views that are already running?** Recommended: no; refuse new ones only.
3. **Should Passthrough ever turn Windows Firewall on for the owner?** Recommended: no; open Windows Security instead.
4. **Should a relay be ended when the account that signed in is not one that consented to Screen (an administrator's, say)?** Recommended: no for now, stated in `SECURITY.md` and logged; revisit with the later SYSTEM helper, which can attribute sessions reliably.
5. **A Microsoft account that signs in with Hello only: report `ready` and let Windows refuse, or report `account` and block the button?** Recommended: `ready`, with the row explaining.
6. **The per-grant cap of 4 quick opens in 10 minutes, 12 for the whole PC?** Recommended: as written.
7. **A debug-build button that makes a test credential for `RelayProbe`?** Recommended: yes, debug builds only.
8. **The after-view notice for views under 10 seconds: skip?** Recommended: skip, but log.
