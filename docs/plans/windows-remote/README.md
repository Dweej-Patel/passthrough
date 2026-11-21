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
* Next on the PC: stage 3 PRs 7–8 (history retention, relay settings and
  reset identity), then stages 4 and 5.
* Needs the Mac and a phone: spikes 0.1, 0.3, 0.5, 0.6; stage 2 (the phones
  call the PC a PC: until then a PC works but is named a Mac); the first real
  test of #56 (turn on, plug in, open a shell from cellular).
