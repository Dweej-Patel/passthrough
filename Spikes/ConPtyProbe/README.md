# ConPTY Probe (throwaway spike, stage 0.7)

Question: do the escape sequences Passthrough depends on (OSC 52 clipboard,
OSC 7501 program status and its query, a DCS string) pass through Windows'
pseudoconsole unchanged and **in order relative to the text around them**,
with the inbox ConPTY and with Microsoft's bundled one
(`Microsoft.Windows.Console.ConPTY`)? Does Claude Code's status work? Does a
kill-on-close job end what a shell started?

```
dotnet build Spikes/ConPtyProbe -c Release
ConPtyProbe host inbox|bundled                         the test child, with a report
ConPtyProbe host <mode> -- <full path> [args...]       any program (--send, --kill-after, --dir: see Program.cs)
ConPtyProbe report|show runs/out-<name>.bin            read a recording again
```

The host makes the pseudoconsole (`CreatePseudoConsole`, or
`ConptyCreatePseudoConsole` from the package's `conpty.dll`), starts the
program in a kill-on-close job with the environment from
`CreateEnvironmentBlock` plus `TERM_PROGRAM=Passthrough`, records every
output byte to `runs/`, answers what a terminal would (the Mac's 7501 support
answer, device attributes, cursor position), resizes once mid-output, and
watches the job's process list. `emit` (and `emit.sh` for a Unix shell)
writes each sequence between two markers, asks for program status the way
Claude Code does, prints what came back, then 200 numbered lines with a
status report between lines 100 and 101.

It is self-contained (.NET 10 is installed only in the user profile here, and
the child gets a clean environment) and changes nothing on the PC.

## Answers (Windows 11 Pro build 26300, inbox conhost 10.0.26100.1, package 1.25.261109001)

| | inbox | bundled |
|---|---|---|
| OSC 52, OSC 7501 report, OSC 7501 query | intact but **moved**: sent ahead of the text written before them | intact, in place |
| DCS string | **dropped** | intact, in place |
| Our 7501 answer reaches the program | **no**: the input side drops it | yes, before the device attributes answer |
| Device attributes request | answered by the pseudoconsole itself; never reaches the host | passed to the host, which must answer |
| 200 lines across a resize, report between 100 and 101 | all present, in order, report in place | same |
| Through PowerShell (typed at its prompt) | as above | as above |
| Through Git Bash | as above (OSC 52 happened to stay in place) | as above |
| vim: alternate screen in and out, typing | works | works |
| Claude Code 2.1.330 status | it asks, never hears back, **reports nothing** | asks, gets the answer, reports `blocked` (permission, "trust this folder"), `clear`, then `idle` |
| Closing the job | ends the shell and what it started (`ping`) | same |

**Pass**, with the bundled package. Inbox fails OSC 7501 outright on this
build, so on every PC:

* **Bundle the package, always.** No fallback to the inbox pseudoconsole:
  with it, program status never works and the replay order is wrong.
* `conpty.dll` and `x64\OpenConsole.exe` are signed by Microsoft Corporation,
  chain to Microsoft Root Certificate Authority 2011, version
  1.25.261109001, 119,608 and 1,089,336 bytes; SHA-256
  `e971856f89748dc3b458125e9afdd79b5e9574a7c937676116d3cbbd3b71f492` and
  `b17e48b07ef153b420f0a6e178bacd31fb4c3390e21ae746586213fc0719a775`.
  `OpenConsole.exe` must sit in an `x64` folder beside `conpty.dll`. The
  package's props run before a project sets `PlatformTarget`, so the project
  must set `ConptyRequiresx64Host` itself or `OpenConsole.exe` isn't copied.

## What stage 3 has to do because of this

* **The pseudoconsole talks first.** At start the bundled one sends
  `ESC[1t ESC[c ESC[?1004h ESC[?9001h`, and both send `?9001h`
  (win32-input-mode) and `?1004h` (focus reports), with `?1004l ?9001l` at
  close. The session manager answers that first `ESC[c` itself (left
  unanswered, nothing stalls), never asks a phone to, and keeps these
  modes out of what phones and recordings see. Phones send VT keys; nothing
  may switch them to win32-input-mode.
* **Device attributes and cursor position requests from programs reach the
  host** with the bundled ConPTY, as they would on a Mac PTY: the session's
  attached terminal answers them (as today), and the 7501 support answer is
  written before them, as the Mac does.
* **Accept the 7501 query ending in BEL as well as ST.** Claude Code sends
  `ESC]7501;?BEL` followed by `ESC[c`, plus `ESC[>0q` (XTVERSION) and
  `ESC[?u` (kitty keyboard), all of which pass through.
* **Kill-on-close jobs work** for a shell and the processes it starts
  directly; the plan's caveat for programs started through brokers stands.

## Not answered here

* **WSL.** WSL2 can't start on this PC: the Virtual Machine Platform
  component isn't enabled (`HCS_E_HYPERV_NOT_INSTALLED`), which takes an
  administrator and a reboot, so it was not changed. Ubuntu is still listed
  in the registry. Run `host bundled --name wsl -- C:\Windows\System32\wsl.exe -d Ubuntu --cd <this folder> -- bash emit.sh`
  on a PC where WSL works. Also for stage 3: the shell chooser can list a
  distro that can't start; opening it shows WSL's own error.
* Claude Code was only started to its prompt; a long session, and a resize
  during its full-screen redraw, were not tried.
