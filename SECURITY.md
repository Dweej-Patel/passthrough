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

Out of scope: the fact that a carrier might detect tethering. That is
documented as a known limit, not a bug.
