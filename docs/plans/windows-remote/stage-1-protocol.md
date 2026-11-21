# Stage 1: Protocol groundwork

## Goal and done-when

Put the whole wire contract for "a PC as a peer" into `protocol/fixtures.json`, `protocol/README.md` and the three envelope implementations (Swift, Kotlin, C#), and give the Windows code a CI job, before any stage sends or acts on a new message. No user-visible behaviour changes in this stage, with one exception stated in PR 3 (a Mac starts sending `host`, which every deployed phone ignores).

Done when:

1. `swift test` (Packages/PassthroughCore), `./gradlew testDebugUnitTest lintDebug` (android) and `dotnet test windows/tests/Passthrough.Core.Tests` all pass against the same `protocol/fixtures.json`, on CI: the C# suite on both `windows-latest` and the macOS job.
2. Every message, field, reason, limit and ordering rule below is in `protocol/README.md`, and each has at least one line or constant in the fixtures.
3. A phone build from before this stage still pairs, is granted, opens shells and the screen against a Mac built from this stage (checked by hand, PR 3), and a phone built from this stage still works against a Mac from before it.
4. `CONTRIBUTING.md` says "three suites" and has a Windows line in the checklist.

## What exists today (verified, with path:line)

**Envelopes**

- Swift `ShellEnvelope` is a flat `Codable` struct of optionals: `Packages/PassthroughCore/Sources/PassthroughCore/ShellProtocol.swift:42-81`. Its top-level keys are `t nonce phoneID mac session data cols rows sessions history exitStatus reason ref done irohID irohRelay relayToken addresses state on push since events battery name viewer key pass`. Synthesised `Codable` ignores unknown keys and omits `nil` (`encodedLine`, `:150-154`). **A known key with the wrong JSON type makes the whole line fail to decode.**
- Swift `ControlEnvelope`: `Packages/PassthroughCore/Sources/PassthroughCore/Protocol.swift:51-133`.
- Kotlin `ShellEnvelope`: `android/app/src/main/java/dev/dpatel/passthrough/core/ShellProtocol.kt:38-111`. It models fewer keys than Swift (no `push`, `name`, `viewer`, `key`, `pass`; `ShellSessionInfo` at `:137-147` has no `origin`, `theme`, `status`). The shared `Json` is `ignoreUnknownKeys = true, explicitNulls = false, encodeDefaults = false` (`Protocol.kt:96-100`).
- C# has `ControlEnvelope` only: `windows/src/Passthrough.Core/Protocol/ControlEnvelope.cs:7-99` (it already carries the `shellGrant` fields, `:61-68`). There is **no C# `ShellEnvelope`**, no `RemoteShell` constants, no shell proof.

**What deployed peers do with something new**

| Situation | Swift phone (`ShellClient.swift`) | Kotlin phone (`ShellConnection.kt`) | Mac host (`ShellHost/ShellListener.swift`) |
|---|---|---|---|
| A line that fails to decode | dropped silently (`:667`) | dropped silently (`:381`) | answered `bad_request` (`:858`) |
| Unknown `t` **before `ready`** | the attempt ends as a protocol violation (`:694-695`) | `ProtocolViolation("unexpected …")` (`:408`) | n/a |
| `error` with an unknown `reason` **before `ready`** | read as `not_authorized` (`:691`), which the iPhone shows as access lost (`iOS/App/Shell/ShellModel.swift:827`) | read as `NOT_AUTHORIZED` (`:405`) | n/a |
| Unknown `t` after `ready` | ignored (`:786-787`) | ignored (`:460`) | answered `bad_request` (`:949-950`) |
| `error` with an unknown `reason` after `ready` | read as `bad_request` (`:758`); with a `ref` it fails that `open` (`:761-766`) | read as `BAD_REQUEST` (`:452`) | n/a |
| Unknown field on a known message | ignored | ignored | ignored |

- After a valid proof the Mac sends, in this order: `ready`, `macInfo` (if it has one), `macState` (if any), `sessions` (`ShellListener.swift:733-742`). A screen-only connection gets `ready` and nothing else (`:736`), and every request but `screenVideo`, `ping`, `pong` is answered `screen_only` **before** anything else is looked at (`:861-863`).
- The proof line is `{"t":"proof","phoneID":…,"mac":…}`, at most 4096 bytes (`ShellListener.swift:390`, `:529-547`), checked against two keys in constant work (`:566-583`).
- `screen` hand-off: the pattern `rdp` copies. Check, dial loopback with a 5 s limit, a line that arrived meanwhile closes the connection, `screenReady`, then a `Splice` (`ShellListener.swift:1134-1209`).
- A phone accepts a `shellGrant` only with a 64-hex `certSHA256`, a 32-byte key and a port (`ControlServer.swift:232-263`; `ControlServer.kt:194-222`); other fields are optional and unknown ones ignored. The stored record is `ShellGrant` (`Pairing.swift:29-44`; `Pairing.kt:53-61`); the credential built from it is `ShellCredential` (`ShellClient.swift:6-28`; `ShellCredentials.kt:10-34`).
- The iPhone offers Lock only when `macState.control == true` (`iOS/App/Screen/ScreenView.swift:63`, `iOS/App/Home/MacHomeView.swift:571`).
- Screen passes: ids start `viewer.` (`ShellProtocol.swift:311`), 8 per granting phone (`:309`), `ScreenPass.isUsable` (`:341-347`).
- Pacing: the README says the ack window is "2 to 16" (`protocol/README.md:677-678`); the code says 24 (`Packages/PassthroughCore/Sources/ScreenHost/StreamPacer.swift:23-24`).

**How the suites read fixtures**

- Swift, control: `ProtocolFixtureTests.swift:75-86` decodes every `messages[].line` with `ControlEnvelope`, re-encodes, and compares as `NSDictionary`: **a field the struct does not model makes the test fail.**
- Swift, shell: `ShellProtocolTests.swift:45-55` does the same for `shell.messages` with `ShellEnvelope`, and requires at least 23 lines (`:47`). Constants at `:20-29`, proofs at `:31-42`.
- Kotlin, shell: `ShellProtocolTests.kt:42-48` round-trips `shell.messages` and compares with `Fixtures.normalize` (numbers by value, `Fixtures.kt:21-25`). Same failure on an unmodelled field. The control round trip is in `ProtocolFixtureTests.kt`.
- C#: `windows/tests/Passthrough.Core.Tests/Protocol/FixtureTests.cs:85-95` round-trips top-level `messages` only, comparing with `JsonNode.DeepEquals`. `Fixtures.cs:7-15` loads the file copied beside the tests (`Passthrough.Core.Tests.csproj`, the `Content Include="../../../protocol/fixtures.json"` item). Nothing reads `shell`.
- The fixtures do **not** hold every message today: `screenGrant`, `screenPass`, `push`, `viewing`, `lock`, `replaying` and `sessions` with `status`/`theme`/`origin` are absent (`protocol/fixtures.json:287-411`), which is why the Kotlin round trip passes without modelling them.

**CI** (`.github/workflows/ci.yml`): three jobs (`core-tests` on `macos-15`, `apple-builds`, `android`), actions pinned by full commit SHA with the tag in a comment (`:29`, `:83`, `:87`), `permissions: contents: read` (`:16-17`), `concurrency` cancelling superseded PR runs (`:12-14`), `timeout-minutes` on every job, `persist-credentials: false` on checkout. No Windows job; nothing runs `dotnet`.

**.NET today**: `windows/Directory.Build.props` (nullable, warnings as errors); no `global.json`, no `nuget.config`, no `packages.lock.json`. Package versions are literal in the two csproj files that have any.

## Design

### Rules every new thing follows

1. **No version bump.** Control stays at protocol version 2; the shell has none.
2. **Nothing new before `ready`.** No new `t` and no new `error` reason is ever sent before `ready` (see the table above: both end the connection on deployed phones, the second as "access lost").
3. **No new top-level key may reuse an existing key name**, and structured data goes in a nested object, because a type clash drops the whole line on phones.
4. **Hosts send new unasked messages only after `ready`**; clients send new requests only to a host whose `host` message says it understands them (below), so a deployed Mac's `bad_request` is a fallback, not the normal path.
5. Lengths are UTF-8 bytes unless stated. A field that fails its rule is dropped and the rest of the message kept, unless stated ("refused": the request is answered `bad_request`; "ignored whole": the message is discarded).

New top-level keys on the shell envelope (all optional): `host` (object), `shell` (string), `detail` (string), `message` (string), `retryAfter` (integer), `certSHA256` (string), `sig` (string), `identityKey` (string), `scopes` (array of strings). On `ShellSessionInfo`: `shell`. On the control envelope: `hostKind`. On `ShellGrant` and `ShellCredential` (stored, and on the wire inside `pass`): `hostKind`.

In the examples below each line is shown as sent; in `fixtures.json` it is one `{"line": "<the same, JSON-escaped>"}` entry, for example:

```json
{ "line": "{\"t\":\"goingAway\",\"reason\":\"sleeping\"}" }
```

### 1. `host`

Sent by the host, unasked: after `ready` on every connection that is not screen-only (`viewer.`), in the order **`ready`, `macInfo`?, `host`, `macState`?, `sessions`**; and again, whole, whenever any field but `idleSeconds` changes, and when `idleSeconds` crosses 120 in either direction. At most one a second per connection (changes within a second are sent as one). Never on a connection that has become a screen relay. A receiver replaces what it held with each new one; a `host` whose `host.kind` is missing or not a string is ignored whole.

```
{"t":"host","host":{"kind":"mac","os":"macOS 15.5","screens":["video","rfb"],"screenAllowed":true}}
{"t":"host","host":{"kind":"windows","os":"Windows 11 Pro","user":"name@outlook.com","signedIn":true,"app":true,"console":"active","idleSeconds":35,"shells":[{"id":"pwsh","name":"PowerShell","default":true},{"id":"powershell","name":"Windows PowerShell"},{"id":"cmd","name":"Command Prompt"},{"id":"wsl.Ubuntu","name":"Ubuntu"},{"id":"gitbash","name":"Git Bash"}],"screens":["rdp"],"rdp":"ready","screenAllowed":true,"sleepAfter":1800,"identityKey":"BG3/brAaPH0cBP7d9HIe8cXhSrNvipoV6v5oj/aqFKTeDp1JsQu1YkWFhJIhmma3gqu9V9JfJL7FoxnH8umDZpQ="}}
{"t":"host","host":{"kind":"windows","os":"Windows 11 Home","signedIn":false,"app":false,"console":"signedOut","shells":[],"screens":[],"rdp":"edition","sleepAfter":0}}
```

(`identityKey` in the second line is the X9.63 public key of `shellKeySeal.recipientPrivateKey` already in the fixtures, base64; the PR computes it and the test checks the two agree.)

| Field | Type | Rule | Meaning |
|---|---|---|---|
| `kind` | string | required. `mac` or `windows`; any other value is kept and shown without a kind | What the host is |
| `os` | string | 1–64 bytes, one line | For display only. A PC builds it from the build number and edition, never `ProductName` |
| `user` | string | 1–256 bytes, one line | The granting account's sign-in name as Remote Desktop wants it typed; pre-fills the sign-in sheet. PCs only. Its exact form per account kind comes from spike 0.3 (i) |
| `signedIn` | bool | | The granting account has a Windows session (locked counts) |
| `app` | bool | | Passthrough is running in that session, so shells can open. `signedIn:true, app:false` is "Passthrough isn't open on the PC" |
| `console` | string | `active`, `locked`, `signedOut`, `otherUser`; unknown → treated as absent | Who is at the physical screen: the granting account unlocked; the granting account locked; nobody; another account |
| `idleSeconds` | integer | ≥ 0; only with `console:"active"`; counted when the message was made | Since the last key or pointer use at the console. Under 120 with `active` is "someone is using it" |
| `shells` | array | at most 32 entries; an entry without a valid `id` is skipped | What `open` may name. Empty or absent: no chooser |
| `shells[].id` | string | 1–64 bytes of `A–Z a–z 0–9 . _ -` | `pwsh`, `powershell`, `cmd`, `gitbash`, `wsl.<distro>`; opaque to the client |
| `shells[].name` | string | 1–64 bytes, one line | Shown in the chooser |
| `shells[].default` | bool | at most one `true`; with none, the first is the default | Opened when `open` names no shell |
| `screens` | array of strings | values `video`, `rfb`, `rdp`; unknown values skipped | The requests this host can serve at all (`screenVideo`, `screen`, `rdp`), in the host's order of preference. Absent: a host from before this message, so the client asks as it does today |
| `rdp` | string | `ready`, `off`, `edition`, `account`, `service`, `exposed`; unknown → shown as unavailable without a reason | Whether `rdp` would work now, and if not why (the same words as `rdp_unavailable`'s `detail`) |
| `screenAllowed` | bool | | This device may ask for the screen (the per-phone Screen switch, or a computer's `screen` scope). Absent: not said; ask and see |
| `sleepAfter` | integer | seconds, ≥ 0; 0 = never | When the host sleeps on its current power source |
| `identityKey` | string | base64 of a 65-byte X9.63 P-256 public key | This host can hold a computer pass, bound to this key (section 7). Absent: it cannot |

The encoded line is at most 16384 bytes; a host that would exceed it drops `shells` entries from the end.

**Old peers**: deployed phones ignore `host` (unknown `t` after `ready`). A phone that hears no `host` within the connection treats the host as a Mac from before this stage.

### 2. `hostKind` on `shellGrant` and stored credentials

```
{"t":"shellGrant","shellKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","certSHA256":"abababababababababababababababababababababababababababababababab","shellPort":7893,"addresses":["192.168.1.30"],"macName":"OFFICE-PC","irohID":"3f2a9c5e7b1d4a60c8e2f9b4d7a1035e6c8b2d4f9a1e3c5b7d0f2a4c6e8b1d3f","grantID":"5B0E2C4A-7F31-4D8E-9A62-1C3B5D7E9F04","hostKind":"windows"}
```

- `hostKind`: 1–16 bytes of `a–z`; otherwise dropped (the grant is still stored). Absent means `mac`. A Mac does not send it.
- The phone stores it in `ShellGrant.hostKind` and copies it to `ShellCredential.hostKind`; a later `host` message's `kind` overwrites the stored value. It is a string in storage, not an enum, so a record written by a newer build still loads in an older one.
- Field names do not change: a PC's name travels in `macName`, its id is `macID`.
- **Old peers**: a deployed phone ignores the field and lists the PC as a Mac until updated (stage 2 ends that).

### 3. Going away

```
{"t":"goingAway","reason":"sleeping"}
```

Host → client, after `ready`, on every connection still in line mode (not on a screen relay, not to `viewer.`), best effort, once, as the last line the host sends: `sleeping` (the system is about to sleep), `turned_off` (Remote access or Remote shell was switched off), `shutting_down` (restart, shut down, sign-out of the service, the app quitting). After `turned_off` and `shutting_down` the host closes the connection; after `sleeping` it may just stop answering. `reason` is required; unknown or missing → the client records only that the host said goodbye.

The client keeps the reason and the time per computer, shows the matching sentence instead of "may be asleep, off, or offline", stops redialling eagerly (one attempt a minute) and forgets it at the next `ready`.

**Old peers** ignore it and behave as today.

### 4. `open` with `shell`, sessions that say their shell, `signed_out`

```
{"t":"open","cols":80,"rows":24,"ref":7,"shell":"wsl.Ubuntu"}
{"t":"sessions","sessions":[{"id":"3F2B8C1A-7D4E-4A55-9C0B-1E6F2A9D8B34","title":"bash","startedAt":1758062400.5,"lastOutputAt":1758062461.25,"running":true,"shell":"wsl.Ubuntu"}]}
{"t":"error","reason":"signed_out","ref":7}
```

- `open.shell`: an id from the host's latest `host.shells`. Absent: the default. Fails the id rule, or is not in the host's catalog **now**: `bad_request` with the `ref`. A host with no chooser (a Mac) ignores the field. Nothing from this field reaches a command line: it is a key into a table built on the host.
- `ShellSessionInfo.shell`: the id the session was opened with; absent on a Mac. The client shows the matching `name` from `host.shells`, or the id.
- `signed_out`: the host cannot run shells for this device now (nobody signed in, another account at the console, or Passthrough not running there; the client tells which from `host`). It answers `open` (with its `ref`), `history` and `transcript` (with its `session`). In that state `list` gets an empty `sessions`, and `attach`, `input`, `close` get `no_such_session` as for any session that is gone. The host also sends `detached` for every session a connection had attached when the state begins, then `host` with `app:false`.
- **Old peers**: a deployed phone reads `signed_out` as `bad_request` (an `open` that failed). A deployed Mac ignores `shell` and opens the login shell.

### 5. `rdp` → `rdpReady`, and its refusals

```
{"t":"rdp"}
{"t":"rdpReady","certSHA256":"5c1e9a407c1e9a405c1e9a407c1e9a405c1e9a407c1e9a405c1e9a407c1e9a40"}
{"t":"error","reason":"rdp_unavailable","detail":"exposed"}
{"t":"error","reason":"try_later","retryAfter":412}
{"t":"error","reason":"screen_not_allowed"}
{"t":"error","reason":"too_many_screens"}
```

The rules are `screen`'s (`protocol/README.md`, *Screen*), restated:

- The client sends `rdp` (no fields) on an authorized connection of its own and then **nothing** until the answer. A line that arrives before `rdpReady` closes the connection. The connection leaves any session it had attached.
- On success the host answers `rdpReady`, and from the byte after that line both directions carry Remote Desktop's bytes unchanged until either side closes; then both close.
- `certSHA256`: required, 64 lowercase hex digits: SHA-256 of the DER certificate Remote Desktop is set to present, read for this relay. The client accepts **only** a TLS certificate with that hash inside the relayed session; anything else, or an `rdpReady` without a valid hash, is a hard stop before any credential is sent, with no "continue".
- Checks, in this order, first failure answers and the connection stays a shell connection:
  1. screen-only id (`viewer.`) → `screen_only` (the existing first check).
  2. the device may not see the screen → `screen_not_allowed`.
  3. Remote Desktop cannot be relayed → `rdp_unavailable` with `detail`: `off` (turned off, or nothing answers on its port within 5 s), `edition` (this Windows cannot host it), `account` (the granting account has no password Remote Desktop accepts, or may not sign in remotely), `service` (the Remote Desktop service is not running, or the far end of the loopback connection is not that service), `exposed` (the port is, or may be, open to the network). `detail` is required from a host; a client shows a general sentence for one it does not know.
  4. too many `rdp` opens → `try_later` with `retryAfter` (whole seconds, 1–3600, until one would be accepted; absent → the client waits 60). Limits: **4 per device in any 10 minutes** and **12 in all in any 10 minutes**; an open whose relay lasted more than 30 seconds is not counted.
  5. no view free → `too_many_screens` (the existing 2 per device and 4 in all, counted together with `screen` and `screenVideo`).
- **Old peers**: a deployed Mac answers `rdp` with `bad_request`; a host built from this stage that is a Mac answers the same. Clients send `rdp` only when `host.screens` contains `rdp`.

`error` gains an optional `message` (1–200 bytes, one line): a sentence written by the host, which a client shows **only** when it has no sentence of its own for the `reason`/`detail`. Clients from stage 2 on honour it; deployed ones ignore it.

### 6. What a PC answers to requests it does not serve

In `fixtures.json` as `shell.pcAnswers`, an array of `{"request": "<line>", "answer": "<line>", "note": "…"}`; each suite round-trips both lines, and the C# host gets one behavioural test per row when it exists (stage 3).

| Request | A PC answers | Why |
|---|---|---|
| `{"t":"setAwake","on":true}` | `{"t":"error","reason":"not_allowed"}` | Stay awake is a setting on the PC |
| `{"t":"setVPN","on":true}` | `{"t":"error","reason":"not_allowed"}` | no VPN layer |
| `{"t":"events","since":1758060000}` | `{"t":"eventList","since":1758060000,"events":[],"battery":[]}` | no timeline yet; not an error |
| `{"t":"push","on":false}` and with a registration | `{"t":"pushState","on":false}` | no notices yet |
| `{"t":"screenVideo"}` | `{"t":"error","reason":"screen_not_allowed"}` when the device may not see the screen, else `{"t":"error","reason":"screen_video_unavailable"}` | no stream of its own yet |
| `{"t":"screen"}` | `{"t":"error","reason":"screen_unavailable","message":"Update Passthrough on this phone to see this PC's screen."}` | no RFB |
| `{"t":"screenGrant","name":"MacBook Pro","viewer":"mac-b"}` | `{"t":"error","reason":"bad_request"}` | screen-only passes cannot use Remote Desktop |
| `{"t":"lock"}` | no reply of its own; `macState` about a second later with `locked` (as a Mac) | supported |
| `{"t":"viewing","on":true}` | no reply (as a Mac) | supported |

A PC's `macState` carries `battery`, `charging`, `locked` and `control`, and never `awake`, `vpn` or their relatives. See *Corrections* 2 for `control`.

### 7. Computers: `computer.` ids, `computerGrant`, `computerPass`, `computerRevoke`, and the proof

A **computer pass** lets one computer (the viewer) reach another (the host) with the scopes the host's owner allowed. It is a credential like a phone's, with three differences: its id starts `computer.` and only a host mints one; it carries `scopes`; and its proof must also be signed by the viewer's own **identity key**, so a copy of the credential is not enough.

**Identity key**: a P-256 signing key each computer makes once and keeps where it cannot be exported (the Mac's Secure Enclave; on Windows a non-exportable CNG key). Its public half travels as base64 of the 65-byte X9.63 form, in `host.identityKey`.

**Hand-over by a phone** (the phone holds shell access to both; H is the computer to be reached, V the one that will reach it):

```
phone → H  {"t":"computerGrant","name":"MacBook Pro","viewer":"mac-b","identityKey":"BG3/brAaPH0cBP7d9HIe8cXhSrNvipoV6v5oj/aqFKTeDp1JsQu1YkWFhJIhmma3gqu9V9JfJL7FoxnH8umDZpQ=","scopes":["shell","screen"]}
H → phone  {"t":"computerGranted","phoneID":"computer.6E1F0B52-93C4-4E0A-8D0B-5A7C1E2F3A44","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","scopes":["screen"]}
phone → V  {"t":"computerPass","pass":{"macID":"pc-a","macName":"OFFICE-PC","certSHA256":"abababababababababababababababababababababababababababababababab","shellKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","phoneID":"computer.6E1F0B52-93C4-4E0A-8D0B-5A7C1E2F3A44","port":7893,"addresses":["192.168.1.30"],"irohID":"3f2a9c5e7b1d4a60c8e2f9b4d7a1035e6c8b2d4f9a1e3c5b7d0f2a4c6e8b1d3f","hostKind":"windows"},"scopes":["screen"]}
V → phone  {"t":"computerPassSaved"}
phone → H  {"t":"computerRevoke","phoneID":"computer.6E1F0B52-93C4-4E0A-8D0B-5A7C1E2F3A44"}      (only if V did not keep it)
H → phone  {"t":"computerRevoked"}
```

`computerGrant` (phone → H):
- `name`: as `screenGrant`'s (1–64 characters, one line). `viewer`: V's id as the phone knows it, 1–128 bytes; a new pass for the same `viewer` from the same phone replaces the old one **once V first proves the new one** (as screen passes do).
- `identityKey`: required; must decode to a valid P-256 point in X9.63 form. The phone takes it from V's `host` message on its own authenticated connection to V, never from anywhere else.
- `scopes`: required, non-empty; values `shell`, `screen`; unknown values dropped; duplicates ignored.
- Refused: `not_allowed` when the owner of H has not let this phone share access (a per-phone switch on H, off by default), or when the asker is itself a `computer.` or `viewer.` id (**no onward grants**); `bad_request` for a bad name, key or empty scopes; `pass_not_saved` when H could not store it. H grants the intersection of what was asked and what the phone itself holds (`shell` always; `screen` only if the phone may see the screen); if that is empty, `screen_not_allowed`.
- H keeps at most **8 computer passes per granting phone**, the oldest going. Each remembers its granter: removing or forgetting that phone removes its passes and closes their connections at once. H shows a notice that stays when a pass is granted.

`computerGranted` (H → phone): `phoneID` (starts `computer.`, at most 128 bytes), `key` (32 bytes, base64), `scopes` (what was granted, never empty). A phone that gets anything else revokes and reports failure.

`computerPass` (phone → V): `pass` is a credential as in `screenPass`, with `phoneID` starting `computer.`, and `scopes`. V keeps it only if: the key is 32 bytes; the id has the prefix and is at most 128 bytes; `certSHA256` is 64 hex; `macID` is 1–128 bytes; the name is valid; at most 16 addresses; iroh details valid when present; `scopes` non-empty after dropping unknown values; `hostKind` valid when present. **It replaces a pass V already holds for the same `macID` only when `certSHA256` and `irohID` both equal the held one's**; otherwise `bad_request` (so a phone cannot repoint an existing computer entry at another machine). Answer: `computerPassSaved`, or `error` `bad_request` / `pass_not_saved`. V notes which phone handed it over; revoking that phone on V forgets the pass.

`computerRevoke` (phone → H): `phoneID` of a pass this phone was granted. Answer `computerRevoked`, or `bad_request` when it is not one of this phone's.

**The proof of a `computer.` id**

```
{"t":"proof","phoneID":"computer.6E1F0B52-93C4-4E0A-8D0B-5A7C1E2F3A44","mac":"nElWNgnCJjzZ2TIJGYHmD1OjNqU7gfAP0KSTIqlGRcE=","sig":"<64 bytes, base64>"}
```

- `mac` as for a phone: HMAC-SHA256(key, `"passthrough-shell-v1"` ‖ nonce).
- `sig` = ECDSA P-256 with SHA-256, by the viewer's identity key, over `"passthrough-computer-v1"` ‖ nonce (32 raw bytes) ‖ the id (UTF-8) ‖ the host's `certSHA256` (32 raw bytes, from the pass); encoded as raw `r ‖ s` (64 bytes), base64.
- The host admits a `computer.` id only when both check out against the stored key and the stored `identityKey`. It does the same amount of work whether the id is known or not, and answers every failure `not_authorized`, as today. A `computer.` id without `sig`, and any other id **with** a pass's key, are refused. The line still fits the 4096-byte limit.

**What a computer's connection gets**: `ready`, `macInfo`, `host`; with the `shell` scope also `macState` (with `control:false`) and `sessions`. Without `shell`, every request but `rdp`, `screenVideo`, `screen`, `ping`, `pong` is answered `screen_only`. Without `screen`, those three are answered `screen_not_allowed`. Whatever its scopes: `setAwake`, `setVPN`, `lock` → `not_allowed`; `computerGrant`, `screenGrant`, `push` → `not_allowed`.

`viewer.` ids are unchanged and stay screen-only for good; a PC refuses them `rdp` (`screen_only`).

**Old peers**: a deployed Mac answers `computerGrant`, `computerPass` and `computerRevoke` with `bad_request`. A phone offers the hand-over only when V's `host` carries `identityKey` and H's `host` was heard at all; otherwise it offers today's screen-only pass, or nothing.

### 8. Names reserved for direct pairing (specified in stage 7)

Reserved now so nothing else takes them; no fixture lines, no code: Bonjour service `_passthrough-pair._tcp`; message types `pairHello`, `pairCommit`, `pairReveal`, `pairCode`, `pairDone`, `pairError`; labels `passthrough-pair-v1` and `passthrough-pair-code-v1`; fixture section `computerPairing`. In `fixtures.json`: `"reserved": {"serviceTypes": ["_passthrough-pair._tcp"], "messageTypes": [...], "labels": [...]}` under `shell`, read by no test.

### Fixture layout (what PR 2 and PR 4 add to `protocol/fixtures.json`)

- `_comment`: "Shared by the Swift tests (Packages/PassthroughCore), the Kotlin tests (android/) and the C# tests (windows/). Change it and all three suites must agree."
- top-level `messages`: + the `shellGrant` with `hostKind` (section 2).
- `shell.messages`: + the three `host` lines, `goingAway`, `open` with `shell`, `sessions` with `shell`, `signed_out`, `rdp`, `rdpReady`, `rdp_unavailable` with `detail`, `try_later` with `retryAfter`, `too_many_screens`, `screen_unavailable` with `message`, `screen_only`, and the `proof` with `sig`.
- `shell.host`: `{"kinds":["mac","windows"],"consoleStates":["active","locked","signedOut","otherUser"],"screens":["video","rfb","rdp"],"rdpStates":["ready","off","edition","account","service","exposed"],"goingAwayReasons":["sleeping","turned_off","shutting_down"],"inUseIdleSeconds":120,"maxShells":32,"maxLineBytes":16384,"rdpOpensPerDevice":4,"rdpOpensInAll":12,"rdpWindowSeconds":600,"rdpLongOpenSeconds":30}`.
- `shell.errors`: every `error` reason as a string, old and new (so each suite's enum is checked for completeness; none is today).
- `shell.pcAnswers`: section 6.
- `shell.computer` (PR 4): `{"idPrefix":"computer.","proofLabel":"passthrough-computer-v1","maxPerGranter":8,"scopes":["shell","screen"],"messages":[…section 7's six lines…],"proofs":[{"identityPublicKey":"<hex X9.63>","identityPrivateKey":"<hex, the shellKeySeal test key>","nonce":"<base64>","phoneID":"computer.…","certSHA256":"<hex>","signed":"<hex of the exact bytes signed>","sig":"<base64>"}],"passes":[{"pass":{…},"scopes":[…],"usable":true|false,"why":"…"} …]}`. ECDSA signatures are not reproducible, so each suite **verifies** the stored `sig`, checks a flipped one fails, rebuilds `signed` from the parts, and signs and verifies one of its own.
- `shell.reserved`: section 8.

### C# types (new, `windows/src/Passthrough.Core/Protocol/`)

`ShellEnvelope.cs`: `public sealed class ShellEnvelope` with every key Swift has plus the new ones, `[JsonPropertyName]` on each, the same `JsonSerializerOptions` as `ControlEnvelope.cs:27-31`, `byte[] EncodeLine()`, `static ShellEnvelope Decode(ReadOnlySpan<byte>)` throwing `ProtocolException`; string constants for every `t`. Records beside it: `ShellSessionInfo`, `ShellStatus`, `ShellTheme`, `ShellHistoryEntry`, `MacState`, `MacEvent`, `BatterySample`, `PushRegistration`, `ShellCredentialWire` (`shellKey` as base64 string), `HostInfo`, `HostShell`. `RemoteShell.cs`: the constants of `ShellProtocol.swift:6-28`, `Proof`, `ProofIsValid` (`CryptographicOperations.FixedTimeEquals`). `ShellErrorWire.cs`: the reasons, with `Parse` returning `BadRequest` for unknown. `IrohInfo.cs`: the three validators. `HostInfoRules.cs`: `HostInfo? Clean(HostInfo)` applying section 1's table. `ComputerPass.cs` (PR 4): `IdPrefix`, `IsComputerId`, `IsUsable`, `MayReplace`, `SignedBytes`, `Verify` (`ECDsa.VerifyData`, `DSASignatureFormat.IeeeP1363FixedFieldConcatenation`). All portable; no Windows API. `ShellAddressPolicy` is **not** ported here (stage 3).

Swift and Kotlin get the same shapes: `HostInfo`/`HostShell` structs, `HostInfo.cleaned()`, `ComputerPass` beside `ScreenPass` (Swift only; Kotlin models no passes).

### The Windows CI job, lock files and source mapping

- **SDK**: a `global.json` at the **repo root** (`dotnet` looks for it from the working directory upward, and every documented command runs from the root): `{"sdk": {"version": "10.0.100", "rollForward": "latestFeature"}}`. CI installs it with `actions/setup-dotnet`, pinned by commit SHA with the tag in a comment, `global-json-file: global.json`. The SHA is looked up when the PR is written (`git ls-remote https://github.com/actions/setup-dotnet 'refs/tags/v5*'`) and recorded like the others in `ci.yml`.
- **Lock files**: `windows/Directory.Build.props` gains `<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>` and `<DisableImplicitNuGetFallbackFolder>true</DisableImplicitNuGetFallbackFolder>`; `packages.lock.json` is committed beside each csproj. CI restores with `--locked-mode`. To change a package: edit the version, `dotnet restore --force-evaluate`, commit the lock file in the same PR.
- **Source mapping**: `windows/nuget.config` (found by NuGet from the project folder upward): `<clear/>`, one source `nuget.org` (`https://api.nuget.org/v3/index.json`), and `<packageSourceMapping>` mapping `*` to it, so no other configured feed can supply a package.
- **Jobs** (added to `.github/workflows/ci.yml`; header comment and `CONTRIBUTING.md` updated to say so):

```yaml
  windows:
    name: Windows tests and app build
    runs-on: windows-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: actions/setup-dotnet@<commit SHA> # v5.x.y
        with:
          global-json-file: global.json
      - name: Restore (locked)
        run: dotnet restore windows/Passthrough.Windows.sln --locked-mode
      - name: dotnet test
        run: dotnet test windows/tests/Passthrough.Core.Tests -c Release --no-restore
      - name: Build the app
        run: dotnet build windows/src/Passthrough.App -c Release --no-restore
```

  and in `core-tests` (macOS), after `swift test`, so the C# suite also runs where the Swift one does (stage 3 adds C#-against-Swift loopback tests to this job):

```yaml
      - uses: actions/setup-dotnet@<commit SHA> # v5.x.y
        with:
          global-json-file: global.json
      - name: dotnet test (Windows Core, portable)
        run: |
          dotnet restore windows/tests/Passthrough.Core.Tests --locked-mode
          dotnet test windows/tests/Passthrough.Core.Tests -c Release --no-restore
```

  The job name becomes "PassthroughCore and Windows Core tests". Later stages append to the `windows` job: stage 3 the bridge (`cargo build --release --locked` in `windows/native/iroh-bridge`, `cargo deny check`, with rustup reading `rust-toolchain.toml`), stage 4 `dotnet build windows/src/Passthrough.Service`. They are not added now because the projects do not exist.
- No package cache in the first version (restore of three projects is quick); add `cache: true` with `cache-dependency-path: windows/**/packages.lock.json` if the job passes five minutes.

### `protocol/README.md`: the new text, as an outline

1. **Opening paragraph**: "What a computer (a Mac or a Windows PC) and a phone say to each other … The Swift implementation is in `Packages/PassthroughCore`, the Kotlin one in `android/…/core`, the C# one in `windows/src/Passthrough.Core`. All three test suites read `fixtures.json`; change a message, a port or a pairing rule there first, then make all three pass." Add one sentence: "The text says *Mac* where the rule is the same for any host; a PC differs only where *A Windows PC as host* says so."
2. **Control channel table**, `shellGrant` row: append "`hostKind`?" to the fields and the rule from section 2.
3. **Remote shell ▸ Handshake**: step 3 becomes "`ready`, then `macInfo`, `host`, `macState` and `sessions` (each only when the host has one to send)". Add: "Nothing but `challenge`, `ready` and `error` `not_authorized` is ever sent before `ready`: phones end the connection on anything else, and read any other error as access lost." Add the `computer.` proof (`sig`) as step 2a, pointing to *Computers*.
4. **Messages table**: new rows `host`, `goingAway`, `rdp`, `rdpReady`, `computerGrant`, `computerGranted`, `computerPass`, `computerPassSaved`, `computerRevoke`, `computerRevoked`; `open` gains `shell`?; `sessions` gains `shell`?; `proof` gains `sig`?; `error` gains `detail`?, `message`?, `retryAfter`? and the reasons `signed_out`, `rdp_unavailable`, `try_later`.
5. **New subsection "The host"** (after *Mac state and control*): section 1's table, the resend rule, the size limit, "absent means a Mac from before".
6. **New subsection "Going away"**: section 3.
7. **New subsection "A Windows PC as host"**: shells and the chooser (section 4); `signed_out`; the answers table (section 6); what its `macState` carries.
8. **Screen**: one added sentence: which request to send is chosen from `host.screens`. **New subsection "Remote Desktop relay"** after *Screen*: section 5 in full, including the limits and the certificate rule, and one paragraph on why the hash is sent (no trust on first use; a stand-in gets nothing).
9. **Screen video ▸ ack**: "2 to 16" → "2 to 24" (`StreamPacer.swift:23-24`).
10. **Screen passes**: add "A PC refuses a screen pass `rdp`." **New subsection "Computers"** after it: section 7, then "Pairing two computers directly: reserved (`_passthrough-pair._tcp`); specified with stage 7."
11. **Address policy**: last sentence "Only the Mac listens, so this check has no Kotlin counterpart and no fixtures" → "Only computers listen; the Windows rule for what counts as a tunnel interface is added with its listener."

## Pull requests, in order

1. **CI: a Windows job, the .NET SDK pinned, NuGet locked to one source**
   Scope: the CI design above. Files: `.github/workflows/ci.yml`, `global.json`, `windows/nuget.config`, `windows/Directory.Build.props`, three `packages.lock.json`, `CONTRIBUTING.md` (Windows set-up paragraph; "three suites"; checklist line "`dotnet test windows/tests/Passthrough.Core.Tests` passes (if you touched `windows/` or `protocol/`)"), `windows/README.md` (Build: lock files and how to change a package), `CHANGELOG.md`. Tests: none new; the existing C# suite now runs twice in CI. Verify by hand: push a branch with a deliberately failing C# test and see both jobs go red; edit a package version without the lock file and see `--locked-mode` fail. Leaves out: service and bridge builds; caching. Depends on stage 0's PR 1 (the app must build).
2. **Protocol: a C# shell envelope, and all three suites reading the same shell fixtures**
   Scope: no new wire content. C# `ShellEnvelope` and friends, `RemoteShell`, `IrohInfo`, `ShellErrorWire`; fixtures gain `shell.errors` (today's reasons only) and the missing lines that all three can model (`replaying`, `lock`, `viewing`); the `_comment`. Tests: see *Tests*, "C#" rows marked PR 2. Docs: `protocol/README.md` opening paragraph (outline 1), `CHANGELOG.md`. Verify: the three commands. Leaves out: anything new on the wire.
3. **Protocol: the host says what it is, names its shells, and can relay Remote Desktop**
   Scope: sections 1–6 and 8 in fixtures, README and the three envelopes; `HostInfo` cleaning in all three; `hostKind` stored in `ShellGrant`/`ShellCredential` on both phones (stored and ignored by the UI until stage 2); **the Mac host sends `host`** (`kind:"mac"`, `os`, `screens`, `screenAllowed`, no `identityKey` yet) in the order of section 1 (`ShellListener.swift:733-742`), and `ShellClient`/`ShellConnection.kt` surface it as a new event that no UI consumes yet. Files: `protocol/*`; `ShellProtocol.swift`, `Protocol.swift`, `Pairing.swift`, `ShellClient.swift`, `ControlServer.swift`, `ShellListener.swift`, the Mac app's listener wiring; `ShellProtocol.kt`, `Protocol.kt`, `Pairing.kt`, `ShellCredentials.kt`, `ShellConnection.kt`, `ControlServer.kt`; the C# files; tests. Docs: README outline 2–9 and 11; `CHANGELOG.md` ("Works now: nothing you can see. Not yet: PCs."). Verify by hand: (a) the iPhone and Android builds from `main` against a Mac from this PR: grant over the cable, open a shell, open the screen, lose and regain the connection; (b) phones from this PR against the Mac from `main`; (c) `nc`/a test client shows `ready, macInfo, host, macState, sessions` in that order. Leaves out: any sender of `goingAway`, `rdp` handling, `signed_out`, the chooser, all UI.
4. **Protocol: computers get their own access, bound to their identity key**
   Scope: section 7 in fixtures (with the proof vector), README (outline 10), the Swift and C# envelopes and `ComputerPass` rules; Kotlin gains only what keeps its round trip honest (see *Tests*). No host mints a `computer.` id yet and no listener accepts one: the Mac's gate refuses any id with the `computer.` prefix (`not_authorized`) until stage 7a implements the store, so the prefix cannot be claimed by a phone's grant meanwhile (the same guard as `ShellAccessStore.swift:145` has for `viewer.`). Docs: README, `CHANGELOG.md`. Verify: the three commands; a hand-made proof for `computer.x` against the Mac is refused. Leaves out: minting, storing, the identity key itself, UI, `SECURITY.md` (stage 7), direct pairing.

Each PR leaves `dev` working: 1 and 2 change no shipped behaviour; 3 adds one ignored message; 4 adds one refusal for ids nobody holds.

## Interfaces

### This stage defines (others depend on these): name, shape, owner

| Name | Shape | Owner after this stage |
|---|---|---|
| `host` message and `HostInfo` (+ cleaning rules) | section 1 | senders: Mac (here), PC (stage 3 for `shells`/`signedIn`/`app`, stage 4 `console`/`sleepAfter`, stage 5 `rdp`); readers: stage 2 |
| `hostKind` | section 2 | stage 3 sends it; stage 2 reads it |
| `goingAway` | section 3 | stage 4 (PC), optionally the Mac later; stage 2 reads it |
| `open.shell`, `ShellSessionInfo.shell`, `signed_out` | section 4 | stage 3 (catalog, sessions), stage 4 (`signed_out`) |
| `rdp`/`rdpReady`, `rdp_unavailable`+`detail`, `try_later`+`retryAfter`, `error.message` | section 5 | stage 5 (host), stage 6 and 7c (viewers) |
| `shell.pcAnswers` | section 6 | stage 3's C# `ShellConnection` has one test per row |
| `computer.` ids, `computerGrant`/`Granted`/`Pass`/`PassSaved`/`Revoke`/`Revoked`, `sig`, `identityKey`, `ComputerPass` rules | section 7 | stage 7a (Mac, phone), stage 8a (PC as viewer), stage 4/5 (PC as host) |
| Reserved pairing names | section 8 | stage 7b |
| C# `ShellEnvelope`, `RemoteShell`, `IrohInfo`, `ShellErrorWire` | *C# types* | stage 3 builds `ShellConnection` on them |
| CI `windows` job; `global.json`; lock-file rule | *CI* | every later Windows PR |

### This stage consumes (from which stage)

- Stage 0, PR 1: the Windows app builds (PR 1's app-build step).
- Stage 0, spike 0.3 (i) and 0.2: the form of `host.user` per account kind. If not known when PR 3 is written, the README says "as Windows shows it on the sign-in screen" and stage 5 tightens it.
- Stage 0, spike 0.3 (a–d): confirms the four `console` values are the right set. A fifth state found there is added before PR 3 merges.

## Tests

**Swift** (`Packages/PassthroughCore/Tests/PassthroughCoreTests/`)

- `ShellProtocolTests.testShellMessagesRoundTrip` (`:45-55`): unchanged code; passes only once `ShellEnvelope` has `host`, `shell`, `detail`, `message`, `retryAfter`, `certSHA256`, `sig`, `identityKey`, `scopes`, and `ShellSessionInfo.shell`. Raise the floor at `:47` to the new count. Add the same loop over `shell.computer.messages` (PR 4).
- New `testErrorReasonsMatchFixtures`: every string in `shell.errors` is a `ShellError` case and the reverse (replaces the four hand-written asserts at `:212-217`).
- New `testHostFields`: decodes the three `host` lines; asserts each field of the full PC line; `HostInfo.cleaned()` drops an over-long `os`, a bad shell id, a second `default`, an unknown `console`, and keeps an unknown `kind`; a `host` with no `kind` is nil; constants equal `shell.host`.
- New `testOlderPeersIgnoreWhatIsNew`: a line with every new key added to a `sessions` message still decodes to the same sessions; `{"t":"host","host":"x"}` (wrong type) fails to decode (documents rule 3).
- New `testPCAnswersRoundTrip`: both lines of every `shell.pcAnswers` row.
- `ProtocolFixtureTests.testMessagesRoundTrip` (`:75-86`): unchanged; passes once `ControlEnvelope.hostKind` exists. New `testHostKindIsKeptWithTheGrant` in the control-server tests: a grant with `hostKind` stores it; an invalid one stores the grant without it.
- `ShellHostTests/ShellListenerTests`: a new test for the order `ready, macInfo, host, macState, sessions`, that a `viewer.` connection gets no `host`, and that `host` is resent on change and at most once a second; existing tests that count lines after `ready` are adjusted.
- PR 4: `testComputerProofVector` (verify, flipped fails, `signed` rebuilt, own sign-and-verify), `testComputerPassRules` over `shell.computer.passes`, including the replace rule; a listener test that a `computer.` id is refused.

**Kotlin** (`android/app/src/test/java/dev/dpatel/passthrough/core/`)

- `ShellProtocolTests.shellMessagesRoundTrip` (`:42-48`): unchanged code; passes once Kotlin's `ShellEnvelope` has `host` (`HostInfo`, `HostShell` as `@Serializable`), `shell`, `detail`, `message`, `retryAfter`, `certSHA256`, `sig`, and `ShellSessionInfo.shell`; `ShellError` gains `SIGNED_OUT`, `RDP_UNAVAILABLE`, `TRY_LATER`, and the screen reasons it lacks today (`SCREEN_NOT_ALLOWED`, `SCREEN_UNAVAILABLE`, `SCREEN_VIDEO_UNAVAILABLE`, `TOO_MANY_SCREENS`, `SCREEN_ONLY`, `PASS_NOT_SAVED`) so `errorReasonsMatchFixtures` holds.
- New `hostFields`, `errorReasonsMatchFixtures`, `pcAnswersRoundTrip`, as Swift's.
- New `computerMessagesAreIgnoredNotFatal` (PR 4): every `shell.computer.messages` line **decodes** and keeps its `t`. Kotlin does not model `pass`, `identityKey` or `scopes` (Android hands nothing over in this plan), so those lines are deliberately not in `shell.messages`.
- `ProtocolFixtureTests` control round trip: passes once `ControlEnvelope.hostKind` exists. `ShellGrantTests`: `hostKind` kept, invalid dropped. `ShellConnectionTests`: a `host` after `ready` becomes a `ShellEvent.Host`; `goingAway` becomes an event; an unknown `t` after `ready` is still ignored.

**C#** (`windows/tests/Passthrough.Core.Tests/`)

- `Fixtures.cs`: add `public static bool JsonEqual(string a, string b)` comparing objects and arrays structurally and **numbers by value** (`1758066000.0` equals `1758066000`), as Kotlin's `normalize` does; `FixtureTests.Messages_RoundTrip` (`:85-95`) switches to it. (`JsonNode.DeepEquals` on parsed text is not relied on for numbers.)
- New `Protocol/ShellFixtureTests.cs` (PR 2): `Constants_MatchFixtures` (port, service type, proof label, limits), `Proof_MatchesFixture`, `ShellMessages_RoundTrip`, `ErrorReasons_MatchFixtures`, `Decode_IgnoresUnknownFields`, `Decode_NonJson_Throws`, `IrohValidation` (the cases of `ShellProtocolTests.swift:125-140`).
- PR 3: `Host_Fields`, `Host_Cleaning`, `PcAnswers_RoundTrip`; `FixtureTests.Messages_RoundTrip` passes once `ControlEnvelope.HostKind` exists.
- PR 4: `ComputerMessages_RoundTrip`, `ComputerProof_Vector`, `ComputerPass_Rules`.

**Fixtures added**: listed under *Fixture layout*.

**Real-hardware checklist** (PR 3, in the PR description, not a file): the two mixed-version runs in PR 3's "verify by hand", on an iPhone and an Android phone.

## Security considerations for this stage

- **`host` tells an authorized device more than before**: the sign-in name, whether anyone is at the PC and for how long, which shells exist. It goes only after a valid proof, never to `viewer.` ids, and to a computer only what its connection may use. `user` is the one sensitive field; it is needed to pre-fill the sign-in sheet, and a device that holds shell access can read it anyway.
- **`rdpReady.certSHA256` replaces trust on first use.** Its strength is the shell connection's own authentication (pinned TLS or iroh, plus the key proof). The rule "a mismatch is a hard stop, no continue" is in the README so no viewer adds a prompt.
- **`try_later` and the open caps** are the only brake the relay has on password guessing, since it cannot see a sign-in fail. The numbers are in the fixtures so host and tests cannot drift; spike 0.3 (h) checks them against a real lockout policy.
- **`open.shell` is an index, not a command.** The id rule (a short ASCII alphabet) is enforced at decode in all three implementations, before any catalog lookup.
- **Computer passes**: the HMAC key alone no longer admits a `computer.` id; the signature covers the nonce, the id and the host's certificate hash, so it cannot be replayed to another host or under another id. The public key reaches the host through the granting phone, which is trusted for this exactly as it is trusted to choose the viewer in `screenGrant` today; a phone that lies binds the pass to a key it controls, which gives it nothing beyond the shell access it already has. No onward grants, a cap per phone, removal with the granter, and scopes that can only shrink.
- **PR 4 closes the prefix before anything mints it**: a grant or proof under `computer.` is refused from this stage on.
- **Nothing new before `ready`** also means an unauthenticated peer learns nothing new: no host kind, no state.
- **CI**: the new action is pinned by SHA; the job has `contents: read` only and no secrets; `--locked-mode` plus source mapping means a package cannot change or come from elsewhere without a diff.

## UX states and strings for this stage

None ship. Two strings are fixed on the wire here because a host sends them: `error.message` for `screen` on a PC, "Update Passthrough on this phone to see this PC's screen." (master plan, *Protocol changes*). Stage 2 maps `host`, `goingAway` and the reasons to the master plan's state tables; this stage's field meanings were chosen so each row there has exactly one source:

| Master-plan row | Read from |
|---|---|
| "went to sleep at 14:02" / "Remote access was turned off" | `goingAway.reason` + receipt time |
| Shell: nobody signed in / someone else / Passthrough closed | `host.console` = `signedOut` / `otherUser`; `signedIn:true, app:false` |
| "Someone is using *Office-PC* right now" | `console:"active"` and `idleSeconds` < 120 |
| Screen switch off / Remote Desktop off / Windows Home / no password | `screenAllowed:false`; `host.rdp` = `off` / `edition` / `account` |
| "Too many sign-ins from this iPhone. Try again in 10 minutes." | `try_later` + `retryAfter` |
| "This isn't the Remote Desktop *Office-PC* told us to expect" | `rdpReady.certSHA256` mismatch |
| "It sleeps after 30 minutes" | `host.sleepAfter` |

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| A deployed client chokes on `host` after `ready` | Read in the code (table above); PR 3's mixed-version runs on real phones before merge |
| A new key collides with an existing one in some envelope | Rule 3; `testOlderPeersIgnoreWhatIsNew`; the key list in *What exists today* |
| The three round trips disagree on number formatting | `Fixtures.JsonEqual` (C#), `normalize` (Kotlin), `NSDictionary` (Swift) all compare by value; PR 2 proves it on today's lines before anything is added |
| The contract is wrong for a state the spikes find | PR 3 waits for spike 0.3's state table; `console`, `rdp` and `detail` are open sets on the reader's side, so adding a value later breaks nobody |
| Lock files differ between macOS and Windows restores | Only Core and its tests are restored on macOS (pure `net10.0`); the app's lock file is only ever restored on Windows. If the SDK's implicit packages make `--locked-mode` fail across patch versions, tighten `rollForward` to `latestPatch` |
| `windows-latest` moves under us | Accepted, as `ubuntu-latest` is for Android (`ci.yml:74`); pin to a named image the first time it breaks a build |
| The Kotlin suite carries fields Android never uses | Limited to plain strings and `HostInfo`; passes are kept out of `shell.messages` on purpose |
| ECDSA encodings differ (DER vs raw) | The vector fixes raw `r‖s`; each suite verifies the same bytes |

## Decisions made here

1. **`host`'s fields live in a nested `host` object**, as `macState`'s live in `state`. Reason: a flat field whose name later collides with a typed key drops the whole line on phones.
2. **`host` is not sent to `viewer.` connections.** Reason: they are screen-only and get only `ready` today; a PC refuses them `rdp` anyway.
3. **Order after `ready`: `macInfo`, `host`, `macState`, `sessions`**, as the master plan's port list has it.
4. **Three fields beyond the master plan's list**: `app` (see Corrections 1), `screenAllowed` (so "Screen is off for this iPhone" shows without a failed tap), `identityKey` (how a phone learns a computer can hold a pass, with no extra request).
5. **Going away is its own message, `goingAway`**, not an `error`. Reason: deployed phones would show an `error` as a failure; they ignore an unknown message.
6. **`signed_out` is one reason**; which of the three situations it is comes from `host`. Reason: old phones collapse every unknown reason anyway, and new ones always have `host`.
7. **An unknown shell id is `bad_request`**, not a new reason. Reason: it can only happen in a race with a catalog change; the next `host` corrects the list.
8. **`rdp_unavailable.detail` and `host.rdp` share one vocabulary**; "the far end isn't Windows' service" is folded into `service`.
9. **`try_later` carries `retryAfter`**; caps are 4 per device and 12 in all per 10 minutes (the master plan gives 4 and "a global cap").
10. **`error.message` added** as a general host-written fallback sentence.
11. **A session says its shell** (`ShellSessionInfo.shell`), so "Ubuntu · running · 4m" needs no guessing from titles.
12. **Computer hand-over reuses the screen-pass choreography** with new message names and an identity key from `host`; signature is ECDSA P-256/SHA-256, raw `r‖s`, over label ‖ nonce ‖ id ‖ host certificate hash. Reason: P-256 is what both platforms can hold non-exportably (Secure Enclave, CNG) and what the repo already uses.
13. **Computer passes: 8 per granting phone**, counted apart from screen passes.
14. **Computer lines sit in `shell.computer.messages`, not `shell.messages`**, and Kotlin only proves it ignores them. Reason: Android hands nothing over in this plan.
15. **The C# shell envelope lands here**, not in stage 3. Reason: "three suites on the same fixtures" is this stage's done-when.
16. **The Mac sends `host` from this stage.** Reason: it is the only way to prove on real phones, now, that the message is harmless; and stage 2 then has something to read.
17. **`global.json` at the repo root; `nuget.config` and the lock-file switch under `windows/`.** Reason: where each tool looks.
18. **`SECURITY.md` is not touched here**; its "paired over the cable" rule is rewritten in stage 7 with the hand-over that changes it (master plan §5).
19. **`pcAnswers` in fixtures now, behavioural tests in stage 3**, since no C# host exists yet.

## Corrections to the master plan

1. **`signedIn` alone cannot tell the three shell states apart.** "Nobody signed in", "someone else signed in" and "Passthrough isn't open" need: `console`, plus whether the granting account has a session, plus whether its app is connected. Added `app`; `signedIn` now means "has a session".
2. **A PC's `macState` cannot say `control:false` and also support Lock.** The iPhone offers Lock only when `control == true` (`iOS/App/Screen/ScreenView.swift:63`, `MacHomeView.swift:571`). A PC should send `control:true` for phones (and omit `awake`/`vpn`), answering `setAwake`/`setVPN` `not_allowed`. Stage 2 must check what a deployed iPhone then shows for Keep awake and the VPN on a PC, and say so in the guide if a dead row appears.
3. **"(the PC sends this text to old apps)" cannot work.** No deployed app shows a host-written sentence for a screen error: the reason is mapped to an enum and the rest ignored (`ShellClient.swift:757-769`, `ShellConnection.kt:451-457`). The `message` field is defined, but only apps from stage 2 on show it; an older iPhone asked for a PC's screen fails as the master plan's "Known and documented" note already says.
4. **"`host` … on every connection"**: every connection except screen-only passes (Decision 2).
5. **New error reasons must never be sent before `ready`** (deployed phones read any unknown pre-`ready` error as access lost). The master plan says this for message types only.
6. **"both existing suites fail on an unmodelled field"** is true of round-tripped lines only, and the fixtures hold fewer messages than the README (no passes, push, status). So the Kotlin envelope need not grow every new field: only those in `shell.messages`.
7. **The pacing fix is "2 to 24"** (`StreamPacer.swift:24`), in `protocol/README.md:677-678`.
8. **The CI line "tests, app, service and bridge builds"**: only tests and the app exist in stage 1; the other two steps are added by the stages that create those projects.

## Open questions for the owner (each with a recommended default)

1. **Should a Mac start sending `host` in this stage** (PR 3), before any phone uses it? **Recommended: yes**; it is ignored by every deployed phone and is the real-hardware proof of that.
2. **`host.user` discloses the Windows sign-in name to every phone with shell access.** Send it always, or only to devices with the Screen switch on? **Recommended: only when `screenAllowed` is true**, since its one use is the sign-in sheet.
3. **The identity key is P-256 held in the Secure Enclave / a non-exportable CNG key**, separate from the TLS certificate key and the iroh key. Acceptable, or reuse the TLS key? **Recommended: a separate key**, so resetting the network identity does not orphan computer passes and the other way round.
4. **Relay caps**: 4 opens per device and 12 in all per 10 minutes, long opens (over 30 s) not counted. **Recommended: keep, subject to spike 0.3 (h).**
5. **`windows-latest` or a pinned image** (`windows-2025`) for CI? The repo pins macOS but not Ubuntu. **Recommended: `windows-latest`, as the master plan says.**
6. **`global.json` at the repo root** affects any `dotnet` command run in the repo (including `Spikes/`). **Recommended: accept.**
