# Stage 8: The PC as viewer

Three tracks that ship separately: (a) the shell client, `passthrough-term.exe`, Hello-kept credentials and *Your computers*; (b) the Mac's screen in a window; (c) sound and microphone. Track (b) needs (a)'s first three PRs; (c) needs (b).

## Goal and done-when

The Windows app opens another computer's shell in a terminal tab and a Mac's screen in a window, with access it was handed by a phone or by direct pairing, kept behind Windows Hello.

**Track (a) is done when**, on a real PC with a real Mac:
- A `computerPass` handed over by an iPhone, and one made by direct pairing, each put the Mac under *Your computers* in the flyout; with the PC unattended the phone's hand-over waits as a notice and becomes usable after one Windows Hello confirmation.
- **New shell** opens a new tab in the current Windows Terminal window titled "*MacBook* · zsh"; without Windows Terminal it opens a console window. vim, Claude Code, mouse reporting, resize, Ctrl+C and non-ASCII typing work in it.
- Closing the tab leaves the session running; it is listed in the flyout with **Open** and **End**; **Open** shows it again with its scrollback.
- It connects on the same network (Bonjour, then addresses), over Tailscale, and from another network over iroh direct and through a relay; pulling the network gives "Reconnecting…" in the tab and the session comes back by itself.
- With the remote a PC, **New shell ▾** lists what that PC reports and remembers the last choice.
- Nothing usable is on disk without Hello: copying `%LOCALAPPDATA%\Passthrough` to another account or PC yields no credential; the log holds no key, token or one-time token.

**Track (b) is done when**: **Screen** asks Windows Hello, opens a window showing the Mac at 60 frames a second with hardware decode (measured GPU decode use, not CPU), pointer, scroll, keys with the mapping below, IME text, Send clipboard and Copy from Mac all work; the subtitle says "Keys go to *MacBook*"; full screen works; a dropped connection dims the last picture and comes back by itself; 30 minutes of use shows no growth in memory or GPU memory; a malformed stream (fuzzed `format` and `frame`) closes the view without a crash.

**Track (c) is done when**: the Mac's sound plays on the PC within about 150 ms and stays in step after a 2 s stall; the PC's microphone is heard on the Mac's "Passthrough Microphone" device; both stop with the window; with Windows' microphone privacy setting off the toggle says why, with the fix.

## What exists today (verified, with path:line)

Windows side:
- Projects are `Passthrough.Core` (net10.0, no Windows APIs), `Passthrough.App` (WinUI 3, unpackaged, x64) and the xUnit tests (`windows/README.md:8-12`). No `Passthrough.Windows`, `Passthrough.Service`, `Passthrough.Term` or iroh bridge yet: those come from stages 3 and 4 (master plan §2 "Projects").
- App lifecycle: one instance per session through `Local\Passthrough.App` (`windows/src/Passthrough.App/App.xaml.cs:58`); `DispatcherShutdownMode.OnExplicitShutdown`, so closing a window never ends the process (`App.xaml.cs:36`); windows are made on demand, kept in a field, nulled on `Closed` and brought forward (`App.xaml.cs:149-158`); `ShutDownAsync` closes each window inside `Try` (`App.xaml.cs:174-202`).
- Window conventions: `SettingsWindow` sets the icon, Mica, `ExtendsContentIntoTitleBar`, sizes itself in DIPs times the monitor scale (`SettingsWindow.xaml.cs:26-33`), and `BringToFront()` calls `Activate()` then `NativeMethods.BringToFront` (`SettingsWindow.xaml.cs:171-175`; the input-queue join is at `Platform/NativeMethods.cs:34-44`). The flyout hides on close and deactivation (`FlyoutWindow.xaml.cs:54-72`) and lists rows through an `ItemsControl` named `Body` (`FlyoutWindow.xaml:45`).
- The manifest is PerMonitorV2 (`app.manifest:12`); minimum Windows 10 1809 (`Passthrough.App.csproj:5`).
- Secrets today: one DPAPI current-user file per slot in a folder limited to the user (`Storage/DpapiSecretStore.cs:13-105`, interface `Core/Storage/ISecretStore.cs:4-16`). Nothing Hello-bound exists.
- `LogText.Redact` knows only 43-character tokens (`Core/Logging/LogText.cs:8-15`); the master plan has stage 3 extend it before anything new logs.
- Core has streams as `System.IO.Stream` behind `StreamConnector` (`Core/Transport/StreamConnector.cs:4`, `ByteStreamConnector.cs:5-21`), line framing in `LineChannel` (`Core/Control/LineChannel.cs:9-60`), and tests with `FakeTimeProvider`, `GatedStream`, `MemoryFileSystem` (`windows/tests/Passthrough.Core.Tests/Fakes/`).
- CI has no Windows job (`.github/workflows/ci.yml`: macOS and Ubuntu jobs only); stage 1(a) adds it.

What is ported (Swift, all under `Packages/PassthroughCore/Sources`):
- `PassthroughCore/ShellClient.swift`: `ShellCredential` with redacted description (`:6-48`); `ShellConnectMode`, `ShellPath` (`:51-68`); `ShellIrohDialing` (`:72-83`); events (`:98-149`); `Liveness` 5/15/2 s (`:166-174`); attempt timeouts 4 s and 10 s for iroh, stagger 0.25 s, iroh delay 0.75 s (`:177-186`); `schedule` (`:275-285`); dialing, first-authorized-wins and dropping losers (`:485-615`); heartbeat and the path-failed probe (`:619-656`); challenge → proof → ready, and an `error` before ready ending every path (`:666-698`); `open` numbering with `ref`, overtaking by `attach`, `openedDetached` (`:310-342`, `:715-729`, `:827-847`); input split at 16384 bytes and dropped while an open is pending (`:347-361`); the screen hand-over, which reads lines only up to `screenReady`/`screenVideoReady` and returns the bytes after it (`:563-587`, `:791-808`). There is no reconnect in it: `finish` reports `disconnected` once (`:821-825`).
- `PassthroughCore/ShellCredentials.swift`: manual address first then granted, no repeats (`:26-30`); the Bonjour result by service name (`:36-42`).
- Helpers: `ShellEndedSessions.swift` (65 lines), `UTF8Repair.swift` (66), `TerminalPaste.swift` (47), `ShellReplay.swift` (`isValid` at `:18-20`, used by the client at `ShellClient.swift:753`).
- Pinned TLS: TLS 1.3 minimum, leaf SHA-256 compared to the pin, no-delay, keep-alive 10 s (`PassthroughCore/WirelessLink.swift:34-50`).
- `PassthroughCore/LocalTerminalWire.swift`: frames of kind u8, length u32 big-endian, payload at most 1 MiB (`:7-14`); kinds 1–4 and 16–21 (`:16-22`); `Hello` (`:44-68`); unknown kinds skipped (`:132-153`). `ShellHost/LocalTerminalAccess.swift`: a 32-byte random token as hex, good once for 60 s for one session (`:34`, `:73-84`); a second use reports `onContested` (`:136-141`). The Mac passes the token in a `.command` file it opens (`macOS/App/Shell/RemoteShellController.swift:697-721`). `passthrough-term/main.swift:89-106` is the attach mode and its closing lines; `LocalTerminalClient.swift:59` drops keys for 0.3 s after a replay and `:71-74` is the mode-restoring sequence.
- `PassthroughCore/ScreenVideoWire.swift`: limits (`:13-29`), messages (`:34-106`), kinds (`:223-228`), encode (`:232-337`), `textPieces` (`:342-360`), per-sender payload limits (`:363-374`), `Reader` (`:378-402`), decode (`:404-515`).
- `ScreenClient/ScreenVideoClient.swift`: hello first and on `relayout` (`:115-138`); frames before a format or before the awaited keyframe are acked, not shown (`:283-290`); `copied` taken only as an answer (`:85-87`, `:291-294`); cursor PNG checked for type and at most 1024 px a side before decoding (`:19`, `:311-321`); parameter-set counts 2 or 3, none empty (`:330-332`); empty frame is malformed (`:356`); voice backlog of half a second (`:214-233`); HEVC offered only with hardware decode (`:93-95`).
- `macOS/App/Views/RemoteScreenWindow.swift`: the per-window Touch ID gate (`:21-23`, `:100-113`); browse for 0.8 s then dial (`:153`, `:166-194`); `requestScreen(video: true)` on ready (`:231-233`); layout fit `mac`, side = largest screen's pixels clamped 1280–4096, 60 fps, 15 when hidden, sharp (`:295-308`); `shown` after each frame and a keyframe request when the display failed (`:262-264`); copy result to the clipboard or a beep (`:271-278`); `movedAway` and `closed` messages (`:279-282`); refusal wording (`:310-321`); pointer leads the echo, remote position otherwise (`:495-523`); off-picture moves ignored unless dragging (`:553-556`); wheel lines ×10 and view-to-stream scaling (`:588-598`); special keys, shortcuts as the unmodified key, everything else through text input (`:627-644`); the IME candidate window at the pointer (`:706-710`); key table (`:716-736`). It does not use sound, microphone, curtain, viewers or Use Here.
- Sound: one AAC-LC packet of 1024 frames at 48 kHz stereo a message, nothing around it (`PassthroughCore/MacSound.swift:5-12`); a packet over 16 KiB is not one (`:89`). The jitter buffer is `PassthroughCore/VoiceBuffer.swift:11-69`; the phone uses 80 ms / 400 ms for sound (`iOS/App/Screen/MacSoundPlayer.swift:46-47`; `protocol/README.md:638-644`). Voice is 16-bit little-endian mono at 16 kHz, at most 8 KiB a message (`ScreenVideoWire.swift:26-29`; `protocol/README.md:740-747`).
- The Mac encodes H.264 Constrained High or HEVC Main, no frame reordering, BT.709 primaries, transfer and matrix (`ScreenHost/VideoEncoder.swift:49-59`), from video-range 4:2:0 capture (`ScreenHost/ScreenCapturer.swift:115-116`).
- `protocol/fixtures.json` has the `shell` section and `screenVideo`/`screenVideoReady` lines (`:272`, `:391-394`) but no binary screen-video messages; the Swift cases live in `Tests/ScreenClientTests/ScreenClientTests.swift`.

## Design

### Where things live

| Project | Added in this stage |
|---|---|
| `Passthrough.Core` | `Client/` (shell client, credentials, helpers, `ComputerLink`, `TermWire`, `TermAccess`, `TerminalLaunch`), `Screen/` (`ScreenVideoWire`, `ScreenVideoClient`, `AnnexB`, `H264Sps`, `HevcSps`, `ScreenKeys`, `ScrollScale`, `PinchFromWheel`, `JitterBuffer`), `Trust/ComputerVault` (the sealed-box format; crypto through an interface) |
| `Passthrough.Windows` (from stage 3) | `Client/DnsSdBrowser`, `Client/IrohShellDialer` (over the bridge), `Client/NetworkPathWatcher`, `Hello/HelloKey`, `Pipes/TermPipeServer` |
| `Passthrough.Media` (**new**, net10.0-windows, referenced by the app only) | D3D11 device, Media Foundation decoders, the presenter, WASAPI render and capture. Interop generated at build time by `Microsoft.Windows.CsWin32` (no runtime dependency) |
| `Passthrough.Term` (from the master plan) | `passthrough-term.exe`: console setup and the pipe client |
| `Passthrough.App` | `ScreenWindow`, *Your computers* rows, *Other computers* in Settings, the keyboard hook |

