# Wire protocol

What the Mac and a phone (iPhone or Android) say to each other, and an iPad
and the iPhone it gets its internet from ([iPad](#ipad)). The Swift
implementation is in `Packages/PassthroughCore`, the Kotlin one in
`android/app/src/main/java/dev/dpatel/passthrough/core`, the C# one (the
Windows host) in `windows/src/Passthrough.Core`. All three test suites read
[`fixtures.json`](fixtures.json); change a message, a port or a pairing rule
there first, then make all three pass.

## Transport

The phone listens on its own loopback only. The Mac reaches those ports
through a *phone link* (`PhoneLink` in `PhoneTransport`): usbmuxd for an
iPhone, the adb server for an Android phone. Everything below runs unchanged
over any link that carries a TCP stream.

| Port | What |
|------|------|
| 7890 | SOCKS5 proxy |
| 7891 | Control channel |

On the Mac, `LocalForwarder` exposes the phone's SOCKS port on
`127.0.0.1:17890` for the root helper's tun2socks.

## Control channel (7891)

Newline-delimited JSON, one object per line, lines up to 256 KB. Every
message has a type tag `t`; every other field is optional and omitted when
absent (never `null`). Unknown fields are ignored. Protocol version 2.

| `t` | From | Fields | Meaning |
|-----|------|--------|---------|
| `hello` | Mac | `protocolVersion`, `clientID`, `name`, `nonce`, `via`? | First message. `nonce` is 32 random bytes, base64, fresh per connection; no token. `via` is `usb` or `wireless`: how this connection reaches the phone (a phone may have a wireless link up while the Mac uses the cable). |
| `welcome` | phone | `protocolVersion`, `paired`, `nonce`, `proof`? | Reply to `hello`, with the phone's own fresh `nonce`. `paired: true` comes with `proof` (below); `paired: false` means pair first. Nothing else: the peer is a stranger until it proves itself, so the phone's name and status wait for `status` (phones before this sent `socksPort` and device facts here too; the Mac ignores them). |
| `auth` | Mac | `proof` | The Mac's proof, sent first after a `welcome` whose proof it verified. The connection is authenticated once the phone has verified it, and the phone answers with a `status` at once. |
| `pair` | Mac | `clientID`, `name`, `code` | The six digits shown on the phone. After `hello`; `clientID` must match it. |
| `paired` | phone | `token`, `socksPort`, `deviceName` | Pairing worked (the connection is now authenticated); followed by a `status`. |
| `error` | phone | `reason`, `protocolVersion`? | `bad_code`, `expired`, `locked` (too many wrong codes on this connection, which the phone then closes), `code_withdrawn` (too many wrong codes against this code: pairing needs a new one), `not_authenticated` or `unsupported_version` (which carries the phone's `protocolVersion`, absent from version 1 phones). Earlier phones sent `locked` for a 30 s lockout; a Mac that doesn't know a reason reads it as `bad_code`. |
| `ping` / `pong` | Mac / phone | none | Heartbeat every 5 s; the Mac gives up after 20 s of silence. |
| `status` | phone | device facts, `activeConnections`, `rxBytes`, `txBytes`, `timestamp` | To authenticated Macs only: right after `auth` or `paired`, then once a second. The Mac ignores it before. |
| `shellGrant` | Mac | `shellKey`, `certSHA256`, `shellPort`, `addresses`, `macName`, `irohID`?, `irohRelay`?, `relayToken`?, `grantID`?, `hostKind`? | Over the cable, on every paired connection while Remote shell is on: gives the phone access to the Mac's remote shell (below). `shellKey` is 32 random bytes, base64; `addresses` are where to dial the Mac. Each grant is a fresh key; the Mac also accepts the key the phone last proved until the phone first proves the new one, since a phone adopts a grant only once its app is unlocked. The optional `irohID` (the Mac's iroh endpoint id: 64 lowercase hex), `irohRelay` (its home relay: an `https` URL, at most 256 characters) and `relayToken` (at most 512 characters; kept in the phone's secret store, never in the grant record) let the phone dial the Mac over iroh (below). If the iroh fields are not valid as a group (a valid `irohID` is required; lengths count UTF-8 bytes), the phone drops all three and still stores the rest of the grant. The optional `grantID` (at most 64 UTF-8 bytes) names this grant for the answer. The Mac keeps one grant per phone in flight; one unanswered within 15 s counts as lost. The Mac then grants again after a wait counted from the end of those 15 s: 15, 30, 60 and 120 s for consecutive lost grants, then every 10 minutes. The next control channel, a new pairing, a change in what grants carry, or an answer starts the waits over. The optional `hostKind` (`mac` or `windows`; absent from older Macs, which are Macs) says what the host is, so a phone shows a newly granted PC as a PC before it first connects; any other value is dropped. A host may also send `hostKind` in `hello`; a phone keeps it only once the connection is authenticated. |
| `shellGranted` | phone | `phoneID`, `grantID`? | The phone stored the grant, its key sealed to the phone app's sealing key (`ShellKeySeal`; the vector is in fixtures.json). A phone whose app has not published a sealing key yet stores nothing and does not answer, so the grant expires and the Mac grants again as above. Echoes the grant's `grantID` when it had a valid one (1 to 64 UTF-8 bytes), so the Mac records the key of the grant answered and ignores a late answer to an earlier one. An answer without `grantID` (from phones that predate it) counts for the grant in flight. |
| `goodbye` | phone | none | The phone's user turned Passthrough off, and the phone stops right after. Sent to authenticated clients only (Macs and iPads), just before the phone stops: the iPhone's extension stopping at the user's request, or the app's foreground host stopping. A link that only drops sends nothing, and is held to resume as usual. An iPad shows at once that Passthrough was turned off on the iPhone; the Mac logs it. Clients ignore it before `auth`. |

Device facts are `deviceName`, `radio`, `carrier`, `battery` (0 to 1),
`hosting` (`background` or `foreground`), `ipv6` and `internetFrom`. `ipv6`
says whether the network the phone sends traffic out on routes IPv6. When it
is `false` the Mac rejects IPv6 in its tunnel, so apps fall back to IPv4 at
once instead of hanging on connections the phone can't make; older phones omit
it and nothing changes. `internetFrom` comes only from an iPad paired with an
iPhone for its internet ([iPad](#ipad), below): that iPhone's name, which the
Mac shows ("<iPad> gets its internet from <iPhone>"). Phones leave it out.

### Authentication

Whatever answers on the phone's port may not be the phone (another device on
the cable, an app squatting the port on an Android phone), and whatever the
Mac talks to may not be the Mac (an adb client), so each side proves the
pairing before the other trusts it, and the token never goes on the wire
after pairing (`ControlAuth`, `ControlAuth.kt`). With K = SHA-256(token), the
32 bytes the phone keeps (as hex), labels as ASCII, the client ID as UTF-8,
and nonces as their raw 32 bytes:

```
phone proof = HMAC-SHA256(K, "passthrough-control-v2 phone" ‖ clientID ‖ nonceMac ‖ noncePhone)
Mac proof   = HMAC-SHA256(K, "passthrough-control-v2 mac"   ‖ clientID ‖ noncePhone ‖ nonceMac)
```

both base64, compared in constant time.

1. `hello` with `nonce` = nonceMac.
2. The phone answers `welcome` with `nonce` = noncePhone. If it holds K for
   that `clientID`: `paired: true` and `proof` = phone proof; else
   `paired: false`.
3. The Mac checks the phone proof against its own token. Only then does it
   send `auth` (`proof` = Mac proof), before anything else, followed by
   `link`, `shellGrant` and so on. A `paired: true` without a valid proof
   from a phone the Mac holds a token for ends the connection (the user can
   forget the pairing and pair again); the Mac never sends anything secret to
   it. A Mac with no token for the phone, or only the token from the slot
   all iPhones once shared (below), treats it as unpaired.
4. The phone treats the connection as authenticated once the Mac proof checks
   out. A bad `auth` gets `error` `not_authenticated` and the connection is
   closed. Before that, nothing privileged is acted on: `link` and
   `shellGrant` are ignored, and no `status` is sent: before it, the phone
   says nothing about itself (`welcome` holds only the handshake). Its
   `paired` and `proof` do answer whether this phone holds a pairing for the
   `clientID` named, which is unavoidable (the proof must come first) and
   tells a peer without K nothing it can use.
5. A completed code pairing (`pair` → `paired`) authenticates the connection
   for both sides. The Mac accepts `paired` only as the answer to its own
   `pair`, once.

The channel is authenticated, not encrypted. The proofs stop a peer that
merely answers on the port (no token, no proof) from learning anything, but a
relay in the path, such as a process running as the Mac user posing as the
adb server on `127.0.0.1:5037` and forwarding to the real one, can let the
proofs through and read what follows them: `link` and `shellGrant` keys,
relay details and, during a pairing, the `paired` token. That is outside the
threat model (code already running as the user); closing it would take an
encrypted channel bound to the pairing, with keys derived from K and both
nonces.

Versions must match: a phone answers any other `protocolVersion` with `error`
`unsupported_version` (carrying its own version) and closes; the Mac refuses a
`welcome` with another version, and tells the user which side to update.

The phone closes a connection that is not authenticated within 10 s, except
while a pairing code is showing and the connection has said `hello` (then it
may wait until the code expires). It drops an authenticated Mac silent for 30
s over the cable (150 s over the wireless link, whose pings stop while it
waits to resume). The Mac opens a fresh connection if the phone closes one
while the user is still entering a code.

## Pairing

* The phone shows a six-digit code, valid for 5 minutes. Wrong guesses are
  counted twice. Per connection: the third wrong code on one connection is
  answered `locked` and the phone closes it (a new connection may try again).
  Per code, over every connection (and, on the iPhone, both the app and its
  extension): the tenth wrong guess withdraws the code, answered
  `code_withdrawn`; later `pair`s get `expired` until the phone shows a new
  code, and the phone app says why the code went away. A lockout in time
  would let anything local that can reach the port (any app on the phone, any
  process on the Mac through adb) keep refusing even the right code by
  guessing now and then; a budget per code never refuses the right code while
  the code stands, and bounds a guesser at 10 in 10^6 per code the user
  shows. A guesser can still burn the user's code, but visibly, and a new one
  is a tap away. A `pair` with an empty or over-long `clientID` or `name` is
  refused (`bad_code`) before the code is looked at, and costs it nothing.
* On success the phone issues a token: 32 random bytes as unpadded URL-safe
  base64 (43 characters, `PairingToken`). The phone stores only its SHA-256
  (lowercase hex); the Mac keeps the token in its keychain, one slot per
  phone: `token.iphone.<UDID>` or `token.android.<serial>` (letters, digits,
  `-`, `_` and `.` only). iPhones once shared the slot `token`: the Mac still
  tries it for an iPhone whose own slot is empty, and once the phone proves
  that token it moves to the phone's slot, with the link key and any shell
  access granted through it. Until then the token may be another iPhone's:
  the Mac shows that iPhone as not paired, and forgetting its pairing leaves
  the shared slot alone (with no iPhone attached, Forget Pairing clears it).
  An iPad on the cable (usbmuxd ProductID `0x12AB`; an iPhone's is `0x12A8`)
  pairs the same way, with the code its app shows, into `token.ipad.<UDID>`.
  It is the Mac's remote only (shell, screen, `macState`): the Mac sends it no
  `link`, never routes through it, and prefers a phone that can route whenever
  one is attached.
* The token is never sent again. The SOCKS5 password is derived from it (below).

## SOCKS5 (7890)

RFC 1928 with username/password auth (RFC 1929) only. The username is the
Mac's `clientID`; the password is HMAC-SHA256(K, "passthrough-socks-v2") as
unpadded URL-safe base64 (43 characters, the shape of a token), so a process
squatting port 7890 learns nothing it can use on the control channel. Commands:

* `CONNECT` (1).
* `FORWARD_UDP` (5), hev-socks5-tunnel's UDP-in-TCP: after the reply, each
  datagram travels as `[length:2][header length:1][address][payload]` on the
  same TCP stream.

Private, link-local and multicast destinations are refused, with one
exception: DNS (port 53) sent to a private IP address, usually the router
the Mac last had, is forwarded unchanged to the phone's own network's DNS
server, or to 1.1.1.1 when the phone knows none. Replies come back under the
address the Mac asked (`DNSRedirect`, `DnsRedirect`).

## Wireless link

An optional second transport, carrying exactly the same control channel and
SOCKS5 streams as the cable. The phone **dials the Mac**: iOS delivers no
incoming connections to the background extension, while outgoing ones work
with the phone locked.

| Phone | Network |
|-------|---------|
| iPhone | The phone's Personal Hotspot, which the Mac joins (the Mac's hotspot guard keeps it from using the hotspot's data while passthrough is down). Optionally Apple peer-to-peer Wi-Fi (AWDL) instead, with no access point; it drops for a minute or more while the phone is locked |
| Android (10+) | A Wi-Fi Direct group the phone hosts; the Mac joins it as an ordinary network |

### Discovery

The Mac advertises Bonjour service `_passthrough._tcp` on its networks, and
over peer-to-peer Wi-Fi when that is enabled. The instance name and TXT key `m` are the first 16 hex digits of
SHA-256(the Mac's clientID), so nothing personal is broadcast. A phone dials
only Macs it has linked with.

### Linking (over the cable, once per phone and Mac)

After the control channel is authenticated, the Mac sends:

```
{"t":"link","linkKey":"<32 random bytes, base64>","certSHA256":"<hex>"}
```

and the phone answers:

```
{"t":"linked","phoneID":"<random, stable per phone>","network":"DIRECT-…","passphrase":"…"}
```

`network`/`passphrase` come only from Android: the Wi-Fi Direct group the
Mac should join. The phone keeps `linkKey` and `certSHA256` next to the
pairing; the Mac keeps `linkKey` per phone, keyed by `phoneID`.

### Connection

1. TLS 1.3 over TCP. The Mac presents its self-made certificate (P-256); the
   phone accepts only the one whose SHA-256 it received when linking.
2. The Mac sends one line `{"t":"challenge","nonce":"<32 bytes, base64>"}`.
3. The phone answers `{"t":"proof","phoneID":"…","mac":"<base64>","session":"…","streams":[…]}`
   where `mac` = HMAC-SHA256(linkKey, "passthrough-link-v1" ‖ nonce).
   `session` and `streams` are present only when the phone is resuming (below).
4. The Mac answers `{"t":"fresh","session":"<id>"}` for a new session, or
   `{"t":"resume","streams":[…]}` to continue the phone's.
5. From then on the connection carries multiplexed streams. A control
   channel opened over it runs the same `hello`/`welcome`/`auth` exchange as
   over the cable, with the token of the pairing the phone was linked through.

### Resuming

A connection that drops does not end the session: both sides keep its
streams for up to 120 s and the phone redials. Each side keeps what it sent
until the other has consumed it (at most one window per stream). On
resuming, both send `streams`, one `{"i":<id>,"r":<bytes received>,"f":<end received>}`
per stream, and each then resends exactly what the other is missing, plus
any FIN it has not seen. A stream only the phone still has is reset by the
Mac; one the Mac opened during the outage is opened again. While a session
waits to resume, the Mac refuses new streams at once rather than queueing
them. A session unknown to the Mac (it restarted) gets `fresh`, and the
phone starts over.

### Multiplexing

Frames: `[type:1][stream:4][length:2][payload]`, big-endian, payload ≤ 16384.

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| 1 | OPEN | Mac → phone | port (2 bytes): 7890 SOCKS or 7891 control |
| 2 | DATA | both | bytes |
| 3 | FIN | both | none: that side sends no more |
| 4 | RESET | both | none: stream aborted |
| 5 | WINDOW | both | bytes consumed so far on the stream (8 bytes, cumulative) |
| 6 | PING | both | 8 bytes, echoed in PONG |
| 7 | PONG | both | the PING's 8 bytes |

The Mac opens streams (odd IDs from 1). The phone connects each one to
127.0.0.1:port, so the same servers answer as over the cable. Each direction
of each stream has 128 KiB of credit: a sender may be at most that far ahead
of what the receiver reported consumed, and the receiver sends WINDOW after
each 64 KiB it consumes. Either side pings every 10 s and drops the connection
after 30 s without any frame; the phone then redials.

## iPad

An iPad can use an iPhone's internet while it is on that iPhone's Personal
Hotspot, with its traffic leaving from the iPhone's own network stack, not
the hotspot's data ("Internet through iPhone"). Only iPhones and iPads speak
this part; Android neither sends nor needs any of it.

### Roles

The iPad takes the Mac's part in the [wireless link](#wireless-link): its
tunnel extension advertises `_passthrough._tcp` (TXT `m` = the first 16 hex
digits of SHA-256(the iPad's clientID)), listens with its own self-made
certificate, and the iPhone dials it. The iPhone dials because the reverse
never connects: an iOS extension gets no incoming connections from the
iPad, while the iPhone's extension dialing out works with both devices
locked. Everything after the dial is the wireless link as above: TLS 1.3
pinned to the iPad's certificate, `challenge` and `proof` with the link key,
`fresh` or `resume`, multiplexed streams (the iPad opens them, to 7890 and
7891 on the iPhone), resuming within 120 s. A control channel over it runs
`hello` / `welcome` / `auth` with the iPad's clientID and the token the
iPhone issued it, then `status`; the iPad's tun2socks signs every SOCKS5
stream with the password derived from that token, as a Mac's does.

On the iPhone the iPad is a `PairedClient` with `kind` `ipad` (records
without `kind` are Macs). Its `LinkCredential` carries `hotspotOnly: true`:

* It is dialed only over the iPhone's Personal Hotspot interface (`bridge*`
  or `ap*`), from the Bonjour result's interface and required on the
  connection, and never over peer-to-peer Wi-Fi. A Wi-Fi network both
  devices share does not count, and the interface is checked again when the
  iPad's `challenge` arrives, before the iPhone sends its proof. So a link is
  proof to the iPad that it is on the iPhone's hotspot.
* The iPhone dials paired iPads whenever Passthrough is on, whether or not
  its wireless link setting is on (with it off, only iPads are dialed).
* The iPhone's `status` and SOCKS5 server are the same as for a Mac:
  private, link-local and multicast destinations are refused, and DNS to a
  private address is forwarded to the iPhone's own resolver. The iPad's
  tunnel tells apps to use `10.255.253.53` for DNS, so its lookups take that
  path.

### Pairing (QR code)

The iPad shows a QR code; the camera plays the cable's part. The code is a
URL, `passthrough://pair-ipad?v=1&c=…&n=…&f=…&s=…&e=…`:

| Key | What |
|-----|------|
| `v` | `1` |
| `c` | The iPad's clientID, 1 to 64 characters (random, made once, kept across re-pairing) |
| `n` | The iPad's name, 1 to 64 characters |
| `f` | SHA-256 of the iPad's certificate, 64 hex digits |
| `s` | A one-time secret: 32 random bytes, unpadded URL-safe base64 |
| `e` | When it expires, Unix seconds: 5 minutes after it was made |

Anything else is not an invitation. While the code shows, the iPad's pairing
listener advertises `_passthrough._tcp` with TXT `e` (not `m`, so it never
mixes with the link's listener) = the same tag as `m`, under the instance
name `<tag>-pair`, over TLS with the same certificate, never peer-to-peer.
The iPhone, after Face ID or the passcode, browses for it (20 s at most;
peer-to-peer off), dials it with TLS pinned to `f`, and then has 15 s for
the exchange, one JSON object per line, each at most 16 KB:

1. iPad: `{"t":"challenge","nonce":"<32 random bytes, base64>"}`.
2. iPhone: `{"t":"enroll","mac":"<base64>","phoneID":"…","name":"…","token":"…","linkKey":"<32 bytes, base64>"}`,
   where `mac` = HMAC-SHA256(secret, "passthrough-enroll-v1" ‖ nonce).
   `token` is a fresh pairing token (`PairingToken`), `linkKey` a fresh link
   key, `phoneID` the iPhone's (as it answers the link challenge with),
   `name` the iPhone's name (1 to 64 characters each).
3. iPad: `{"t":"enrolled"}` once it has stored the iPhone, or
   `{"t":"error","error":"<why, in words>"}`, then it closes.

The iPad checks the proof in constant time and stores the iPhone (its
`phoneID`, name, token and link key) only after it holds. A code works once:
after `enrolled` the listener stops, and so it does at expiry and after 5
wrong proofs. It takes at most 4 connections at a time, each closed after
15 s. The iPhone stores the iPad (token hash, link key, the certificate pin
`f`) only after `enrolled` (`prepareClient`, then `commit`), so a failed
re-pair leaves an earlier pairing of the same iPad working. A code whose
clientID belongs to a Mac paired with the iPhone is refused: it can never
replace a Mac. Pairing another iPhone, or forgetting it, makes the iPad drop
every link so only the iPhone paired now links again.

## Remote shell

A phone opens terminal sessions on the Mac. The Mac hosts them as PTYs, so a
session outlives the phone's connection and can be attached again.

### Transport and discovery

The Mac listens on TCP port 7893 (`RemoteShell.defaultPort`) with TLS 1.3
and the same self-made certificate as the wireless link; the phone accepts
only the certificate whose SHA-256 it got in `shellGrant`. The Mac advertises
Bonjour service `_passthrough-sh._tcp`. The phone first receives a
`shellGrant` over the cable (control channel, above): a per-phone `shellKey`,
the certificate pin, the port, the Mac's `addresses` and `macName`. It answers
`shellGranted` with its `phoneID`. The same shell protocol also runs over iroh
(ALPN `passthrough/shell/1`, one bidirectional stream per connection); the
iroh details come in the grant and are refreshed by `macInfo` (below). The
phone dials the relay exactly as last given; if the Mac's home relay moves,
a phone that is away picks up the new one at its next connection on any path.

Newline-delimited JSON like the control channel, lines up to 262144 bytes.
Binary fields (`data`, `nonce`, `mac`) are base64.

### Handshake

1. `{"t":"challenge","nonce":"<32 bytes, base64>"}` from the Mac.
2. `{"t":"proof","phoneID":"…","mac":"<base64>"}` from the phone, where `mac` =
   HMAC-SHA256(shellKey, "passthrough-shell-v1" ‖ nonce).
   Over iroh the Mac's accept only fires once the phone writes, so the phone
   first sends `{"t":"hello"}` right after opening the stream; the Mac reads it
   and then sends the challenge. Over iroh the 10-second timeout starts when
   the connection attempt arrives, before the QUIC handshake, so the QUIC
   handshake, `hello` and proof must all fit in it. Over TLS there is no
   `hello`.
3. `{"t":"ready"}`, then `macInfo`, `host`, `macState` and `sessions` (each only when the host has one to send; a screen pass gets `ready` alone), or
   `{"t":"error","reason":"not_authorized"}` and the connection closes. Nothing but
   `challenge`, `ready` and that error is ever sent before `ready`: phones end the connection on
   any other message, and read any other error as access lost.

Nothing the phone sends is acted on before a valid proof. The Mac closes a
connection whose `hello` or proof line exceeds 4096 bytes (a hard limit: a
newline-terminated line over it is refused too) or that has not proved itself
within 10 seconds, and holds at most 2 unproven connections per address (16 in
total; over iroh, 8 of them for connections arriving through relays). A public
IPv4 peer is counted by its /24 and a ULA or global IPv6 peer by its /64, so
taking many addresses does not multiply a stranger's share; a link-local IPv6
peer (`fe80::/10`, where every AWDL and LAN neighbour is) is counted by its own
address. 4 of the 16 are kept for addresses that proved a shell key within the
last 30 days (remembered across relaunches, at most 256), which are counted on their own. Over
iroh a slot is taken only once QUIC has validated the peer's address (it is
sent a retry first), so packets with forged source addresses hold none.
After `ready` a line over the 262144-byte limit closes the connection.

A connection is attached to at most one session: `open` attaches it to the
new session, `attach` to another session leaves the previous one first.
After an `attach` the Mac sends `replaying`, the scrollback as `output`, then
`attached`, then live output. Output a phone receives between its `attach`
and `replaying` was live output of a session it was already attached to; the
scrollback holds it too, so a phone that draws the replay drops it. A phone's terminal should not answer terminal queries
(device attributes, cursor position, color reports…) found in the replay:
the program that asked is long gone, and the answer would arrive as input.
`input` must name the attached session, else `bad_request`. `resize` is for
whatever session the connection has attached when the Mac reads it; with
nothing attached it is ignored. A `session` it names is ignored too (Macs
before this required it, so phones still name the one they know): it may be
the one an `open` or `attach` ahead of it just left. A connection's lines are
handled in order, and those after an `open` wait until it is answered, so a
resize sent before `opened` (a keyboard coming up) sizes the new session.
Every `open` is answered, by `opened` or `error`, either carrying the
phone's `ref` for it: a phone that `attach`es before an `open` is answered
knows from the `ref` that the session it made is left detached. A
line that is not valid JSON or has an unknown `t` gets `bad_request`; the
connection stays open.
A phone that stops reading while 8 MiB of output waits to be sent is
disconnected; it can attach again and gets the scrollback.

### Terminals on the Mac

A terminal window on the Mac can look at a session too, beside the phone
attached to it: it is added as a viewer, takes nothing over and is never sent
`detached`, so phones see no difference except in what the session prints and
how big it is. A session's terminal has the size of whoever attached or typed
last: a phone's `resize` is remembered, and applied once that phone is the one
the session follows (it attached last, or types). What a terminal sends by
itself in `input` (its answers to a program's questions: cursor position,
device attributes, status, mode, window and colour reports, DCS and APC
replies; and focus in and out) is not typing: it never moves the session, and
it is dropped from any terminal but the one the session follows. When that
one goes, the session follows whoever is left, at that one's size. A session started in
a window on the Mac is listed with `origin` `mac`; the Mac keeps up to 32 of
those, apart from the 8 sessions phones may open. Closing its window ends it.

The window talks to the app over a Unix socket on the Mac, never the network
(`LocalTerminalWire`): frames of one byte of kind, a big-endian UInt32 length
and a payload. The window sends `hello` (1, JSON: `mode` `hook`, `new`,
`attach` or `list`, `session`?, `cols`, `rows`, `directory`?, `environment`?,
`token`?, `typeahead`?, `inside`?),
then `input` (2, raw bytes), `resize` (3, two big-endian UInt16: columns,
rows) and, for a session it started, `theme` (4, JSON: its colours). The app answers `started` (16, JSON `session`), `refused` (20, JSON
`reason`) or `sessions` (21, the JSON list), then sends `output` (17, raw
bytes), `replayed` (18, after the scrollback of a session that was already
running) and `ended` (19, JSON `exitStatus`). Only connections from the app's
own user are accepted, and of those: `hook`, `new` and `list` only while *Show
new terminals on my phones* is on (else `refused` `not_sharing`); `attach`
only with the `token` the app wrote, for that exact `session`, into the
command file of a window it opened (good once, for a minute; else `refused`
`not_allowed`; a token used a second time is also refused, and the app then
takes that session off its windows and tells the owner). The owner can stop a
window showing a phone's session at any time (`refused` `stopped`, after
`started`; the session carries on), and never to the session named in `inside`, the one the
window is already in (`refused` `own_session`). `typeahead` (with `hook`): a
whole line was waiting on the terminal before its shell asked, as a terminal
types the command into a window it opens to run one; the window "Open here"
opened is told `not_sharing` that way, so its own shell runs that command.

### Messages

| `t` | From | Fields | Meaning |
|-----|------|--------|---------|
| `challenge` | Mac | `nonce` | Starts the handshake. |
| `proof` | phone | `phoneID`, `mac` | Answer to the challenge. |
| `ready` | Mac | none | Authorized; the commands below are accepted. |
| `hello` | phone | none | iroh only: the first line the phone writes, so the Mac sees the stream. Ignored elsewhere. |
| `macInfo` | Mac | `irohID`, `irohRelay`?, `relayToken`?, `addresses` | Sent right after `ready` on every path, except while the Mac's iroh endpoint is on but not ready to hand out (still starting, or on the default relays with no home relay yet): then it is not sent at all, so phones keep what they have (the grant likewise leaves the iroh fields out). The phone updates the stored grant's iroh details and addresses (`addresses` at most 16; validation as in `shellGrant`; absent `relayToken` clears the stored one). Valid `addresses` always apply. The iroh fields apply as a group only when valid; no `irohID` clears the stored iroh details and token, and a token without an `irohID` is never stored. It never changes the shell key or certificate pin. |
| `list` | phone | none | Ask for the live sessions. |
| `sessions` | Mac | `sessions` | Reply to `list`, and sent unasked whenever the list changes (a session opens, ends, or starts or stops waiting): `ShellSessionInfo` objects `id`, `title`, `startedAt`, `lastOutputAt` (Unix seconds), `running`, `exitStatus`?, `waiting`?, `origin`?. `origin` is `mac` for a session started in a terminal window on the Mac (below) and absent otherwise; a phone that does not know it lists the session like any other. `theme` is that window's colours when its terminal told them: `foreground`?, `background`? and `palette`? (the 16 ANSI colours), each `#rrggbb`; a phone may draw the session with them, and must ignore any that is not six hex digits. `waiting` is the question a running session went quiet on, read off its last lines of output (a line ending in `?`, a `[y/N]` choice, a password prompt) after 1.5 s without output. Input clears it, and only output after the last input is read again, so an answered question isn't found again above the next prompt. A heuristic: phones show it as a nudge, never act on it. A program that reports its status (*Program status*, below) replaces the heuristic: `waiting` is then its question while it is blocked (its message, or `Needs you`), and absent otherwise. `status` is what such a program says it is doing: `state` (`working`, `blocked`, `done`, `error`, `idle`), `kind`? (blocked: `permission`, `question`, `auth`), `message`? (one line, at most 300 characters: the question while blocked, what it is doing while working), `agents` (its agents still working or blocked), `since` (Unix seconds, when it entered this state) and `seen` (done or error while someone was looking at the session, or once someone looks or types: nothing to tell anyone). A phone is looking while it says so (`viewing`); a Mac terminal window showing the session is while someone is at the Mac (a key or the pointer used in the last two minutes, the screen unlocked), whether or not the window is in front. |
| `open` | phone | `cols`, `rows`, `ref`? | Start a new session. `ref`, a number the phone picks, comes back in the answer. |
| `opened` | Mac | `session`, `cols`, `rows`, `ref`? | The session exists and this connection is attached to it (until a later `open` or `attach`). |
| `attach` | phone | `session`, `cols`, `rows` | Attach to a live session; the Mac replays its scrollback as `output` first. |
| `attached` | Mac | `session` | The replay for an `attach` is complete: every later `output` is live. Sent before `ended` for a session that already exited. |
| `input` | phone | `session`, `data` | Keystrokes for the PTY. |
| `resize` | phone | `cols`, `rows`, `session`? | The terminal changed size: for whatever session is attached (above). |
| `output` | Mac | `session`, `data` | PTY output, at most 16384 bytes before base64 per line. |
| `close` | phone | `session` | End the session (the shell is hung up). |
| `ended` | Mac | `session`, `exitStatus`? | The shell exited. |
| `detached` | Mac | `session`, `reason`? | Another phone's connection took the session over (a terminal window on the Mac never does). |
| `history` | phone | none | Ask for past sessions. |
| `historyList` | Mac | `history` | `ShellHistoryEntry` objects `id`, `title`, `phoneLabel`, `startedAt`, `endedAt`?, `exitStatus`?, `bytes`, `cols`?, `rows`? (the terminal's size when the session started; absent from older Macs); newest first. At most the newest 500, and fewer (the oldest dropped) if the line would otherwise exceed 262144 bytes. |
| `transcript` | phone | `session` | Ask for a past session's recorded output: at most its last 8 MiB. |
| `transcriptData` | Mac | `session`, `data`, `cols`?, `rows`?, `done`? | A piece of the transcript (same chunk size); `done: true` on the last. `cols`/`rows`, when present, are the size the recorded terminal had from this piece on: set it before feeding `data` (which may be empty when a size change ends the transcript). The first piece always carries the size its first byte was drawn at; older Macs send none. |
| `screen` | phone | none | See and control the screen: the connection becomes a relay to Screen Sharing (below). |
| `screenReady` | Mac | none | Reply to `screen`; every later byte, both ways, is Screen Sharing's. |
| `macState` | Mac | `state` | How the Mac is doing (below): sent after `macInfo` and before `sessions`, then whenever it changes, on every connection that isn't carrying the screen. A Mac that has nothing to say sends none. |
| `setAwake` / `setVPN` | phone | `on` | Turn Keep awake or the Mac's VPN on or off. An accepted request gets no reply of its own: the phone that asked gets a `macState` about a second later whether anything changed or not (a battery or heat limit can refuse Keep awake), and every phone gets one when something does. |
| `push` | phone | `on`, `push`? | Asks for notices through Apple's push service (`on` true, with `push`: `token` (the APNs device token, lowercase hex), `environment` (`sandbox` or `production`), `topic` (the app's bundle ID), `key` (32 random bytes, base64, that this phone made for this Mac) and `mac` (the phone's ID for this Mac)), or to stop (`on` false, no `push`). A registration that isn't well formed is refused `bad_request`. The Mac keeps one per phone until it is replaced or stopped, the token stops working, or the phone loses shell access. Answered `pushState`. *Notices* below. |
| `pushState` | Mac | `on` | Whether this Mac will send this phone notices: false while it has no push key set up, or after the phone stopped them. |
| `viewing` | phone | `on` | Whether the phone's terminal is on screen for the session it has attached. A phone stays attached to the last session it showed, so attached is not looking: a result (`status` done or error) is `seen` only while the phone looks, or once it does. Said again on each connection; no reply. |
| `lock` | phone | none | Lock the Mac's screen, as the Apple menu's Lock Screen does: the Mac stays awake and everything keeps running. Allowed and answered as `setAwake` is (`macState` about a second later, with `locked`). There is no unlocking: that takes the Mac's password. An older Mac answers `bad_request`. |
| `events` | phone | `since` | What happened on the Mac since then (Unix seconds), for the phone's timeline. A Mac that keeps no log answers `bad_request`. |
| `eventList` | Mac | `since`, `events`, `battery` | The answer, oldest first: at most the newest 500 `MacEvent`s since `since` and no older than 7 days (`t`, `kind`, `title`, `detail`?, `session`?, `warning`?), and `BatterySample`s (`t`, `level` 0 to 1, `charging`?), one per 5 minutes at most plus one at each plug or unplug, starting with the one just before `since`. Fewer events if the line would exceed 262144 bytes (the oldest dropped). `title` and `detail` are written by the Mac, ready to show; `kind` (`awake`, `vpn`, `link`, `power`, `sleep`, `shell`, `asked`, `answered`) picks an icon, and phones show unknown kinds plainly. |
| `screenGrant` | phone | `name`, `viewer` | Issue a screen pass for another device (below), which the Mac lists as `name`; `viewer` is that device's id as the phone knows it. Answered `screenGranted`, or `error`: `screen_not_allowed` (the phone may not see the screen itself), `not_authorized`, `bad_request` (a name that is empty, over 64 characters or more than one line) or `pass_not_saved`. |
| `screenGranted` | Mac | `phoneID`, `key` | The pass: the viewer's id (starting `viewer.`) and its 32-byte key, base64. |
| `screenPass` | phone | `pass` | Keep a pass to another Mac's screen: a credential as the phone keeps its own (`macID`, `macName`, `certSHA256`, `shellKey`, `phoneID`, `port`, `addresses`, `irohID`?, `irohRelay`?, `relayToken`?). Answered `screenPassSaved`, or `error` `bad_request` when it isn't usable. |
| `screenPassSaved` | Mac | none | The Mac kept the pass. |
| `screenRevoke` | phone | `phoneID` | Take back a pass this phone was granted (`phoneID`, the viewer's) and couldn't hand over. Answered `screenRevoked`, or `error` `bad_request` when it isn't one of this phone's passes. |
| `screenRevoked` | Mac | none | The pass is gone. |
| `host` | host | `host` | What the host is (*The host*, below): after `macInfo`; a PC sends it again whenever it changes. Never sent to a screen pass. |
| `goingAway` | host | `reason` | The host is about to go away: `sleeping`, `turned_off` (Remote access) or `shutting_down`. Not sent for an update or a plain stop. A client shows "went to sleep" only after this. |
| `rdp` | phone | none | See and control the screen through the host's Remote Desktop (*Remote Desktop relay*, below). |
| `rdpReady` | host | `certSHA256` | Reply to `rdp`; every later byte, both ways, is Remote Desktop's. `certSHA256` is the SHA-256 of the certificate Remote Desktop will present, 64 lowercase hex; the viewer accepts only that one. |
| `screenEnded` | host | `reason` | Sent on a device's other live connections when one of its views of the screen ended for a reason the view itself can't carry: `switched_off` (its Screen switch went off), `stopped` (from the host) or `taken` (someone signed in at the host). |
| `ping` / `pong` | either | none | Liveness; each side answers `ping` with `pong`. A phone pings after 5 s without hearing from the Mac and gives the connection up after 15 s of silence and then dials again. The iPhone also gives it up 2 s after a ping it sent because the system said the connection's path failed (the cable it used unplugged, Wi-Fi lost) and nothing came back; Android closes the sockets of a network it lost by itself. |
| `error` | Mac | `reason`, `session`?, `ref`? | `not_authorized`, `too_many_sessions` (8 at once), `no_such_session`, `bad_request`, `screen_not_allowed`, `screen_unavailable`, `screen_video_unavailable`, `too_many_screens`, `not_allowed` (the owner hasn't let this phone change Keep awake and the VPN), `vpn_not_set_up`, `screen_only` (a screen pass asked for something else), `pass_not_saved`, `signed_out` (no shell can start: *A Windows PC as host*), `rdp_unavailable` (with `detail`, in `host.rdp`'s words), `try_later` (with `retryAfter`, seconds), `too_many_computers` (a host lets in at most 8 computers a phone, 16 in all) or `pass_conflict` (a hand-over would replace a computer's access to a host with different details). `ref` when it refuses an `open`. An optional `message` is a sentence the host wrote, which a client shows only when it has none of its own. New reasons are only ever sent after `ready`; a client that doesn't know one reads it as `bad_request`. |

The Mac keeps 1 MiB of scrollback per session.

A transcript must be replayed at the sizes it was recorded at, never at the
viewer's own: shells draw for their terminal's width (zsh relies on autowrap
at the right margin and then clears the wrapped line with `\r\e[K`), so the
same bytes at another width draw something else. Viewers set their read-only
terminal to each size in order; a size narrower than the screen is drawn at
the left, a larger one with a smaller font (and, on phones, panned sideways
once the font is as small as it goes). The Mac records sizes in the cast file
as asciicast v2 resize events (`[t, "r", "COLSxROWS"]`) whenever the phone
resizes the session, and restates the size every 1 MiB of cast so a tail read
finds the size its start was drawn at; the header keeps the initial size.

### Program status

The Mac reads the [Program Status Protocol](https://mitchellh.com/writing/program-status-osc7501) (OSC 7501, spec 0.4) out of every session's output; Claude Code speaks it from v2.1.295. A program asks first, `ESC ] 7501 ; ?` followed by a device attributes request, and the Mac writes the answer into the session itself, before the output goes on to anyone: `ESC ] 7501 ; ? : states=idle,working,done,blocked,error : kinds=permission,question,auth ESC \`. Phones' terminals don't know the protocol, and an answer from a Mac terminal window that does is dropped from its input, so the program hears exactly one. From then on the program reports `ESC ] 7501 ; key=value:key=value… ST` (BEL or `ESC \`); each report replaces a record, the root one without an `id` and one per `id` (Claude Code gives each agent a record with a `title`, cleared when it finishes). `msg` and `title` are base64 UTF-8; a report with an unknown `state`, a bad `id`, invalid base64 or a control character is ignored whole, and so is one over 4096 bytes. `state=clear` removes the record and those beneath its `id` (all of them without one), as does a full reset (`ESC c`). The Mac notes the terminal's foreground job when a program first reports; once another job is in front and that job's process group is gone (the program was killed, or exited without clearing), every record it left is dropped and the session is a plain shell again. A job that is only stopped (^Z) or put in the background keeps its records. The session's `status` sums the records up: blocked if any is (the root's question first, else an agent's, as `title: msg`), else working while the root or any agent is, else the root's state.

### Notices

What the Mac sends APNs (HTTP/2, token authentication with the Mac's `.p8` key; `apns-push-type: alert`, `apns-collapse-id` the session, an hour's expiry, priority 10 for Time Sensitive and 5 otherwise) says nothing about what happened:

`{"aps": {"alert": {"title": "Passthrough", "body": "Something on your Mac needs a look."}, "mutable-content": 1, "sound": "default", "interruption-level": "time-sensitive" | "active", "thread-id": <session>}, "pt": {"m": <mac>, "b": <box>}}`

`b` is a JSON `PushNotice` (`macName`, `title`, `body`, `session`, `state`) sealed with ChaCha20-Poly1305 under the registration's `key`, with `m` (the registration's `mac`) as associated data, base64 of the combined nonce, ciphertext and tag. The phone's notification extension finds the key for `m`, opens the box and shows its title, the Mac's name and its body; a tap opens `session` on that Mac. One it can't open is shown as sent. When the Mac sends one: a session's `status` turning `blocked` (again whenever its kind or message changes), as Time Sensitive; `done` or `error` that isn't `seen`, after a turn of at least 30 seconds (from the first `working` to the end); never about a session someone is looking at (a phone that said `viewing`, or a Mac terminal window while someone is at the Mac); at most ten a minute to one phone.

### Mac state and control

`macState` carries an object whose fields are all optional; a Mac leaves out
what it doesn't know or doesn't have, and a phone ignores fields it doesn't know:

| Field | Meaning |
|-------|---------|
| `awake` | Keep awake is on. |
| `awakeStopped` | Why Keep awake turned itself off or refused to turn on: `battery` or `heat`. |
| `battery` | 0 to 1; absent on a Mac without a battery. |
| `charging` | On power, not the battery. |
| `minutesLeft` | Minutes until Keep awake's battery limit, on battery, from macOS's own estimate (rounded to 5). |
| `batteryFloor` | The level (0 to 1) where Keep awake turns itself off; absent when that limit is off. |
| `hot` | macOS reports the Mac running hot. |
| `vpn` | `off`, `connecting`, `on` or `failed`; absent when the Mac has no VPN set up. |
| `vpnName`, `killSwitch` | The VPN profile in use, and whether its kill switch is on. |
| `control` | This phone may send `setAwake`, `setVPN` and `lock`. |
| `locked` | The Mac's screen is locked. Absent from a Mac that doesn't say. |
| `internet` | The Mac is online through a phone, or on its way there. A phone falls back to whether it is sharing itself when a Mac leaves it out. |

Whether a phone may change Keep awake and the VPN is a per-phone setting on
the Mac, on unless the owner turns it off (a phone with shell access can
already run commands as the owner). Requests from a phone without it get
`not_allowed`; `setVPN` with `on` on a Mac without a VPN gets
`vpn_not_set_up`. The Mac's own limits still apply: Keep awake stays off at
the battery limit or while hot, whoever asked. Phones ask for Face ID (or the
passcode) before sending `setVPN` with `on: false`, and the Mac shows a notice
that stays until dismissed whenever a phone turns its VPN off. A Mac that
predates these messages answers them `bad_request` and sends no `macState`,
so a phone offers neither until it has heard one.

### The host

`host` carries one object, `host`, with every field optional:

| Field | Meaning |
|-------|---------|
| `kind` | `mac` or `windows`. A `host` without it is ignored; a client keeps a kind it doesn't know and treats it as neither. |
| `os` | The operating system and version, to show (at most 64 characters). |
| `signedIn` | The account that granted this device has a session on the host (locked counts). |
| `app` | Passthrough is running in that session, so shells can start. |
| `console` | Who is at the host's screen: `active`, `locked`, `signedOut` or `otherUser`; absent when unknown. |
| `idleSeconds` | With `console` `active`: seconds since its keyboard or mouse was used. Under 120 means someone is using it. |
| `shells` | The shells `open` may name: `id` (1 to 80 characters: a letter or digit, then letters, digits, `:`, `.`, `_`, `-`), `name`, and `default` on at most one. At most 32. A Mac names its login shell, id `login`. |
| `screens` | How the screen can be seen: any of `video` (*Screen video*), `rfb` (*Screen*), `rdp` (*Remote Desktop relay*). A client asks only for what is listed. |
| `rdp` | `ready`, or why the relay can't be used: `off`, `edition`, `account`, `service`, `exposed`, `policy`. |
| `access` | What this device may do here: `shell`, `screen`, `share` (hand access on to another computer). |
| `lock` | This device may send `lock`. |
| `idKey` | The host's identity public key for computers (*Computers*), lowercase hex. |
| `user` | The name its Windows sign-in takes; sent only to a device whose `access.screen` is true. |
| `sleepAfter` | Seconds on mains until the host sleeps; 0 for never. |

A host sends a `host` line of at most 16384 bytes. Clients drop the parts that
are out of range rather than the whole message: an over-long `os`, an unknown
`console`, a negative number, a shell with a bad id or name or a repeated id, a
second `default` (`HostInfo.cleaned`; the cases are in fixtures.json,
`shell.host`). Text fields are one line counted in UTF-16 units, with no
control, format (bidi, zero-width) or separator characters. A field of the wrong
JSON type still fails the whole line on the phones. A Mac sends `host` once per
connection and no `lock`: on a Mac, Lock follows `macState.control`. A host
that sends no `host` is a Mac from before it, which has one shell and the
screen by `video` or `rfb`.

### A Windows PC as host

`open` may name a shell from `host.shells` (`shell`); without one the host
starts the default. An id it doesn't list is `bad_request`. Each session
says which shell it runs (`shell` in `sessions`). When no shell can start
(the granting account isn't signed in, or Passthrough isn't running in its
session) `open`, `attach`, `history`, `transcript` and `lock` are answered
`signed_out`, and `host` says which (`signedIn`, `app`, `console`). If
Passthrough stops in that session, attached sessions get `detached`, then an
empty `sessions`, then a `host`.

A PC answers what only a Mac serves (fixtures.json, `shell.pcAnswers`):
`setAwake` and `setVPN` with `not_allowed`; `events` with an empty
`eventList`; `push` with `pushState` off; `screenVideo` and `screen` with
`screen_not_allowed` until it streams its own screen (so an older iPhone app
never asks for a Mac login); `screenGrant`, `screenPass` and `screenRevoke`
with `bad_request`. Its `macState` carries `battery`, `charging` and
`locked`, with `control` false; Lock is offered from `host.lock`.
### Screen

A phone the owner has also given screen access (a per-phone setting on the
Mac, off by default, kept when the phone is granted shell access again)
sends `screen` on an authorized connection. The connection leaves any
session it was attached to, and the Mac dials macOS Screen Sharing on
loopback (TCP 5900, `RemoteShell.screenSharingPort`). If it answers within 5
seconds the Mac replies `screenReady`, and from the byte after that line the
connection carries RFB (VNC) unchanged in both directions: Screen Sharing
speaks first (its `RFB 003.889` banner), then asks for the Mac account's
name and password itself. When either end closes, both are closed. Without
screen access the reply is `error` `screen_not_allowed`; if Screen Sharing
does not answer it is `screen_unavailable`. In both cases the connection
stays a shell connection. The phone sends nothing after `screen` until
`screenReady`; a line that does arrive meanwhile closes the connection. A
phone uses its own connection for the screen, beside any shell connection.
Turning a phone's screen access off ends its screen connections at once. A
Mac shows its screen to at most 2 connections per phone and 4 in all
(`screen` and `screenVideo` together); past that the reply is `error`
`too_many_screens` and the connection stays a shell connection.

### Screen video

The fast way to see the screen, asked for first: `screenVideo` instead of
`screen`, with the same screen access check. The Mac streams its main
display itself, as HEVC (when the phone decodes it) or H.264 from its
hardware encoder in low-latency mode, at
most at the display's size in points, or a display it makes in the phone's
shape (`hello`'s fit, below); no Mac password is involved (screen
access is the owner's consent). If it can't (Passthrough lacks Screen
Recording or Accessibility) the reply is `error` `screen_video_unavailable`
and the connection stays a shell connection, so the phone can ask for
`screen` next; a Mac too old to know `screenVideo` answers `bad_request`,
read the same way. Otherwise the Mac replies `screenVideoReady`, and from
the byte after that line both directions carry binary messages: a type
byte, a 4-byte big-endian payload length (at most 16 MiB from the Mac), the
payload. Unknown types are skipped. Numbers are big-endian. The Mac takes
less from a phone, and closes the connection on a payload over it: 4 KiB for
`text` (the phone sends a longer paste in pieces), 64 KiB for `clipboard` and
for a type it doesn't know, 64 bytes for every other message. The phone, in
turn, takes at most 64 KiB and a byte for `copied`. It types text
at up to 8 KiB a second (keys sent after text wait their turn), and drops
text once 256 KiB is waiting.

Mac → phone:
- `1` format: codec u8 (0 H.264, 1 HEVC), width u16, height u16, count u8,
  then that many parameter sets, each a length u16 and the bytes (H.264:
  SPS, PPS; HEVC: VPS, SPS, PPS). Sent before every keyframe. The size
  changes when the phone asks for another (`hello`) and when the link is
  too slow for the full size: the Mac then captures each side at ¾, then
  ½, once its bitrate has been under 35% of what that size takes for 2 s,
  and back up a step once it reaches 70% of what the bigger size takes for
  5 s, at most one change every 5 s.
- `2` frame: number u32 (from 1), flags u8 (bit 0: keyframe), then the
  frame's NAL units, each after a 4-byte length (AVCC, HVCC for HEVC).
- `3` copied: the answer to `copy`. Status u8, then for status 0 the copied
  text, UTF-8. Status 0: text; 1: nothing was copied (the clipboard didn't
  change within a second of the ⌘C, the change came from another device or
  a phone's paste, or the text is empty); 2: text over 64 KiB; 3: not text. A status the phone
  doesn't know reads as 1. The phone takes `copied` only as the answer to a
  `copy` it sent, never unasked.
- `4` curtained: the answer to `curtain`. Hidden u8: 1 when the Mac's
  displays are hidden now, 0 when they show (also when it couldn't hide
  them). Also sent unasked, 0, when the curtain comes down by itself: it
  couldn't be put up again after the displays changed, or the phone went
  quiet (below).
- `5` fitted: fit u8 (as `hello`'s), what the stream shows from now on. The
  answer to every `hello` that changes what's shown, sent before that
  stream's first format. 0 after a `hello` asking for 1 means the Mac
  couldn't make the phone's display (another phone's view has it, or macOS
  wouldn't), and shows its own.
- `6` cursor: x u16, y u16 (each 0…65535 across the stream, as `pointer`),
  visible u8 (0 when the pointer is on another of the Mac's displays). Sent
  when it moves, up to 60 times a second. The frames leave the pointer out:
  the phone draws it, at once where its own input puts it, and where this
  says when the Mac's pointer moved by itself (its own trackpad).
- `7` cursor shape: width u16, height u16, hot x u16, hot y u16 (all in
  stream pixels: how big to draw it, and where its tip is), then a PNG.
  Sent when the pointer's look changes (looked at 10 times a second), and
  again for each new stream size.
- `8` viewers: count u8, then each a length u8 and a UTF-8 name: the other
  devices viewing this Mac's screen now (the names they were paired with;
  a device with several streams counts once). Sent when the list changes.
- `9` moved away: UTF-8 name: another device took over (`useHere`); the
  Mac ends this stream right after it.
- `10` microphone state: state u8, the answer to `microphone`: 0 off, 1 on
  (the Mac plays the phone's `voice` to its "Passthrough Microphone" input
  device), 2 not installed (the Mac has no such device: its audio driver is
  installed from the Mac app's Remote Shell settings), 3 failed (the device
  is there but couldn't be played to). A state added later reads as failed.
- `11` sound state: state u8, the answer to `sound`: 0 off, 1 on (`sound
  packet`s follow), 3 failed (the Mac's sound couldn't be captured). Sent
  again, failed, if the capture ends and can't be started again.
- `12` sound packet: what the Mac's apps play, next: one AAC-LC packet
  (1024 frames, 48 kHz stereo, about 128 kb/s) with nothing around it.
  Captured with ScreenCaptureKit, whatever the Mac's volume, without the
  app's own sound (so a phone's `voice` isn't sent back to it). None are sent
  while the Mac is silent, and one is left out when frames are waiting to go
  out: sound is for now or never. The phone plays them through a small
  buffer (it starts once 80 ms wait; over 400 ms the oldest are dropped).

Phone → Mac:
- `16` hello: width u16, height u16, fit u8, codecs u8 (bit 0 H.264, which
  the Mac assumes anyway; bit 1 HEVC, sent when the phone decodes it in
  hardware: the Mac then uses HEVC if its encoder can), fps u8 (the most
  the phone shows, 15–120: 60, or 120 on ProMotion), quality u8 (0 sharp:
  60 fps, and the size kept until the bitrate is under 20% of what it
  takes; 1 smooth: the phone's rate, half again the bitrate above 60 fps;
  2 fast: the phone's rate, ¾ size from the start and shrinking sooner),
  space u8 (fit 1 only: the display's size against the stream's in percent,
  50–200; the phone offers 80 for larger text, 100, 125 for more room).
  While every frame for a second has changed under 3% of the screen (a
  spinner, streaming text) and the phone has sent no input for as long,
  the Mac sends at most 15 frames a second, at full rate again from the
  phone's next input. Sent first, and again whenever
  what the phone wants changes (it turned, or the user chose another fit);
  the Mac starts anyway after a second without one. Fit 0: the Mac's own
  main display, fitted inside width×height pixels (the phone sends its
  longer side for both). Fit 1: a display of exactly width×height pixels
  made for the phone (CoreGraphics' virtual display, in Retina mode, so
  half that in points), which the Mac's own displays mirror while it lasts;
  the phone sends the pixels of its screen view as it's held (clear of the
  Dynamic Island and its own controls, and not changed while its keyboard
  is up). The display goes away
  when the stream ends or the phone asks for fit 0, and macOS undoes the
  mirroring if the app quits. One at a time per Mac. A fit the Mac doesn't
  know reads as 0. Each change is a new capture (and a keyframe): the old
  one goes on, curtain and all, until the new one is up.
- `17` ack: frame number u32, once that frame is on screen. The Mac sends a
  new frame only while fewer than a window of frames is unacked, encoding
  only the newest capture (older ones are dropped before encoding), so
  little queues anywhere and the picture stays current on a slow path. The
  window is as many frames as fit in the shortest round trip of the last
  10 s (frame sent to ack), 2 to 24; the bitrate falls when acks lag behind
  that trip (a queue building on the way), more the worse the lag, and
  creeps back up while they don't. Keyframes, slow anyway, don't count. A
  frame the phone can't show (one before the keyframe it is waiting for) is
  acked anyway.
- `18` pointer: x u16, y u16 (each 0…65535 across the screen), buttons u8
  (1 left, 2 middle, 4 right, as RFB).
- `19` scroll: dx i16, dy i16 in the stream's pixels (what the fingers
  moved over); the Mac turns them into its points by the captured
  display's width over the stream's, so content follows the fingers at any
  stream size. Positive dy brings earlier content into view.
- `20` key: X keysym u32 (as RFB), modifiers u8 (1 command, 2 shift, 4
  option, 8 control), pressed and released, with each modifier's own key
  pressed around it as a keyboard does (apps such as Windows App's RDP follow
  those keys, not the flags on the key). A character's key is the one that
  types it on the Mac's layout, with ⌘ held for a ⌘ shortcut (on AZERTY,
  ⌘A is where ANSI's Q is).
- `21` text: UTF-8, typed as is whatever the Mac's keyboard layout. Up to 64
  UTF-16 units go as that layout's keys (with Shift where it takes it), each
  carrying its character, so apps that read keys (RDP, virtual machines) get
  it too. A character no key types there, longer text, and all text while an
  input method (Japanese, Chinese…) is selected, goes as characters on the A
  key's code: apps that read keys get an A. The phone sends text longer than
  that as `clipboard` and ⌘V.
- `22` clipboard: UTF-8, put on the Mac's clipboard once the text and keys
  before it are typed, so the ⌘V after it pastes it and not a later one.
- `23` keyframe request: the phone lost its place (its display failed, or
  it was in the background).
- `24` copy: no payload. Once the text and keys before it are typed, the Mac
  reads its clipboard's change count, presses ⌘C, and answers `copied` with
  the clipboard only if the count moves within a second, so what was on it
  before (a password copied on the Mac, say) doesn't go to the phone. A
  clipboard marked `com.apple.is-remote-clipboard` (Universal Clipboard) or
  `org.nspasteboard.TransientType` (a phone's paste among them) is not the
  ⌘C's and answers 1. Every `copy` gets exactly one answer: one sent while
  another is unanswered gets 1 at once.
- `25` curtain: hidden u8 (1 hide, 0 show). Hidden, the Mac puts a black
  window over each of its displays and leaves those windows out of the
  stream, so whoever is at the Mac sees black while the phone sees the
  screen. The iPhone asks for it as each view starts, unless the user
  turned it off, and asks to show it again while the app is in the
  background. Answered with `curtained`. There is one curtain for the Mac:
  every stream leaves it out, also one that didn't ask for it (another
  phone's view), and it stays up while any stream wants it. It comes down
  for a stream when that stream ends, however it ends, or when its phone
  has sent nothing for 20 s with frames unacked (put away, or gone without
  a word). It hides the picture only: the Mac's own keyboard and trackpad
  still work. A Mac that predates it skips the message and doesn't answer.
- `27` gesture: kind u8 (0 magnify, 1 rotate), phase u8 (1 began, 2
  changed, 4 ended, 8 cancelled, as macOS numbers them), value i32 in
  ten-thousandths: the change since the last one (magnification as a
  trackpad gives it, the new size over the last less one; rotation in
  degrees counterclockwise), 0 on began and ended. The Mac posts it as its
  own trackpad's gesture (CoreGraphics' undocumented gesture event), which
  goes to the window under the pointer: the phone moves the pointer under
  the fingers first in touch mode. The phone sends these on a display made
  for it, or on the Mac's own if the user chose it; otherwise a pinch zooms
  the phone's view.
- `28` microphone: on u8 (1 be this Mac's microphone, 0 stop). Answered
  with `microphone state`; the phone records and sends `voice` only once
  that says on, and the Mac drops voice at any other time. It ends with the
  stream. A Mac that predates it skips the message and doesn't answer.
- `29` voice: what the phone's microphone heard next, as 16-bit
  little-endian mono samples at 16 kHz, at most 8 KiB a message (the phone
  sends one about every 10 ms). The Mac plays it to the device as it comes,
  through a small buffer: it starts once 60 ms wait (so a late message finds
  some left), and when more than 250 ms wait (the link stalled, then caught
  up) the oldest are dropped, so what the Mac hears stays close to what was
  just said. The device records what is played to it and nothing else; any
  app on the Mac that may use a microphone can listen to it meanwhile.
- `30` function: down u8 (1 the Mac's Fn key goes down, 0 it comes up), as
  a keyboard's "modifiers changed" event. Let go when the stream ends.
- `31` sound: on u8 (1 send what the Mac plays, 0 stop). Answered with
  `sound state`. It ends with the stream. A Mac that predates it skips the
  message and doesn't answer.
- `26` use here: no payload. Every other device's stream of this Mac's
  screen gets `movedAway` with this phone's name and ends; a display made
  for a phone that one of them had is free again, and this stream moves to
  its own (if it asked for one) a second later.

The Mac marks text a phone puts on its clipboard (`22`) with
`org.nspasteboard.ConcealedType` and `TransientType`, so clipboard managers
leave it out of their history. Over Screen Sharing, which sends the Mac's
clipboard whenever it changes (RFB ServerCutText), the phone takes it only
in the 2 seconds after its own ⌘C for Copy, never when it is the text the
phone itself just pasted, and ignores it otherwise.

When the screen goes still the Mac sends its last frame again, twice, a
quarter of a second apart, so the encoder sharpens it.

Acks are the phone's word, so the Mac also counts what it has handed the
connection that the network has not taken yet: it encodes a new frame only
while fewer than 2 frames and under 4 MiB wait there, and closes the
connection when more than 8 MiB has waited for 5 seconds (a phone that acks
without reading).

The phone uses Apple's login (security type 30) with Screen Sharing and
nothing else: a server offering only None (type 1) is refused. It refuses a
framebuffer wider or taller than 16384 or of more than 50 million pixels
(Screen Sharing sends every display as one), a refusal reason or desktop
name over 64 KiB, and Zlib or ZRLE data that inflates past what its
rectangle can hold.

### Remote Desktop relay

A host that lists `rdp` in `host.screens` relays its own Remote Desktop
(Windows' RDP service, on loopback) the way a Mac relays Screen Sharing
(*Screen*). The device sends `rdp` on an authorized connection; the host
checks, in order, and answers the first that applies: `screen_only` (a
screen pass: never relayed, since its sign-in would let a pass try the
account's password), `screen_not_allowed` (this device's Screen switch is
off), `too_many_screens`, `rdp_unavailable` with `detail` (the relay can't be
used: the same words as `host.rdp`), or `try_later` with `retryAfter`.

Otherwise it connects to Remote Desktop on `127.0.0.1` at the port Windows is
set to, checks the far end of that connection is Windows' own Remote Desktop
service, and replies `rdpReady` with `certSHA256`, the hash of the certificate
that service presents. From the byte after that line the connection carries
Remote Desktop unchanged in both directions; the device sends nothing after
`rdp` until then, and a line that arrives meanwhile closes the connection.
The viewer runs Remote Desktop's own TLS and Network Level Authentication
over it and accepts only the certificate named in `certSHA256`: there is no
trust on first use and no prompt when Windows re-makes its certificate, and a
stand-in for Remote Desktop gets no credential.

The relay can't see a sign-in fail, so it limits what it can see: at most 4
quick `rdp` opens per device's grant in 10 minutes (fewer when Windows locks
an account out sooner) and 12 in all per host; an open that lasted over 30 s
doesn't count. Past that the answer is `try_later`. When a view ends for a
reason the relay can't carry (its Screen switch went off, it was stopped from
the host, someone signed in there), the host tells the device's other
connections with `screenEnded`, and answers `rdp` `try_later` for 30 s after
a Stop.

### Screen passes

A phone with shell access to two Macs can let one see the other's screen.
It asks the Mac to be seen for a pass (`screenGrant`), which that Mac
grants only to a phone it also lets see its screen. The Mac stores the pass
like a phone's access, under a new id starting `viewer.` with its own key,
screen access on and Keep awake and the VPN off, and remembers the phone
that asked: removing that phone (or forgetting its pairing) removes its
passes, and a pass may see the screen only while that phone may. A new
pass for the same `viewer` replaces the old one once the viewer first
connects with it; until then the old one keeps working, so a hand-over that
fails leaves the viewer its working pass (8 per phone at most, the oldest
going). Passes are kept in their own Keychain item, apart from the phones,
so a Mac running a build from before passes never reads one as a phone. Only the Mac mints `viewer.` ids: a phone granted access
under one is refused. The phone then builds a credential from its own for
that Mac, updated with the `macInfo` that Mac sent on this connection
(addresses, certificate and iroh details, including the relay token, so
the other Mac holds that token too), with the pass's id and key, and hands
it to the other Mac (`screenPass`), which keeps one per Mac, noting which
phone handed it over (revoking that phone there forgets it). If the other
Mac doesn't keep it, the phone takes the pass back (`screenRevoke`) on the
connection it got it on.

The viewer connects and proves its key exactly as a phone does, on either
path, dialing the pass's addresses and any Bonjour result named as the
Mac. Any `viewer.` id is screen-only, whatever else the Mac knows of it. A
Mac sends a pass's connection only `ready`: no `macInfo`,
`macState` or `sessions`, then or later. It accepts only `screenVideo`,
`ping` and `pong` from it; anything else, `screen` (the tunnel to macOS
Screen Sharing) included, is answered `error` `screen_only`. On the stream,
a pass's view sends pointer, keys, text and the clipboard like a phone's,
but its `curtain` is refused (answered `curtained` false) and its Use Here
is ignored. The Mac shows a notice when a phone grants a pass. The owner sees
each pass in the Mac's settings and can remove it like a phone. The viewing
Mac asks for Touch ID or its password before each window it opens.

### Address policy

The Mac closes a connection from any peer outside these ranges before the TLS
handshake completes: 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8,
100.64/10, `fc00::/7`, `fe80::/10`, `::1` and `fd7a:115c:a1e0::/48`
(Tailscale). 100.64/10 is also carrier-grade NAT space, so a peer from it, or
from `fd7a:115c:a1e0::/48`, is let in only while one of the Mac's own tunnel
interfaces (a point-to-point `utun`, as Tailscale, NetBird and Headscale set
up; on a Windows PC, an adapter of virtual or tunnel type with no hardware and
no connector, which is what Wintun and WireGuard adapters report, never
Ethernet, Wi-Fi, WWAN or a Hyper-V or WSL switch) has an address in that range of the same family, and only when the
connection arrived on such an address; the same range on Wi-Fi or Ethernet is
the carrier's network and does not count. A connection from such a peer whose
arrival address is not known is refused. Hosts may carry a `%zone` suffix, which is ignored. A global
IPv6 peer (`2000::/3`) is also let in when it shares a /64 with one of the
Mac's own global addresses, so an IPv6-only LAN works; any other global
address is refused. Only computers listen, so this check has no Kotlin
counterpart; the Windows rule for what counts as a tunnel interface comes with
its listener.
`addresses` in a `shellGrant` omit loopback and link-local, list Tailscale
addresses last, and never include anything outside those ranges
(`ShellAddressPolicy`).
