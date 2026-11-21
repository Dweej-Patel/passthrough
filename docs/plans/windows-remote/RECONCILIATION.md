# Reconciliation: where the stage plans disagree, and what holds

The ten stage plans were written in parallel, each without seeing the others. **Where a stage plan and this file disagree, this file holds.** Each stage's author applies its part when that stage starts (the list at the end says which).

Sources: each planner's own corrections and open questions; the per-stage extracts made for the interface review; the finished security review of stage 3 (`slice-B`, findings B-1 to B-17). **Not done:** the cross-stage security review of stages 4 to 8 and the cross-stage UX review were cut off before reporting. They are to be run per stage, when that stage starts (see *Review still owed*).

## 1. The wire contract (stage 1 is made authoritative with these changes)

| Item | Disagreement | Holds |
|---|---|---|
| `host` message | shape and field set differ in every plan | `{"t":"host","host":{…}}`, after `ready` and `macInfo`, re-sent on change, never before `ready`, to every connection except screen-only passes. Line at most 16384 bytes. Type name `HostInfo` in Swift, Kotlin and C# (stage 8's `HostDescription` is renamed; the `macInfo` payload stays `MacInfo`). |
| `host` fields | | `kind`, `os`, `signedIn`, `app`, `console`, `idleSeconds`?, `shells`, `screens`, `rdp`, `access`, `lock`, `idKey`?, `user`?, `sleepAfter`? |
| `signedIn` / `app` | stage 1 added `app`; stages 2, 4 derive it otherwise | Both sent. `signedIn`: the granting account has a Windows session (stays true when only the tray app is gone). `app`: Passthrough is running in it. Phone: `signedIn:false` → "Sign in to…"; `signedIn:true, app:false` → "Passthrough isn't open on…"; `console: otherUser` → "Someone else is signed in…". |
| `console` | stage 5 sends `locked` when unknown; stage 6 invents `unknown` | `active`, `locked`, `signedOut`, `otherUser`; **omitted when unknown**. A phone that sees it absent, or `active` without `idleSeconds`, asks the takeover question. |
| `access` | stage 2 `access{shell,screen}`; stage 1 `screenAllowed`; stage 7 `share` | `access: {shell, screen, share}` (booleans, for this connection's device). Replaces `screenAllowed`. |
| `lock` | `macState.control` gates Lock on today's phones; stage 1 said `control:true`, stages 2, 3, 7 `false` | PC sends `macState.control:false` and `host.lock:true`. Phones from stage 2 on show Lock from `host.lock`. Older phones don't offer Lock on a PC. |
| `user` | sent to all (stage 3) / only when screen allowed (stage 1) / Microsoft account address (stage 5) | Sent only when `access.screen` is true. Value: the name Remote Desktop accepts (the Microsoft account address, else `PC\name`). |
| `idKey` | `identityKey` (stage 1) vs `idKey` (stage 7) | `idKey`. A separate P-256 signing key, never the TLS or iroh key. |
| `rdp` | no value for "off by policy" | `ready`, `off`, `edition`, `account`, `service`, `exposed`, `policy`. `exposed` only where Passthrough turned Remote Desktop on (stage 5's *closed* mode). NLA not required → `service`. |
| `sleepAfter` | unit unstated | seconds on mains; 0 = never or Stay awake holding. |
| `shells` ids | `wsl.<distro>` lower-case (stage 1) vs `wsl:<name>` (stages 2, 3); stage 3's own grammar rejects `wsl:Ubuntu` | `pwsh`, `powershell`, `cmd`, `gitbash`, `wsl:<DistroName, case kept>`; a Mac sends one entry, `login`. Grammar `[A-Za-z0-9][A-Za-z0-9:._-]{0,79}`, matched whole (never `^…$` in .NET). At most 32. |
| `sessions[].shell` | absent in stage 1 | Added, optional: the shell id the session runs. |
| `hostKind` | stage 1: grant and credential only; stage 2 also wants it on the control `hello`; stage 4 has it nowhere | On `shellGrant`, stored credentials, **and the control channel's `hello`** (the phone keeps it only once the connection is authenticated). Stage 4's `grantInfo`, records and `SavePass` carry it. |
| Going away | `goingAway` (stage 1) vs `goodbye` (stage 2) | `{"t":"goingAway","reason":…}`: `sleeping`, `turned_off`, `shutting_down`. None for an update or plain stop. |
| Shell switch off | `shell_not_allowed` (stage 2) vs `not_allowed` (stage 3) | `not_allowed` (older phones know it) plus `access.shell:false`. One check before dispatch (B-2): every shell request refused, `sessions` sent empty, nothing pushed. |
| `signed_out` | `open` only (stage 1) vs wider (stages 3, 4) | `open`, `attach`, `history`, `transcript`, `lock`. `close` of an unknown session stays `no_such_session`. On tray loss: `detached` per attached session, empty `sessions`, then `host`. |
| PC's answer to `screenVideo` and `screen` | `screen_video_unavailable` (stage 1) drops today's iPhone into the Mac login prompt | `screen_not_allowed` for both, until the PC has its own stream. `screenPass`, `screenRevoke`, `screenGrant` → `bad_request`. Before the service exists, `rdp` → `rdp_unavailable` `service`. |
| `rdp` refusal order | stage 1 and stage 5 differ | `screen_only`, `screen_not_allowed`, `too_many_screens`, `rdp_unavailable`, `try_later`. (Say why it can't before saying wait.) |
| `try_later` | stage 5 sends it bare; stage 6 hard-codes "10 minutes" | Always carries `retryAfter` (seconds); the phone's sentence uses it. |
| Relay caps | per device vs per grant | Per grant (account, id): 4 quick opens in 10 minutes, lowered to Windows' lockout threshold minus one when that is lower; 12 in all per PC. Counted from `rdpReady`; an open that lasted over 30 s stops counting. In memory. |
| `rdpReady.certSHA256` | encoding left open in stage 6 | 64 lower-case hex of the leaf certificate's DER. |
| Why a view ended | nothing defined; the relay only carries Remote Desktop's bytes | New: `{"t":"screenEnded","reason":…}` on the phone's other live connections: `switched_off`, `stopped`, `taken`. After Stop, `rdp` answers `try_later` for 30 s. Stage 1 defines it, stage 5 sends it, stage 6 reads it. |
| `message` on errors | "the PC sends this text to old apps" can't work | Defined, shown only by apps from stage 2 on. The master plan's "App too old" row is produced by `screen_not_allowed` on old apps. |
| Computer proof | stage 1 and stage 7 sign different things | Stage 7's: ECDSA P-256 over `"passthrough-computer-v1" ‖ 0x00 ‖ path (0x01 TLS, 0x02 iroh) ‖ nonce ‖ host binding (certificate hash on TLS, endpoint id on iroh) ‖ id`, field `sig`, verified after the HMAC with a decoy key when the record is missing. Stage 8's `IComputerProof.Sign` takes that whole context, not the nonce alone. |
| Computer messages | stage 7 and 8 add to stage 1's set | `computerGrant` (`kind`?), `computerGranted` (`pending`?), `computerPass` (`pending`?), `computerRevoke`; errors `too_many_computers`, `pass_conflict`, `pass_not_saved`. Caps: 8 per phone, 16 per host, refused, not oldest-dropped. A computer gets `macState` with `control:false`, and `not_allowed` for lock, history, transcript, events, push. |
| Direct pairing | stage 1 reserved other names | Stage 7's: service `_passthrough-pair._tcp`; lines `hello`, `reveal`, `confirm`, `grant`, `done`, `fail`; labels `passthrough-pair-v1 …`; fixture section `pair`. The vector's digits must be reproduced by Swift and C# before the fixture is merged (so far one Python script made them). |
| Pacing text | README says 2 to 16 | 2 to 24. |

## 2. Between stages, off the wire

- **Grant before any listener (stage 3).** The grant carries `certSHA256` of sixty-four zeros, port 7893, no addresses. No client may treat that value as "no pin"; a viewer that sees it skips the TCP candidates. Rules that identify a host by certificate and iroh id use the iroh id alone for such a PC (B-10).
- **Keys at stage 4.** The service makes its own TLS key **and its own iroh key**; it never adopts keys a user's programs could read or plant (on a shared PC an adopted iroh key lets one account stand in for the PC to another's phones). Only the access records are handed over, re-keyed by the pipe token's account. Consequence: after the service is installed, **plug each phone in once**. Spike 0.8 (key hand-over) is dropped; the changelog says so.
- **`ISessionHost`.** Stage 3's shape holds, with its two changes: an event `Replaying`, and the attach generation chosen by the caller. Stage 4's pipe frames follow it. Stage 5's additions (new `HostState` fields, notices, `ackNotice`) bump the pipe's version.
- **Elevated verbs.** `--install`, `--update`, `--off`, `--remove`, `--configure`. The service build is self-contained (.NET on the owner's PC is per user; a service account can't use it). The tray app writes Start at login, as the user.
- **Stage 4 fix.** Its service DACL lets interactive users send user-defined controls while control code 200 deletes the service's key: drop that right or that control.
- **Firewall.** The install also adds the rule for the tray app's pairing listener (stage 7): inbound TCP, the app, local subnet, every profile.
- **C# layout.** Protocol types under `Passthrough.Core.Shell`; clients under `Client`; pairing and computers under `Trust`. `ShellEnvelope` is added once, in stage 1's PR.
- **iroh.** Crate pinned `=1.0.2` (what `iroh-ffi` 1.1.0 locks; an interop run against a Mac is the proof). Stage 8 dials through stage 3's C ABI as written; no second bridge surface.
- **Remote Desktop engine.** One shim with one transport interface (two byte queues and an event). On iOS the queues are filled in process; on the Mac the same queues are fed inside the sandboxed helper, so the Mac app never links FreeRDP. The xcframework ships iOS, simulator and Mac slices from stage 6's first build.
- **Phones store the last `host` per computer** (stage 2), not just the kind: the takeover prompt and refusals read it.
- **The Mac sends `host` from stage 1**, with `shells: [{id:"login"…}]`.

## 3. Security fixes accepted into stage 3 (from the finished review)

B-1 the cable peer check never falls through on a missing service; the per-process fallback also requires the owner to be a system account or the current user. B-2 one Shell-off gate before dispatch. B-3 static C runtime for the bridge and `SetDefaultDllDirectories` before any native load. B-4 redaction: escaped base64, secrets by field name, tokens registered at load, a hashed grant fingerprint, **no secret ever written as hex**. B-5 refuse high-integrity tokens, refuse at launch too, and say plainly that Shell on an administrator account is administrator access. B-6 name grammars matched whole. B-7 trusted locations also checked for who may write. B-8 the Store PowerShell alias verified against the package before launch. B-9 transcript ids must be UUIDs. B-11 the PTY probe is debug-only. B-12 package lock files required; ConPTY checked by chain and hash. B-13 a deadline and a way out for an advisory on a pinned crate. B-14 phone-chosen ids and labels filtered. B-16 a WSL distro may open as root, said in the guide. B-17 relay slots can be occupied by someone who knows the endpoint id, said in SECURITY.md.

## 4. Order of work, corrected

1. Stage 0 spikes (0.8 dropped). Only ConPTY (0.7) needs just this PC.
2. Stage 1: CI → C# `ShellEnvelope` → host/shell/relay contract with the rows above → computers.
3. Stage 2 (phones) needs only stage 1; it must merge before stage 3's wire-up PR.
4. Stage 3 (shell from anywhere), then stage 4 (service), then stage 5 (relay).
5. Stage 6: its seam PR and the vendored engine build can run **in parallel with stages 3 to 5**; the backend needs stage 5.
6. Stage 7: (a) computers after stage 4; (b) pairing after (a); (c) Mac screen window after stage 6; (d) shells after (a).
7. Stage 8: (a) shell client after stage 3 and 7(a); (b), (c) after (a).

The owner's main use case (the PC's shell and screen from the phone) is done at the end of stage 6; stages 7 to 9 don't hold it up.

## 5. Decided here without the owner (each can be overruled)

Sound off by default in the PC's viewer · Windows Hello once per unlock for shells, every time for a screen · the phone's default shape is *Fit* · the tab title is fixed ("*MacBook* · zsh") · kind prefix in the switcher only when Macs and PCs are mixed · "New session" becomes "New shell" for Macs too · the split New shell control appears only when a host lists more than one shell · hidden WSL distros are the container engines' · per-user Git and tool-installed PowerShell are not offered · turning Remote access off ends running shells · removing Passthrough deletes every phone's access and the service's keys, after a confirmation · up to 4 Windows accounts per PC · the PC's keyboard layout is left alone · the vendored engine is committed, revisited if it passes 60 MB · rebuild within 7 days of an advisory a server can trigger, 30 otherwise · pairing only on the same network, never over Tailscale · a computer can't read shell history · default relay is n0's, as on the Mac.

## 5a. Decided by the owner

- **Remote Desktop already on and open** (as on the owner's own PC): leave it as it is, relay anyway, and show a one-time note offering *Close it to the network*. Stage 5's *owner* mode, as written.
- **Rust and the MSVC build tools are installed on the PC** when the iroh bridge work starts; the bridge is built and tested locally, not only on a CI runner.
- **Reviews**: each of stages 4 to 8 gets its security and UX review when it starts, not all up front.
- **The plans live in the repo** (`docs/plans/windows-remote/`), so the Mac can pull them for the Mac and iOS work and for testing.

## 6. Review still owed

The cross-stage security review covered stage 3 only; the UX review did not report. Each of stages 4, 5, 6, 7 and 8 gets a security and a UX review of its plan **when that stage starts**, after the spikes and the stages before it have settled what it builds on. The open points already known: stage 5's *owner* mode relays to a Remote Desktop that is open to the network; stage 8 keeps a phone's hand-over under plain DPAPI before the Hello vault exists, uses a low-level keyboard hook and decodes in the tray process; stage 7's helper does not hide the Mac's pasteboard from the engine; debug and preview switches (`PTWindowsScreen`, stage 5's preview variable and test-credential button) must be shown not to ship enabled.

## 7. What each stage's author changes

- **Stage 0**: drop 0.8; the relay spike saves and restores the owner's existing Remote Desktop rules.
- **Stage 1**: every row of section 1.
- **Stage 2**: `goingAway`; `not_allowed` and `access`; `app`; `lock`; `host` field names and limits; shell id grammar; store the last `host`.
- **Stage 3**: section 3; `app`, `access`, `lock`, `user` rule; shell id grammar.
- **Stage 4**: own iroh key, records-only hand-over; `hostKind`; `signed_out` set; the DACL fix; the pairing firewall rule; pipe version on stage 5's additions.
- **Stage 5**: refusal order; `retryAfter`; `policy`; NLA-off → `service`; `screenEnded`; `console` omitted when unknown.
- **Stage 6**: read `retryAfter`, `screenEnded`, `app`, `access`; hex pin; drop client-side `unknown`.
- **Stage 7**: names from section 1; firewall rule moved to stage 4; reproduce the vectors in Swift and C#.
- **Stage 8**: `HostInfo` naming; proof context; stage 3's ABI; `Passthrough.Core.Shell`.
