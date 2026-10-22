# Security policy

Passthrough runs a root helper on the Mac and a network extension on the
iPhone, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue. Use GitHub's private vulnerability
reporting on this repository (*Security* tab → *Report a vulnerability*).

Include what you can of:

* which component is affected (iOS app, tunnel extension, Mac app, root helper,
  `PassthroughCore`, vendored engines)
* steps to reproduce, or a proof of concept
* the impact you believe it has

You should hear back within a week. Fixes for confirmed issues are released as
soon as they are ready, and you will be credited unless you would rather not be.

## Scope

In scope: anything that lets an unpaired device or another process on the Mac
use the proxy, anything that lets an imported VPN profile execute code or read
files as root, and anything that bypasses the kill switch or IPv6 blocking
while a VPN is up.

The remote shell (off by default) is in scope end to end: the shell listener (pre-auth connection limits, the HMAC challenge, pinned TLS 1.3, the private/Tailscale address policy, and the built-in iroh endpoint), the key grant over the control channel, how the shell key is stored on the Mac and on phones, transcripts at rest under `ShellHistory`, and the consequences of a network-reachable app holding Full Disk Access. Anything that gets a shell, or a transcript, to a device that was not paired over the cable is a vulnerability.

**Internet-reachable iroh endpoint.** With *Reach this Mac from anywhere (built-in)* on (the default while Remote shell is on), the Mac runs an iroh endpoint that accepts connections from the internet. That is by design, so the shell's own authentication is the gate. The pre-auth surface is not limited to holders of the endpoint id: anyone who can reach the endpoint's UDP port directly (on the same LAN, or over public IPv6) can start a handshake, as can anyone who knows the endpoint id and reaches it through a relay. Every such attempt is bounded: at most 16 connections are unproven at once (2 per remote IP on direct paths, 8 arriving through relays), each gets 10 seconds from the moment it arrives (before the QUIC handshake), and its `hello` and proof lines are limited to 4096 bytes (a hard limit). Nothing is read past the proof until the phone proves its per-phone 256-bit shell key with the HMAC challenge. On this path the transport encryption is iroh's QUIC (TLS 1.3, end to end between phone and Mac, the Mac authenticated by its endpoint id, which is its public key); there is no further pinned TLS inside the stream, and the HMAC shell-key proof is the authorization. The endpoint id and relay are sent only to phones that have authenticated (in `macInfo`) or over the cable; they are not secret in the cryptographic sense, but are not published anywhere. Relays see both endpoint ids, source and destination IP addresses, timing and traffic volume, never content. The default relays are run by a third party (n0) with no uptime guarantee. A custom relay is configured on the Mac, and its access token is stored in the Mac's Keychain; the Mac also gives that token to paired phones (in the cable grant and in `macInfo`) so they can use the relay, and phones keep it in their secure store (the iPhone's Keychain; on Android, storage encrypted with a Keystore key), so a lost phone holds it. To rotate it, change the token on the relay and in the Mac's settings: phones get the new one the next time they connect on any path. A phone dials the Mac's relay as it was last given; if the Mac's home relay moves, a phone that is away reaches it again after its next connection on any path (local, Tailscale, or iroh directly) brings the new one. The Mac's endpoint secret key is also in the Keychain (it is its identity, not a shell credential); *Reset built-in identity...* replaces it. Phones use a fresh ephemeral endpoint key for every connection attempt and store none. Turning the option off removes the endpoint entirely. Weaknesses in any of this are in scope.

Out of scope: the fact that a carrier might detect tethering. That is
documented as a known limit, not a bug.
