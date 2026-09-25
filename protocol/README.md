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
| `hello` | Mac | `protocolVersion`, `clientID`, `name`, `token`? | First message. With a valid token the Mac is authenticated. |
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
