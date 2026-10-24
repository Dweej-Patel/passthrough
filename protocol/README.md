# Wire protocol

What the Mac and a phone (iPhone or Android) say to each other. The Swift
implementation is in `Packages/PassthroughCore`, the Kotlin one in
`android/app/src/main/java/dev/dpatel/passthrough/core`. Both test suites read
[`fixtures.json`](fixtures.json); change a message, a port or a pairing rule
there first, then make both suites pass.

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
| `welcome` | phone | `protocolVersion`, `paired`, `nonce`, `proof`?, `socksPort`, device facts | Reply to `hello`, with the phone's own fresh `nonce`. `paired: true` comes with `proof` (below); `paired: false` means pair first. |
| `auth` | Mac | `proof` | The Mac's proof, sent first after a `welcome` whose proof it verified. The connection is authenticated once the phone has verified it. |
| `pair` | Mac | `clientID`, `name`, `code` | The six digits shown on the phone. After `hello`; `clientID` must match it. |
| `paired` | phone | `token`, `socksPort`, `deviceName` | Pairing worked (the connection is now authenticated); followed by a `status`. |
| `error` | phone | `reason`, `protocolVersion`? | `bad_code`, `expired`, `locked`, `not_authenticated` or `unsupported_version` (which carries the phone's `protocolVersion`, absent from version 1 phones). |
| `ping` / `pong` | Mac / phone | none | Heartbeat every 5 s; the Mac gives up after 20 s of silence. |
| `status` | phone | device facts, `activeConnections`, `rxBytes`, `txBytes`, `timestamp` | Once a second to authenticated Macs. |
| `shellGrant` | Mac | `shellKey`, `certSHA256`, `shellPort`, `addresses`, `macName`, `irohID`?, `irohRelay`?, `relayToken`?, `grantID`? | Over the cable, on every paired connection while Remote shell is on: gives the phone access to the Mac's remote shell (below). `shellKey` is 32 random bytes, base64; `addresses` are where to dial the Mac. Each grant is a fresh key; the Mac also accepts the key the phone last proved until the phone first proves the new one, since a phone adopts a grant only once its app is unlocked. The optional `irohID` (the Mac's iroh endpoint id: 64 lowercase hex), `irohRelay` (its home relay: an `https` URL, at most 256 characters) and `relayToken` (at most 512 characters; kept in the phone's secret store, never in the grant record) let the phone dial the Mac over iroh (below). If the iroh fields are not valid as a group (a valid `irohID` is required; lengths count UTF-8 bytes), the phone drops all three and still stores the rest of the grant. The optional `grantID` (at most 64 UTF-8 bytes) names this grant for the answer. The Mac keeps one grant per phone in flight; one unanswered within 15 s counts as lost. The Mac then grants again after a wait counted from the end of those 15 s: 15, 30, 60 and 120 s for consecutive lost grants, then every 10 minutes. The next control channel, a new pairing, a change in what grants carry, or an answer starts the waits over. |
| `shellGranted` | phone | `phoneID`, `grantID`? | The phone stored the grant, its key sealed to the phone app's sealing key (`ShellKeySeal`; the vector is in fixtures.json). A phone whose app has not published a sealing key yet stores nothing and does not answer, so the grant expires and the Mac grants again as above. Echoes the grant's `grantID` when it had a valid one (1 to 64 UTF-8 bytes), so the Mac records the key of the grant answered and ignores a late answer to an earlier one. An answer without `grantID` (from phones that predate it) counts for the grant in flight. |

Device facts are `deviceName`, `radio`, `carrier`, `battery` (0 to 1),
`hosting` (`background` or `foreground`) and `ipv6`: whether the network the
phone sends traffic out on routes IPv6. When it is `false` the Mac rejects
IPv6 in its tunnel, so apps fall back to IPv4 at once instead of hanging on
connections the phone can't make; older phones omit it and nothing changes.

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
   `shellGrant` are ignored, and no `status` is sent.
5. A completed code pairing (`pair` → `paired`) authenticates the connection
   for both sides. The Mac accepts `paired` only as the answer to its own
   `pair`, once.

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

* The phone shows a six-digit code, valid for 5 minutes. Five wrong guesses in
  a row lock code entry for 30 s (every `pair` gets `locked`, even with the
  right code); the code itself stays.
* On success the phone issues a token: 32 random bytes as unpadded URL-safe
  base64 (43 characters, `PairingToken`). The phone stores only its SHA-256
  (lowercase hex); the Mac keeps the token in its keychain, one slot per
  phone: `token.iphone.<UDID>` or `token.android.<serial>` (letters, digits,
  `-`, `_` and `.` only). iPhones once shared the slot `token`: the Mac still
  tries it for an iPhone whose own slot is empty, and once the phone proves
  that token it moves to the phone's slot, with the link key and any shell
  access granted through it.
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
3. `{"t":"ready"}` followed by `sessions` from the Mac, or
   `{"t":"error","reason":"not_authorized"}` and the connection closes.

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
After an `attach` the Mac sends the scrollback as `output`, then `attached`,
then live output. A phone's terminal should not answer terminal queries
(device attributes, cursor position, color reports…) found in the replay:
the program that asked is long gone, and the answer would arrive as input.
`input` and `resize` must name the attached session, else `bad_request`. A
line that is not valid JSON or has an unknown `t` gets `bad_request`; the
connection stays open.
A phone that stops reading while 8 MiB of output waits to be sent is
disconnected; it can attach again and gets the scrollback.

### Messages

| `t` | From | Fields | Meaning |
|-----|------|--------|---------|
| `challenge` | Mac | `nonce` | Starts the handshake. |
| `proof` | phone | `phoneID`, `mac` | Answer to the challenge. |
| `ready` | Mac | none | Authorized; the commands below are accepted. |
| `hello` | phone | none | iroh only: the first line the phone writes, so the Mac sees the stream. Ignored elsewhere. |
| `macInfo` | Mac | `irohID`, `irohRelay`?, `relayToken`?, `addresses` | Sent right after `ready` on every path, except while the Mac's iroh endpoint is on but not ready to hand out (still starting, or on the default relays with no home relay yet): then it is not sent at all, so phones keep what they have (the grant likewise leaves the iroh fields out). The phone updates the stored grant's iroh details and addresses (`addresses` at most 16; validation as in `shellGrant`; absent `relayToken` clears the stored one). Valid `addresses` always apply. The iroh fields apply as a group only when valid; no `irohID` clears the stored iroh details and token, and a token without an `irohID` is never stored. It never changes the shell key or certificate pin. |
| `list` | phone | none | Ask for the live sessions. |
| `sessions` | Mac | `sessions` | Reply to `list`: `ShellSessionInfo` objects `id`, `title`, `startedAt`, `lastOutputAt` (Unix seconds), `running`, `exitStatus`?. |
| `open` | phone | `cols`, `rows` | Start a new session. |
| `opened` | Mac | `session`, `cols`, `rows` | The session exists and this connection is attached to it. |
| `attach` | phone | `session`, `cols`, `rows` | Attach to a live session; the Mac replays its scrollback as `output` first. |
| `attached` | Mac | `session` | The replay for an `attach` is complete: every later `output` is live. Sent before `ended` for a session that already exited. |
| `input` | phone | `session`, `data` | Keystrokes for the PTY. |
| `resize` | phone | `session`, `cols`, `rows` | The terminal changed size. |
| `output` | Mac | `session`, `data` | PTY output, at most 16384 bytes before base64 per line. |
| `close` | phone | `session` | End the session (the shell is hung up). |
| `ended` | Mac | `session`, `exitStatus`? | The shell exited. |
| `detached` | Mac | `session`, `reason`? | Another connection took the session over. |
| `history` | phone | none | Ask for past sessions. |
| `historyList` | Mac | `history` | `ShellHistoryEntry` objects `id`, `title`, `phoneLabel`, `startedAt`, `endedAt`?, `exitStatus`?, `bytes`, `cols`?, `rows`? (the terminal's size when the session started; absent from older Macs); newest first. At most the newest 500, and fewer (the oldest dropped) if the line would otherwise exceed 262144 bytes. |
| `transcript` | phone | `session` | Ask for a past session's recorded output: at most its last 8 MiB. |
| `transcriptData` | Mac | `session`, `data`, `cols`?, `rows`?, `done`? | A piece of the transcript (same chunk size); `done: true` on the last. `cols`/`rows`, when present, are the size the recorded terminal had from this piece on: set it before feeding `data` (which may be empty when a size change ends the transcript). The first piece always carries the size its first byte was drawn at; older Macs send none. |
| `screen` | phone | none | See and control the screen: the connection becomes a relay to Screen Sharing (below). |
| `screenReady` | Mac | none | Reply to `screen`; every later byte, both ways, is Screen Sharing's. |
| `ping` / `pong` | either | none | Liveness. |
| `error` | Mac | `reason`, `session`? | `not_authorized`, `too_many_sessions` (8 at once), `no_such_session`, `bad_request`, `screen_not_allowed`, `screen_unavailable`, `screen_video_unavailable` or `too_many_screens`. |

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
display itself, as H.264 from its hardware encoder in low-latency mode, at
most at the display's size in points; no Mac password is involved (screen
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
for a type it doesn't know, 64 bytes for every other message. It types text
at up to 8 KiB a second (keys sent after text wait their turn), and drops
text once 256 KiB is waiting.

Mac → phone:
- `1` format: width u16, height u16, SPS length u16, SPS, PPS length u16,
  PPS. Sent before every keyframe.
- `2` frame: number u32 (from 1), flags u8 (bit 0: keyframe), then the
  frame's NAL units, each after a 4-byte length (AVCC).

Phone → Mac:
- `16` hello: max width u16, max height u16, the phone's largest useful
  size in pixels. Sent first; the Mac fits the stream inside it (and
  starts anyway after a second without it).
- `17` ack: frame number u32, once that frame is on screen. The Mac sends
  a new frame only while fewer than 2 are unacked, encoding only the newest
  capture (older ones are dropped before encoding), so nothing queues
  anywhere and the picture stays current on a slow path. A frame the phone
  can't show (one before the keyframe it is waiting for) is acked anyway.
- `18` pointer: x u16, y u16 (each 0…65535 across the screen), buttons u8
  (1 left, 2 middle, 4 right, as RFB).
- `19` scroll: dx i16, dy i16 in the Mac's points; positive dy brings
  earlier content into view.
- `20` key: X keysym u32 (as RFB), modifiers u8 (1 command, 2 shift, 4
  option, 8 control), pressed and released.
- `21` text: UTF-8, typed as is whatever the Mac's keyboard layout.
- `22` clipboard: UTF-8, put on the Mac's clipboard.
- `23` keyframe request: the phone lost its place (its display failed, or
  it was in the background).

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

### Address policy

The Mac closes a connection from any peer outside these ranges before the TLS
handshake completes: 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8,
100.64/10, `fc00::/7`, `fe80::/10`, `::1` and `fd7a:115c:a1e0::/48`
(Tailscale). 100.64/10 is also carrier-grade NAT space, so a peer from it, or
from `fd7a:115c:a1e0::/48`, is let in only while one of the Mac's own tunnel
interfaces (a point-to-point `utun`, as Tailscale, NetBird and Headscale set
up) has an address in that range of the same family, and only when the
connection arrived on such an address; the same range on Wi-Fi or Ethernet is
the carrier's network and does not count. A connection from such a peer whose
arrival address is not known is refused. Hosts may carry a `%zone` suffix, which is ignored. A global
IPv6 peer (`2000::/3`) is also let in when it shares a /64 with one of the
Mac's own global addresses, so an IPv6-only LAN works; any other global
address is refused. Only the Mac listens, so this check has no Kotlin
counterpart and no fixtures.
`addresses` in a `shellGrant` omit loopback and link-local, list Tailscale
addresses last, and never include anything outside those ranges
(`ShellAddressPolicy`).
