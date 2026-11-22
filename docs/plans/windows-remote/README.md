# Windows PCs as full peers: the plans

Working plans for making a Windows PC a host and a viewer for the remote shell
and screen. They describe work that is not built yet; what each stage ships is
recorded in the changelog and the guide, not here.

## Read in this order

1. [`MASTER.md`](MASTER.md): the approved plan. Decisions, what it will feel
   like (wording, state tables), architecture, protocol changes, order of work.
2. [`RECONCILIATION.md`](RECONCILIATION.md): where the stage plans disagree
   and what holds. **It overrides the stage plans**, and lists what the owner
   decided, what was decided without them, and the reviews still owed.
3. The stage you are about to build:

| Stage | Plan | Needs |
|---|---|---|
| 0 | [Spikes](stage-0-spikes.md) | mostly a Mac, a phone and this PC; only ConPTY runs on the PC alone |
| 1 | [Protocol groundwork](stage-1-protocol.md) | stage 0's answers |
| 2 | [Phones know a PC](stage-2-phones.md) | stage 1; a Mac to build |
| 3 | [The PC's shell, from anywhere](stage-3-shell-host.md) | stages 1, 2; Rust and MSVC tools on the PC |
| 4 | [The service](stage-4-service.md) | stage 3 |
| 5 | [The Remote Desktop relay](stage-5-rdp-relay.md) | stage 4 |
| 6 | [The PC's screen on iPhone and iPad](stage-6-ios-rdp.md) | stage 5; its first two PRs can start any time |
| 7 | [Mac ↔ PC](stage-7-mac-pc.md) | stages 4 to 6 |
| 8 | [The PC as viewer](stage-8-pc-viewer.md) | stages 3, 7 |
| 9 | [Later](stage-9-later.md) | outlined only |

[`BRIEF.md`](BRIEF.md) is the brief the stage planners were given, with the
facts measured on a real PC.

## Before starting a stage

* Apply that stage's line under *What each stage's author changes* in the
  reconciliation to its plan first.
* Stages 4 to 8 each get a security review and a UX review of their plan when
  they start (only stage 3 has had its cross-stage security review).
* Every pull request goes against `dev`, leaves it working, changes
  `protocol/fixtures.json` first when the wire changes, and carries its docs
  and changelog entry.

## Where things stand

* Built on the PC, in open pull requests stacked in this order against `dev`
  (merge in order; each description says what still needs a real device):
  * #42–#44 stage 1: CI with a Windows job; the C# shell envelope; the wire
    contract (`host`, shells, `signed_out`, `goingAway`, Remote Desktop relay
    messages, `hostKind`), with the Mac sending `host`.
  * #45–#49 stage 3, PRs 1–2: grants over the cable and log redaction; the
    grant ledger; a channel to every attached phone, iPads pairing, Forget
    revoking; grants to every paired, genuine channel; the address policy and
    handshake limits.
  * #50–#52 stage 3, PR 3: the terminal logic, recording, and the session
    manager, ported with their tests.
  * #53 stage 3, PR 4: real shells in the bundled ConPTY, a job each, from the
    PC's catalog.
  * #54 stage 3, PR 5: the iroh bridge (Rust, iroh 1.0.2 as the phones use).
  * #55–#56 stage 3, PR 6: the shell protocol and the phones' access; Remote
    access in the tray app, grants behind the cable peer check.
* Found while building, differing from the plan:
  * With Apple Devices (the Store app) there is no Apple Mobile Device
    Service: usbmuxd is a packaged process running as the user. The peer
    check accepts the service's process or that package's identity.
  * The bundled ConPTY's opening (`ESC[1t ESC[c ESC[?1004h ESC[?9001h`) is
    dropped before phones and recordings see it; its `ESC[c` is left
    unanswered (nothing stalls).
* Left from the stage 1 review, still: the Mac sends `host` once per
  connection; `hostKind` takes only `mac` and `windows`; C# decodes a little
  more leniently than Swift and Kotlin; Swift and Kotlin tests for `hostKind`
  on the grant and `host` ordering are not written.
  * #57–#58 stage 3, PRs 7–8 and its review fixes: history retention, relay
    settings, reset identity; the security fixes B-1 to B-17.
  * #59–#63 stage 4, PRs 1–5, the service (its plan review applied): install,
    update, off and remove behind one prompt; the pipe; phones in the service
    (records-only hand-over, the service's own iroh key); TLS 1.3 and DNS-SD
    on the same network; Stay awake and going-away messages. CI's install
    round trip runs it for real on the runner.
  * #64 stage 5, the Remote Desktop relay (its plan review applied): NLA
    enforced per relayed connection, the far-end check, the certificate pin,
    caps, and Screen's setup in closed, owner and policy modes.
* Changed by the stage 4 and 5 reviews (beyond the reconciliation): no service
  control deletes anything (removal deletes the service's profile); one exe at
  a fixed path launches the installed app, so Start at login never dangles;
  logs are administrators-only; the Remote Desktop block rules have a firewall
  group of their own; the relay reads the first PDU each way and closes any
  connection without NLA.
  * #65–#68 stage 5's notices (exposure, after-view, Allow screen), the
    hand-off to the installed copy, and stage 7 (a) on the PC: computer
    access (`computer.` ids, HMAC plus a signature bound to this host, a
    decoy check), Hello-sealed passes handed to this PC.
  * #69 and #71 stage 2 on iOS and Android: phones know a PC (kind, words,
    the PC page and its states, the split New shell, a screen gate that never
    sends a PC to the Mac's Screen Sharing login).
  * #70 stage 8 (a): the PC as a shell client (pinned TLS and iroh),
    `passthrough-term.exe`, Your computers in the flyout.
  * #72 stage 7 (a) on the Mac and iPhone: the Mac lets in computers a phone
    shares, the iPhone's share flow, the Mac keeps passes handed to it.
  * #73 stage 8 (b): a Mac's screen in a window on the PC (Media Foundation
    decoding on the GPU, input, clipboard).
  * #74 stage 6: a PC's screen on the iPhone and iPad through Remote Desktop,
    behind a debug-only switch; FreeRDP 3.33.1 built by a script and a
    workflow, never committed.
  * #75 fixes from an independent review of stages 4, 5, 7 and 8 on the PC;
    review fixes for #69–#74 are on their own branches.
* Not yet: the quit dialog; `host.console` and the takeover question; stage 6's
  clipboard, display resize, Windows menu, gestures and shared-surface path;
  stage 7 (b) direct pairing, (c) the Mac's window onto a PC, (d)
  `passthrough-term remote`; stage 8 (c) sound and microphone; fixtures for
  the computer messages; keeping a replaced computer grant until the new one
  first connects.
* Not run for real on this PC (each changes it; left for the owner):
  `--install`, Screen setup, stock FreeRDP through the relay, `--remove`.
* Needs the Mac and a phone: spikes 0.1, 0.3, 0.5, 0.6; stage 2 on real
  phones; the first real test of #56 (turn on, plug in, open a shell from
  cellular); stage 6 against a real PC (sign-in, pin, NLA over the hook);
  stage 7 and 8 against a real Mac.