The viewer role runs wholly in the tray app (master plan §2 diagram: "viewer windows"). It makes outbound connections only; the service is not involved except to pass a phone's `computerPass` up through `ISessionHost.SavePassAsync`.

### (a1) Shell client in Core

```csharp
namespace Passthrough.Core.Client;

public sealed record ShellCredential(
    string HostId, string HostName, string CertSha256, byte[] ShellKey, string ClientId,
    int Port, IReadOnlyList<string> Addresses,
    string? IrohId = null, string? IrohRelay = null, string? RelayToken = null,
    string? HostKind = null)            // "mac" | "windows", from stage 1(b)
{ public override string ToString(); }  // never prints ShellKey; RelayToken as "<redacted>" (ShellClient.swift:32-39)

public enum ShellConnectMode { Automatic, LocalOnly }
public enum ShellPath { Local, Direct, Relay, Unknown }

public readonly record struct ShellEndpoint(string Host, int Port);

public abstract record DialCandidate
{ public sealed record Tcp(ShellEndpoint Endpoint) : DialCandidate; public sealed record Iroh : DialCandidate; }

/// One TLS 1.3 connection that accepts exactly the certificate whose SHA-256 is the pin.
public interface IPinnedTlsDialer
{ Task<IShellStream> ConnectAsync(ShellEndpoint endpoint, string certSha256, CancellationToken ct); }

public interface IShellIrohDialer
{
    Task<IShellStream> ConnectAsync(string irohId, string? relayUrl, string? relayToken, CancellationToken ct);
    ShellPath PathOf(IShellStream stream);
    void Shutdown();                    // ends dials in progress and every stream it made
}

/// A duplex stream plus the one thing Stream lacks: word that its path went away.
public interface IShellStream : IAsyncDisposable
{
    Stream Stream { get; }
    IPAddress? LocalAddress { get; }    // null over iroh
}

public interface INetworkPathWatcher { event Action? AddressesChanged; IReadOnlySet<IPAddress> Current(); }

/// Signs the host's nonce with this computer's identity key (computer. ids; stage 1(c)/7).
public interface IComputerProof { string? Sign(ReadOnlySpan<byte> nonce); }   // null for a plain key

public sealed class ShellClient : IAsyncDisposable
{
    public static readonly TimeSpan AttemptTimeout = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan IrohAttemptTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan Stagger = TimeSpan.FromMilliseconds(250);
    public static readonly TimeSpan IrohDelay = TimeSpan.FromMilliseconds(750);

    public sealed record Liveness(TimeSpan Interval, TimeSpan Silence, TimeSpan Probe)
    { public static Liveness Default => new(TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(2)); }

    public ShellClient(ShellCredential credential, IPinnedTlsDialer tls, IShellIrohDialer? iroh,
        INetworkPathWatcher paths, IComputerProof? proof, TimeProvider time,
        Action<ShellClientEvent> onEvent, ShellConnectMode mode = ShellConnectMode.Automatic, Liveness? liveness = null);

    public static IReadOnlyList<ShellEndpoint> Candidates(ShellCredential c, IReadOnlyList<ShellEndpoint> discovered);
    public static IReadOnlyList<(DialCandidate Candidate, TimeSpan Delay)> Schedule(
        ShellCredential c, IReadOnlyList<ShellEndpoint> discovered, ShellConnectMode mode);

    public void Connect(IReadOnlyList<ShellEndpoint>? discovered = null);
    public void Disconnect();
    public void List();
    public void Open(int cols, int rows, string? shell = null);   // `shell`: the chooser id (stage 1(b))
    public bool OpenPending { get; }
    public void Attach(string session, int cols, int rows);
    public void Input(ReadOnlyMemory<byte> data);
    public void Resize(int cols, int rows);
    public void Close(string session);
    public void SetViewing(bool on);
    public void RequestScreen(bool video);
}

public abstract record ShellClientEvent
{
    public sealed record Ready(ShellPath Path) : ShellClientEvent;
    public sealed record HostInfo(ShellEnvelope Message) : ShellClientEvent;     // macInfo
    public sealed record Host(HostDescription Value) : ShellClientEvent;         // stage 1(b)'s `host`
    public sealed record State(MacState Value) : ShellClientEvent;
    public sealed record Sessions(IReadOnlyList<ShellSessionInfo> List) : ShellClientEvent;
    public sealed record Opened(string Session) : ShellClientEvent;
    public sealed record OpenedDetached(string Session) : ShellClientEvent;
    public sealed record OpenFailed(ShellError Reason) : ShellClientEvent;
    public sealed record Output(string Session, ReadOnlyMemory<byte> Data) : ShellClientEvent;
    public sealed record Replaying(string Session) : ShellClientEvent;
    public sealed record Attached(string Session) : ShellClientEvent;
    public sealed record Ended(string Session, int ExitStatus) : ShellClientEvent;
    public sealed record Detached(string Session) : ShellClientEvent;
    public sealed record Failed(ShellError Reason, string? Session) : ShellClientEvent;
    public sealed record GoingAway(string Reason) : ShellClientEvent;            // stage 1(b)
    public sealed record Disconnected(Exception? Error) : ShellClientEvent;      // once per Connect
    public sealed record Screen(IShellStream Stream, ReadOnlyMemory<byte> InitialBytes) : ShellClientEvent;
}
```

Behaviour is the Swift client's, line for line, with these mappings:

- **Schedule**: discovered endpoints first, then each granted address at the credential's port, 0.25 s apart; iroh at 0.75 s after the first (at once when there are none), only in `Automatic` and when the id is valid; sorted, TLS first on a tie (`ShellClient.swift:264-285`). A failed attempt starts the next at once (`:592-602`). Per-attempt timeout 4 s, iroh 10 s. The first to read `ready` after a challenge wins and every other attempt is disposed; an iroh loser also shuts the dialer down (`:659-664`). An `error` line before `ready` ends every path with that reason (`:687-693`).
- **Handshake**: on TLS the host speaks first; on iroh the client writes `{"t":"hello"}` first (`:542-548`). The nonce must be 32 bytes. Proof is HMAC-SHA256(key, "passthrough-shell-v1" ‖ nonce) (`ShellProtocol.swift:31-33`); for a `computer.` id the envelope also carries `IComputerProof.Sign(nonce)` in the field stage 1(c) names.
- **Threading**: one serial loop per client (a `Channel<Action>` drained by one task; the Swift `work` queue). All state lives on it. Events are posted, in order, to the `SynchronizationContext` captured at construction (the UI thread in the app, an inline context in tests). The `open` bookkeeping keeps its own lock and is judged when the event is *delivered*, exactly as `ShellClient.swift:715-729` does, so an `Attach` the app made before `opened` reached it still overtakes.
- **Reading**: `LineBuffer` with the 262144-byte limit; a longer line is a protocol violation and ends that attempt. After `RequestScreen`, lines are read only up to `screenReady`/`screenVideoReady` and the remainder is handed over in `Screen` (`:791-808`); the client then sends and reports nothing more.
- **Liveness**: `TimeProvider` timers. Ping after 5 s of silence, give up at 15 s with `StoppedAnsweringException`. The path probe: when `INetworkPathWatcher.AddressesChanged` fires and the winner's `LocalAddress` is no longer in `Current()`, send one ping and give up after 2 s unless anything arrives (`:646-656`). Over iroh there is no local address and only the 5/15 s rule applies.
- **No reconnect inside**: `Disconnected` is final for that `Connect`. Redialling is `ComputerLink`'s job (below).
- **Not ported** (a computer may not ask for them, master plan "Computers"): `setAwake`, `setVPN`, `push`, `events`, `lock`, `screenGrant`, `screenPass`, `screenRevoke`, history and transcripts. The envelope still decodes them; the client has no method.

`ShellCredentials` ports `addresses(granted:manual:)` and `discovered(among:macName:shellMacCount:)`; the PC always calls the latter with count 0 (by name only, never its own listener, as `RemoteScreenWindow.swift:171-172`).

Helpers, each a direct port with the Swift tests' cases: `ShellEndedSessions`, `Utf8Repair` (struct with `Repair(ReadOnlySpan<byte>, IBufferWriter<byte>)` and `Reset()`), `TerminalPaste`. `ShellReplay` comes from stage 3.

### (a2) Dialing on Windows

