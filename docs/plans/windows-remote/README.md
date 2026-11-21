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
* Done from stage 0:
  * [`Spikes/PcProbe`](../../../Spikes/PcProbe/README.md) (0.2): what a PC
    can tell us without an administrator, run on one PC.
  * [`Spikes/ConPtyProbe`](../../../Spikes/ConPtyProbe/README.md) (0.7):
    **passes with the bundled ConPTY, fails with the inbox one**, so stage 3
    bundles it with no fallback; Claude Code's status works through it. Its
    README lists what stage 3's session manager must add (answer the
    pseudoconsole's own start-up query, keep its win32-input and focus modes
    from phones, accept BEL-terminated 7501 queries). WSL is still to be run
    on a PC where WSL2 starts.
* Open pull requests (each stacked on the one before, all against `dev`;
  merge in this order):
  * #42 CI: a Windows job, the .NET SDK pinned, NuGet locked (stage 1, PR 1).
  * #43 the C# shell envelope, all three suites on the same fixtures (stage 1, PR 2).
  * #44 the wire contract: `host`, shells, `signed_out`, `goingAway`, the
    Remote Desktop relay messages, `hostKind`; the Mac sends `host` (stage 1, PR 3).
  * #45 shell grants over the cable and log redaction (stage 3, PR 1).
  * #46 the shell grant ledger (stage 3, first half of PR 2).
  All were reviewed together and the findings fixed. Each says in its
  description what still has to be checked by hand on a Mac and phones.
* Deliberately left from that review: the Mac sends `host` once per connection
  (a phone sees a changed Screen switch at its next connection); `hostKind`
  takes only `mac` and `windows`; C# decodes a little more leniently than
  Swift and Kotlin when a required field is missing; the plan's Swift and
  Kotlin tests for `hostKind` on the grant and for `host` ordering on the Mac
  listener are not written yet.
* Next, on the PC: stage 3, second half of PR 2 (a control channel to every
  attached phone, iPads pairing, Forget revoking shell access), then PR 3 (the
  shell's logic ported from the Mac). Stage 1 PR 4 (computers) waits for stage 7.
* Next, needing the Mac and a phone: spikes 0.1, 0.3, 0.5, 0.6, and stage 2
  (the phones show a PC as a PC).
* Needs your PC set up: Rust and the MSVC build tools (an administrator
  install), for the iroh bridge in stage 3, PR 5.
