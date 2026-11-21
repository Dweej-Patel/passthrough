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

* Planned: every stage. Built: nothing yet beyond the Windows foundation
  already on `dev`.
* Done from stage 0: [`Spikes/PcProbe`](../../../Spikes/PcProbe/README.md)
  (what a PC can tell us without an administrator), run on one PC.
* Next: the rest of stage 0, starting with the ConPTY spike (PC only), then
  stage 1's CI job and `ShellEnvelope` for C#.
