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
while a VPN is up. That includes routes a network can push (DHCP option 121,
IPv6 route information), which the kill switch's pf rules are meant to defeat,
and a crash of the app or the helper, which is meant to leave the kill switch
in place. By design, the kill switch lets through traffic to the private
networks the Mac is directly on while *Allow local network* is on, link-local
and link-scoped multicast traffic, Tailscale's own interfaces, and the Mac's
replies on Passthrough's wireless link to the phone.

The cable control channel is in scope too. It assumes whatever is on the
other end may be hostile: another phone plugged into the Mac, an app bound to
the phone's loopback control port while Passthrough isn't running (reachable
through adb), or a fake adb server on the Mac that answers itself. The
pairing token is sent once, in answer to the code shown on the phone, and
never again: each connection proves the pairing both ways with HMAC-SHA256
over fresh nonces (the phone first), the Mac hands over link and shell keys
only after that, the phone tells a connection nothing about itself and acts
on nothing privileged before the Mac's proof, and the SOCKS5 password is a
separate value derived from the token. A pairing code is withdrawn after ten
wrong guesses in all (each connection may send three before the phone closes
it), so wrong guesses can't lock out the right code, and the phone closes
connections that prove nothing within 10 seconds unless a code is showing.
Anything that gets a token, a link key, a shell key or relay details out of
this channel without the pairing, or lets a peer that hasn't proved it change
what the phone or Mac stores, is a vulnerability. Deliberately pairing with a
device (typing the code it shows) is not.

The control channel is authenticated, not encrypted. A process running as
the Mac user can put itself between the app and adb (a fake adb server on
`127.0.0.1:5037` that relays to the real one, or to the phone): the proofs
pass through it untouched, and it can then read what is sent after them, the
wireless link key, the shell key, relay details and, during a pairing, the new
pairing token. That is out of scope: code already running as the user is
outside the threat model (it can read the user's files and drive the user's
apps). The fix would be an encrypted control channel bound to the pairing
(keys derived from K and both nonces), which Passthrough does not have.

The Mac app reads its secrets only from the data-protection keychain, never
the legacy file keychain, where any process running as the user could plant
an item under Passthrough's name.

The remote shell (off by default) is in scope end to end: the shell listener (pre-auth connection limits, the HMAC challenge, pinned TLS 1.3, the private/Tailscale address policy, and the built-in iroh endpoint), the key grant over the control channel, how the shell key is stored on the Mac and on phones (including while a new key waits for the phone app's next unlock: the iPhone's extension and Android's service keep it only sealed to a key that needs the unlocked app, a Secure Enclave key with user presence on the iPhone or one inside the Android shell key vault; a pending key readable without the user is a vulnerability), transcripts at rest under `ShellHistory` (excluded from backups; finished sessions deleted after the *Keep shell history* period, 30 days by default, and past 2 GB oldest first), and the consequences of a network-reachable app holding Full Disk Access. Anything that gets a shell, or a transcript, to a device that was not paired over the cable is a vulnerability.

Screen (off for every phone by default) is in scope too: the per-phone Screen permission, the hand-over of an authorized connection to the screen stream or to the Screen Sharing relay on loopback, the stream's binary messages as the Mac parses them, the input it posts as the user's own events, and the consequences of a network-reachable app holding Screen Recording and Accessibility. The stream asks for no Mac password by design (the Screen switch is the consent). Anything that shows the screen to, or takes input from, a phone without that permission is a vulnerability, with one exception by design: shells inherit Passthrough's privacy permissions, so while Screen Recording and Accessibility are granted, a phone with shell access can capture the screen and post input with command-line tools. Shell access is already full control of the user account, so the Screen switch gates only Passthrough's own stream and the Screen Sharing relay.

The clipboard is in scope as well. Text from the Mac reaches the phone's clipboard only on a user action (Copy in the terminal or in Screen) or a program's OSC 52 copy in an attached, writable terminal, and Screen's Copy returns only a change to the Mac's clipboard in the moment after its own ⌘C (a second on the stream, two over Screen Sharing), never what was already there. Something else copying on the Mac inside that window would be taken as the ⌘C's; that window is the accepted limit. On the iPhone it is kept off Universal Clipboard and cleared after two minutes. The Mac never reads the phone's clipboard; the phone sends it only on Paste. A paste into the shell is stripped of escape and control characters, so it can't inject terminal commands or end a bracketed paste. Anything that moves clipboard contents between the devices without those actions, or lets a paste run commands the user didn't see while the shell asked for bracketed paste, is a vulnerability.

**Internet-reachable iroh endpoint.** With *Reach this Mac from anywhere (built-in)* on (the default while Remote shell is on), the Mac runs an iroh endpoint that accepts connections from the internet. That is by design, so the shell's own authentication is the gate. The pre-auth surface is not limited to holders of the endpoint id: anyone who can reach the endpoint's UDP port directly (on the same LAN, or over public IPv6) can start a handshake, as can anyone who knows the endpoint id and reaches it through a relay. Every such attempt is bounded: a slot is taken only once QUIC has validated the peer's address (a retry round trip), and at most 16 connections are unproven at once (2 per remote IP on direct paths, a public IPv4 address counted by its /24 and IPv6 by its /64, a link-local one by itself; 8 arriving through relays; 4 kept for addresses that proved a shell key in the last 30 days), each gets 10 seconds from the moment it arrives (before the QUIC handshake), and its `hello` and proof lines are limited to 4096 bytes (a hard limit). Nothing is read past the proof until the phone proves its per-phone 256-bit shell key with the HMAC challenge. On this path the transport encryption is iroh's QUIC (TLS 1.3, end to end between phone and Mac, the Mac authenticated by its endpoint id, which is its public key); there is no further pinned TLS inside the stream, and the HMAC shell-key proof is the authorization. The endpoint id and relay are sent only to phones that have authenticated (in `macInfo`) or over the cable; they are not secret in the cryptographic sense, but are not published anywhere. Relays see both endpoint ids, source and destination IP addresses, timing and traffic volume, never content. The default relays are run by a third party (n0) with no uptime guarantee. A custom relay is configured on the Mac, and its access token is stored in the Mac's Keychain; the Mac also gives that token to paired phones (in the cable grant and in `macInfo`) so they can use the relay, and phones keep it in their secure store (the iPhone's Keychain; on Android, storage encrypted with a Keystore key), so a lost phone holds it. To rotate it, change the token on the relay and in the Mac's settings: phones get the new one the next time they connect on any path. A phone dials the Mac's relay as it was last given; if the Mac's home relay moves, a phone that is away reaches it again after its next connection on any path (local, Tailscale, or iroh directly) brings the new one. The Mac's endpoint secret key is also in the Keychain (it is its identity, not a shell credential); *Reset built-in identity...* replaces it. Phones use a fresh ephemeral endpoint key for every connection attempt and store none. Turning the option off removes the endpoint entirely. Weaknesses in any of this are in scope.

Out of scope: the fact that a carrier might detect tethering. That is
documented as a known limit, not a bug.
