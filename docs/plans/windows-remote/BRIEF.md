# Brief for phase planners

You are writing the detailed implementation plan for one or two stages of an approved master plan. Read these first, in this order:

1. The master plan: `docs/plans/windows-remote/MASTER.md` (all of it; it holds the decisions, the UX wording, the architecture, the protocol changes and the stage list).
2. The repo at `D:\projects\passthrough` (branch `windows-remote-spikes`, same tree as `dev`): `README.md`, `CONTRIBUTING.md`, `protocol/README.md`, `protocol/fixtures.json`, `windows/README.md`, `docs/GUIDE.md`, `SECURITY.md`, and the source your stage touches. Verify every claim you make about existing code by opening the file; cite `path:line`.
3. `Spikes\PcProbe\README.md`: facts already measured on a real PC.

## Rules

- **Do not ask the owner anything and do not stop for input.** Where a decision is needed, make the best call, write it down under *Decisions made here* with the reason, and list anything that is genuinely the owner's to decide under *Open questions for the owner* with your recommended default. The owner will be asked once, at the end, about what is left.
- **Do not change the repo.** Write exactly one file per stage, at the path given in your task, and nothing else. No code, no commits.
- Stay inside the master plan's decisions. If you find the master plan is wrong or incomplete for your stage, say so under *Corrections to the master plan*; don't silently diverge.
- Follow the repo's conventions (one feature per PR against `dev`; fixtures first for protocol changes; Core portable with no Windows APIs and tested with fakes; vendored binaries built by script; docs and changelog in the same PR; comment and wording style).
- Plain, specific writing. No filler. An engineer who has not read the conversation must be able to build from your file.

## Facts measured on the owner's PC (Windows 11 Pro, build 26300, local administrator account, desktop, .NET 10 SDK in the user profile, no Rust toolchain)

- Remote Desktop was **already on and open** before Passthrough (both "Remote Desktop - User Mode" rules enabled on every profile, by the owner's choice; a Terminal Services policy key is present). The master plan's "refuse when open to the network" must tell this apart from a Remote Desktop that Passthrough itself turned on.
- The connection-owner check works unprivileged (TCP table row + `QueryServiceStatusEx(TermService)`; the service shares its process).
- Remote Desktop answers on loopback and selects CredSSP. Its certificate is in `LocalMachine\Remote Desktop`, readable by anyone, lifetime 183 days.
- `ProductName` says "Windows 10 Pro" on Windows 11: use the build number.
- The Hello-only setting reads "on" for a local account that signs in with a password: only meaningful together with the account kind.
- PowerShell 7 is the Store package: the only `pwsh.exe` is the alias in the user-writable `%LOCALAPPDATA%\Microsoft\WindowsApps`.
- WSL lists `docker-desktop` beside Ubuntu.
- BitLocker's state needs an administrator to read.

## The file you write

Use exactly these sections:

```
# Stage N: <name>

## Goal and done-when
## What exists today (verified, with path:line)
## Design
   (types, interfaces with signatures, wire formats byte-for-byte where new, state machines, storage formats,
    threading, error handling, limits and timeouts, exact user-facing strings where the master plan gives them)
## Pull requests, in order
   For each: title in the repo's style; scope; files added/changed; tests added; docs changed;
   how to verify by hand; what it deliberately leaves out. Each must leave `dev` working.
## Interfaces
   ### This stage defines (others depend on these): name, shape, owner
   ### This stage consumes (from which stage)
## Tests
   (automated, by suite; fixtures added; real-hardware checklist items)
## Security considerations for this stage
## UX states and strings for this stage
## Risks and how each is retired
## Decisions made here
## Corrections to the master plan
## Open questions for the owner (each with a recommended default)
```

Be complete enough to execute, but do not pad: cite the master plan for wording it already gives instead of repeating whole tables.
