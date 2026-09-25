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
absent (never `null`). Unknown fields are ignored.

| `t` | From | Fields | Meaning |
|-----|------|--------|---------|
| `hello` | Mac | `protocolVersion`, `clientID`, `name`, `token`?, `via`? | First message. With a valid token the Mac is authenticated. `via` is `usb` or `wireless`: how this connection reaches the phone (a phone may have a wireless link up while the Mac uses the cable). |
| `welcome` | phone | `protocolVersion`, `paired`, `socksPort`, device facts | Reply to `hello`. `paired: false` means pair first. |
| `pair` | Mac | `clientID`, `name`, `code` | The six digits shown on the phone. |
| `paired` | phone | `token`, `socksPort`, `deviceName` | Pairing worked; followed by a `status`. |
| `error` | phone | `reason` | `bad_code`, `expired`, `not_authenticated` or `unsupported_version`. |
| `ping` / `pong` | Mac / phone | none | Heartbeat every 5 s; the Mac gives up after 20 s of silence. |
| `status` | phone | device facts, `activeConnections`, `rxBytes`, `txBytes`, `timestamp` | Once a second to authenticated Macs. |

Device facts are `deviceName`, `radio`, `carrier`, `battery` (0 to 1),
`hosting` (`background` or `foreground`) and `ipv6`: whether the network the
phone sends traffic out on routes IPv6. When it is `false` the Mac rejects
IPv6 in its tunnel, so apps fall back to IPv4 at once instead of hanging on
connections the phone can't make; older phones omit it and nothing changes.

## Pairing

* The phone shows a six-digit code, valid for 5 minutes. Five wrong guesses
  withdraw it.
* On success the phone issues a token: 32 random bytes as unpadded URL-safe
  base64 (43 characters, `PairingToken`). The phone stores only its SHA-256
  (lowercase hex); the Mac keeps the token in its keychain.
* The Mac sends the token in `hello`, and as the SOCKS5 password with its
  `clientID` as the username.

## SOCKS5 (7890)

RFC 1928 with username/password auth (RFC 1929) only. Commands:

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
5. From then on the connection carries multiplexed streams.

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