- **`PinnedTlsDialer`** (Core; `SslStream` is not a Windows API): `SslClientAuthenticationOptions { EnabledSslProtocols = Tls13, RemoteCertificateValidationCallback = leaf SHA-256 hex == pin, CertificateRevocationCheckMode = NoCheck, TargetHost = "passthrough" }`; socket `NoDelay`, keep-alive idle 10 s. Schannel has TLS 1.3 from Windows 11 only: on Windows 10 the dialer throws `PlatformNotSupportedException` once, the schedule is built without TCP candidates, and the row says "Local connections need Windows 11. Using the built-in connection." (the master plan's known limit).
- **`DnsSdBrowser`** (`Passthrough.Windows`, extending stage 4's DNS-SD wrapper): `DnsServiceBrowse` for `_passthrough-sh._tcp.local`, then `DnsServiceResolve` for the instance whose name equals `HostName`; result: up to 4 addresses and the SRV port, as `ShellEndpoint`s. `Task<IReadOnlyList<ShellEndpoint>> FindAsync(string instanceName, TimeSpan limit, CancellationToken)`; the limit is 0.8 s (`RemoteScreenWindow.swift:153`), returning early on the first resolve. An address outside `ShellAddressPolicy`'s ranges is dropped. The pin still decides: a forged answer gets a failed handshake and nothing else.
- **`IrohShellDialer`** over stage 3's bridge: each `ConnectAsync` binds a fresh endpoint with an ephemeral key and the host's relay (URL and token from the credential, default relays when none), dials ALPN `passthrough/shell/1`, opens one bidirectional stream; `Shutdown` closes every endpoint it bound and bumps an epoch so a late bind closes itself (`IrohShellDialer.swift:8-38`). `PathOf` asks the bridge for the connection type.
- **`NetworkPathWatcher`**: `NetworkChange.NetworkAddressChanged` plus a snapshot of unicast addresses.

### (a3) `ComputerLink`: one computer, kept connected while it is wanted

```csharp
public sealed class ComputerLink : IAsyncDisposable
{
    public enum Phase { Locked, Idle, Connecting, Connected, Reconnecting, Unreachable, Refused }
    public sealed record Snapshot(Phase Phase, ShellPath? Path, HostDescription? Host,
        IReadOnlyList<ShellSessionInfo> Sessions, ShellError? Refusal, DateTimeOffset? LastHeard);
    public event Action<Snapshot>? Changed;
    public void Want(object holder);      // the open flyout, a terminal bridge
    public void Release(object holder);   // disconnects 60 s after the last holder goes
    public Task<ShellClient> NewClientAsync(Action<ShellClientEvent> onEvent, CancellationToken ct);  // a tab's or the screen's own connection
}
```

The link holds one status connection (for `host`, `sessions`, state) while anything wants it. Redial delays after a loss: 0, 1, 2, 4, 8, 15, then 30 s, reset by `ready`; an `AddressesChanged` event redials at once. `not_authorized` or a stored-credential mismatch stops for good (`Refused`). `macInfo` updates the stored addresses and iroh details under the rules of `protocol/README.md:453` (never the key or pin); the update is sealed without a prompt (below). Each terminal tab and each screen window gets a connection of its own from `NewClientAsync` ("A phone uses its own connection for the screen", `protocol/README.md:559-560`; a connection attaches to one session, `:383`).

### (a4) Credentials behind Windows Hello

**API: `Windows.Security.Credentials.KeyCredentialManager`**, not the Passport key storage provider through NCrypt. Reasons: it is the documented, supported surface for an unpackaged desktop app; it works with a PIN alone; `IsSupportedAsync` answers "is Hello set up" without the account-kind confusion measured on the owner's PC (BRIEF: the Hello-only setting reads on for a password account). The NCrypt provider would give a direct decrypt, but its name, key naming and prompt behaviour are not documented for third parties.

`KeyCredential` can only sign, so the wrap is built on a signature:

- Hello key: `KeyCredentialManager.RequestCreateAsync("Passthrough.Computers.v1", KeyCredentialCreationOption.FailIfExists)` (RSA-2048, held by Hello; one prompt). Signing is RSASSA-PKCS1-v1_5 with SHA-256, which is deterministic: the same challenge always gives the same signature.
- `unlockKey` = HKDF-SHA256(ikm = signature over `challenge`, salt = `salt`, info = "passthrough-computers-unlock-v1"), 32 bytes. `challenge` and `salt` are 32 random bytes each, made once and stored in the clear.
- A **sealing key pair** (P-256, made in software once): its public half is stored in the clear; its private half (PKCS#8) is stored as AES-256-GCM(`unlockKey`).
- Each computer's record is sealed **to the public half** with no prompt: ephemeral P-256 ECDH, HKDF-SHA256(shared secret, salt = ephemeral public ‖ recipient public, info = "passthrough-computer-seal-v1"), AES-256-GCM, associated data = the record's file name. Opening needs the private half, so needs Hello.

So writing (a hand-over arriving, `macInfo` refreshing addresses) never prompts, and reading always went through Hello at least once since the PC was last locked.

Files, under `%LOCALAPPDATA%\Passthrough\computers\` (folder ACL as `DpapiSecretStore.EnsureFolder`, `DpapiSecretStore.cs:93-104`):

```
vault.json        {"v":1,"keyName":"Passthrough.Computers.v1","challenge":b64,"salt":b64,
                   "sealPublic":b64 (SEC1 uncompressed, 65 bytes),"sealPrivate":{"nonce":b64(12),"box":b64}}
<sha256(hostId) hex, first 32>.json
                  {"v":1,"hostId":…,"name":…,"kind":"mac"|"windows","scopes":["shell","screen"],
                   "from":"iPhone"|"paired here","fromPhoneId":…?,"receivedAt":unix,
                   "lastShell":…?,"ctrlIsCommand":false,
                   "sealed":{"epk":b64(65),"nonce":b64(12),"box":b64}}
pending\<random>.bin   DPAPI(current user) of a pass that arrived before the vault existed
```

`sealed.box` is the UTF-8 JSON of `ShellCredential` (key, pin, addresses, iroh details, relay token). Name, kind and scopes are in the clear so the flyout can list computers while locked. Whole-file writes go to a `.tmp` and are moved over, as the DPAPI store does.

```csharp
public interface IHelloKey   // Passthrough.Windows; a fake in Core tests
{
    Task<HelloAvailability> AvailabilityAsync();            // Ready | NotSetUp | NotHere (Remote Desktop session) | Unsupported
    Task<HelloResult> CreateAsync(string name, IntPtr window);
    Task<HelloSignature> SignAsync(string name, ReadOnlyMemory<byte> challenge, IntPtr window, string reason);
    Task DeleteAsync(string name);
    Task<bool> ConfirmPresenceAsync(IntPtr window, string reason);   // UserConsentVerifier, no key use
}

public sealed class ComputerVault   // Core/Trust
{
    public IReadOnlyList<ComputerEntry> Entries { get; }               // clear-text fields only
    public bool IsUnlocked { get; }
    public event Action? Changed;
    public Task<VaultResult> UnlockAsync(IntPtr window, string reason, CancellationToken ct);   // one Hello prompt
    public void Lock();                                                // wipes the private half and every opened credential
    public ShellCredential? Open(string hostId);                       // null while locked
    public SaveResult Save(ReceivedComputerPass pass);                 // no prompt; Pending when there is no vault yet
    public Task<VaultResult> ConfirmPendingAsync(IntPtr window, CancellationToken ct);   // creates the vault if needed; one prompt
    public void UpdateReach(string hostId, HostInfoUpdate update);     // macInfo; re-seals, no prompt (needs IsUnlocked to read the old record)
    public void Remove(string hostId);
}
```

**What is prompted, and when** (each prompt is parented to the asking window through `IKeyCredentialManagerInterop` / `IUserConsentVerifierInterop`, after `BringToFront`, or it opens behind):

| Moment | Prompt |
|---|---|
| First computer kept on this PC (direct pairing finishing, or confirming a pending hand-over) | One: creating the Hello key. "Passthrough wants to keep access to *MacBook* on this PC." |
| First use after the app started or the PC was locked: **Connect**, **New shell**, **Open**, **Screen** | One: the signature that unlocks the vault. "Passthrough wants to connect to *MacBook*." |
| Every screen window, on opening and again after the PC was locked while it was open | One. If that prompt was the unlock, it is not asked twice; otherwise `ConfirmPresenceAsync` ("Passthrough wants to show *MacBook*'s screen."). |
| Further shells and session actions while unlocked | None. |
| A hand-over arriving while the vault exists | None (sealed to the public half). A notice that stays says what arrived. |

The vault locks itself on `WTS_SESSION_LOCK`, on session disconnect, on sign-out and on quit; status connections and screen windows close with it; terminal tabs already open keep their connection (the tab's bridge keeps the one credential it was given until the tab closes).

**No Hello set up** (`AvailabilityAsync` ≠ `Ready`): this PC can't hold access to other computers (master plan "Secrets"). *Add a computer* and a phone's hand-over both stop: the hand-over is answered `pass_not_saved`, and Settings ▸ Remote access ▸ *Other computers* shows the row "Set up a Windows Hello PIN to keep access to other computers on this PC." **Open sign-in options** (`ms-settings:signinoptions`). Inside a Remote Desktop session Hello can't be asked: "Windows Hello isn't available in a Remote Desktop session. Use this PC's own screen and keyboard to open another computer."

**Hello reset** (PIN removed or reset: the key is gone, `SignAsync` reports not found): the sealed records can no longer be opened. They are deleted and a notice stays: "Windows Hello was reset on this PC, so its access to other computers is gone. Add them again."

**Receiving a pass.** Both sources call `ComputerVault.Save`:
- *From a phone* (stage 7(a)): the phone's `computerPass` arrives on a connection the service holds; the service checks the phone's "May share access with other computers" switch and calls `ISessionHost.SavePassAsync`, which reaches the tray app. Not signed in or app not running: `pass_not_saved`.
- *From direct pairing* (stage 7(b)): the pairing sheet's result, with the user present.

Rules in `Save`: the credential must be usable (`ShellCredential` validation as `shellGrant`'s); the id must start `computer.`; a record for the same `hostId` is replaced only when certificate pin and iroh id both match the stored record's clear-text copies (kept beside the sealed box for this check, pin as its hash), otherwise it is refused and a notice says "*iPhone* shared *MacBook* again, but it isn't the MacBook this PC knows. Remove it under Other computers first if you reset that Mac."; with no vault yet the pass is written to `pending\` under DPAPI (at most 4, each dropped after 7 days) and the notice reads "*iPhone* shared *MacBook* with this PC. Confirm with Windows Hello to keep it." **Keep** · **Discard**. Revoking the phone that handed a pass over forgets it (`fromPhoneId`, as `ScreenPassStore.swift:11-13`).

### (a5) `passthrough-term.exe` and its pipe

The tool is a thin bridge: console ⇄ pipe ⇄ the tray app's `ShellClient`. It never sees a credential or an address. The tray app starts it; nobody types its arguments:

```
passthrough-term.exe remote --pipe <name> --token <64 hex>
```

**Pipe.** Name `passthrough-term-<user SID>-<session id>`, served by the tray app (`TermPipeServer`): byte mode, `PipeOptions.CurrentUserOnly | FirstPipeInstance | Asynchronous`, an explicit ACL of the current user only with a deny entry for the NETWORK SID (no remote clients), at most 16 connections. The client connects with `CurrentUserOnly` (which checks the pipe's owner is this user, so a squatter gets nothing) at identification level. The server reads the client's process id (`GetNamedPipeClientProcessId`), requires the same session and, as a best-effort check, that its image is the `passthrough-term.exe` beside the app. A `hello` must arrive within 5 s and fit 4096 bytes.

**Wire** (`TermWire`, the framing and kind numbers of `LocalTerminalWire` so stage 9's terminals-on-the-PC reuses the pipe): kind u8, length u32 big-endian, payload ≤ 1 MiB; unknown kinds skipped.

| Kind | Dir | Payload |
|---|---|---|
| 1 `hello` | term → app | JSON `{"v":1,"mode":"remote","token":"<64 hex>","cols":N,"rows":N}` |
| 2 `input` | term → app | raw bytes |
| 3 `resize` | term → app | cols u16, rows u16, big-endian |
| 16 `started` | app → term | JSON `{"session":"<id>","title":"MacBook · zsh"}` |
| 17 `output` | app → term | raw bytes, ≤ 65536 a frame |
| 18 `replayed` | app → term | none: the scrollback of a running session is drawn |
| 19 `ended` | app → term | JSON `{"exitStatus":N}` |
| 20 `refused` | app → term | JSON `{"reason":…}`: `not_allowed`, `no_such_session`, `too_many_sessions`, `signed_out`, `unreachable`, `detached`, `stopped`, `bad_request`, `version` |
| 22 `status` (new) | app → term | JSON `{"state":"reconnecting"|"live"}` |

`mode:"remote"` is the mode the master plan gives the Mac's tool in stage 7(d); the Windows hello names nothing but the token, because everything else is bound to the token in the app.

**Tokens** (`TermAccess` in Core, a port of `LocalTerminalAccess`): 32 random bytes as hex, good once, for 60 s, bound to (host id, session id or "new" with a shell id, title). A token asked with a second time after a window was let in is refused, reported (`Contested`), and the app closes that tab's bridge and shows "Something else tried to open that shell. The tab was closed." The token is on a command line, which any program running as the same user can read: that is code running as you, the limit `LocalTerminalAccess.swift:18-26` already accepts, and the double-use check is the same tripwire.

**The app's side of a tab** (`TermBridge`): takes a client from `ComputerLink.NewClientAsync`; on `Ready` sends `Open(cols, rows, shell)` or `Attach(session, cols, rows)` and `SetViewing(true)`; forwards `Output` for the attached session only, dropping what arrives between its `Attach` and `Replaying` (`protocol/README.md:386-388`); sends `replayed` on `Attached`; on `Ended` sends `ended` and closes; on `Detached` sends `refused detached`. On `Disconnected` it sends `status reconnecting`, redials on `ComputerLink`'s delays for up to 2 minutes, re-attaches the same session, and sends `status live` before the replay; after 2 minutes `refused unreachable`. Output waiting for a slow console is capped at 8 MiB: past it the bridge disconnects from the host and re-attaches once the pipe drains (the scrollback redraws), so a stalled console never holds the host's send queue. The pipe closing (tab closed) disposes the client; the session carries on and stays listed.

**Console setup in the tool** (in this order; every step's old value saved first):

1. Both standard handles must be consoles (`GetConsoleMode` succeeds), else: "passthrough-term needs a terminal." exit 1.
2. Code pages: `SetConsoleCP(65001)`, `SetConsoleOutputCP(65001)`.
3. Output mode: add `ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN`. Input mode: set `ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS`; clear `ENABLE_LINE_INPUT`, `ENABLE_ECHO_INPUT`, `ENABLE_PROCESSED_INPUT`, `ENABLE_QUICK_EDIT_MODE`, `ENABLE_MOUSE_INPUT`. If either VT flag is refused (the legacy console is selected): "This console can't show a remote shell. Turn off 'Use legacy console' in its properties, or install Windows Terminal." exit 1.
4. **Input**: a dedicated thread on `ReadConsoleInputW` (not `ReadFile`, which mangles non-ASCII on older console hosts). `KEY_EVENT` records with `bKeyDown` and a non-zero character are the VT stream, one UTF-16 unit each, honouring `wRepeatCount`; surrogate pairs are joined across records; a key-up of `VK_MENU` with a character is an Alt+numpad result and counts. Encoded to UTF-8 and sent as `input`. `WINDOW_BUFFER_SIZE_EVENT` triggers a size read. Other records are ignored.
5. **Size** is the window, not the buffer: `srWindow` from `GetConsoleScreenBufferInfo` (a console host's buffer is its scrollback). Sent in `hello`, on each size event after a 50 ms debounce, and checked every 500 ms as well, since a console host reports only buffer changes.
6. **Ctrl+C** arrives as byte 0x03 because processed input is off. **Ctrl+Break** still raises a control event: `SetConsoleCtrlHandler` sends 0x03 and returns TRUE. `CTRL_CLOSE_EVENT`, logoff and shutdown: restore, close the pipe, return (the session carries on).
7. **Mouse reporting** needs nothing more: with VT input on and QuickEdit off, the terminal turns the mouse into the sequences the remote program asked for.
8. **Output**: each `output` frame through `Utf8Repair`, then `WriteFile` to the console (a character split across two writes is otherwise drawn as two errors). Keys are dropped for 0.3 s after `replayed`: the terminal is answering questions found in the replay (`LocalTerminalClient.swift:59`).
9. **`status reconnecting`**: writes a dim line "\r\n[Reconnecting to *MacBook*…]". **`status live`**: writes the restore sequence, then `ESC[3J ESC[H ESC[2J`, so the replay that follows draws on a clean screen.
10. **Restore**, on every way out (normal end, `refused`, the control handler, `AppDomain.ProcessExit`, an unhandled exception): write the port of `LocalTerminalClient.restoreTerminal` (`LocalTerminalClient.swift:71-74`), then the saved input mode, output mode and code pages. A killed process can't restore, but then its tab or console window closes with it.

Closing lines, as the Mac tool's (`main.swift:97-103`): "[session ended: N]", "[no longer shown here; the session carries on]"; refusals print one sentence each ("Passthrough isn't running." when the pipe is missing; "This window may not show that shell. Open it from Passthrough." for `not_allowed`; "Sign in to *Office-PC* to use its shell." for `signed_out`; "Couldn't reach *MacBook*." for `unreachable`; "Update Passthrough: this tool and the app don't match." for `version`).

Build: an ordinary framework-dependent console exe referencing Core, copied beside the app (ReadyToRun on publish for start time). Native AOT is left out: it needs the C++ build tools, which the owner's PC does not have.

**Launching it** (`TerminalLaunch` in Core builds the argument list; the app runs it):

- **Windows Terminal**: `wt.exe -w 0 new-tab --title "<title>" --suppressApplicationTitle -- "<full path>\passthrough-term.exe" remote --pipe <name> --token <hex>`. `-w 0` is the current window, or a new one when none is open. `wt.exe` is the app execution alias in `%LOCALAPPDATA%\Microsoft\WindowsApps`; before running it the app reads the alias's reparse data and requires the package family `Microsoft.WindowsTerminal_8wekyb3d8bbwe` (or the Preview family). Arguments go through `ProcessStartInfo.ArgumentList`.
- **Without it** (no alias, wrong target, or `wt` exits non-zero within 2 s): `CreateProcess` of `passthrough-term.exe` with `CREATE_NEW_CONSOLE`, which opens the user's default terminal, the console host on Windows 10; the tool sets the title itself with `SetConsoleTitleW`. The token is revoked if neither starts.
- **Title**: "*MacBook* · zsh" (the shell's `name` from `host.shells`; the name alone when the host reports none). The name comes from the other computer, so `TerminalLaunch.Title` keeps letters, digits, spaces and `.-_'()·` only, drops everything else (`;` splits `wt` commands, quotes end arguments), and cuts at 64 characters. Nothing else from the network reaches a command line.

### (a6) *Your computers* in the flyout

One row per `ComputerVault` entry, above the phones:

- Line one: name. Line two: kind and state: "Mac · Connected · 1 shell open", "PC · Connecting…", "Mac · Reconnecting…", "Mac · Can't reach it. It may be asleep, off, or offline.", "Mac · Confirm with Windows Hello to connect" (locked), "PC · No longer lets this PC in. Add it again." (refused). The kind is always in words; state is never colour alone.
- Buttons: **Screen** (only when the entry has the screen scope and the host reports `screens` containing `video`), **New shell ▾** (only with the shell scope), then each running session as "zsh · running · 4m" with **Open** and **End**. Sessions come from `ComputerLink.Snapshot.Sessions` through `ShellEndedSessions`; ended ones are not listed.
- **New shell ▾** is a `SplitButton`: the button opens the remembered shell (`lastShell`, else the host's default, captioned with its name); the chevron lists `host.shells` when there is more than one (a PC), footed "Shells open as you, never as administrator." A Mac, with one shell, shows a plain button.
- **End** asks in a small flyout: "End zsh on *MacBook*? Anything running in it stops." **End** · **Cancel**; then `Close(session)`.
- Opening the flyout calls `Want`; while locked nothing connects and nothing prompts until a button is pressed. The flyout hides when the Hello prompt takes focus (`FlyoutWindow.xaml.cs:61-72`), so each action is carried by the app, not the flyout: the prompt is parented to a small hidden owner window brought to the front, and the result (a tab, a window, or a notice that stays) does not depend on the flyout being open.
- Settings ▸ Remote access ▸ *Other computers*: the same entries with what this PC may do there, who handed it over, the "Ctrl acts as ⌘" switch (Macs), and **Remove** ("This PC forgets how to reach *MacBook*. Its access there stays until it is revoked on *MacBook*.").

### (b1) Screen stream in Core

`Screen/ScreenVideoWire` is a direct port: the same constants, message set, kind numbers, encodings and per-sender limits (`ScreenVideoWire.swift:13-29`, `:223-228`, `:363-374`); `Reader(Sender)` checks each payload's limit from the 5-byte header before buffering it and skips unknown kinds; decode tolerances are kept (unknown fit or quality reads as the first, unknown copy status as nothing, odd voice bytes trimmed). Messages are `readonly record struct`s over `ReadOnlyMemory<byte>`; frame payloads are rented from `ArrayPool` and returned by the sink.

```csharp
public sealed class ScreenVideoClient : IAsyncDisposable
{
    public const int MaxCursorSide = 1024;
    public const int MaxStreamSide = 4096;
    public sealed record Layout(int Width, int Height, Fit Fit, int Fps = 60, Quality Quality = Quality.Sharp, int Space = 100);

    public ScreenVideoClient(Stream stream, ReadOnlyMemory<byte> initialBytes, Layout layout, Codecs codecs,
        IScreenSink sink, TimeProvider time);
    public void Start();
    public void Relayout(Layout layout);
    public void Shown(uint number);                 // ack
    public void RequestKeyframe();
    public void Pointer(double x, double y, byte buttons);
    public void Scroll(int dx, int dy);
    public void Key(uint keysym, Modifiers modifiers);
    public void Text(string text);                  // in TextPieces of ≤ 4 KiB
    public bool Clipboard(string text);             // false over 64 KiB, nothing sent
    public void CopySelection();
    public void Gesture(Gesture g, GesturePhase phase, double value);
    public void Function(bool down);
    public void Sound(bool on);
    public void Microphone(bool on);
    public void Voice(ReadOnlySpan<byte> samples);  // dropped while 16000 bytes are unsent
}

public interface IScreenSink   // called on the client's read loop, in order
{
    void Format(Codec codec, int width, int height, IReadOnlyList<ReadOnlyMemory<byte>> parameterSets);  // validated; only when changed
    void Frame(uint number, bool keyframe, IMemoryOwner<byte> annexB);   // the sink acks through Shown when presented or superseded
    void Fitted(Fit fit);
    void Cursor(double x, double y, bool visible);
    void CursorShape(int width, int height, int hotX, int hotY, ReadOnlyMemory<byte> png);   // size fields checked; PNG not decoded here
    void Viewers(IReadOnlyList<string> names);
    void MovedAway(string to);
    void Copied(CopyResult result);
    void SoundState(SoundState state);
    void SoundPacket(ReadOnlyMemory<byte> packet);
    void MicrophoneState(MicrophoneState state);
    void Closed(Exception? error);                  // once; null after DisposeAsync
}
```

State machine (as `ScreenVideoClient.swift:260-325`): hello first, then the initial bytes, then the read loop (reads of 256 KiB). `awaitingKeyframe` starts true and is set by `RequestKeyframe`; a frame with no format yet, or a delta while awaiting, is acked at once and not passed on. `copied` is passed on only while a `CopySelection` is unanswered. A wire error or a validation failure closes the stream with `MalformedStreamException`. Sends go through one ordered queue; voice has its own backlog rule.

**Validation before anything reaches a decoder** (all in Core, all tested):
- `format`: codec known and one this client offered; 16 ≤ width, height ≤ 4096; exactly 2 parameter sets for H.264, 3 for HEVC, each 1…4096 bytes.
- `H264Sps.TryParse` (profile, level, chroma format, bit depth, size in macroblocks, frame-only flag, cropping, and the VUI's full-range flag and matrix when present; emulation-prevention bytes removed first): profile must be 66, 77 or 100, chroma 4:2:0, 8 bits, frame-only, and the cropped size must equal `format`'s width and height. `HevcSps.TryParse` likewise for Main profile (PR b5).
- `AnnexB.Convert`: walks 4-byte big-endian lengths; a length of zero, past the end, or more than 4096 NAL units fails. Each unit is written after `00 00 00 01`. **In-band parameter sets are dropped** (H.264 types 7 and 8; HEVC 32–34), and on a keyframe the validated sets from `format` are written first. The decoder therefore only ever sees sizes that were checked.
- An empty frame is malformed.

### (b2) Decode and present (`Passthrough.Media`)

**Threads.** *Read loop* (thread pool): the client. *Decode thread* (dedicated, MTA, owns the transform): takes frames from a bounded channel (8 frames or 32 MiB; overflowing it drops everything waiting, acks them and asks for a keyframe). *Render thread* (dedicated): owns the swap chain and the video processor. *UI thread*: XAML, the pointer overlay, input. *Hook thread*: keys (b3). Decoded frames pass through a one-slot mailbox: a newer frame replaces an unpresented older one, which is acked then. Every frame gets exactly one ack, in order: when presented, when superseded, or at once when it couldn't be shown.

**Device.** `D3D11CreateDevice` (hardware adapter, feature levels 11_1 then 11_0, `BGRA_SUPPORT | VIDEO_SUPPORT`); `ID3D10Multithread.SetMultithreadProtected(true)`; an `IMFDXGIDeviceManager` reset to the device. If no hardware device or the decoder refuses the manager: WARP and software decode (system-memory NV12 copied into a dynamic texture), with one log line. `DXGI_ERROR_DEVICE_REMOVED` anywhere: rebuild device, decoder and swap chain, then `RequestKeyframe`.

**H.264 decoder.** Microsoft's H.264 decoder transform (`CLSID_MSH264DecoderMFT`), synchronous. Before types: `MFT_MESSAGE_SET_D3D_MANAGER`; `CODECAPI_AVLowLatencyMode = true` (one frame out per frame in, no reordering delay; the Mac sends none, `VideoEncoder.swift:50`); `CODECAPI_AVDecVideoAcceleration_H264 = true`. Input type: `MFVideoFormat_H264`, the validated frame size, progressive. Output type: NV12. Loop: `ProcessInput` with one sample per frame (sample time = frame number × 1/60 s) then `ProcessOutput` until `MF_E_TRANSFORM_NEED_MORE_INPUT`. `MF_E_TRANSFORM_STREAM_CHANGE`: read the new output type; its frame size must match the validated size (rounded up to 16), else close; set it and continue. Any other failure: flush, drop to awaiting a keyframe, `RequestKeyframe`; three failures in 10 s close the view ("This PC couldn't decode the picture."). A new `format` with a different size or codec drains and re-creates the transform. The output sample's buffer gives `IMFDXGIBuffer` → texture and array slice; the sample is held until the next frame replaces it (the decoder reuses its textures on release).

**HEVC** (PR b5): `MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, SYNCMFT | HARDWARE | SORTANDFILTER, input HEVC)`; a candidate counts only if it activates, is D3D11-aware and accepts the device manager (the HEVC Video Extensions decoder does; without the extension nothing enumerates). Probed once per run off the UI thread and cached. `Codecs` in `hello` is `H264` alone unless the probe passed, then `H264 | Hevc` (`protocol/README.md:647-649`: the bit means hardware decode). Asynchronous-only transforms are not used in this stage. A debug setting forces H.264.

**Colour.** `ID3D11VideoProcessor` converts and scales in one blit from the decoder's texture to the back buffer. Input colour space `DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709` (BT.709, video range: `VideoEncoder.swift:57-59`, `ScreenCapturer.swift:115-116`), or the full-range 709 space when the SPS's VUI says full range; output `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709`. Set through `ID3D11VideoContext1`; on a device without it, the older `VideoProcessorSetStreamColorSpace` with the 709 and nominal-range bits.

**Swap chain.** `CreateSwapChainForComposition`: `B8G8R8A8_UNORM`, 2 buffers, `FLIP_DISCARD`, scaling `STRETCH`, alpha `IGNORE`, flag `FRAME_LATENCY_WAITABLE_OBJECT`; `SetMaximumFrameLatency(1)`; attached to a WinUI 3 `SwapChainPanel` through `ISwapChainPanelNative` (the WinUI 3 interface, `63aad0b8-7c24-40ff-85a8-640d944cc325`, not UWP's). Its size is the panel's size in physical pixels: `ActualWidth × CompositionScaleX`, rounded, at least 1; `IDXGISwapChain2.SetMatrixTransform` with the inverse scale so XAML doesn't stretch it. `SizeChanged` and `CompositionScaleChanged` (a move to a monitor with another scale) post a resize to the render thread, which calls `ResizeBuffers` after releasing its views.

**Presenting the newest frame.** The render thread waits on {the swap chain's waitable object} then on {a new frame, a resize, stop}. With a frame: clear to black, blit into the aspect-fitted rectangle (the letterbox computed as `RemoteScreenWindow.swift:477-483`), `Present(1, 0)`, then `Shown(number)`. Because the wait on the waitable comes first, at most one frame is ever queued in the compositor, and frames that arrive during the wait replace each other in the mailbox. With the window minimized, hidden or cloaked the render thread skips the blit and present and acks at once.

**The pointer** is not in the frames. It is a XAML `Image` laid over the panel and moved by a `TranslateTransform` on the UI thread, sized `shape size × picture width / stream width`, its hot spot at the tip (`RemoteScreenWindow.swift:515-522`). It follows this PC's pointer while that is over the picture (it leads the echo) and the Mac's reported position otherwise; hidden when the Mac says not visible. The PNG: check the 8-byte signature, open with `BitmapDecoder` restricted to the PNG codec, read `PixelWidth`/`PixelHeight` and require 1…1024 before asking for pixels; a shape that fails any check is skipped and the last one stays. While the remote shape is drawn, this PC's own cursor is hidden over the picture (a blank cursor resource set as the panel host's `ProtectedCursor`).

### (b3) Input

All mapping tables and state machines are in Core (`Screen/ScreenKeys`, `ScrollScale`, `PinchFromWheel`); the app feeds them events.

**Pointer.** `PointerMoved/Pressed/Released/CaptureLost/Exited` on the panel's host. Position → 0…1 across the picture, clamped, × 65535. Buttons: left 1, middle 2, right 4 (`protocol/README.md:683-684`); the extra buttons are ignored. A press outside the picture is not a click (`RemoteScreenWindow.swift:562-564`); the pointer is captured during a drag, and moves outside the picture are sent only while a button is held. Moves are sent at most every 8 ms; a button change always, with its position. Touch and pen act as the left button. On losing capture or focus every held button is released with one message.

**Wheel and precision touchpad.** `PointerWheelChanged`: a precision touchpad arrives as the same event with small deltas. Pixels in the view = delta × 100 / 120 (a wheel notch is 100 DIPs, a touchpad follows the fingers as it does in a browser); stream pixels = that × stream width / picture width in DIPs. Vertical: positive delta → positive `dy` (earlier content). Horizontal: positive delta → negative `dx`. Fractions are carried over (`RemoteScreenWindow.swift:338-345`) and cleared 150 ms after the last event; values clamp to Int16. The pointer's position is sent first (`:591-592`). **With Ctrl held** (which is also how Windows delivers a touchpad pinch) the wheel is a `gesture` instead: `magnify`, `began` on the first event, `changed` with value = delta / 1200, `ended` 150 ms after the last. Rotation is not sent.

**Keys.** A low-level keyboard hook (`WH_KEYBOARD_LL`) is installed only while a screen window is live, focused and not showing a dialog, on a thread of its own that does table lookups and posts results (a slow hook delays every key on the PC). It is what lets the Windows key and Alt reach the Mac without opening Start or the window menu. If it can't be installed the window falls back to XAML key events and the subtitle says "The Windows key stays on this PC."

Modifier mapping (`ScreenKeys.Modifiers(state, ctrlIsCommand)`):

| This PC's key | Default | With "Ctrl acts as ⌘" |
|---|---|---|
| Alt (left; right too on layouts without AltGr) | ⌘ (1) | ⌃ (8) |
| Ctrl | ⌃ (8) | ⌘ (1) |
| Windows | ⌥ (4) | ⌥ (4) |
| Shift | ⇧ (2) | ⇧ (2) |
| Menu key (☰), held | the Mac's Fn: `function(true)` on down, `function(false)` on up | same |

Per key-down, in this order:
1. **Kept by Windows, never seen**: Ctrl+Alt+Del, Win+L. **Left to this PC on purpose** (passed through the hook): Alt+Tab and Alt+Shift+Tab, Alt+Esc, Alt+F4 (closes the view), Ctrl+Alt+Break (full screen), PrintScreen and Win+Shift+S, the media and volume keys. After any of them, and on losing focus, the tracked modifier state is cleared and a held Fn is released.
2. **While an input method is composing**: everything passes through untouched (`RemoteScreenWindow.swift:630-631`).
3. **AltGr** (right Alt on a layout that has it, recognised by the injected left Ctrl that precedes it): text path.
4. **A special key** → `key(keysym, modifiers)`, swallowed. Table (virtual key → keysym, values from `RFBKeys.swift:6-25`): Return and numpad Enter 0xFF0D, Tab 0xFF09, Back 0xFF08, Delete 0xFFFF, Escape 0xFF1B, Left 0xFF51, Up 0xFF52, Right 0xFF53, Down 0xFF54, Home 0xFF50, End 0xFF57, Prior 0xFF55, Next 0xFF56, F1–F12 0xFFBE–0xFFC9. Insert, F13 and above: not sent.
5. **⌘ or ⌃ or ⌥ held** (after mapping) → a shortcut: `key(keysym of the character the key types unshifted on this PC's layout, modifiers)`, swallowed. The character comes from `MapVirtualKeyEx(vk, MAPVK_VK_TO_CHAR)`, lower-cased (never `ToUnicodeEx`, which disturbs dead keys); the keysym from `RFBKeys.keysym(for:)`'s rule (`RFBKeys.swift:29-36`). The Mac presses the key that types that character on its own layout (`protocol/README.md:689-694`).
6. **Otherwise text**: the key is not swallowed. It reaches a nearly invisible `TextBox` that holds focus while the view is live (1×1, placed at the pointer so an input method's candidate window opens there, as `RemoteScreenWindow.swift:706-710`). Committed text (a `TextChanged` outside a composition, or `TextCompositionEnded`) is sent as `text` and the box cleared; dead keys and input methods therefore compose on this PC and only finished text is sent. Losing focus mid-composition discards it.

Key repeats send the key again. Modifier keys alone send nothing: `key` is a press and release with its modifiers, so nothing can stay held on the Mac except Fn, which is released on focus loss, on close and by the Mac at the stream's end.

### (b4) The window

`ScreenWindow(ComputerEntry, AppServices)`: one per computer, kept in a dictionary in `App` as `_settings` is (`App.xaml.cs:149-158`); a second **Screen** click brings the existing one forward with `BringToFront`. Icon set, black content, `ExtendsContentIntoTitleBar` with a title-bar strip holding the name, the subtitle and the buttons; minimum 480×300 DIPs (`RemoteScreenWindow.swift:58`); first size: the stream's shape fitted in 80% of the work area once `format` is known. `ShutDownAsync` closes them all. Every button has an automation name and a tooltip.

**Phases** (the model is in Core, `ScreenSession`, tested with a fake host):

```
Locked ──Hello ok──▶ Connecting ──size──▶ Live ──closed(error)──▶ Reconnecting ──size──▶ Live
   ▲                     │ failed/refused      │ movedAway, refused     │ 3 tries / 20 s
   └── PC locked ────────┴──────────▶ Failed(message, canRetry) ◀───────┘
```

- **Connecting**: unlock or confirm with Hello; browse 0.8 s; a new `ShellClient`; on `Ready` → `RequestScreen(video: true)`; on `Screen` → `ScreenVideoClient` with layout below. Never `screen` (RFB): there is no RFB client here; `screen_video_unavailable` is a failure with its sentence.
- **Layout the PC asks for**: fit `mac` (0), width = height = the longest side in physical pixels of the largest monitor, clamped 1280–4096; 60 fps (15 while minimized, hidden or cloaked: `Relayout`); quality sharp; space 100. The Mac's own display, scaled by this PC into whatever size the window is. Fit `device` is not asked for: it re-captures on every change of size, mirrors the Mac's displays, and one viewer at a time may have it (`protocol/README.md:661-672`).
- **Live**: subtitle "Keys go to *MacBook*" while the window has the keyboard, followed by the path when it isn't local (" · through a relay", " · direct"); just the path while it hasn't. Other viewers, when the Mac reports any: " · *iPhone* is also viewing".
- **Reconnecting**: the last picture stays, dimmed to 40%, with "Reconnecting…"; redials at 0, 2 and 5 s without asking Hello again; then **Failed** "The connection to *MacBook* was lost." **Try again**.
- **PC locked** (`WTS_SESSION_LOCK`) or the vault locking: the stream closes, the picture is cleared, and the window returns to **Locked** ("Confirm it's you to see and control *MacBook*'s screen." **Confirm**).
- **Moved away**: "*iPhone* took over this view of *MacBook*'s screen." **Try again**.
- **The entry removed or replaced** while open: closed with "This PC no longer has access to *MacBook*'s screen." (no retry), or restarted with the new one.

**Clipboard**: text only, only on a click, as the Mac's window. **Send clipboard**: this PC's clipboard text → `clipboard`; nothing or not text: a short "There's no text on the clipboard."; over 64 KiB: "That's too much text to send (64 KB at most)." **Copy from Mac**: `copy`; the answer's text goes on this PC's clipboard with roaming off (`ClipboardContentOptions.IsRoamable = false`); "Nothing was copied.", "That's too much text to copy.", "What was copied isn't text." otherwise. Ctrl/Alt+V in the view is a key for the Mac, not a paste of this PC's clipboard.

**Full screen**: the title-bar button and Ctrl+Alt+Break switch the `AppWindow` presenter to full screen on the window's monitor; a bar with the same buttons and **Exit full screen** slides in when the pointer rests at the top edge for 300 ms. Esc is a key for the Mac.

### (c) Sound and microphone

**Sound** (`Passthrough.Media/MacSoundPlayer`): a title-bar toggle, off by default, remembered per computer. On: `Sound(true)`; `soundState on` starts playback; `failed`: off with "*MacBook* couldn't send its sound."; no answer in 3 s (an older Mac): off with "*MacBook* doesn't send sound yet. Update Passthrough there."
- Decode: Microsoft's AAC decoder transform. Input type `MFAudioFormat_AAC`, 48000 Hz, 2 channels, `MF_MT_AAC_PAYLOAD_TYPE = 0` (raw, nothing around the packet), `MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION = 0x29`, `MF_MT_USER_DATA` = the 12 trailing bytes of `HEAACWAVEINFO` (payload type 0, level 0x29, zeros) then the AudioSpecificConfig `11 90` (AAC-LC, 48 kHz, stereo). Output: 32-bit float, interleaved. One packet in, up to 1024 frames out; the first packets give less or nothing. A packet that is empty or over 16 KiB is dropped (`MacSound.swift:89`); a decode error drops that packet; 20 errors in a row turn sound off.
- Buffer: `JitterBuffer` (the port of `VoiceBuffer`, counting interleaved samples): play once 80 ms wait (7680 samples), drop the oldest back to 80 ms when more than 400 ms wait (38400), wait for 80 ms again after running dry (`protocol/README.md:643-644`).
- Render: WASAPI shared mode on the default output, event-driven, our format (float, 48 kHz, stereo) with `AUTOCONVERTPCM | SRC_DEFAULT_QUALITY` so Windows converts to the device's; a 20 ms buffer; a thread registered with the multimedia scheduler ("Audio") that on each event asks the padding, pulls that many frames from the buffer under a short lock and releases. The default device changing or the device being invalidated: rebuild on the same buffer. Stops with the toggle, the stream, and the window.

**Microphone** (`Passthrough.Media/VoiceCapture`): a title-bar toggle, always off when a window opens.
- Permission: an unpackaged app gets no prompt of its own; Windows' "Let desktop apps access your microphone" decides. On toggling: `AppCapability.Create("microphone").CheckAccess()`; when not allowed, or when starting the capture fails with access denied: off with "Windows isn't letting desktop apps use the microphone. Turn it on in Settings ▸ Privacy & security ▸ Microphone." **Open settings** (`ms-settings:privacy-microphone`). No microphone: "This PC has no microphone."
- Then `Microphone(true)` and wait for `microphoneState`: `on` starts capturing; `notInstalled`: "*MacBook* has no Passthrough Microphone. Install it in Passthrough's settings on the Mac."; `failed`: "*MacBook* couldn't use this PC's microphone." Nothing is captured before `on` (`protocol/README.md:736-739`).
- Capture: WASAPI shared mode on the default communications input, event-driven, asking for 16 kHz mono 16-bit directly with `AUTOCONVERTPCM | SRC_DEFAULT_QUALITY`, stream category Communications; each 10 ms period (320 bytes) is one `voice` message, little-endian, never over 8 KiB. The client's backlog rule drops voice while 16000 bytes are unsent. Stops on: the toggle, any state but `on`, the stream ending, the window losing its Live phase, the PC locking, the device going away (then off with "The microphone was disconnected.").
- While it is on, the toggle is filled and the subtitle ends " · microphone on"; Windows shows its own in-use indicator.

## Pull requests, in order

Titles follow the repo ("Area: what changed"). Each goes against `dev` with its changelog entry ("Works now / Not yet") and guide text.

### Track (a)

**a1. Windows viewer: the shell client in Core**
- Scope: `ShellCredential`, `ShellCredentials`, `ShellClient` with its schedule, handshake, liveness and screen hand-over; `ShellEndedSessions`, `Utf8Repair`, `TerminalPaste`; `PinnedTlsDialer`.
- Files: `Core/Client/*.cs`; tests `Client/ShellClientTests.cs`, `ShellClientScheduleTests.cs`, `ShellCredentialsTests.cs`, `ShellEndedSessionsTests.cs`, `Utf8RepairTests.cs`, `TerminalPasteTests.cs`, `Fakes/FakeShellHost.cs`, `Fakes/FakeDialers.cs`.
- Docs: `windows/README.md` layout; changelog.
- By hand: nothing visible; `dotnet test`.
- Leaves out: any Windows API, storage, UI.

**a2. Windows viewer: finding and dialing another computer**
- Scope: `DnsSdBrowser`, `IrohShellDialer` over the bridge, `NetworkPathWatcher`, `ComputerLink`; a debug-only command (`Passthrough.exe --dial <credential file>`, debug builds) that connects and logs `ready` with its path.
- Files: `Passthrough.Windows/Client/*.cs`, `Core/Client/ComputerLink.cs`; tests `ComputerLinkTests.cs`; the C#-client-against-Swift-host loopback test on the macOS CI job.
- By hand: with a credential exported from a debug Mac build, the command reaches `ready` on Wi-Fi (Bonjour), by address, and over iroh from a hotspot.
- Leaves out: stored credentials, UI.

**a3. Windows viewer: access to other computers, kept behind Windows Hello**
- Scope: `IHelloKey`/`HelloKey`, `ComputerVault`, pending passes, both receive paths (`SavePassAsync` from the service; the pairing sheet's result), the notices, Settings ▸ Remote access ▸ *Other computers* with **Remove**, the no-Hello and Hello-reset rows, locking on session lock.
- Files: `Core/Trust/ComputerVault.cs`, `Passthrough.Windows/Hello/HelloKey.cs`, `App/SettingsWindow.xaml(.cs)`, `App/SessionViewModel.cs`; tests `ComputerVaultTests.cs` (with a fake Hello key and `MemoryFileSystem`).
- Docs: guide §Windows ("Other computers", what Hello protects); `SECURITY.md` (the vault, what a program running as you can and can't get).
- By hand: share a Mac from the iPhone with the PC locked → the notice waits → **Keep** asks Hello once → the Mac is listed; remove the Hello PIN → the reset notice.
- Leaves out: using the credential for anything.

**a4. Windows viewer: passthrough-term.exe and its pipe**
- Scope: `TermWire`, `TermAccess`, `TermPipeServer`, `TermBridge`, the `Passthrough.Term` project with the console setup, `TerminalLaunch`.
- Files: `Core/Client/TermWire.cs`, `TermAccess.cs`, `TermBridge.cs`, `TerminalLaunch.cs`; `Passthrough.Windows/Pipes/TermPipeServer.cs`; `src/Passthrough.Term/*`; solution and app csproj (copy the tool beside the app); tests `TermWireTests.cs`, `TermAccessTests.cs`, `TermBridgeTests.cs`, `TerminalLaunchTests.cs`, and a pipe test (Windows job only) for the ACL, wrong-session and late-hello cases.
- Docs: `windows/README.md` (project list, checklist items); `protocol/README.md` gets the Windows pipe beside "Terminals on the Mac" (`status`, the token-only hello).
- By hand: a debug menu item "Open a shell on *first computer*" opens the tab; run the track's terminal checklist.
- Leaves out: the flyout rows (the debug item goes in a5).

**a5. Windows viewer: Your computers in the flyout**
- Scope: the rows, **New shell ▾** with the chooser for a PC, sessions with **Open** / **End**, the locked, connecting and refused states, remembering the last shell; the **Screen** button present but hidden until b2.
- Files: `App/FlyoutWindow.xaml(.cs)`, `App/ComputerRow.cs`, `App/SessionViewModel.cs`, `Core/Presentation/ComputerRowText.cs`; tests `ComputerRowTextTests.cs`.
- Docs: guide; `README.md`'s Windows line; changelog.
- By hand: the track (a) done-when list.

### Track (b)

**b1. Screen viewer on Windows: the stream's messages and client in Core**
- Scope: `ScreenVideoWire`, `ScreenVideoClient`, `AnnexB`, `H264Sps`, `ScreenSession` (phases), fixtures.
- Fixtures first: a new `screenVideoMessages` section in `protocol/fixtures.json`: each message as hex with its decoded fields, the per-sender limit cases, an unknown kind skipped. The Swift suite gains a test reading it in the same PR; Kotlin has no screen client and is not touched.
- Files: `Core/Screen/*.cs`; tests `ScreenVideoWireTests.cs`, `ScreenVideoClientTests.cs`, `AnnexBTests.cs`, `H264SpsTests.cs`, `ScreenSessionTests.cs`, `Fakes/FakeScreenHost.cs`; `Packages/PassthroughCore/Tests/PassthroughCoreTests/ProtocolFixtureTests.swift`.
- Docs: `protocol/README.md`: the pacing window corrected (see *Corrections*).

**b2. Screen viewer on Windows: the Mac's screen in a window**
- Scope: `Passthrough.Media` with the device, H.264 decoder and presenter; `ScreenWindow` with the Hello gate, phases, reconnect, the pointer overlay, hidden-window slow-down; the **Screen** button. View only.
- Files: `src/Passthrough.Media/*` (`NativeMethods.txt`, `VideoDevice.cs`, `H264Decoder.cs`, `Presenter.cs`), `App/ScreenWindow.xaml(.cs)`, `App/App.xaml.cs`, solution; `THIRD_PARTY_NOTICES.md` (CsWin32, build-time).
- Tests: a decoder smoke test on the Windows job (a committed 2-frame H.264 clip made by the Mac encoder decodes to NV12 of the right size; skipped when no decoder is present).
- By hand: the picture, 60 fps, GPU decode in Task Manager, resize, a second monitor at another scale, minimize (the Mac's frame rate drops), unplug the network.

**b3. Screen viewer on Windows: pointer, scrolling and keys**
- Scope: `ScreenKeys`, `ScrollScale`, `PinchFromWheel` in Core; pointer and wheel handlers; the hook; the text proxy; `function`; "Ctrl acts as ⌘"; the "Keys go to" subtitle.
- Files: `Core/Screen/ScreenKeys.cs`, `ScrollScale.cs`, `PinchFromWheel.cs`; `App/Platform/KeyboardHook.cs`, `App/ScreenWindow.*`; tests `ScreenKeysTests.cs` (every table row, AltGr, composing, the kept and local keys), `ScrollScaleTests.cs`, `PinchFromWheelTests.cs`.
- By hand: the keys part of the checklist.

**b4. Screen viewer on Windows: clipboard, full screen, other viewers**
- Scope: the two clipboard buttons and their messages, full screen with its bar, viewers in the subtitle, `movedAway`.

**b5. Screen viewer on Windows: HEVC where this PC decodes it**
- Scope: the probe, `HevcSps`, the HEVC decoder path, the codecs bit; fixture cases for an HEVC `format`.

### Track (c)

**c1. Screen viewer on Windows: the Mac's sound** — `JitterBuffer` (Core, with `VoiceBuffer`'s test cases), `MacSoundPlayer`, the toggle. Test: a committed AAC packet sequence decodes to the expected frame count (Windows job).

**c2. Screen viewer on Windows: this PC as the Mac's microphone** — `VoiceCapture`, the permission check, the toggle and its states.

## Interfaces

### This stage defines (others depend on these)

| Name | Shape | Owner |
|---|---|---|
| `Core.Client.ShellClient`, `ShellCredential`, `IPinnedTlsDialer`, `IShellIrohDialer`, `IShellStream` | above | Core |
| `ComputerVault` and the `computers\` file formats | above; `Save(ReceivedComputerPass)` is what stage 7's Windows halves call | Core/Trust |
| `IHelloKey` | above | `Passthrough.Windows` |
| `TermWire` kind 22 `status`, hello `mode:"remote"` with a token only | above; stage 9's terminals-on-the-PC adds modes to the same pipe | Core |
| Pipe name `passthrough-term-<SID>-<session>` and its checks | above | `Passthrough.Windows` |
| `ScreenVideoWire`, `ScreenVideoClient`, `IScreenSink` (C#) | above; stage 9's PC stream reuses the wire and `JitterBuffer` from the host side | Core |
| `screenVideoMessages` fixtures | hex + fields | `protocol/fixtures.json` |
| `Passthrough.Media` | decoders, presenter, WASAPI; stage 9's encoder and capture join it | new project |

### This stage consumes

| From | What |
|---|---|
| Stage 1(a) | the Windows CI job; `dotnet test` on the macOS job |
| Stage 1(b) | `ShellEnvelope` in C# with `host` (`kind`, `shells`, `screens`, `signedIn`), `open.shell`, `signed_out`, going-away reasons |
| Stage 1(c) | `computer.` ids, `computerPass` with `scopes`, the proof's signature field |
| Stage 3 | `Shell/ShellEnvelope`, `LineBuffer`, `ShellAddressPolicy`, `ShellReplay`, `RemoteShell` constants; the iroh bridge and its dial calls; `LogText.Redact` for 44-character keys and relay tokens |
| Stage 4 | `Passthrough.Windows`' DNS-SD wrapper; `ISessionHost.SavePassAsync`; the session-lock notification |
| Stage 7(a) | the phone's hand-over reaching `SavePassAsync`, the "may share" check, `ReceivedComputerPass`, revoking a phone forgetting what it handed over |
| Stage 7(b) | the pairing sheet and its result; this computer's identity key behind `IComputerProof` |
| Stage 7(a), Mac side | a Mac accepting a `computer.` id with the screen scope for `screenVideo`, and with the shell scope for sessions |

## Tests

**Automated, in `Passthrough.Core.Tests` (run on any OS)**
- `ShellClientScheduleTests`: the Swift cases (no addresses, addresses only, iroh placement, local-only, invalid iroh id, discovered first).
- `ShellClientTests` against `FakeShellHost` and `FakeTimeProvider`: first authorized wins and losers are disposed; a failed attempt dials the next at once; 4 s and 10 s timeouts; `error` before ready ends every path; bad nonce; iroh says `hello` first; queued commands flush on ready; `open`/`attach` overtaking with `ref` (opened, openedDetached, openFailed, a host that echoes no ref); input dropped while an open is pending; input split at 16384; `ended`/`detached`/`no_such_session` clearing the current session; ping at 5 s, give up at 15 s; the path probe at 2 s and its cancellation by any byte; the hand-over returning the bytes after `screenVideoReady` and going silent; a line over the limit; the computer proof's signature present for a `computer.` id.
- `ComputerLinkTests`: redial delays, reset on ready, redial on address change, stop on `not_authorized`, `macInfo` update rules.
- `ComputerVaultTests`: seal and open round trip; locked `Open` is null; `Save` without a prompt; pending then confirm; replacement only on matching pin and iroh id; tampered box, wrong file name (associated data), truncated file; Hello reset deletes; `Lock` wipes; a redacted `ToString`.
- `TermWireTests`, `TermAccessTests` (once, 60 s, wrong session, contested), `TermBridgeTests` (attach replay ordering, output between attach and replaying dropped, reconnect and re-attach, the 8 MiB rule, ended, detached), `TerminalLaunchTests` (title cleaning incl. `;`, quotes, control and bidi characters; argument lists).
- `ScreenVideoWireTests` on the fixtures; `ScreenVideoClientTests` (hello first, initial bytes, awaiting keyframe acks, copied only as an answer, text pieces, clipboard limit, voice backlog, malformed closes once); `AnnexBTests`; `H264SpsTests`/`HevcSpsTests` (real parameter sets from a Mac, each rejection rule, random bytes never throw anything but a parse failure); `ScreenSessionTests` (every phase edge).
- `ScreenKeysTests`, `ScrollScaleTests`, `PinchFromWheelTests`, `JitterBufferTests`.
- Helper suites mirroring the Swift ones.

**Automated, Windows job only**: the pipe's ACL and refusals; decoder and AAC smoke tests; `HelloKey` is not testable in CI (no Hello) and stays behind its interface.

**Cross-implementation (macOS job)**: the C# `ShellClient` against the Swift `ShellListener` through `ready`, `open`, output and `screenVideo` hand-over; where the runner's .NET can't do TLS 1.3 as a client the test runs over the iroh path only.

**Needs a real Mac and PC** (added to `windows/README.md`'s checklist):
1. Hand-over from the iPhone with the PC unlocked, locked, and with Passthrough closed (expect `pass_not_saved` and the phone saying so).
2. Direct pairing, then the Hello prompt appears in front and names the Mac.
3. New shell in Windows Terminal: tab in the current window, title, vim, Claude Code, mouse in `htop`, resize, Ctrl+C, Ctrl+Break, typing "héllo 日本語" with an input method, paste of 1 MB.
4. The same with Windows Terminal uninstalled (Windows 11 default terminal, and Windows 10's console host).
5. Close the tab → session listed → **Open** → scrollback drawn once; **End**.
6. Wi-Fi off for 10 s mid-`top` → "Reconnecting…" → back, clean screen.
7. Same network; Tailscale; phone hotspot (iroh direct); relay only.
8. A PC as the remote: the chooser lists its shells; the choice is remembered.
9. Lock the PC with a tab and a screen window open: the tab keeps working after unlock; the window asks Hello again.
10. Screen: picture and 60 fps on integrated and discrete GPUs; a 4K monitor at 150% beside a 1080p one at 100%, dragging the window between them; minimized; full screen.
11. Keys: Alt+C copies, Ctrl+C interrupts in the Mac's Terminal, Win+E types ´ (⌥E) and does not open Explorer, Alt+Tab switches on the PC, Alt+Space opens Spotlight, the Menu key held starts dictation, a German layout's AltGr+Q types @, a Japanese input method composes at the pointer, "Ctrl acts as ⌘" swaps.
12. Scroll with a wheel and a precision touchpad (direction and speed against a browser), pinch zooms in Preview.
13. Send clipboard, Copy from Mac with nothing selected, with an image, with 100 KB of text.
14. The Mac asleep, Screen switch off there mid-view, another device's Use Here.
15. HEVC: with and without the HEVC Video Extensions installed, the log names the codec.
16. Sound: music for 10 minutes, a Bluetooth headset connected mid-play, a 2 s network stall. Microphone: heard in QuickTime on the Mac; the privacy switch off; unplugging the microphone.
17. Windows 10: shell over iroh only, with the row saying why.
18. Inside a Remote Desktop session to this PC: the Hello sentence.

## Security considerations for this stage

- **Untrusted input comes from the host being viewed.** It is a computer the owner paired, authenticated by pin and key, but it may be compromised. Everything it sends is bounded before it is buffered (the wire's per-type limits), and the two system decoders only see data that passed Core's checks: sizes from a parsed SPS equal to the announced ones and at most 4096, allowed profiles only, in-band parameter sets removed, NAL counts capped, AAC packets at most 16 KiB, cursor images at most 1024 px checked before decode and decoded by the PNG codec only. Decoders run in the tray process, which holds unlocked credentials: that is the residual risk, stated in `SECURITY.md`, and the reason the validation is strict (see *Open questions*).
- **Credentials at rest** can't be opened without a Hello signature; with the vault locked a program running as the user can read names and kinds and can delete or replace records, but replacing one needs a credential the host would accept, and a replaced record can't match the stored pin check. While unlocked, a program running as the user that can read the app's memory has them: outside the threat model, as on the Mac. Unlocked material is wiped on lock, disconnect and quit. Pending passes are under DPAPI only: bounded to 4 and 7 days, and said in the docs.
- **The signature-derived key** rests on RSA PKCS#1 v1.5 signatures being deterministic and on the signature never leaving memory. The challenge is fixed and public; that is fine because only the Hello key can sign it.
- **The pipe**: current user only, no remote clients, first instance, owner checked by the client, session checked by the server, a one-time token that expires in 60 s, and double use reported. The tool is given nothing secret but the token and is told nothing about where the host is.
- **Command lines** carry the pipe name, the token and a cleaned title; a host's name can't inject a `wt` command or an argument. `wt.exe` is run only through an alias verified to be Windows Terminal's.
- **The keyboard hook** sees every key on the PC while a live screen window is focused and at no other time; it is removed on deactivation, on leaving Live and on close. Keys are never logged. This is said in the guide, since security software may ask about it.
- **Clipboard** moves only on a click, text only, size-capped both ways; the Mac's copies are accepted only as answers.
- **Microphone** audio is captured only after the Mac says `on`, only while the window is live, and stops when the PC locks.
- **Hello gate**: per window and again after a lock, so someone at an unlocked PC can't take over the Mac with a click (`RemoteScreenWindow.swift:21-23`). A shell needs Hello once per unlock; that is weaker than the screen's rule on purpose (see *Open questions*).
- **Logs**: `ShellCredential.ToString` is redacted; tokens are 64 hex characters, which `LogText.Redact` must also cover (added in a4 with a test).

## UX states and strings for this stage

Given by the master plan and used as written: "Your computers" row "MacBook · Connected · 1 shell open" with **Screen**, **New shell ▾**, **Open** / **End**; tab title "*MacBook* · zsh"; "Keys go to *MacBook*"; "Shells open as you, never as administrator."; the setting "Ctrl acts as ⌘"; "Reconnecting…"; "The connection to *MacBook* was lost." **Try again**.

New in this stage (each also listed where it is designed above):

| Where | String |
|---|---|
| Row, locked | "Mac · Confirm with Windows Hello to connect" |
| Row, unreachable | "Mac · Can't reach it. It may be asleep, off, or offline." |
| Row, refused | "Mac · No longer lets this PC in. Add it again." |
| Row, Windows 10 | "Local connections need Windows 11. Using the built-in connection." |
| Notice, hand-over kept | "*iPhone* shared *MacBook* with this PC. It is under Your computers." **OK** |
| Notice, hand-over pending | "*iPhone* shared *MacBook* with this PC. Confirm with Windows Hello to keep it." **Keep** · **Discard** |
| Notice, not the same computer | "*iPhone* shared *MacBook* again, but it isn't the MacBook this PC knows. Remove it under Other computers first if you reset that Mac." |
| Settings, no Hello | "Set up a Windows Hello PIN to keep access to other computers on this PC." **Open sign-in options** |
| Remote Desktop session | "Windows Hello isn't available in a Remote Desktop session. Use this PC's own screen and keyboard to open another computer." |
| Hello reset | "Windows Hello was reset on this PC, so its access to other computers is gone. Add them again." |
| Hello prompts | "Passthrough wants to keep access to *MacBook* on this PC." / "…wants to connect to *MacBook*." / "…wants to show *MacBook*'s screen." |
| Remove | "This PC forgets how to reach *MacBook*. Its access there stays until it is revoked on *MacBook*." |
| End | "End zsh on *MacBook*? Anything running in it stops." **End** · **Cancel** |
| Contested token | "Something else tried to open that shell. The tab was closed." |
| Screen, locked | "Confirm it's you to see and control *MacBook*'s screen." **Confirm** |
| Screen, connecting | "Connecting to *MacBook*…" |
| Screen, unreachable | "Couldn't reach *MacBook*. Check that it's awake and Remote Shell is on there." **Try again** |
| Screen, refused | "*MacBook* no longer lets this PC see its screen. Add it again, or share it from your phone." |
| Screen, can't stream | "*MacBook* can't stream its screen yet. On *MacBook*, allow Passthrough Screen Recording and Accessibility." |
| Screen, too many | "*MacBook* is already showing its screen as often as it allows. Close another view of it first." |
| Screen, decode | "This PC couldn't decode the picture." **Try again** |
| Screen, taken over | "*iPhone* took over this view of *MacBook*'s screen." **Try again** |
| Screen, access gone | "This PC no longer has access to *MacBook*'s screen." |
| Hook unavailable | "The Windows key stays on this PC." |
| Clipboard, sound, microphone | the sentences in (b4) and (c) |
| Terminal | the closing and refusal lines in (a5) |

Accessibility: every title-bar button has an automation name and a tooltip naming keys in words; phase changes are a live region; the dimmed picture always has its text; the keyboard can leave the view (Alt+Tab, Alt+F4) at any time.

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| `KeyCredential` signatures not deterministic on some TPMs or Hello configurations, so the vault can't be reopened | a3 starts with a one-day spike: sign the same challenge 100 times across a reboot, on a TPM PC and a software-key PC. Fallback: the Passport key storage provider's decrypt through NCrypt, behind the same `IHelloKey`. |
| The Hello prompt opening behind other windows for an unpackaged tray app | the interop calls with an owner window brought forward first; checklist item 2 |
| IME and dead keys through a hidden `TextBox` under a low-level hook | b3 starts with a spike window (hook + proxy box + Japanese and German layouts). Fallback: no hook while composing languages are active, with the Windows key left to the PC. |
| The hook flagged by security software, or slowing typing | hook thread does lookups only; active only while a view is focused; said in the guide |
| Hiding the local cursor over a `SwapChainPanel` | blank cursor resource; fallback: handle `WM_SETCURSOR` on the window's input child |
| Decoder differences across GPUs (stream-change, texture arrays, no low-latency support) | software path through WARP kept working and tested; checklist item 10 on two GPUs; three-failures rule |
| Latency worse than the Mac's window | waitable swap chain with one frame of latency and a one-slot mailbox; measure glass-to-glass with a phone camera in b2's PR and record it |
| `wt.exe` alias missing, disabled or pointed elsewhere | verified alias, then the `CREATE_NEW_CONSOLE` fallback; checklist item 4 |
| Console differences (Windows 10 console host, legacy mode) | the VT-flag check with its sentence; `ReadConsoleInputW`; the 500 ms size poll |
| Scroll direction or speed wrong | constants in Core with tests; checklist item 12 fixes the numbers |
| .NET on the macOS runner can't be a TLS 1.3 client | the cross test falls back to the iroh path |
| Stages 1(c) and 7 name things differently from what is assumed here | the consumed names are in one table above; a1 and a3 touch them in one place each |

## Decisions made here

1. **`KeyCredentialManager` with a signature-derived key**, and a sealing key pair so writes never prompt. Reason: documented API, PIN is enough, and a hand-over can be kept while nobody is at the PC.
2. **A hand-over that arrives before any vault exists waits under DPAPI** (4 at most, 7 days) rather than being refused. Reason: the master plan offers sharing from the phone "away from one of them".
3. **Hello once per unlock for shells, every window for the screen.** Reason: the screen rule is the Mac's; asking for every tab would make the terminal unusable.
4. **The viewer runs in the tray app; nothing in the service.**
5. **One connection per tab and per screen window, plus one status connection while wanted** (released 60 s after the flyout closes). No standing connections in the background.
6. **Reconnect lives in `ComputerLink`, `TermBridge` and `ScreenSession`**, never in the client.
7. **The tool gets a token and nothing else**; computer, session and shell are bound to the token in the app.
8. **The tab title is fixed** (`--suppressApplicationTitle`), as the master plan words it; the remote program's own titles are not shown.
9. **Ctrl+Break sends 0x03.**
10. **`passthrough-term.exe` is framework-dependent**, not Native AOT.
11. **Media interop through CsWin32 in a new `Passthrough.Media` project**; no wrapper library at run time; the service never loads it.
12. **Decoders run in-process**, behind strict validation in Core.
13. **Fit `mac`, largest monitor's longest side clamped 1280–4096, 60 fps, sharp.**
14. **Only synchronous decoder transforms; HEVC in its own PR**, offered only when a hardware-backed decoder passes the probe.
15. **The pointer is a XAML overlay**, not drawn in the swap chain.
16. **A low-level hook for keys and a hidden `TextBox` for text.**
17. **"Ctrl acts as ⌘" swaps Ctrl and Alt** (Alt becomes ⌃); Windows stays ⌥.
18. **The Menu key is the Mac's Fn.**
19. **Ctrl+wheel and touchpad pinch become `magnify`; no rotation.**
20. **Alt+Tab, Alt+Esc, Alt+F4, Ctrl+Alt+Break, PrintScreen and media keys stay on the PC.**
21. **Automatic reconnect of the screen: three tries in 20 s, last picture dimmed**; the Mac's own window has none, the master plan's viewer rule asks for it.
22. **Locking the PC closes screen views and requires Hello again.**
23. **Text copied from the Mac doesn't roam to other devices** but may appear in this PC's clipboard history.
24. **Sound off by default and remembered; microphone always off at start.**
25. **The PC accepts `computerPass` only**; the older `screenPass` is answered `bad_request`.
26. **`TerminalPaste` is ported though nothing calls it yet** (see *Corrections*).

## Corrections to the master plan

1. **The client helpers.** The master plan lists `TerminalPaste` among the viewer's ports. On Windows the terminal (Windows Terminal or the console host) does the pasting itself, so `passthrough-term.exe` has no use for it; it is ported with its tests in a1 for parity and has no caller until something in the app pastes into a shell. `ShellReplay` is listed under stage 3 (with the transcript store), and this stage consumes it from there.
2. **The pacing window.** `protocol/README.md:678` says "2 to 16"; the code is 2 to 24 (`ScreenHost/StreamPacer.swift:23-24`). The master plan already says to fix the README; b1 does it, since it is the PR that adds the fixtures for this section.
3. **Windows 10 as a viewer.** The master plan says the local path needs Windows 11 for the *listener*. The same holds for the *client*: Windows 10 can't make a TLS 1.3 connection, so a Windows 10 viewer reaches other computers over iroh only. Added to the known limits.
4. **A PC viewing a PC's screen is in no stage.** Stage 8(b) decodes the Mac's stream; a PC host offers only `rdp`. The flyout therefore shows no **Screen** button for a PC. If wanted, it is either the PC's own stream (stage 9) or a Remote Desktop client on Windows, which nothing plans.
5. **Windows Hello inside a Remote Desktop session.** The PC's screen is reached through Remote Desktop (stage 5), and Hello can't be asked there. So someone viewing their PC from a phone can't open a Mac from that PC. Stated in the guide; no fix planned.
6. **"A PC without Hello can't hold them"** needs one exception to work with the phone hand-over: the pending pass (decision 2). It is unusable until confirmed, but it is on disk under DPAPI for up to 7 days.
7. **The Mac's shell name.** The tab title "*MacBook* · zsh" needs a Mac to report its shell; `host.shells` must be sent by Macs too (one entry), or the title is the name alone. Stage 1(b) should say so.
8. **Stage 7(d)'s `remote` mode** for the Mac's tool is not yet specified; this stage's pipe hello (a token only) and `status` frame are written so the Mac can adopt the same.

## Open questions for the owner (each with a recommended default)

1. **Hello for shells: once per unlock, or every time?** Default: once per unlock (and every screen window), as designed.
2. **Keep a hand-over that arrives before the vault exists** (under DPAPI, up to 7 days, unusable until confirmed), or refuse it? Default: keep it.
3. **Decode in the tray process, or in a locked-down helper process?** Default: in-process now with the validation above; a helper (as the Mac gets for FreeRDP) only if you want the same bar on Windows, at roughly two more weeks.
4. **"Ctrl acts as ⌘": what does Alt become?** Default: ⌃ (a straight swap).
5. **The Mac's Fn key**: the Menu key, held. Default: yes; alternative Right Ctrl.
6. **Which keys stay on the PC**: Alt+Tab, Alt+Esc, Alt+F4, Ctrl+Alt+Break, PrintScreen, media keys. Default: as listed (so Alt+Tab never reaches the Mac as ⌘Tab).
7. **A low-level keyboard hook while a view is focused** is the only way the Windows key can be ⌥. Default: use it, and say so in the guide.
8. **Should the tab show the remote program's own title** instead of the fixed "*MacBook* · zsh"? Default: fixed.
9. **Fit to the window** (the Mac making a display in the window's shape) as a later option? Default: later, not in this stage.
10. **A PC viewing another PC's screen**: wait for the PC's own stream (stage 9)? Default: yes.
11. **Text copied from the Mac in Windows' clipboard history** (Win+V)? Default: allowed locally, never roamed.
12. **Sound on by default?** Default: off, remembered per computer.
