# Stage 3: The PC's shell, from anywhere

## Goal and done-when

The Windows tray app hosts shell sessions (ConPTY) that a paired iPhone, iPad or Android phone opens over iroh, direct or through a relay. There is no TCP listener, no service and no administrator prompt in this stage. Access is handed out over the cable (after a check that the far end of the cable link is the real thing), can be switched per phone, and is revoked by Revoke or Forget. Sessions are recorded and can be read back on the PC. Everything network-facing is written against two asynchronous interfaces (`ISessionHost`, `IAccessAdmin`) so stage 4 can move it into a Windows service without a redesign.

Done when (master plan §3, stage 3):

1. An iPhone and an Android phone open a shell on the PC from another network, once directly (hole-punched) and once through a relay, and the PC's Settings shows which.
2. A session survives a dropped connection (airplane mode on and off: same session, scrollback replayed in one go) and a relaunch of the phone app.
3. **Revoke** and **Forget pairing** end that phone's live connections and the sessions it opened, at once.
4. An iPad on the cable pairs and gets shell access.
5. Claude Code's status (working / needs you / done) shows on the phone for a PowerShell session.
6. `passthrough.log` holds no shell key, iroh secret key or relay token after all of the above (checked by a grep in the checklist and by `LogText` tests).
7. `dotnet test` passes on Windows and, for Core, on the macOS job; `cargo test`, `cargo deny check` and `cargo audit` pass for the bridge.

Not in this stage: the service, the TLS listener, DNS-SD, firewall rules, the screen, computers (`computer.` ids), the viewer role, Stay awake, going-away reasons, terminals on the PC shown on phones.

## What exists today (verified, with path:line)

**Windows (extended by this stage)**

- Two projects and one test project: `windows/src/Passthrough.Core` (net10.0, no Windows APIs, `windows/src/Passthrough.Core/Passthrough.Core.csproj:3`), `windows/src/Passthrough.App` (WinUI 3, x64, unpackaged, `Passthrough.App.csproj:4-13`), `windows/tests/Passthrough.Core.Tests` (xUnit, reads `protocol/fixtures.json`, `Passthrough.Core.Tests.csproj:16`). There is no `Passthrough.Windows` project and no `native/` folder.
- `ControlClient` only receives after the handshake: its `Handle` knows `welcome`, `paired`, `error`, `goodbye`, `status` (`windows/src/Passthrough.Core/Control/ControlClient.cs:240-289`); it never sends `shellGrant` and ignores `shellGranted`. `Send` is private (`:336`). Events are `Welcomed`, `PairedWith`, `PairingFailed`, `StatusUpdate`, `Goodbye`, `Disconnected` (`Control/ControlEvent.cs:14-31`).
- `ControlEnvelope` already carries the grant fields: `shellKey`, `shellPort`, `addresses`, `macName`, `irohID`, `irohRelay`, `relayToken`, `grantID`, `phoneID`, `certSHA256` and the type tags `shellGrant` / `shellGranted` (`Protocol/ControlEnvelope.cs:20-21, 56-68`), and `MaxGrantIdLength = 64` (`:25`).
- `HostSession` keeps **one** control channel, to the active phone (`Session/HostSession.cs:58-59`), picks the first device that can route (`:302`), and shows an iPad as `RemoteOnlyLater` with "Pairs once Remote shell is available." (`:28`, `:553`; `Session/PhoneState.cs:24-25`). All state changes run on one loop fed by a channel of work items (`:38-40`, `:249-262`); this stage reuses that pattern.
- `ForgetAsyncCore` deletes the token and the saved name only (`HostSession.cs:213-222`). `PairedSlotsAsync` returns every slot in the secret store (`:211`), and `PairedPhone.List` turns any slot that is not `token.*` into a row titled with the raw slot name (`Presentation/PairedPhone.cs:18-23`). So a shell secret stored in the same store would be listed as a "paired phone" today.
- `ISecretStore` is string get/set/delete/list (`Storage/ISecretStore.cs:4-16`); `DpapiSecretStore` is one DPAPI (current user) file per slot in a folder limited to the user (`windows/src/Passthrough.App/Storage/DpapiSecretStore.cs:41`, `:93-104`). The app makes one at `%LOCALAPPDATA%\Passthrough\secrets` (`App.xaml.cs:76`).
- `LogText.Redact` replaces only runs of exactly 43 URL-safe base64 characters (`Logging/LogText.cs:12-15`). A base64 shell key or iroh secret is 44 characters with `=` and uses `+` and `/`; a relay token has no fixed shape. Neither is caught.
- The cable link is plain loopback TCP: `ByteStreamConnector.Tcp("127.0.0.1", 27015)` for Apple Mobile Device Service and `("127.0.0.1", 5037)` for adb (`App.xaml.cs:86-90`). The stream handed back hides its socket (`Transport/ByteStreamConnector.cs:24-47`), and `UsbMuxClient.ConnectAsync` returns that raw connection once the device connect is done (`Transport/UsbMuxClient.cs:69-70`). Nothing checks who owns the far end; `docs/GUIDE.md:85` documents that exposure.
- Settings has General (Start at login, Android support) and Paired phones (`SettingsWindow.xaml:28-98`); the flyout has a header, rows, hints, Settings and Quit (`FlyoutWindow.xaml:9-144`); the header is built by `Presentation/FlyoutHeader.cs:15-40`.
- One instance per Windows session: `Local\Passthrough.App` (`App.xaml.cs:58`).
- Tests use fakes: `Fakes/FakePhone.cs` (a phone's control server on a loopback socket), `Fakes/FakeTimeProvider.cs` (timers by `Advance`), `Fakes/MemoryFileSystem.cs`.
- The roadmap in `windows/README.md:20` still lists "Remote shell from anywhere: ConPTY sessions, the TLS listener, the built-in iroh endpoint…" as one stage.

**Swift host (ported)**: all under `Packages/PassthroughCore/Sources`.

- `ShellHost/ShellListener.swift`: `ScreenViewLimit` (`:351-381`), `ShellGate` (`:387-673`), `ShellConnection` (`:677-1339`). Ordering after `ready` at `:733-745`; the `busy` requests at `:703-708`, `:837-853`; the 1 s `macState` reply at `:775`, `:875`, `:890`; proof check against two keys at `:566-583`; `not_authorized` then a forced close 1 s later at `:541-546`; 8 MiB send backlog at `:681`, `:1266-1272`; history reply at `:1078-1103`; transcript pump at `:1108-1123`; attach generation check at `:1329-1338`.
- `ShellHost/IrohShellListener.swift`: accept loop (`:162-196`), address validation and retry (`:185-188`), bucket (`:248-251`), admit (`:255-273`), `connectionPaths` (`:226-241`).
- `ShellHost/ShellSessionManager.swift`: open with a reserved slot (`:269-319`), attach and replay (`:329-381`), input (`:421-448`), resize rules (`:454-465`), redraw (`:538-553`), `received` (`:585-600`), OSC 7501 reply before fan-out (`:629-632`), status owner rules (`:645-662`), `updateStatus` (`:667-689`), question look (`:604-623`, `:746-754`), end and retention (`:756-780`), title from echo (`:786-878`).
- `ShellHost/ScrollbackBuffer.swift`, `TerminalModes.swift`, `TerminalReports.swift`, `ProgramStatus.swift`, `ShellQuestion.swift`, `ShellReach.swift`, `LocalAddresses.swift`, `TranscriptStore.swift`, `ShellAccessStore.swift`, `PTYProcess.swift`.
- `PassthroughCore/ShellProtocol.swift` (constants `:6-38`, envelope `:42-159`, `IrohInfo` `:162-186`, errors `:277-300`, `MacState` `:352-397`, address policy `:457-577`), `ShellReplay.swift`, `MacSessionPolicy.swift` (`struct ShellGrantLedger`, the second type in the file), `Splice.swift` (not needed until stage 5's relay).
- `PhoneTransport/HandshakeLimiter.swift`, `PhoneTransport/ControlClient.swift` (`grantShell` `:152-168`, `shellGranted` `:223-226`).
- `IrohTransport/IrohEndpoints.swift`, `IrohByteStream.swift`, `IrohShellDialer.swift`: the complete use of iroh.
- `macOS/App/Session/SessionCoordinator.swift`: grant sending `:545-596`, revoke hold `:601-605`, ledger calls at `:139`, `:388`, `:624`, `:632`, `:817`, `:1091`, `shellGranted` `:845-868`, relabel `:887`, regrant on reach changes `:344-349`. `macOS/App/Shell/RemoteShellController.swift`: start/stop `:262-348`, iroh run `:364-479`, relay storage `:493-513`, status refresh `:517-544`, revoke `:780-824`, history `:1098-1188`, `IrohRun` `:1221-1305`.
- The #41 change on `dev` (commit `32d372e`): the host sends `replaying` before each replay (`ShellSessionManager.swift:358`, `ShellListener.swift:1311-1318`); the phone holds the replay until `attached`. `protocol/README.md:385-388` states it.

**What a phone needs in a grant.** A phone drops a `shellGrant` whose `certSHA256` is not 64 hex digits or whose `shellPort` is not 1 to 65535 (`PassthroughCore/ControlServer.swift:234-237`; `android/.../core/ControlServer.kt:196-198`). With no addresses it dials iroh at once (`ShellClient.swift:271-274`, `:523-534`). So a PC with no TLS listener must still send a certificate hash and a port (see *Design ▸ The grant before the listener exists*).

**iroh pins.** Apple: `.package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.1.0")` (`Packages/PassthroughCore/Package.swift:25`). Android: `computer.iroh:iroh-android:1.1.0` (`android/app/build.gradle.kts:69`). `THIRD_PARTY_NOTICES.md:17-24` records both.

**Measured facts used here** (`Spikes/PcProbe/README.md`): the connection-owner check works unprivileged (TCP table row plus `QueryServiceStatusEx`); the only `pwsh.exe` on the owner's PC is the Store alias in the user-writable `%LOCALAPPDATA%\Microsoft\WindowsApps`; WSL lists `docker-desktop`; the PC has no Rust toolchain.

## Design

### 0. Shape

```
Passthrough.Core (portable)                      Passthrough.Windows (new, net10.0-windows, no WinUI)
  Shell/            envelope, constants, policy     Pty/        ConPtyFactory, JobObject, UserEnvironment
  Shell/Host/       ShellGate, ShellConnection,     Shells/     WindowsShellCatalogSource, StorePackages
                    IrohShellListener, limiter,     Iroh/       IrohBridge (P/Invoke), IrohRuntime, IrohEndpoint…
                    ShellReach, PcAnswers           Cable/      LoopbackPeerInspector
  Shell/Sessions/   ShellSessionManager + parts     HostState/  WindowsHostState, MessageWindow
  Shell/Recording/  TranscriptStore, ShellReplay    Security/   Elevation, AclFolder
  Shell/Access/     AccessStore
  Shell/Seams/      ISessionHost, IAccessAdmin,   native/iroh-bridge (Rust, cdylib)
                    IPty, IIrohEndpoint, …
  Session/          ShellGrantLedger, ShellGranter, DeviceChannel
  Threading/        SerialQueue
```

In this stage one process holds both halves. The **network-facing half** (`IrohShellListener`, `ShellGate`, `ShellConnection`, `AccessStore`, `ShellReach`, the iroh endpoint) only ever calls `ISessionHost`; the **tray UI and the cable grants** only ever call `IAccessAdmin`. Stage 4 lifts the network-facing half into the service and puts a pipe behind both interfaces.

`Passthrough.Windows` is created here (master plan §2 lists it) so the service in stage 4 can reference ConPTY-free pieces (iroh, peer checks, host state) without WinUI. `Passthrough.App` references it.

### 1. Threading: `SerialQueue`

The Swift host leans on serial dispatch queues; `HostSession` already uses the same idea (`HostSession.cs:38`). One small Core type carries it:

```csharp
namespace Passthrough.Core.Threading;

/// Runs work items one at a time, in the order posted. An item may be async: the next starts when it completes.
public sealed class SerialQueue : IAsyncDisposable
{
    public SerialQueue(string name, TimeProvider time, Action<Exception>? onError = null);
    public void Post(Action work);
    public void Post(Func<Task> work);
    /// Runs after `delay` (a TimeProvider timer, so tests advance it); the returned handle cancels it.
    public IDisposable PostAfter(TimeSpan delay, Action work);
    public Task RunAsync(Action work);          // posts and completes when it has run
    public Task<T> RunAsync<T>(Func<T> work);
    public bool IsCurrent { get; }              // for Debug.Assert in queue-confined code
    public void Suspend(); public void Resume(); // tests: hold back callouts, as ShellSessionManager.suspendCallouts
}
```

Queues in this stage, one-to-one with the Mac:

| Queue | Swift | Confines |
|---|---|---|
| `gate.Queue` | `ShellGate.queue` | limiter, admissions, every connection's state |
| `gate.Work` | `ShellGate.work` (serial on purpose) | `open` calls, so they run in arrival order and `Stop` drains them with one item |
| `manager.Queue` | `passthrough.shell.sessions` | session table |
| `manager.Callouts` | `passthrough.shell.callouts` | every event to attachments and change handlers, in order |

No `lock` is held across an await. No queue ever blocks on another (`RunAsync` from one queue to another is forbidden; use `Post` and a continuation that posts back).

### 2. Core types, each mapped to its Swift source

Names are the Swift names unless noted. "Preserve" lists the behaviours that tests pin.

#### 2.1 Protocol (`Shell/`)

Stage 1 lands `ShellEnvelope` in C# with the fixture round-trips. This stage needs these members to exist; anything stage 1 did not add is added in PR 3.

```csharp
public static class RemoteShell               // ShellProtocol.swift:6-38
{
    public const int DefaultPort = 7893;
    public const string ServiceType = "_passthrough-sh._tcp";
    public const string ProofLabel = "passthrough-shell-v1";
    public const int MaxSessions = 8;
    public const string SessionVariable = "PASSTHROUGH_SESSION";
    public const int MaxScreenViewsPerPhone = 2, MaxScreenViews = 4;
    public const int ScrollbackBytes = 1_048_576, OutputChunk = 16_384, LineLimit = 262_144;
    public static byte[] Proof(ReadOnlySpan<byte> shellKey, ReadOnlySpan<byte> nonce);
    /// Constant time (CryptographicOperations.FixedTimeEquals over the full HMAC).
    public static bool ProofIsValid(ReadOnlySpan<byte> mac, ReadOnlySpan<byte> shellKey, ReadOnlySpan<byte> nonce);
}
public static class IrohShell { public const string Alpn = "passthrough/shell/1"; }
public enum ShellError { NotAuthorized, TooManySessions, NoSuchSession, BadRequest, ScreenNotAllowed, ScreenUnavailable,
    ScreenVideoUnavailable, TooManyScreens, NotAllowed, VpnNotSetUp, ScreenOnly, PassNotSaved, SignedOut /* stage 1 */ }
public static class ShellErrorWire { public static string ToWire(this ShellError e); public static ShellError? Parse(string? s); }
public sealed record ShellSessionInfo(string Id, string Title, double StartedAt, double LastOutputAt, bool Running,
    int? ExitStatus = null, string? Waiting = null, string? Origin = null, ShellStatus? Status = null, string? Shell = null /* stage 1, if defined */);
public sealed record ShellStatus(string State, string? Kind, string? Message, int Agents, double Since, bool Seen);
public sealed record ShellHistoryEntry(string Id, string Title, string PhoneLabel, double StartedAt, double? EndedAt,
    int? ExitStatus, long Bytes, int? Cols, int? Rows);
public sealed record MacState(double? Battery = null, bool? Charging = null, bool? Locked = null, bool? Control = null /* others unused on a PC */);
public static class IrohInfo { MaxRelayLength = 256; MaxTokenLength = 512; MaxAddresses = 16;
    bool IsValidId(string); bool IsValidRelay(string); bool IsValidToken(string); bool AreValid(string? id, string? relay, string? token); }
public static class ShellAddressPolicy { … }   // ShellProtocol.swift:457-577, whole, with the fixtures' `shell.addresses`
```

`ShellAddressPolicy` is ported whole now (pure, has fixtures) though only `Advertisable` is reachable in this stage (it yields nothing: see 2.9). The Windows meaning of "tunnel interface" belongs to stage 4.

Encoding rule: `System.Text.Json`, nulls omitted, property names exactly the wire names, as `ControlEnvelope` does (`ControlEnvelope.cs:27-31`). `ExitStatus` is `int` on the wire; a Windows exit code is an unsigned 32-bit value and is cast unchecked (`0xC000013A` becomes `-1073741510`).

#### 2.2 `HandshakeLimiter`, `IProvenAddressStore` (`Shell/Host/`) ← `PhoneTransport/HandshakeLimiter.swift`

```csharp
public sealed class HandshakeLimiter
{
    public const int MaxHandshakes = 16, MaxHandshakesPerHost = 2, ReservedForProven = 4, ProvenLimit = 256;
    public static readonly TimeSpan ProvenFor = TimeSpan.FromDays(30), ResaveInterval = TimeSpan.FromHours(1);
    public HandshakeLimiter(SerialQueue queue, TimeSpan timeout, IProvenAddressStore store, TimeProvider time,
        int maxTotal = MaxHandshakes, int maxPerHost = MaxHandshakesPerHost, int reservedForProven = ReservedForProven);
    public Slot? Acquire(string host, int? maxForHost, Action onTimeout);
    public void Proven(string host);
    public int Count { get; }
    internal static string Bucket(string host);
    public sealed class Slot { public bool IsReleased { get; } public bool Release(); }
}
public interface IProvenAddressStore { IReadOnlyDictionary<string, DateTimeOffset> Load(); void Save(IReadOnlyDictionary<string, DateTimeOffset> proven); }
public sealed class MemoryProvenAddressStore : IProvenAddressStore;
public sealed class FileProvenAddressStore(IFileSystem files, string path) : IProvenAddressStore;   // JSON address → Unix seconds, written whole, tmp + rename
```

Preserve: a proven address is counted on its own key (`proven/<bare>`) and may use the 4 reserved slots; public IPv4 by /24, ULA and global IPv6 by /64, link-local IPv6 by its own address; `%zone` ignored; a stored date in the future counts as now; only IP addresses are remembered (the shared `relay` bucket never is); a slot frees once, whichever of release or timeout comes first; `onTimeout` runs only when the timeout won.

The iroh listener uses a `MemoryProvenAddressStore`, as the Mac's does (`IrohShellListener.swift:156-158` passes none). `FileProvenAddressStore` is ported and tested now and first used by stage 4's TLS listener.

#### 2.3 `ScreenViewLimit` ← `ShellListener.swift:351-381`

Ported as is (`Take(phoneId)`, `Release(phoneId)`, `Count`). Unused until stage 5; it is three methods and keeps `ShellConnection` the same shape as the Mac's.

#### 2.4 `ShellGate` ← `ShellListener.swift:387-673`

```csharp
public sealed class ShellGate
{
    public const int ProofLineLimit = 4096;
    public static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(10);      // WirelessLink.handshakeTimeout

    public ShellGate(string label, ISessionHost host, IAccessCheck access, Func<ShellEnvelope?> macInfo,
        Func<string, ShellEnvelope?> hostMessage,           // `host` for this phone (stage 1's message)
        TimeProvider time, IProvenAddressStore? proven = null, TimeSpan? handshakeTimeout = null);

    public SerialQueue Queue { get; }
    public SerialQueue Work { get; }
    public bool Accepting { get; }                           // false once Stop has begun (read off the queue)
    public Action<string>? OnSessionEvent { get; set; }      // "Jane's iPhone opened a session"; never what was typed

    // On the queue:
    public Admission? Admit(string host, int? maxForHost, Action abandon);
    public void Abandon(Admission admission);
    public void RunHandshake(Admission admission, Stream stream, bool expectHello);
    public void Stop();
    public void AfterWork(Action completion);
    public int PendingHandshakes { get; }
    public IReadOnlyList<(string PhoneId, Stream Stream, bool Viewing)> OpenStreams { get; }

    // Any thread:
    public void Disconnect(string phoneId);                  // close its connections, then (after Work) host.CloseSessions(openedBy)
    public void DisconnectShell(string phoneId);             // new: its Shell switch went off (same effect; kept apart for the log line)
    public void PushMacState(); public void PushHost(); public void PushSessions();
}

/// What the gate asks about a phone on every handshake and request. Answered from memory; must not block.
public interface IAccessCheck
{
    IReadOnlyList<byte[]> CandidateKeys(string phoneId);     // current first, then previous while accepted; empty for unknown
    void KeyConfirmed(string phoneId, byte[] proven);        // called off the gate's queue
    string Label(string phoneId);                            // "Phone" when unknown
    bool ShellAllowed(string phoneId);
    bool ScreenAllowed(string phoneId);
    bool IsScreenOnly(string phoneId);                       // true for any id starting "viewer."
}
```

Preserve, exactly:

- **Handshake**: over iroh the first line must be `{"t":"hello"}` within the proof line limit; then `challenge` with a fresh 32-byte nonce; the proof line is read with a hard 4096-byte limit (a longer newline-terminated line is refused too); bytes after the proof line are handed to the connection as `initialBytes`.
- **Two-key check at constant cost**: every proof is checked against exactly two keys. Missing keys (unknown phone, no previous key) and keys shorter than 32 bytes are replaced by 32 fresh random bytes, and both checks always run (`ShellListener.swift:566-576`). The first real key that matches wins.
- **`keyConfirmed`** is called only when the match was key 0 **and** a previous key exists, off the gate's queue (thread pool).
- **Refusal**: `{"t":"error","reason":"not_authorized"}`, slot released first, stream closed after the write, and closed again unconditionally 1 s later.
- **Timeout**: the admission's slot timing out cancels the stream, or runs `abandon` if no stream exists yet. A handshake result that arrives after the timeout is ignored (`admission.IsOver`).
- On success: slot released, `limiter.Proven(admission.Host)`, then the connection starts.
- `Stop` releases every pending slot, cancels every attempt, closes every connection, and refuses new ones.
- `PushMacState`, `PushHost`, `PushSessions` skip connections that carry the screen.

Reading a line from a `Stream` before the connection exists uses one helper, `LineReader.ReadLineAsync(Stream, int softLimit, ReadOnlyMemory<byte> buffered, CancellationToken)` returning `(line, rest)` (port of `WirelessLink.readLine`).

#### 2.5 `ShellConnection` ← `ShellListener.swift:677-1339`

Internal to Core. One per authorized stream; all state on `gate.Queue`.

```csharp
internal sealed class ShellConnection
{
    public const int SendBacklogLimit = 8 << 20;
    public static readonly TimeSpan ControlAnswerDelay = TimeSpan.FromSeconds(1);
    public const int HistoryLimit = 500;
    public long ConnId { get; }                 // unique per process; what ISessionHost knows this connection by
    public string PhoneId { get; }
    public void Start(ReadOnlyMemory<byte> initialBytes, ShellEnvelope? macInfo);
    public void Close();
    internal static ShellEnvelope HistoryReply(IReadOnlyList<ShellHistoryEntry> entries);   // newest 500, binary search to fit the line
}
```

Stream handling over a .NET `Stream` (the Swift `ByteStream` has callbacks; this is the equivalent):

- **Writer**: a per-connection unbounded channel of encoded lines and one writer task that calls `WriteAsync` then `FlushAsync` per line. `backlog` grows by the line length when queued and shrinks (on the queue) when its write completes; over 8 MiB the connection is closed ("a phone is not reading its output; disconnected"). A `then` continuation, when given, runs on the queue after that line's write completes.
- **Reader**: one task reading up to 65 536 bytes at a time. Before each read it awaits a gate (`AsyncManualResetEvent`) that the queue closes while `busy` and opens in `Resume()`. That is `readPaused`: a phone cannot pile up requests while one is being handled off the queue.
- **End**: read returning 0, any read or write exception, or `Close()` all lead to one `Close()` on the queue. `Close` disposes the stream; for iroh that is the graceful close in 3.2.

**Order after `ready`** (`ShellListener.swift:733-745` plus stage 1's `host`): `ready`, then `macInfo` if the provider returns one, then `host`, then `macState` if there is one, then `sessions`; then `initialBytes` are handled, then reading starts. A screen-only id gets `ready` and nothing else. This order is asserted byte for byte in tests; `host` must never precede `ready` (master plan §2, protocol changes).

**Requests.** `inbox` holds complete lines; `Drain()` handles them one at a time until one sets `busy`. A line over `LineLimit` closes the connection. A line that is not JSON, or has an unknown `t`, gets `bad_request` and the connection stays open.

| `t` | Handling on a PC (this stage) | busy |
|---|---|---|
| `ping` | `pong` | |
| `pong` | nothing | |
| `list` | `sessions` from `host.Sessions` (empty when the phone's Shell is off) | |
| `open` | needs `cols`, `rows` (else `bad_request` with `ref`). Shell off: `not_allowed` with `ref`. Else on `gate.Work`: if the connection has closed or the gate stopped accepting, `bad_request`; else `await host.OpenAsync(connId, phoneId, label, message.shell, cols, rows)`. Back on the queue: `opened` (`session`, `cols`, `rows`, `ref`), log "opened a session", then attach as below; or `error` with the host's reason and `ref`. Then `Resume()`. | yes |
| `attach` | needs `session`, `cols`, `rows`. Shell off: `not_allowed`. If attached elsewhere: `host.Detach(connId)`. Set `attached = id`, `generation = ++attachSeq`, then `await host.AttachAsync(connId, id, cols, rows, generation)`. `NoSuchSession`/`SignedOut`: `attached = null`, `error` with `session`. Ok: log "attached to a session". Then `Resume()`. | yes |
| `input` | `session` must equal `attached` and `data` must be base64, else `bad_request` with `session`. `host.Input(connId, id, bytes)`. | |
| `resize` | needs `cols`, `rows` (else `bad_request`). Applies to whatever is attached when the line is read; nothing attached: ignored. The `session` named is ignored. | |
| `close` | needs `session`; it must be in `host.Sessions` and running, else `no_such_session`. `host.Close(id)`; log "closed a session". | |
| `viewing` | needs `on`; `host.SetViewing(connId, on)`. No reply. | |
| `history` | Shell off: `not_allowed`. Else `await host.HistoryAsync()` off the queue, reply `HistoryReply(entries)` if still open, `Resume()`. | yes |
| `transcript` | needs `session`. Shell off: `not_allowed`. Reads the replay off the queue (not busy, as on the Mac), then sends `transcriptData` lines one at a time, each after the previous was written. Unknown session: `no_such_session`. | |
| `lock` | `await host.LockAsync()` is started; refused only when the host says it cannot (`not_allowed`). A `macState` goes to this connection 1 s later either way. | |
| `setAwake`, `setVPN` | `not_allowed` | |
| `events` | needs a finite `since` (else `bad_request`); answers `eventList` with that `since`, `events: []`, `battery: []` | |
| `push` | a registration that is not well formed (when `on` is not false) is `bad_request`, as the Mac; else `pushState` with `on: false` | |
| `screen` | `screen_unavailable` with `message` "Update Passthrough on this phone to see this PC's screen." (the `message` field is stage 1's) | |
| `screenVideo` | `screen_not_allowed` when the phone's Screen is off, else `screen_video_unavailable` | |
| `rdp` | `screen_not_allowed` when Screen is off, else `rdp_unavailable` with `detail` `service` (stage 1's values; the relay needs the service) | |
| `screenGrant`, `screenRevoke`, `screenPass` | `bad_request` | |
| anything else | `bad_request` | |

These PC answers live in one static class, `PcAnswers`, so the fixture test from stage 1 ("one test each") calls the same code the connection does.

A screen-only id (`viewer.`) gets `screen_only` for everything but `ping`/`pong`/`screenVideo`, checked before anything else (`ShellListener.swift:861-863`). A PC never mints such ids, so this is fail-closed dead code with one test.

**Events from the host** arrive on the manager's callouts queue and are re-posted to `gate.Queue`, where each is checked before it is written:

- `Output(connId, session, data)`: only if `session == attached`; split into `output` lines of at most 16 384 raw bytes.
- `Replaying`: only if attached to it; `{"t":"replaying","session":…}`.
- `Replayed`: `{"t":"attached","session":…}`.
- `Ended`: only if attached; `attached = null`; `ended` with `exitStatus`.
- `Detached(connId, session, generation)`: only if `session == attached` **and** `generation == this.generation` (a takeover of an earlier attach, queued before this one, is not ours); then `attached = null` and `detached`.

`Close()`: idempotent; clears the inbox, `host.Drop(connId)`, disposes the stream, tells the gate, logs "a phone disconnected".

#### 2.6 `IrohShellListener` ← `ShellHost/IrohShellListener.swift`

```csharp
public sealed class IrohShellListener
{
    public const string RelayBucket = "relay";
    public const int MaxRelayHandshakes = 8;
    public IrohShellListener(IIrohEndpoint endpoint, ShellGate gate);
    public ShellGate Gate { get; }
    public Action<Exception>? OnFailure { get; set; }        // the endpoint stopped accepting; on the gate's queue
    public void Start();                                     // one listener per endpoint
    public Task StopAsync();                                 // completes once no connection can open a session
    public Task<IReadOnlyDictionary<string, IrohPathKind>> ConnectionPathsAsync();   // direct beats relay beats unknown
    internal static (string Key, int? Max) Bucket(IrohPathKind path, string? ip);
}
```

Preserve: the accept loop never waits on a handshake (each incoming is handled in its own task); an attempt whose address QUIC has not validated is sent a retry, and refused if it cannot be asked; a slot is taken **before** the QUIC handshake, by the peer's IP on a direct path (per-host cap 2) and under `relay` (cap 8) otherwise; when no slot is free the attempt is refused without a handshake; at the timeout an attempt with no stream yet is cancelled so a late accept fails; after `Stop`, an accept already waiting refuses what it gets (`gate.Accepting` is false) and the loop ends; the endpoint is shut down by its owner after `StopAsync`.

#### 2.7 `ShellSessionManager` and its parts (`Shell/Sessions/`) ← `ShellSessionManager.swift`

Clients are known by `connId` (a `long`), not by object, because the same calls will cross a pipe in stage 4. The manager keeps, per client, whether it is looking (`SetViewing`) so nothing has to be asked synchronously of a client.

```csharp
public interface ISessionEvents      // called on the manager's callouts queue, in order
{
    void Output(long connId, string session, ReadOnlyMemory<byte> data);
    void Replaying(long connId, string session);
    void Replayed(long connId, string session);
    void Ended(long connId, string session, int exitStatus);
    void Detached(long connId, string session, ulong generation);
    void SessionsChanged();
    void StatusChanged(ShellSessionInfo session, bool looking);   // for a later notifications stage; unused now
}

public sealed class ShellSessionManager
{
    public ShellSessionManager(TranscriptStore transcripts, IPtyFactory ptys, IShellCatalog catalog, ISessionEvents events,
        TimeProvider time, TimeSpan? endedRetention = null /* 600 s */, TimeSpan? quietBeforeAsking = null /* 1.5 s */);

    public IReadOnlyList<ShellSessionInfo> Sessions { get; }               // a snapshot, replaced on every change (volatile read)
    public Task<string> OpenAsync(string phoneLabel, string? phoneId, string? shellId, int cols, int rows);   // throws ShellException
    public Task AttachAsync(string id, long connId, int cols, int rows, ulong generation);                    // throws ShellException(NoSuchSession)
    public void Detach(long connId);            // leave whatever it is attached to; it stays known (keeps `looking`)
    public void Drop(long connId);              // Detach, and forget the client
    public void SetViewing(long connId, bool on);
    public void Input(string id, ReadOnlyMemory<byte> data, long? from);
    public void Resize(string id, int cols, int rows, long? from);
    public void Close(string id);
    public void CloseSessions(string openedBy);
    public Task CloseAllAsync();                // ends every session; completes when transcripts are finished or after 5 s
    internal static bool EchoShows(string line, ReadOnlySpan<byte> output);
    internal static byte[] VisibleText(ReadOnlySpan<byte> data);
}
```

Dropped from the Mac's: `shared` viewers, `origin: .mac`, themes, `setOutputPaused`, `maxMacSessions` (all belong to terminals on the Mac itself; roadmap stage 7). The `active` / `followNext` / `attachmentSize` logic collapses to "the terminal follows its one attachment"; a `TerminalReports.Removing` pass on input stays (it decides what counts as typing).

Preserve:

- **Open**: ended sessions are pruned first; the cap (8) counts running sessions plus opens in progress; the spawn and the transcript's first write happen off the manager's queue with the slot reserved; `PASSTHROUGH_SESSION=<id>` is in the environment; if the transcript cannot begin, the process just started is terminated and the error thrown; the session id is an upper-case UUID string (`UUID().uuidString`).
- **Attach** (`:329-381`), in this order on the queue: a previous attachment that is a different client is told `Detached` with **its own** generation; the terminal takes the new client's size (recorded in the transcript as a resize); the replay is taken from the scrollback; **the redraw trick** runs when the session is running, the attach did not change the size, the replay is partial and the alternate screen is on; then callouts `Replaying`, the replay in 16 384-byte chunks as `Output`, `Replayed`; then, if the client is looking, a waiting result is marked seen; then the client becomes the attachment (running) or, for an ended session still listed, gets `Ended` after `Replayed`.
- **Replay in one go (#41)**: the host's part is only the order above: `Replaying` is queued before the first replay chunk on the same ordered queue as live output, so a phone can tell live output that raced the attach from the replay. Nothing may be sent between `Replaying` and `Replayed` for that client except the replay itself; live output produced meanwhile queues behind `Replayed` because both come from the manager's queue through the callouts queue.
- **Redraw** (`:538-553`): one at a time; needs more than one row; resize to one row fewer, and 0.25 s later back, unless the size changed meanwhile or the session ended. Both resizes are recorded in the transcript.
- **Input** (`:421-448`): answers to OSC 7501's question are stripped first (`TerminalReports.RemovingProgramStatusReplies`); what is left is written to the PTY; if anything in it is typing (not a terminal report): a waiting result is marked seen, the title is learnt, the question tail is emptied and `waiting` cleared.
- **Output** (`received`, `:585-600`), in this order: scrollback append, `outputCount`, transcript append, `lastOutputAt`, pending-title adoption, `ReadStatus`, question tail, then fan-out. **`ReadStatus` writes `ProgramStatus.SupportReply` into the PTY before the chunk is fanned out** (`:629-632`): the program's question must be answered ahead of the terminal's reply to the device-attributes request that follows it.
- **Title from echo** (`:786-878`): the title starts as the shell's display name ("PowerShell"; the Mac's is `~`). Typed printable bytes are collected (512 at most; escape sequences skipped whole; Ctrl-C and Ctrl-U start over; backspace removes one); on Return the trimmed line (60 characters at most) becomes a pending title with a window of 2048 output bytes; it is adopted only when the visible text of the output since the line began shows it on one line. A line typed at a no-echo prompt never becomes the title. Once known, the title is written to the transcript's `.json` and never changes.
- **Question detection** (`:604-623`, `:746-754`, `ShellQuestion.swift`): a 4096-byte tail of output since the last input; one pending look per session; it fires after 1.5 s of quiet (re-arming for the rest of the quiet time if output came meanwhile); skipped while the program reports its own status; the last 12 visible lines are read bottom-up for `[y/n]`, `(y/n)`, `[yes/no]`, `(yes/no)`, a line ending `password:` / `passphrase:`, `password for `, or a sentence ending `?` with at least two words and eight characters; cut to 120 characters.
- **Status** (`:667-704`): `since` is kept while the state is unchanged; `seen` is set when a `done`/`error` arrives while a client is looking, or stays set across a repeat; only changes that show (state, kind, seen, agents, a blocked message) raise `SessionsChanged` and `StatusChanged`; each summary in a chunk is applied in turn.
- **End** (`:756-780`): the transcript is finished with the exit status; every client gets `Ended`; the session stays listed (not running) for 600 s, or until an `open` prunes it.
- `waiting` in the listed info is the program's question while blocked (its message, or "Needs you"), else the heuristic's.

**"The program left"** (replaces `statusOwner` / `foregroundGroup` / `shellIsInFront`, which need process groups). `IPty.OtherProcesses()` returns the ids of the processes in the session's job other than the shell itself, or null when the PTY cannot tell (WSL). While the session has status records:

- On each output chunk, and every 2 s while there are records (a `PostAfter` on the manager's queue), read `others`.
- No owner yet: if `others` is empty, the reporter is already gone: drop all records (after applying the chunk's reports in turn, as the Mac does). Else owner = `others`.
- Owner set, and none of the owner's ids is in `others` any more: if this chunk changed no record, or `others` is empty, drop all records; else another program in front reported: owner = `others`.
- Records empty: owner cleared.

For a PTY that cannot tell (`OtherProcesses()` is null), `PromptReturn` decides (the master plan's "the prompt came back"): records are dropped when the summarized state is `working`, output has been quiet for 5 s (a working program animates), and the last visible line of the tail ends in `$`, `#`, `%` or `>` with optional trailing space; or when the state is `blocked`, something was typed since it became blocked, output has been quiet for 5 s and the last line looks the same. It is a heuristic, said so in the guide.

**Parts**, each a direct port with the Swift tests ported one for one:

| C# | Swift | Notes |
|---|---|---|
| `ScrollbackBuffer` (struct → sealed class) | `ScrollbackBuffer.swift` | 1 MiB; holds up to twice that and trims by copy; `IsPartial`; `Replay` starts after the first newline within 4096 bytes of the cut (else at the first UTF-8 lead byte) and is prefixed with `TerminalModes.Restoring` for the modes in force at that point |
| `TerminalModes` (struct) | `TerminalModes.swift` | alt screen 47/1047/1049; mouse tracking and encoding; switches 1, 7, 25, 66, 1004, 2004, 2031 with their defaults; application keypad; modifyOtherKeys; kitty keyboard flags and stack per screen (16 deep); `ESC c` resets all; DECSTR; never 2026. `Restoring` byte order as `:76-88` |
| `TerminalReports` | `TerminalReports.swift` | whole reports only; cut-off ones are left as typing |
| `ProgramStatus` (struct) | `ProgramStatus.swift` | `SupportReply` bytes exactly `ESC ] 7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth ESC \`; 4096-byte reports; 256 records; base64 `msg` ≤ 2048 bytes and `title` ≤ 192; id grammar; `clear`; summary rule |
| `ShellQuestion` | `ShellQuestion.swift` | trims box-drawing and marker characters |
| `PromptReturn` | new | above |

#### 2.8 `TranscriptStore`, `TranscriptWriter`, `ShellReplay` (`Shell/Recording/`) ← `TranscriptStore.swift`, `ShellReplay.swift`

See section 8.

#### 2.9 `ShellReach` ← `ShellReach.swift`

```csharp
public sealed record IrohRelayConfig(string? Url = null, string? Token = null);
public sealed record ShellReach(bool ReachAnywhere, string? EndpointId = null, string? HomeRelay = null,
    IrohRelayConfig? Relay = null, IReadOnlyList<string>? Addresses = null)
{
    public sealed record IrohDetails(string Id, string? Relay, string? Token);
    public IrohDetails? Iroh { get; }       // null while off or not up; custom relay with its token; else the home relay, and nothing until it is known
    public ShellEnvelope? MacInfo();        // null while the endpoint is on but has nothing to hand out; else addresses + iroh fields
}
```

On a PC in this stage `ReachAnywhere` is always true while Remote access is on (iroh is the only door) and `Addresses` is always empty (there is no listener to dial). `macInfo` is therefore `{"t":"macInfo","addresses":[],"irohID":…,"irohRelay":…,"relayToken":…}`, or not sent while the endpoint is starting.

#### 2.10 `AccessStore` (`Shell/Access/`) ← `ShellAccessStore.swift`

```csharp
public sealed record ShellPhone(string PhoneId, string Label, string PairingSlot, byte[] Key, byte[]? PreviousKey,
    DateTimeOffset GrantedAt, bool? Shell = null /* absent = on */, bool? Screen = null /* absent = off */, bool? MayShare = null /* absent = off */)
{
    public bool ShellAllowed => Shell ?? true;
    public bool ScreenAllowed => Screen ?? false;
    public override string ToString();     // never prints a key
}

public sealed class AccessStore : IAccessCheck
{
    public const string Slot = "shell.phones";
    public static readonly TimeSpan EmptyTtl = TimeSpan.FromSeconds(5);
    public AccessStore(ISecretStore secrets, TimeProvider time, Action<string>? log = null);
    public IReadOnlyList<ShellPhone> Phones { get; }
    public static byte[] NewKey();                                        // 32 random bytes
    public bool Record(ShellPhone phone);
    public void ConfirmCurrentKey(string phoneId, byte[] proven);
    public bool Relabel(string pairingSlot, string label);
    public bool SetShellAllowed(string phoneId, bool allowed);
    public bool SetScreenAllowed(string phoneId, bool allowed);
    public bool SetMayShare(string phoneId, bool allowed);
    public (bool Done, IReadOnlyList<ShellPhone> Removed) Revoke(string phoneId);
    public (bool Done, IReadOnlyList<ShellPhone> Removed) RevokeSlot(string pairingSlot);
    // IAccessCheck from memory
}
```

Stored form: one secret slot holding a JSON array, keys base64, dates ISO 8601 (`[{"phoneID":…,"label":…,"pairingSlot":…,"key":"…","previousKey":"…","grantedAt":"…","shell":true,"screen":false}]`), as the Mac keeps one Keychain item.

Preserve:

- Answers come from memory; the store is read once and after any failed write. A read that found nothing is trusted for 5 s only. The lock guarding the copy is never held across store I/O; writes serialize on their own lock; a read that began before a write does not install what it saw (`generation`).
- **`Record`**: refuses an id starting `viewer.` or `computer.` (those are the host's to mint; a phone claiming one must never turn it into phone access). For an id already present: refuses when the earlier record's `PairingSlot` differs (one paired phone must not take over another's access by naming it); else `PreviousKey = earlier.PreviousKey ?? earlier.Key` (dropped when equal to the new key: an unconfirmed earlier grant was never used, so the phone may hold only the key before it), and `Shell`, `Screen`, `MayShare` carry over (plugging in renews the key, not what the phone may do). Returns false when the stored list is unreadable (never overwritten) or the write failed.
- **`ConfirmCurrentKey`**: clears `PreviousKey` only when the current key is still the one proved; writes only when there is a key to drop.
- **Fail closed**: `Revoke`, and turning Shell or Screen off, take effect in memory first. If the write fails: a revoke deletes the whole slot rather than leave a revoked key stored, and if even that fails the ids are remembered (`unsavedRevokes`) and laid over every later read until a write succeeds; a switch turned off is remembered the same way (`unsavedShellOff`, `unsavedScreenOff`) and the caller is told so it can say "may come back when Passthrough restarts". A failed switch *on* changes nothing.
- A revoke that matches nothing writes nothing.

Not ported: screen passes and their second item (`grantViewer`, `supersede`, `revokeViewer`, `viewers`), `control`, and `move` (the Windows app never had the slot iPhones once shared). Computers (`computer.` ids, stage 7) will add their own records.

#### 2.11 `ShellGrantLedger` (`Session/`) ← `MacSessionPolicy.swift` (`ShellGrantLedger`)

```csharp
public sealed class ShellGrantLedger
{
    public static readonly TimeSpan AnswerTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan[] RetryDelays = [15 s, 30 s, 60 s, 120 s];
    public static readonly TimeSpan SlowRetryDelay = TimeSpan.FromSeconds(600);
    public static string Contents(string certificateSha256, int port, string macName, string? irohId, string? irohRelay, string? relayToken);
    public bool ShouldGrant(string deviceId, string contents, DateTimeOffset now);
    public static bool AnswerMatches(string? echoedGrantId, string inFlightGrantId);
    public bool IsHeld(string deviceId);
    public void Sent(string deviceId, string contents, string grantId);
    public bool Confirmed(string deviceId, string grantId);
    public Expiry Expired(string deviceId, string grantId, DateTimeOffset now);   // Stale | Retry(after, firstTimeout)
    public void ChannelClosed(string deviceId); public void ChannelOpened(string deviceId);
    public void Paired(string deviceId); public void Detached(string deviceId);
    public void Revoked(string deviceId); public void Reset();
}
```

**Fingerprint contents**, byte for byte as the Mac: the six values `certificateSHA256`, the port in decimal, `macName`, `irohID`, `irohRelay`, `relayToken`, each absent one replaced by `-`, each written as `<UTF-8 byte count>:<value>` and concatenated with nothing between. Addresses are not in it (they change with the network; phones learn them from `macInfo`). `hostKind` is not in it (it never changes on a PC). A test vector is taken from the Swift implementation and asserted in C#.

Back-off: one grant per device in flight; an answer that names another grant id is ignored; no answer in 15 s is a loss; consecutive losses of the same contents wait 15, 30, 60, 120 s then 600 s each (counted from the end of the 15 s); other contents start afresh; `ChannelOpened`, `Paired`, a confirmation or `Detached` clear the back-off; `Revoked` holds the device until `ChannelOpened` or `Paired`.

#### 2.12 The grant before the listener exists

Phones ignore a grant without a 64-hex `certSHA256` and a port (see *What exists today*). In this stage the PC sends:

- `certSHA256`: sixty-four `0` characters (`ShellGrantContents.NoListenerPin`). No certificate hashes to it, so even if something on the phone's network advertised `_passthrough-sh._tcp` under this PC's name, the phone's pinned TLS would refuse it.
- `shellPort`: 7893. `addresses`: `[]`.
- `macName`: `Environment.MachineName`, the same value the control channel's `hello` carries (`App.xaml.cs:96`), and the one source stage 4 must keep using for the DNS-SD instance name.
- `hostKind`: `windows` (stage 1's field).
- the iroh fields from `ShellReach.Iroh`, left out while the endpoint is not up.

When stage 4's service creates its TLS key the fingerprint changes and the ledger re-grants at the next cable connection, as the master plan says.

### 3. The seams

#### 3.1 `IPty`, `IPtyFactory`

```csharp
public sealed record PtyLaunch(string Executable, IReadOnlyList<string> Arguments, string WorkingDirectory,
    IReadOnlyDictionary<string, string> EnvironmentAdditions, int Cols, int Rows, bool TracksPrograms);

public interface IPtyFactory
{
    /// Starts the program on a new pseudoconsole. Throws PtyException (elevated host, pseudoconsole or process creation failed).
    IPty Start(PtyLaunch launch);
}

public interface IPty : IAsyncDisposable
{
    int ProcessId { get; }
    /// What the program wrote, in order, on one thread at a time. Set before Begin.
    Action<ReadOnlyMemory<byte>>? Output { get; set; }
    /// Once, after the last Output: the exit code (unchecked cast of the Windows exit code).
    Action<int>? Exited { get; set; }
    void Begin();
    /// Queued and written in order; never blocks the caller; dropped once the PTY is closed.
    void Write(ReadOnlyMemory<byte> data);
    void Resize(int cols, int rows);
    /// Process ids in the session's job besides the shell itself; null when this PTY cannot tell (WSL).
    IReadOnlyCollection<int>? OtherProcesses();
    /// Ends the session as closing its window does; anything still alive after 2 s is killed.
    void Terminate();
}
```

`EnvironmentAdditions` are laid over a fresh user environment by the factory; the manager never sees the full environment. Tests use `FakePty` (scripted output, recorded writes and resizes, settable `OtherProcesses`).

#### 3.2 `IIrohEndpoint` and friends: exactly what `IrohTransport/*.swift` uses

```csharp
public enum IrohPathKind { Unknown, Direct, Relay }

public interface IIrohEndpointFactory
{
    byte[] NewSecretKey();                                                           // IrohEndpointHost.newSecretKey
    /// Minimal preset: no n0 DNS or pkarr publishing or lookup, no mDNS; relay mode from `relay` (null Url: n0's defaults), or none at all.
    Task<IIrohEndpoint> BindAsync(byte[]? secretKey, IReadOnlyList<string> alpns, IrohRelayConfig relay, bool relayEnabled, CancellationToken ct);
}

public interface IIrohEndpoint : IAsyncDisposable                                    // IrohEndpointHost + IrohDialer
{
    string EndpointId { get; }                                                       // 64 lowercase hex
    string? HomeRelay { get; }                                                       // current; changes
    IReadOnlyList<string> DirectAddresses { get; }
    IReadOnlyList<string> LoopbackAddresses { get; }                                 // tests
    /// The next attempt, before any handshake. Throws IrohException(EndpointClosed) once shut down. One loop per endpoint.
    Task<IIrohIncoming> AcceptAsync(string alpn, CancellationToken ct);
    /// Connects and opens one bidirectional stream (stage 8's dialer; here for the loopback tests).
    Task<IrohStream> ConnectAsync(string endpointId, string? relayUrl, IReadOnlyList<string> addresses, string alpn, CancellationToken ct);
    Task ShutdownAsync();                                                            // idempotent; ends a pending AcceptAsync
}

public interface IIrohIncoming                                                       // IrohIncoming
{
    (IrohPathKind Path, string? Ip) Origin { get; }
    bool IsAddressValidated { get; }
    Task<bool> RetryAsync();          // false if it cannot be asked (it already came with a token)
    Task RefuseAsync();
    /// Completes the handshake, checks the ALPN, waits for the peer's first bidirectional stream.
    Task<IrohStream> AcceptStreamAsync(CancellationToken ct);
    /// Refuses if AcceptStreamAsync has not started; closes the connection if it finished; else fails it as soon as its handshake ends.
    void Cancel();
}

/// One bidirectional stream that owns its connection (IrohByteStream).
public abstract class IrohStream : Stream
{
    public abstract string RemoteId { get; }
    public abstract IrohPathKind PathKind { get; }
    public abstract string? RemoteIp { get; }
    /// Completes when the connection closes: null for a clean close (ours, or the peer's with code 0), else why.
    public abstract Task<IrohException?> Closed { get; }
}
```

`IrohStream` rules (the Swift class's, in `Stream` terms): reads return 0 once the peer finished its half; a read asks for at most 65 536 bytes; one read and one write in flight at a time (the callers above guarantee it; a second is an `InvalidOperationException`); `DisposeAsync` stops new reads and writes at once, finishes the send half, waits up to 2 s for the peer to acknowledge what was sent, then closes the connection with code 0, so "write the error line, then close" delivers the line; `Dispose` does the same without waiting on the caller's thread.

Core tests use `FakeIrohEndpoint` (in-memory duplex streams, scripted origins and validation). `Passthrough.Windows` implements the interfaces over the bridge.

#### 3.3 `ILocalAddresses`

```csharp
public sealed record LocalInterfaceAddress(string Address, string InterfaceName, bool IsTunnel, bool IsLoopback, int? PrefixLength);
public interface ILocalAddresses
{
    IReadOnlyList<LocalInterfaceAddress> All();
    IReadOnlyList<string> Advertisable();        // ShellAddressPolicy.Advertisable over All()
}
```

Defined now with a portable default (`System.Net.NetworkInformation`, `IsTunnel` false everywhere). Nothing in this stage reads it except `IAccessAdmin.GrantContentsAsync`, which ignores it while there is no listener. Stage 4 supplies the Windows implementation with the real meaning of "tunnel" and its fixtures.

#### 3.4 `ISessionHost`

What a connection needs from the Windows account that will run its shells. Per account; in this stage there is one.

```csharp
public interface ISessionHost
{
    // Cached; never a round trip.
    IReadOnlyList<ShellSessionInfo> Sessions { get; }
    event Action SessionsChanged;
    HostState State { get; }
    event Action StateChanged;

    Task<OpenResult> OpenAsync(long connId, string phoneId, string label, string? shellId, int cols, int rows, CancellationToken ct = default);
    /// `generation` is the caller's own number for this attach; it comes back in Detached.
    Task<AttachResult> AttachAsync(long connId, string session, int cols, int rows, ulong generation, CancellationToken ct = default);
    void Detach(long connId);
    void Drop(long connId);                                  // the connection is gone
    void Input(long connId, string session, ReadOnlyMemory<byte> data);
    void Resize(long connId, string session, int cols, int rows);
    void Close(string session);
    void CloseSessions(string openedByPhoneId);
    void SetViewing(long connId, bool on);

    /// One subscriber (the gate). Called in order; never while the host holds a lock.
    ISessionHostEvents? Events { get; set; }

    Task<IReadOnlyList<ShellHistoryEntry>> HistoryAsync(CancellationToken ct = default);
    /// The end of the session's recording (at most TranscriptStore.ReadLimit of output) in pieces of at most 64 KiB. Throws ShellException(NoSuchSession).
    IAsyncEnumerable<ShellReplayChunk> TranscriptAsync(string session, CancellationToken ct = default);

    Task<bool> LockAsync(CancellationToken ct = default);
    /// Keeping a pass to another computer's screen (stage 8). False here.
    Task<bool> SavePassAsync(string phoneId, string label, ShellCredential pass, CancellationToken ct = default);
}

public interface ISessionHostEvents
{
    void Output(long connId, string session, ReadOnlyMemory<byte> data);
    void Replaying(long connId, string session);
    void Replayed(long connId, string session);
    void Ended(long connId, string session, int exitStatus);
    void Detached(long connId, string session, ulong generation);
}

public readonly record struct OpenResult(string? Session, ShellError? Error);
public enum AttachResult { Ok, NoSuchSession, SignedOut }

public sealed record HostState(
    string Kind,                       // "windows"
    string Os,                         // "Windows 11 Pro (26300)"
    string User,                       // the account's sign-in name
    bool SignedIn,
    string Console,                    // "active" | "locked" | "signedOut" | "otherUser"
    int? IdleSeconds,
    IReadOnlyList<ShellChoice> Shells, // id, name, default
    IReadOnlyList<string> Screens,     // [] in this stage
    int? SleepAfter,                   // seconds; null: never
    double? Battery, bool? Charging, bool Locked);
public sealed record ShellChoice(string Id, string Name, bool Default);
```

Rules of the contract (they are what makes the pipe possible later):

- Every method is non-blocking: `Task`-returning or fire-and-forget. Fire-and-forget calls from one connection are applied in the order made.
- `connId` is the only identity. The host never sees a stream or an object.
- **Events and attach results are ordered on one stream.** Events for an attach may arrive before `AttachAsync` completes; that is safe because the caller chose `generation` before calling and set its own `attached` first.
- **Availability**: when the host goes away (in stage 4: the pipe drops), the holder of the interface raises `Detached` for every attached connection, sets `State.SignedIn` false and `Console` `signedOut`, empties `Sessions`, and answers `OpenAsync` with `SignedOut` and `AttachAsync` with `SignedOut`. Stage 3's in-process host never goes away, but `ShellConnection` is written and tested against a `FakeSessionHost` that does.
- `Output` data is valid only during the call; a subscriber copies or encodes before returning.

**In-process implementation, this stage:** `LocalSessionHost` (Core) wraps `ShellSessionManager`, `TranscriptStore`, `IShellCatalog`, `IHostStateSource` and `IScreenLock`. `OpenAsync` maps `ShellException` to `OpenResult`; an unknown `shellId` is `bad_request`; an elevated host is `bad_request` (and Remote access cannot be on in that state anyway). `HistoryAsync` and `TranscriptAsync` run on the thread pool. `SavePassAsync` returns false.

**What stage 4 puts behind the pipe:** every member above, one message each; `Sessions` and `State` become pushed snapshots cached in the service; `Output` is the hot path (raw bytes, length-prefixed, no JSON); `TranscriptAsync` is already chunked; `Events` becomes the pipe reader posting to `gate.Queue` in arrival order; a slow phone is still dropped by the gate's 8 MiB rule, and a full pipe drops that connection, never stalls `manager.Callouts`. Transcripts stay in the user's profile; the service asks for them.

#### 3.5 `IAccessAdmin`

The tray UI's and the cable granter's view of whoever holds the keys.

```csharp
public interface IAccessAdmin
{
    Task<AccessSnapshot> SnapshotAsync(CancellationToken ct = default);
    event Action Changed;                                            // re-read the snapshot

    /// What a cable grant must say right now, or null while there is nothing to hand out (Remote access off, endpoint starting).
    Task<GrantContents?> GrantContentsAsync(CancellationToken ct = default);
    /// Keeps the key of an answered grant. False: not stored, so the phone has no access (say so; plug in again).
    Task<bool> AddKeyAsync(string phoneId, string label, string pairingSlot, byte[] key, CancellationToken ct = default);
    Task RelabelAsync(string pairingSlot, string label, CancellationToken ct = default);

    Task<SwitchResult> SetShellAsync(string phoneId, bool on, CancellationToken ct = default);
    Task<SwitchResult> SetScreenAsync(string phoneId, bool on, CancellationToken ct = default);
    Task<SwitchResult> SetMayShareAsync(string phoneId, bool on, CancellationToken ct = default);
    /// Key first, then its connections, then the sessions it opened. Returns the pairing slots that lost access.
    Task<RevokeResult> RevokeAsync(string phoneId, CancellationToken ct = default);
    Task<RevokeResult> RevokeSlotAsync(string pairingSlot, CancellationToken ct = default);
    /// "Stop": drops its connections and ends the sessions it opened; access stays.
    Task DisconnectAsync(string phoneId, CancellationToken ct = default);

    // Machine-wide; in stage 4 these change only through the elevated step.
    Task<RemoteAccessSettings> SettingsAsync(CancellationToken ct = default);
    Task SetEnabledAsync(bool on, CancellationToken ct = default);
    Task SetRelayAsync(IrohRelayConfig relay, CancellationToken ct = default);
    Task ResetIdentityAsync(CancellationToken ct = default);
}

public sealed record AccessSnapshot(bool Enabled, IReadOnlyList<PhoneAccess> Phones, IReadOnlyList<SetupRow> Rows);
public sealed record PhoneAccess(string PhoneId, string Label, string PairingSlot, DateTimeOffset GrantedAt,
    bool Shell, bool Screen, bool MayShare, int Connections, IrohPathKind Path, int ShellsOpen, bool Viewing);
public sealed record SetupRow(string Id, SetupState State, string Text, string? Action);     // Id: "anywhere", "network", "screen", …
public enum SetupState { Done, Needed, Optional, Problem, Working }
public sealed record GrantContents(string CertificateSha256, int Port, IReadOnlyList<string> Addresses, string MacName,
    string? IrohId, string? IrohRelay, string? RelayToken)
{ public string Fingerprint { get; } public override string ToString(); /* no token */ }
public enum SwitchResult { Done, NotSaved /* off holds until restart */, Failed }
public sealed record RevokeResult(bool Done, IReadOnlyList<string> PairingSlots);
public sealed record RemoteAccessSettings(bool Enabled, string? RelayUrl, bool HasRelayToken, string? EndpointId, string? HomeRelay, EndpointState Endpoint, string? EndpointError);
public enum EndpointState { Off, Starting, Running, Failed }
```

**In-process implementation, this stage:** `LocalRemoteAccess` (Core) owns the `AccessStore`, the `ShellGate`, the `IrohShellListener`, the endpoint's lifecycle (4.3) and the current `ShellReach`. It implements `IAccessAdmin`. `Changed` fires on store writes, connections opening and closing, endpoint state, and a 5 s refresh of paths and home relay (the Mac's `startStatusRefresh`, `RemoteShellController.swift:517-544`).

**Stage 4:** the same interface over the pipe, every answer filtered by the caller's Windows account; `SetEnabledAsync`, `SetRelayAsync` and `ResetIdentityAsync` move behind the elevated step and the tray's implementation of them starts it.

### 4. `native/iroh-bridge`

Our own Rust library over the `iroh` crate, exposing only what 3.2 needs. First-party source; the DLL is built by script and in CI, never committed.

#### 4.1 Version to pin

`iroh-ffi` tag `v1.1.0` declares `iroh = "1.0.0"` and its committed `Cargo.lock` resolves **`iroh 1.0.2`** (with `iroh-base 1.0.2`, `iroh-relay 1.0.2`, `noq 1.0.1`, `tokio 1.52.3`); read from the tag while writing this plan. The bridge pins `iroh = "=1.0.2"` and matching `iroh-base`, `iroh-relay`, and commits its own `Cargo.lock`.

Confirm in the PR, and write the answer into the PR description:

1. `git clone --depth 1 --branch v1.1.0 https://github.com/n0-computer/iroh-ffi` and read `Cargo.lock` for `name = "iroh"`. That is what the Apple xcframework was built from.
2. Android: `computer.iroh:iroh-android:1.1.0` is published from the same repository and tag; check the POM's SCM tag on Maven Central.
3. Interop is the real test: the bridge's endpoint and a Mac's `IrohDialer` dial each other, direct and through a relay (the master plan's spike), before the listener PR merges.

When the phones move to a new `iroh-ffi`, the bridge's pin moves in the same PR series; CONTRIBUTING gains that line.

#### 4.2 Crate layout

```
native/iroh-bridge/
  Cargo.toml              name = "passthrough-iroh-bridge"; crate-type = ["cdylib", "rlib"]; edition 2021
                          [profile.release] panic = "unwind", lto = "thin", strip = "symbols"
  Cargo.lock              committed
  rust-toolchain.toml     exact stable channel, target x86_64-pc-windows-msvc, components rustfmt, clippy
  deny.toml               licences: MIT, Apache-2.0, BSD-2/3-Clause, ISC, Unicode-3.0, Zlib; sources: crates.io only; advisories: deny
  include/passthrough_iroh_bridge.h    the ABI, hand-written, the reference for the C# declarations
  src/lib.rs              the exports and nothing else; each is `guard(|| …)` (catch_unwind)
  src/abi.rs              codes, structs, constants; compile-time size and offset assertions
  src/handles.rs          the generation-checked table
  src/runtime.rs          tokio runtime, completion queue, cancellation
  src/endpoint.rs  src/incoming.rs  src/stream.rs  src/relay.rs  src/paths.rs
  tests/abi.rs            bad, stale and wrong-kind handles; double close; small buffers; cancel races
  tests/loopback.rs       two endpoints, relays off: accept, retry, refuse, wrong ALPN, read/write/finish, close codes, drain
  fuzz/                   cargo-fuzz; fuzz_targets/calls.rs: arbitrary sequences of exports with arbitrary arguments
```

Dependencies: `iroh`, `iroh-base`, `iroh-relay` (default features trimmed to what the minimal preset needs), `tokio` (rt-multi-thread, sync, time), `parking_lot`. No `uniffi`.

#### 4.3 Conventions

- **Every export** is `extern "C"`, returns `int32_t` (0 or a negative code), writes results through out-pointers, and runs inside `catch_unwind`. A panic returns `PTIRB_ERR_PANIC`; a panic inside an async task completes that operation with `PTIRB_ERR_PANIC`. Nothing unwinds across the boundary. The table's locks cannot be poisoned (`parking_lot`).
- **Handles** are `uint64_t`, never pointers. Layout: bits 63-56 kind (1 runtime, 2 endpoint, 3 incoming, 4 stream), bits 55-32 generation (never 0), bits 31-0 slot index + 1. Zero is never valid. A slot's generation is bumped when it is freed, so a stale or forged handle fails with `PTIRB_ERR_INVALID_HANDLE`. Looking a handle up clones an `Arc`, so a close on another thread cannot free what a running call uses.
- **Buffers are the caller's.** The bridge never returns memory to free. String and list getters take `(buf, cap, *len)`: on success `*len` is the byte count written (UTF-8, no terminator); when `cap` is too small they write nothing, set `*len` to what is needed and return `PTIRB_ERR_BUFFER_TOO_SMALL`. Input strings are `(ptr, len)` UTF-8, validated. Write data is copied before the call returns. The one pointer the bridge keeps past a call is a read's destination buffer, until that read completes (see `ptirb_stream_read`).
- **Async model: a completion queue, no callbacks.** The bridge never calls into managed code. Each asynchronous export takes a caller-chosen `uint64_t token` (non-zero, unique among pending operations of that runtime), starts a task on the runtime and returns at once. Exactly one completion per started operation is later returned by `ptirb_runtime_poll`. `ptirb_runtime_cancel(rt, token)` asks for cancellation; the completion still arrives exactly once (`PTIRB_ERR_CANCELLED`, or the real result if it finished first). After `ptirb_runtime_shutdown` every pending operation completes with `PTIRB_ERR_RUNTIME_SHUTDOWN` and poll then returns `PTIRB_ERR_RUNTIME_SHUTDOWN` itself.
- **Threads**: one tokio multi-thread runtime per runtime handle (2 workers by default). No export blocks except `ptirb_runtime_poll` (up to its timeout) and `ptirb_runtime_shutdown` (up to its timeout). All exports are safe to call from any thread, concurrently.

```c
typedef struct {            /* 32 bytes, little-endian, natural alignment */
    uint64_t token;
    int32_t  status;        /* 0 or a PTIRB_ERR_* */
    uint32_t kind;          /* PTIRB_OP_* : which operation completed */
    uint64_t value;         /* a new handle, or a byte count */
    uint64_t extra;         /* operation-specific */
} ptirb_completion;

typedef struct {
    const uint8_t* secret_key;   uint32_t secret_key_len;      /* 32, or 0 for an ephemeral key */
    const uint8_t* alpns;        uint32_t alpns_len;           /* '\n'-joined */
    uint32_t relay_mode;                                       /* 0 disabled, 1 n0 defaults, 2 custom */
    const uint8_t* relay_url;    uint32_t relay_url_len;       /* mode 2 */
    const uint8_t* relay_token;  uint32_t relay_token_len;     /* optional, mode 2 */
} ptirb_bind_options;

typedef struct {
    const uint8_t* endpoint_id;  uint32_t endpoint_id_len;     /* 64 hex */
    const uint8_t* relay_url;    uint32_t relay_url_len;       /* optional */
    const uint8_t* addresses;    uint32_t addresses_len;       /* '\n'-joined "ip:port", optional */
    const uint8_t* alpn;         uint32_t alpn_len;
} ptirb_connect_options;
```

Error codes:

| Code | Name | Meaning |
|---|---|---|
| 0 | `PTIRB_OK` | |
| -1 | `PTIRB_ERR_INVALID_HANDLE` | zero, stale, freed or wrong kind |
| -2 | `PTIRB_ERR_INVALID_ARGUMENT` | null where not allowed, bad UTF-8, bad length, token 0 or in use |
| -3 | `PTIRB_ERR_BUFFER_TOO_SMALL` | `*len` holds the size needed |
| -4 | `PTIRB_ERR_CANCELLED` | |
| -5 | `PTIRB_ERR_CLOSED` | the endpoint, connection or stream is closed |
| -6 | `PTIRB_ERR_PANIC` | a bug in the bridge; logged by the caller, the handle is unusable |
| -7 | `PTIRB_ERR_TIMEOUT` | poll: nothing completed in time (not a failure) |
| -8 | `PTIRB_ERR_WRONG_ALPN` | |
| -9 | `PTIRB_ERR_BIND` | |
| -10 | `PTIRB_ERR_CONNECT` | |
| -11 | `PTIRB_ERR_IO` | a stream read or write failed |
| -12 | `PTIRB_ERR_BUSY` | a read (or a write) is already pending on this stream |
| -13 | `PTIRB_ERR_RUNTIME_SHUTDOWN` | |
| -14 | `PTIRB_ERR_RELAY_CONFIG` | not an https URL the relay map accepts |
| -15 | `PTIRB_ERR_INVALID_KEY` | not 32 bytes, or not a valid endpoint id |
| -16 | `PTIRB_ERR_STATE` | the incoming was already accepted, retried or refused |

`ptirb_last_error_message(buf, cap, *len)` returns a thread-local, static-text description of the last failure on the calling thread, for the log. It never contains a key, a token or a peer's bytes.

#### 4.4 The exports

Synchronous unless marked **async** (those complete through the queue; `value`/`extra` as stated).

```c
/* library */
uint32_t ptirb_abi_version(void);                                         /* 1; the managed side refuses any other */
int32_t  ptirb_version(uint8_t* buf, uint32_t cap, uint32_t* len);        /* "passthrough-iroh-bridge 0.1.0 (iroh 1.0.2)" */
int32_t  ptirb_last_error_message(uint8_t* buf, uint32_t cap, uint32_t* len);

/* runtime */
int32_t  ptirb_runtime_new(uint32_t worker_threads /* 0 = 2 */, uint64_t* out_runtime);
int32_t  ptirb_runtime_poll(uint64_t runtime, ptirb_completion* out, uint32_t cap, uint32_t timeout_ms, uint32_t* out_count);
int32_t  ptirb_runtime_cancel(uint64_t runtime, uint64_t token);          /* OK even if already complete */
int32_t  ptirb_runtime_shutdown(uint64_t runtime, uint32_t timeout_ms);   /* closes every endpoint and stream; frees the handle */

/* keys */
int32_t  ptirb_secret_key_generate(uint8_t out_key[32]);
int32_t  ptirb_secret_key_endpoint_id(const uint8_t key[32], uint8_t out_hex[64]);

/* endpoint */
int32_t  ptirb_endpoint_bind(uint64_t runtime, uint64_t token, const ptirb_bind_options* options);        /* async: value = endpoint */
int32_t  ptirb_endpoint_id(uint64_t endpoint, uint8_t out_hex[64]);
int32_t  ptirb_endpoint_home_relay(uint64_t endpoint, uint8_t* buf, uint32_t cap, uint32_t* len);         /* len 0: none yet */
int32_t  ptirb_endpoint_direct_addresses(uint64_t endpoint, uint8_t* buf, uint32_t cap, uint32_t* len);   /* '\n'-joined */
int32_t  ptirb_endpoint_bound_sockets(uint64_t endpoint, uint8_t* buf, uint32_t cap, uint32_t* len);      /* '\n'-joined */
int32_t  ptirb_endpoint_accept(uint64_t endpoint, uint64_t token);                                        /* async: value = incoming; CLOSED once shut down */
int32_t  ptirb_endpoint_connect(uint64_t endpoint, uint64_t token, const ptirb_connect_options* options); /* async: value = stream (connect, then open_bi) */
int32_t  ptirb_endpoint_close(uint64_t endpoint, uint64_t token);                                         /* async: completes when closed; the handle is freed */

/* incoming: owned by the caller until retry, refuse, accept_stream or cancel consumes it */
int32_t  ptirb_incoming_origin(uint64_t incoming, uint32_t* out_path /* 0 unknown, 1 direct, 2 relay */,
                               uint8_t* ip_buf, uint32_t cap, uint32_t* len);                             /* ip only when direct */
int32_t  ptirb_incoming_address_validated(uint64_t incoming, uint32_t* out_validated);
int32_t  ptirb_incoming_retry(uint64_t incoming);                          /* frees it on success; STATE if it cannot be asked */
int32_t  ptirb_incoming_refuse(uint64_t incoming);                         /* frees it */
int32_t  ptirb_incoming_accept_stream(uint64_t incoming, uint64_t token, const uint8_t* alpn, uint32_t alpn_len);
                                                                            /* async: handshake, ALPN check, accept_bi; value = stream; frees the incoming */
int32_t  ptirb_incoming_cancel(uint64_t incoming);                         /* refuse if untouched; fail a pending accept_stream as soon as it can */

/* stream: owns its connection */
int32_t  ptirb_stream_read(uint64_t stream, uint64_t token, uint8_t* buf, uint32_t cap /* ≤ 65536 */);    /* async: value = bytes; 0 = the peer finished */
int32_t  ptirb_stream_write(uint64_t stream, uint64_t token, const uint8_t* data, uint32_t len /* ≤ 262144 */, uint32_t finish);
                                                                            /* async: completes when all of it is written (and the half finished) */
int32_t  ptirb_stream_closed(uint64_t stream, uint64_t token);             /* async: value = close kind, extra = application code */
int32_t  ptirb_stream_path(uint64_t stream, uint32_t* out_path, uint8_t* ip_buf, uint32_t cap, uint32_t* len);
int32_t  ptirb_stream_remote_id(uint64_t stream, uint8_t out_hex[64]);
int32_t  ptirb_stream_close(uint64_t stream, uint32_t drain_ms);           /* frees the handle at once; in the background: finish, wait for
                                                                              acknowledgement up to drain_ms, close the connection with code 0 */
```

Ownership, in one place: a handle belongs to the caller from the completion (or call) that produced it until the call documented as freeing it. `ptirb_runtime_shutdown` frees everything left. Freeing a stream with a read pending completes that read with `PTIRB_ERR_CLOSED` before the buffer may be reused; the managed side frees the buffer only after it has seen that completion.

Close kinds from `ptirb_stream_closed` (the numeric code that replaces the string matching in `IrohByteStream.isCleanClose`, `IrohByteStream.swift:199-205`): 0 closed locally; 1 closed by the peer's application (`extra` = its code); 2 closed by the peer's transport; 3 timed out; 4 reset; 5 other. Clean means kind 0, or kind 1 with `extra == 0`.

If a getter the ABI shows as synchronous is asynchronous in `iroh 1.0.2` (the Swift wrapper awaits `remoteAddr()` and `remoteAddrValidated()`), the bridge resolves it inside the accept task and stores the result with the incoming, so the ABI stays as written.

#### 4.5 The managed side (`Passthrough.Windows/Iroh/`)

- `IrohBridge`: `[LibraryImport]` declarations, `partial`, no marshalling of strings (spans and lengths). The library is loaded once by full path, `NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory, "passthrough_iroh_bridge.dll"))`, through `NativeLibrary.SetDllImportResolver`; the search path is never consulted. `ptirb_abi_version() != 1` throws `IrohException(Incompatible)` with "Passthrough's connection library doesn't match this build. Rebuild it with scripts\build-iroh-bridge.ps1."
- `IrohRuntime` (one per process, created on first use, shut down at quit with a 3 s limit): one background thread named `iroh-completions` loops on `ptirb_runtime_poll(rt, buffer[64], timeout 250 ms)`. Pending operations live in a `ConcurrentDictionary<ulong, PendingOp>`; tokens come from `Interlocked.Increment`. Each completion resolves a `TaskCompletionSource` created with `RunContinuationsAsynchronously`, so no continuation runs on the pump thread.
- **Blocking calls become tasks** like this: `StartAsync(kind, start, ct)` registers the pending operation, calls the export (a negative return removes it and throws), and registers `ct` to call `ptirb_runtime_cancel`. The task completes only from the pump, so a cancelled operation's resources are released exactly once: on `PTIRB_ERR_CANCELLED` the task is cancelled; if the operation won the race, a handle it produced is closed by the continuation.
- `IrohStreamImpl : IrohStream`: one native 64 KiB read buffer per stream (`NativeMemory.Alloc`), freed after the stream handle is closed and the last read has completed; `ReadAsync` copies out of it; `WriteAsync` pins the caller's memory for the duration of the export call only (the bridge copies).
- Every handle is wrapped in a `SafeHandle`-like class with a released flag, so a double dispose never reaches the bridge with a live handle value twice.

#### 4.6 Build and where the DLL lands

- `scripts/build-iroh-bridge.ps1` (beside `build-hev.sh`): checks `rustup` and the MSVC linker are present (prints what to install if not), runs `cargo build --locked --release --target x86_64-pc-windows-msvc --manifest-path native/iroh-bridge/Cargo.toml`, copies `target\x86_64-pc-windows-msvc\release\passthrough_iroh_bridge.dll` to `windows\native\win-x64\` (gitignored) and prints its SHA-256 and size.
- `Passthrough.Windows.csproj` includes `..\..\native\win-x64\passthrough_iroh_bridge.dll` as `Content` copied to the output folder, so it sits beside `Passthrough.exe` and beside the test assemblies. A target before build fails with "Build the connection library first: scripts\build-iroh-bridge.ps1" when the file is missing; `-p:SkipIrohBridge=true` builds without it (the app then shows *From anywhere* as a problem row: "This build has no connection library. Run scripts\build-iroh-bridge.ps1 and rebuild.").
- CI (the Windows job stage 1 adds): install the toolchain from `rust-toolchain.toml` (action pinned by commit, as every action in `ci.yml` is), `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test --locked`, `cargo deny check`, `cargo audit`, the script, then `dotnet test`. Fuzzing runs for 60 s per target on pull requests that touch `native/`.

### 5. ConPTY, jobs, the shell catalog

All in `Passthrough.Windows`.

#### 5.1 The package

`Microsoft.Windows.Console.ConPTY` (MIT), pinned to an exact stable version in `Passthrough.Windows.csproj` (1.25.261109001 was the newest stable on nuget.org when this was written; take the newest stable when the PR is opened and record it in `THIRD_PARTY_NOTICES.md`). It carries `conpty.dll` and `OpenConsole.exe` for x64; both are copied beside the app. `conpty.dll` is loaded by full path and starts the `OpenConsole.exe` next to it, so the terminal behaviour (OSC 52, OSC 7501, DCS pass-through) is the same on every Windows build.

A build target (`VerifyConPtySignature`) runs after restore on Windows: both files must carry a valid Authenticode signature whose signer subject is Microsoft Corporation; otherwise the build fails. The app checks nothing at run time (it runs from a folder the user owns in this stage; stage 4's install is where copies are verified).

If the bundled files are missing at run time the factory falls back to nothing: `Start` throws and the session is refused. There is no silent fallback to the inbox `CreatePseudoConsole`, because the two differ in what they pass through.

#### 5.2 `ConPtyFactory.Start(PtyLaunch)`

1. **Refuse when elevated.** `Elevation.IsElevated` (`GetTokenInformation(TokenElevation)` on the process token) throws `PtyException(Elevated)`. This covers "Run as administrator", UAC turned off for an administrator, and the built-in Administrator account.
2. Two anonymous pipes (`CreatePipe`): input (we write) and output (we read). Handles not inheritable.
3. `ConptyCreatePseudoConsole(COORD{cols, rows}, inputRead, outputWrite, 0, out hPC)`; then close our copies of `inputRead` and `outputWrite`.
4. **Job**: `CreateJobObject`, `SetInformationJobObject(JobObjectExtendedLimitInformation)` with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. No breakaway allowed.
5. **Environment**: `OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE)`, `CreateEnvironmentBlock(out block, token, bInherit: false)`: the account's own environment as a fresh sign-in would get it, with the machine's and the user's current `PATH`, and nothing from whatever launched the app. The block is parsed, `EnvironmentAdditions` are laid over it (`TERM_PROGRAM=Passthrough`, `PASSTHROUGH_SESSION=<id>`, and the shell's own from the catalog), re-encoded sorted case-insensitively as a double-null-terminated UTF-16 block, and `DestroyEnvironmentBlock` is called.
6. **Process**: `InitializeProcThreadAttributeList` with two attributes, `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` (hPC) and `PROC_THREAD_ATTRIBUTE_JOB_LIST` (the job), so the process is in the job from its first instruction. `CreateProcessW(lpApplicationName: the absolute executable, lpCommandLine: the quoted argument vector, bInheritHandles: false, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, the block, lpCurrentDirectory: launch.WorkingDirectory)`. `lpApplicationName` is always given, so nothing is searched for. The command line is built from the fixed vector with the standard quoting rules (backslashes before quotes doubled).
7. A reader thread per session reads the output pipe in 16 384-byte blocks and calls `Output`. A writer task drains a channel of input into the input pipe.
8. **Exit**: `RegisterWaitForSingleObject` on the process handle. When it fires: `GetExitCodeProcess`; `TerminateJobObject` (the shell is gone, what it left behind goes with it, as a hang-up does on the Mac); `ConptyClosePseudoConsole` from a thread that is not the reader (closing blocks until the output is drained, and the reader keeps draining); the reader sees the pipe end; then `Exited(code)` is raised once, after the last `Output`.
9. `Resize` → `ConptyResizePseudoConsole` (cols and rows clamped to 1…32767).
10. `OtherProcesses()` → `QueryInformationJobObject(JobObjectBasicProcessIdList)` minus the shell's id; null when `launch.TracksPrograms` is false.
11. `Terminate()` → `ConptyClosePseudoConsole` (console clients get the close event, as when a window is closed); 2 s later, if the process is still there, `TerminateJobObject(job, 1)`.
12. `DisposeAsync` → terminate if running, close every handle. If the app dies, the job handle closes with it and the kill-on-close limit ends every shell.

Working directory: the user's profile folder (`SHGetKnownFolderPath(FOLDERID_Profile)`); if it does not exist, the system drive's root.

Not ported from `PTYProcess`: reading paused by a slow local viewer (no local viewers yet).

**WSL** processes live outside the job: `OtherProcesses()` is null, `PromptReturn` stands in, and ending the session ends `wsl.exe` only. What runs inside the distro may carry on (WSL ends it when its last session closes). The guide says so, and says Revoke cannot promise to end it.

#### 5.3 The shell catalog

```csharp
public sealed record ShellEntry(string Id, string Name, string Executable, IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string> Environment, bool TracksPrograms);
public interface IShellCatalog
{
    IReadOnlyList<ShellEntry> Entries { get; }          // cached; the default first
    ShellEntry? Default { get; }
    ShellEntry? Find(string id);                        // ordinal, exact
    event Action Changed;
    void Refresh();                                     // re-runs discovery; called every 60 s while Remote access is on and before each open
}
```

Core holds `ShellCatalog` (ordering, default, lookup, id grammar `^[a-z0-9:._-]{1,80}$`, distro-name validation) over an `IShellCatalogSource`; `WindowsShellCatalogSource` does the discovery. Tests give Core a fake source.

**The trusted-location rule**, applied to every candidate: the path is absolute; after resolving links (`GetFinalPathNameByHandle`) it lies under `%ProgramFiles%`, `%ProgramFiles(x86)%` or `%SystemRoot%\System32` as the system reports those folders (known-folder API and `GetSystemDirectory`, never environment variables); and the file's owner is TrustedInstaller, SYSTEM or the Administrators group. Anything else is not listed. `PATH` is never searched, and `HKEY_CURRENT_USER` is never used to find an executable.

| Id | Name | Discovery | Arguments |
|---|---|---|---|
| `pwsh` | PowerShell | (1) `%ProgramFiles%\PowerShell\7\pwsh.exe`; (2) `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe`; (3) the Store package: `PackageManager.FindPackagesForUser("", "Microsoft.PowerShell_8wekyb3d8bbwe")`, newest version, `InstalledLocation\pwsh.exe` (under `%ProgramFiles%\WindowsApps`, which users cannot write). **Never** `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe` (the alias, in a folder the user can write) and never `%USERPROFILE%\.dotnet\tools` | `-NoLogo` |
| `powershell` | Windows PowerShell | `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` | `-NoLogo` |
| `cmd` | Command Prompt | `%SystemRoot%\System32\cmd.exe` | none |
| `wsl:<name>` | the distro's name | `%SystemRoot%\System32\wsl.exe` must exist. Distros from `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{guid}`: `DistributionName` where `State` is 1. Only the **names** are read from there. A name must match `^[A-Za-z0-9._-]{1,64}$`. Left out: `docker-desktop`, `docker-desktop-data`, `rancher-desktop`, `rancher-desktop-data`, and anything starting `podman-machine-`. The default distro (`DefaultDistribution`) is listed first among them | `--distribution <name> --cd ~` |
| `gitbash` | Git Bash | `HKLM\SOFTWARE\GitForWindows` `InstallPath` (64-bit view, then the 32-bit one) → `<InstallPath>\bin\bash.exe`. A per-user Git install is not listed | `--login -i` ; environment `TERM=xterm-256color` |

WSL also gets `WSLENV` extended with `TERM_PROGRAM/u:PASSTHROUGH_SESSION/u` so both variables reach the Linux side. `TracksPrograms` is false for `wsl:*`, true otherwise.

The Store package's folder changes with every update, so the catalog is refreshed before each open and the entry's path is checked to exist at that moment; an entry that has gone is dropped and the open answers `bad_request`.

**Default**: `pwsh` when found, else `powershell`. The last choice per computer is the phone's to remember (master plan §1).

**How `open.shell` maps to it**: absent → `catalog.Default`; present → `catalog.Find(value)`; no match → `error` `bad_request` with the `ref`. The string from the wire is used as a dictionary key and for nothing else: the executable, the arguments and the distro name all come from the entry the PC built. `host.shells` is `catalog.Entries` as `{id, name, default}`.

If launching the Store package's real `pwsh.exe` is refused for an unpackaged process (see *Risks*), the fallback is a verified alias: read the alias's reparse data (`IO_REPARSE_TAG_APPEXECLINK`), require its package family name to be `Microsoft.PowerShell_8wekyb3d8bbwe` and its target to be the package's installed `pwsh.exe`, then launch the alias. An unverified alias is never launched.

### 6. The cable peer check

Before the PC proves anything on a control channel it finds out who owns the far end of its loopback connection. The result gates grants only; pairing goes ahead either way (master plan §2, "Cable grants need a real peer").

```csharp
// Core
public enum PeerVerdict { Genuine, NotGenuine, Unknown }
public interface ILoopbackConnection { System.Net.IPEndPoint Local { get; } System.Net.IPEndPoint Remote { get; } }
public interface ICablePeerInspector { PeerVerdict Inspect(WatchTransport transport, Stream stream); }
```

- `ByteStreamConnector.OwnedTcpStream` implements `ILoopbackConnection` (it holds the `TcpClient`). `UsbMuxClient.ConnectAsync` and `AdbClient.ConnectAsync` already return that same stream, so the control channel's stream exposes the endpoints of the socket to port 27015 or 5037.
- `ControlClient` takes an optional `Func<Stream, PeerVerdict>` and calls it once, right after the stream opens and before `hello` is written. The verdict is the first event (`ControlEvent.Opened(PeerVerdict)`) and is kept in the client: `GrantShell` returns false and sends nothing unless it is `Genuine`.
- `LoopbackPeerInspector` (`Passthrough.Windows/Cable/`), fail closed at every step:
  1. `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_CONNECTIONS, AF_INET)`; find the row with local address 127.0.0.1, local port = the service's port (our `Remote.Port`), remote address 127.0.0.1, remote port = our `Local.Port`. Its `dwOwningPid` is the process that accepted our connection. No row: `Unknown`.
  2. **usbmux (27015)**: `OpenSCManager(SC_MANAGER_CONNECT)`, `OpenService("Apple Mobile Device Service", SERVICE_QUERY_STATUS)`, `QueryServiceStatusEx(SC_STATUS_PROCESS_INFO)`. Require state running and its process id equal to the row's. Read the table row again, then the service status again: both must still say the same process (a process id cannot be handed to a new process while the service still reports it running). No process is opened.
  3. **adb (5037)**: `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, pid)`; a refusal is `NotGenuine` (another account's process). With the handle held (so the id cannot be reused): `OpenProcessToken(TOKEN_QUERY)`, `GetTokenInformation(TokenUser)` must equal the current user's SID, and `TokenSessionId` must equal our session; then read the row again and require the same process id.
  4. Any API failure: `Unknown`. `Unknown` and `NotGenuine` both mean no grant.
- What the user sees for a phone that paired but did not pass: the row's message is "Paired. This PC can't confirm the cable link is Apple's own service, so it isn't handing out shell access. Restart Apple Devices, then plug the iPhone in again." (adb: "…can't confirm adb is running as you… Close other copies of adb, then plug the phone in again."). The log gets one line with the verdict and the transport, no ids beyond the device's.
- On other operating systems (tests) the inspector is a fake.

### 7. Changes to existing code

#### 7.1 `LogText.Redact` (first PR, before anything new logs)

- Keep the 43-character rule.
- Add: a run of exactly 43 standard-base64 characters followed by `=` (a 32-byte value: shell key, iroh secret key), with or without URL-safe letters: `(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{43}=(?![A-Za-z0-9+/=_-])`.
- Add: a run of exactly 64 hex digits is **not** redacted (endpoint ids and certificate hashes are public and useful in a log).
- Add: registered secrets. `LogText.Register(string secret)` keeps up to 16 exact strings (the relay token as typed, and its URL-encoded form); `Redact` replaces any occurrence. `Unregister` when the token changes. Strings shorter than 8 characters are replaced only at word boundaries.
- Add: `Authorization: Bearer <anything up to whitespace>` → `Authorization: Bearer (redacted)`, and `relayToken":"…"` in any JSON text.
- Every record type that holds a secret overrides `ToString` (`ShellPhone`, `GrantContents`, `IrohRelayConfig`, the `ShellGrant` event), as `ControlIdentity` does (`ControlIdentity.cs:10-11`).

#### 7.2 `ControlClient`

```csharp
public sealed class ControlClient(Func<CancellationToken, Task<Stream>> open, ControlIdentity identity, string deviceKind,
    TimeProvider time, Func<Stream, PeerVerdict>? inspect = null) : IAsyncDisposable
{
    /// Hands the phone a shell key and how to reach this PC. False (nothing sent) unless the phone has proved the pairing
    /// on this channel and the cable peer check said Genuine. `grantId`: 1 to 64 UTF-8 bytes.
    public bool GrantShell(byte[] shellKey, GrantContents contents, string grantId);
}
public abstract record ControlEvent {
    public sealed record Opened(PeerVerdict Peer) : ControlEvent;                     // first event of a channel that opened
    public sealed record ShellGranted(string PhoneId, string? GrantId) : ControlEvent;
    … }
```

- `GrantShell` runs under `_gate`: `!_closed && _authenticated && _peer == Genuine`, then queues `shellGrant` with `grantID`, `shellKey` (base64), `certSHA256`, `shellPort`, `addresses`, `macName`, `irohID`, `irohRelay`, `relayToken`, and stage 1's `hostKind: "windows"`.
- `Handle` gains `case ControlEnvelope.ShellGranted`: only when `_authenticated`, `phoneID` non-empty and at most 64 characters (`ControlClient.swift:223-226`); `grantID` passed through as sent. It does not count as the phone "being there" for the silence limit (only answers do, `ControlClient.cs:238`); add `ShellGranted` to that list, since it is an answer.
- Nothing else about the handshake changes.

#### 7.3 `HostSession`: a channel to every attached device

**Decision: one control channel per attached device, not the Mac's single channel lent to an iPad.**

The Mac has one channel because its tunnel rides on it and only one phone carries its internet; pairing an iPad means taking the channel away from the phone for up to three minutes, with a button, a timeout and a hand-back (`SessionCoordinator.swift:406-452`). The PC carries no internet through a phone yet, and when it does (roadmap stage 4 of the old list) the tunnel needs only that *one* device's channel to be special. Each phone's control server serves the PC that connects to it independently, so nothing in the protocol requires one channel. Per-device channels mean: an iPad pairs like any phone, two phones on two cables both get and renew their grants without "Use this phone", there is no lending state machine to port and test, and a relay change reaches every attached device at once. The cost is a refactor of `HostSession`'s single-active fields into a per-device object, which the grants need anyway (one pending grant per device).

Changes:

- New `Session/DeviceChannel.cs`: everything `HostSession` keeps for "the active phone" today, per device: client, state, status and counters, message, reason, held, reconnect timer and sequence, failures, last logged line, opened-at, has-credential, welcomed, unsent code, **peer verdict**, **pending grant** `(key, grantId, contents)`, **grant timers**. `HostSession` keeps `Dictionary<string, DeviceChannel>` and the single work loop.
- A channel is opened for every attached device, paired or not (an unpaired one needs it to take a code). The existing rules apply per device unchanged: reconnect back-off (`HostSession.cs:25`), the hold on a failed proof, the re-open of a channel the phone closed after 10 s unpaired (`:446-454`), the unsent code.
- `IsActive` stays in `PhoneEntry` as a marker only: the first attached device that can route, or the one `MakeActiveAsync` chose. It decides the flyout header and, later, which phone carries internet. It no longer decides who has a channel. `RetryAsync(phoneId)` reopens that device's channel.
- `PhoneState.RemoteOnlyLater` and `IPadMessage` are removed; an iPad's row goes through NotPaired → Pairing → Paired like a phone's. `PhoneRowModel` and `FlyoutHeader` lose that case; "Use this phone" is never shown for an iPad.
- `SubmitCodeAsync(phoneId, attachment, code)` addresses any attached device, not only the active one.
- `PhoneEntry` gains `ShellAccess` (`None`, `Granted`, `Waiting`, `Refused(reason)`), for the row's second line.

**Granting** (`Session/ShellGranter.cs`, on `HostSession`'s loop; port of `SessionCoordinator.swift:545-596`, `:601-605`, `:845-868`):

```csharp
internal sealed class ShellGranter(IAccessAdmin access, ShellGrantLedger ledger, TimeProvider time, Action<string> log)
{
    public Task ConsiderAsync(DeviceChannel channel);                 // "sendShellGrant"
    public Task OnShellGrantedAsync(DeviceChannel channel, string phoneId, string? grantId);
    public void OnChannelOpened(DeviceChannel c);  public void OnChannelClosed(DeviceChannel c);
    public void OnPaired(DeviceChannel c);         public void OnDetached(string deviceId);
    public void OnAccessRevoked(IReadOnlyCollection<string> pairingSlots, IEnumerable<DeviceChannel> attached);
    public void Reset();                                               // Remote access turned on again
}
```

- `ConsiderAsync` sends a grant when all hold: the channel's state is Paired; its peer verdict is Genuine; `await access.GrantContentsAsync()` is not null (Remote access on and the endpoint has something to hand out); `ledger.ShouldGrant(deviceId, contents.Fingerprint, now)`. Then: key = `AccessStore.NewKey()`, grant id = a new GUID string, remember the pending grant on the channel, `ledger.Sent`, `client.GrantShell`, and a timer for `AnswerTimeout`.
- The timer: `ledger.Expired`. `Stale`: nothing. `Retry(after, first)`: drop the pending grant if it is still this one, log once per streak ("the iPhone did not confirm its shell key in 15 s; it may not have stored it. Trying again in N s", the first at warning weight), and call `ConsiderAsync` after `after + 0.5 s`.
- `OnShellGrantedAsync`: no pending grant: ignore. `ShellGrantLedger.AnswerMatches(grantId, pending.GrantId)` false: ignore (an answer to an earlier grant). Clear the pending grant. `ledger.Confirmed` false (revoked meanwhile): call `ConsiderAsync` unless held, and stop. Else `await access.AddKeyAsync(phoneId, label: status?.DeviceName ?? kind label, slot, key)`; on false the row says "Couldn't save shell access for *label*. Plug it in again to retry."; then `ConsiderAsync` again (the contents may have changed while this one was in flight).
- Ledger calls, as the Mac makes them: `ChannelOpened` when a channel is opened; `ChannelClosed` when it ends; `Paired` on `PairedWith`; `Detached` when the device is unplugged; `Revoked` for attached devices whose slot lost access (and their pending grant is dropped so a late answer cannot record that key); `Reset` when Remote access is turned on and when a pairing is forgotten.
- Triggers for `ConsiderAsync` on every channel: a channel reaching Paired; `IAccessAdmin.Changed` when the grant fingerprint differs from the last one seen (endpoint up or down, home relay learnt, relay setting, identity reset); Remote access turned on.
- Each `StatusUpdate` calls `access.RelabelAsync(slot, deviceName)` when the name differs from the last one sent for that slot (`SessionCoordinator.swift:887`).

Stage 4 changes nothing here except what stands behind `IAccessAdmin`.

#### 7.4 `ForgetAsyncCore`, `PairedSlotsAsync`, `PairedPhone.List`

- `ForgetAsyncCore(slot)`: after deleting the token and the name, `await access.RevokeSlotAsync(slot)` (keys gone first, then that phone's connections, then the sessions it opened), `granter.Reset()` for that device, and the existing reopen rule. A failed revoke is reported through `Error` and shown in Settings ("Couldn't remove the forgotten phone's shell access."); the token is still gone.
- `PairedSlotsAsync` returns only slots starting `token.`. Shell secrets live in another folder (7.5), so this is a second fence.
- `PairedPhone` gains `Access` (`null`, or `Shell`/`Screen` as granted) and `PairedPhone.List(slots, savedName, accessBySlot)` fills it, so Settings ▸ Paired phones can say "Has shell access" under a pairing and the Forget dialog can say what goes with it. A slot that is not `token.*` is skipped, never listed.

#### 7.5 Settings and secrets: the per-user layout now, the hand-over later

| What | Where (stage 3) | Key | Stage 4 |
|---|---|---|---|
| Cable pairing tokens | `%LOCALAPPDATA%\Passthrough\secrets\` (DPAPI, current user) | `token.*` | stay with the user |
| Phones with access, with their keys | `%LOCALAPPDATA%\Passthrough\host-secrets\` (a second `DpapiSecretStore`) | `shell.phones` | handed to the service on first connect, then the folder is deleted |
| iroh endpoint secret key (base64 of 32 bytes) | `host-secrets` | `iroh.secretKey` | handed over with it |
| Relay token | `host-secrets` | `iroh.relayToken` | handed over |
| Remote access on/off | `settings.json` | `remoteAccess` = `true`/`false` (absent: false) | moves to the service's settings |
| Relay URL | `settings.json` | `relayUrl` (absent or empty: the public relays) | moves |
| History retention (days; 0 forever) | `settings.json` | `historyRetentionDays` (absent: 30) | stays with the user |
| Grant notice not yet acknowledged | `settings.json` | `notice.granted.<phoneID>` = ISO time | stays |
| Transcripts | `%LOCALAPPDATA%\Passthrough\ShellHistory\` | | stay |

One folder, `host-secrets`, holds exactly what the service will own, so the hand-over is "read these three slots, give them to the service over the pipe, delete the folder" and nothing else has to be untangled. The store interface is unchanged (`ISecretStore`); `AccessStore` and the endpoint's owner get the `host-secrets` instance, `HostSession` keeps the `secrets` one.

The Remote access switch and relay setting are per Windows account in this stage. Stage 4 makes them machine-wide; on its first run it takes this account's values as the starting point.

### 8. Recording

#### 8.1 `TranscriptStore` and `TranscriptWriter` ← `TranscriptStore.swift`

```csharp
public sealed class TranscriptStore
{
    public const long CastLimit = 64L << 20;          // one session's cast file; then a marker and recording stops
    public const int ReadLimit = 8 << 20;             // most output one read returns: the end of the session
    public const long MaxTotalBytes = 2L << 30;       // the folder; past it the oldest finished sessions go
    public const long SizeCheckpoint = 1 << 20;       // the size is restated at least this often
    public TranscriptStore(ITranscriptFiles files, string directory, TimeProvider time, long castLimit = CastLimit, long sizeCheckpoint = SizeCheckpoint);
    public TranscriptWriter Begin(string id, string title, string phoneLabel, int cols, int rows, DateTimeOffset at);
    public IReadOnlyList<ShellHistoryEntry> Entries();                       // newest first; only changed .json files are decoded again
    public IReadOnlyList<ShellReplayChunk> Replay(string id, int maxBytes = ReadLimit);
    public byte[] Output(string id, int maxBytes = ReadLimit);
    public void Delete(string id); public void DeleteFinished(); public void DeleteAll();
    public int Prune(DateTimeOffset? endedBefore, long maxBytes = MaxTotalBytes);
    public long TotalBytes();
}
public sealed class TranscriptWriter
{
    public void Append(ReadOnlySpan<byte> data, DateTimeOffset at);
    public void Resize(int cols, int rows, DateTimeOffset at);
    public void SetTitle(string title);
    public void Finish(int? exitStatus, DateTimeOffset at);
    internal bool IsRecording { get; }
}
```

`ITranscriptFiles` is a small seam (create-exclusive, append, random-access read, list with size and modified time, delete) with a physical implementation and a memory one for tests; `IFileSystem` (`Storage/IFileSystem.cs`) has no random access or listing and stays as it is.

Format, identical to the Mac's so the same viewers read both: `<id>.cast` is asciicast v2. First line the header `{"version":2,"width":cols,"height":rows,"timestamp":unix,"title":…}`; then one JSON array per line: `[seconds, "o", text]` for output and `[seconds, "r", "COLSxROWS"]` for a size. `<id>.json` is the `ShellHistoryEntry`.

Preserve:

- Sizes clamped to 1…1000 (`ShellReplay.Clamp`). A resize to the same size writes nothing.
- Output is written as text: an incomplete UTF-8 sequence at the end of a chunk (at most 3 bytes) is held for the next chunk; invalid bytes become U+FFFD, as `String(decoding:)` does.
- The size is restated whenever 1 MiB of cast has passed since it was last written.
- At `CastLimit - 128` bytes the marker `"\r\n[transcript truncated]\r\n"` is written as a last output event and recording stops; the session carries on.
- `Replay` reads **backwards** from the end in 256 KiB blocks, never the whole file: it takes output until `maxBytes`, then keeps looking back up to 2 MiB for the size in force at the cut, else takes the header's; consecutive sizes collapse to the last; the oldest output piece is cut on a character boundary; a line over 16 MiB stops the read. The result starts with a size.
- `Begin` and the deletes share one lock so files exist only once their writer is registered; `Prune` reads the folder outside that lock, takes it only around the deletes, checks each session again there (one begun mid-scan stays), and one prune runs at a time.
- A session never seen to end counts as ending when its files were last written.
- Ids become file names: an id that is empty or contains `/`, `\`, `:` or `..` is refused.

`ShellReplay` ← `ShellReplay.swift`: `ShellReplayChunk` (output or resize), `IsValid`, `Clamp`, `SizeString`, `ParseSize`, `TranscriptLines(session, chunks, chunkSize = 16384)` (a size rides on the line whose data follows it; `done: true` on the last; an empty replay is one empty `done` line).

#### 8.2 Location and ACLs

`%LOCALAPPDATA%\Passthrough\ShellHistory\`. Created by `AclFolder.EnsureOwnerOnly(path)` in `Passthrough.Windows`: inheritance off, one rule, full control for the current user, applied to the folder at creation and re-applied to an existing folder (the Mac's 0700 and its "tighten it too"). Files inherit it. `%LOCALAPPDATA%` is not roamed and not in OneDrive's known-folder backup, which is the Mac's "excluded from backups" in Windows terms; the guide says a third-party backup of the whole profile will include it.

Nothing in a transcript is ever logged.

#### 8.3 Retention and pruning

`historyRetentionDays`: 7, 30 (default), 90, or 0 for forever, the Mac's choices (`RemoteShellController.swift:119-138`). Pruned at launch, when the setting changes, and whenever a session ends: finished sessions that ended before the cut-off go, then the oldest finished ones until the folder is within 2 GiB. A session still recording is never deleted, whatever its age or size.

#### 8.4 The history window

A window opened from Settings ▸ Remote access ▸ **Session history…** (`HistoryWindow.xaml`):

- A list, newest first: title, phone, started, length, size; a running session is marked "Recording" and cannot be deleted.
- Selecting one shows its text in a read-only, monospaced, scrolling box: the replay's output with escape sequences removed (`TranscriptText.Plain`: CSI, OSC, DCS dropped; CR/LF normalized; the last 8 MiB at most), with a line above it saying "Plain text of the end of the session. Colours and full-screen programs aren't drawn here." There is no terminal emulator in the Windows app in this stage.
- **Open file** shows the `.cast` in Explorer (any asciinema player reads it); **Delete**; **Delete all finished…** ("Delete the recordings of every finished session? Running sessions keep recording." **Delete** · **Cancel**).
- A footer: "Kept for 30 days · 412 MB on this PC" with the retention choice.

### 9. Lifecycle: `LocalRemoteAccess`

Port of `RemoteShellController.start/stop`, the iroh run and `IrohRun`, as one state machine on its own `SerialQueue` (`lifecycle`).

- **Turn on** (`SetEnabledAsync(true)`): refuse when elevated; save the setting; turn Start at login on (`StartupRegistration.SetEnabled(true)`), since shells need the tray app running; `granter.Reset()`; start the endpoint.
- **Start the endpoint**: state Starting. Load `iroh.secretKey` (a stored value that is not 32 bytes is an error: "the built-in identity is unreadable; reset it"), or make one and store it first (if it cannot be stored, fail: an identity that changes every launch would strand every phone). Bind with a 15 s limit (a bind that finishes later is shut down). On the public relays, wait up to 5 s in 250 ms steps for a home relay so the first phones told about the endpoint hear of the relay too; a stop cuts the wait short. Make the gate and listener, start accepting, publish `ShellReach` with the id and relay: state Running. Any failure: state Failed with the reason; the row offers **Try again**.
- **Every 5 s while on**: refresh the home relay and each phone's path; raise `Changed` when something differs.
- **Listener failure** (the endpoint stopped accepting): clear the id from `ShellReach` so no grant or `macInfo` hands out a dead endpoint; state Failed "Stopped: *reason*. Turn Remote access off and on to try again."
- **Turn off / quit**: end every session (`CloseAllAsync`), stop the listener (waits for `gate.Work`), shut the endpoint down (5 s limit each), end any session opened meanwhile. No shell outlives the setting. Quit waits for transcripts to get their end time, within the app's existing 3 s quit limit raised to 6 s (`App.xaml.cs:21`).
- **Relay changed**: save URL and token, register the token with `LogText`, restart the endpoint (connections drop and phones redial; sessions keep running).
- **Reset identity**: stop the endpoint, delete `iroh.secretKey`, start again with a new key. Phones away from the cable lose the PC until their next cable connection (the new id is in the next grant) or a connection on a path that still works; in this stage there is no other path, so the confirmation says: "Phones will lose this PC until they are plugged in again."
- **Revoke(phone)**: store first (so it cannot prove itself again), then `gate.Disconnect(id)` (connections closed; after work in flight, sessions it opened ended), `host.CloseSessions(id)` in case the listener is off, then `Changed` and the pairing slots back to the granter.
- **Shell switch off**: store first, then `gate.DisconnectShell(id)` and `host.CloseSessions(id)`.

Connections admitted while the phone's Shell is off stay open (they can still hear `host` and `macState`, and stage 5's screen will use them).

### 10. `macState` and `host` in the tray app

`IHostStateSource` (Core) is implemented by `WindowsHostState` (`Passthrough.Windows/HostState/`), which owns a message-only window (`MessageWindow`) on its own thread for the notifications below, and raises `Changed` at most once per 250 ms.

| Field | Source | Updates |
|---|---|---|
| `battery` | `GetSystemPowerStatus`: `BatteryLifePercent / 100`; absent when `BatteryFlag` has 128 (no battery) or the percent is 255 | `RegisterPowerSettingNotification(GUID_BATTERY_PERCENTAGE_REMAINING)` |
| `charging` | `ACLineStatus == 1` ("on power, not the battery", the Mac's meaning); absent with no battery | `GUID_ACDC_POWER_SOURCE` |
| `locked` | at start: `WTSQuerySessionInformation(WTS_CURRENT_SESSION, WTSSessionInfoEx)` session flags; then `WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION)`: `WTS_SESSION_LOCK` / `WTS_SESSION_UNLOCK` | session notifications |
| `control` | always `false` | |
| `host.kind` | `windows` | |
| `host.os` | "Windows 11" when the build is 22000 or later, else "Windows 10" (never `ProductName`), the edition from `EditionID`, and the build: `Windows 11 Pro (26300)` | once |
| `host.user` | the account's sign-in name: `WindowsIdentity.GetCurrent().Name` (`PC\name`). Stage 5 replaces it with the Microsoft account's address where there is one | once |
| `host.signedIn` | `true` (the tray app runs only when signed in) | |
| `host.console` | `active`: our session is the console's (`WTSGetActiveConsoleSessionId`) and unlocked; `locked`: it is locked, or our session is disconnected and nobody else is at the console; `otherUser`: another account's session holds the console | `WTS_CONSOLE_CONNECT` / `_DISCONNECT`, lock, unlock |
| `host.console.idleSeconds` | `GetLastInputInfo` at the moment the message is built | re-sent when it crosses 120 s either way (checked every 15 s) |
| `host.shells` | the catalog | `catalog.Changed` |
| `host.screens` | `[]` | |
| `host.rdp` | absent (stage 5) | |
| `host.sleepAfter` | `PowerReadACValueIndex` / `PowerReadDCValueIndex` for the standby idle timeout of the active scheme, by the current power source; absent when 0 | power source change, and every 5 min |

`macState` is sent after `host` and before `sessions`, and to every shell connection when battery, charging or locked changes. `host` is sent again to every shell connection when anything in it changes. A phone's Shell switch being off is not in `host`; it is answered `not_allowed` (2.5).

`lock`: `IScreenLock.LockAsync()` calls `LockWorkStation()` from the tray app; it returns false when the session is not the console's (nothing to lock), which the gate answers `not_allowed`. The `macState` 1 s later carries `locked`.

## Pull requests, in order

Titles follow the repo's style ("Area: what changed, in a sentence"). Each goes against `dev`, carries its docs and its CHANGELOG entry, and leaves `dev` building and its tests green. Remote access stays off by default throughout.

### PR 1: Windows host: shell grants can be sent, and keys and relay tokens never reach the log

- **Scope**: 7.1 and 7.2 without the peer check's implementation (the `inspect` parameter exists; the app passes none, so `GrantShell` always refuses outside tests). No behaviour change in the app.
- **Files**: `Core/Logging/LogText.cs`; `Core/Control/ControlClient.cs`, `ControlEvent.cs`; new `Core/Shell/Access/GrantContents.cs`, `Core/Cable/PeerVerdict.cs`; `tests/Fakes/FakePhone.cs` (answers `shellGrant` with `shellGranted`, options: no answer, wrong grant id, no grant id, answer before auth).
- **Tests**: `LogTextTests` (44-character keys, URL-safe and standard; a registered token, plain and URL-encoded; `Bearer`; 64-hex left alone; the existing 43 rule); `ControlClientTests`: grant refused before auth, refused when the verdict is not Genuine, sent after auth with every field, `shellGranted` only after auth, id length limits, a grant id echoed, `Opened` is the first event; `ToString` of every secret-bearing record.
- **Docs**: CHANGELOG ("Not yet: nothing uses it"), `SECURITY.md` one line on log redaction.
- **Verify by hand**: none needed beyond tests; pair a phone, nothing changes.
- **Leaves out**: any grant actually going out.

### PR 2: Windows host: a channel to every attached phone, iPads pair, and Forget takes shell access with it

- **Scope**: 7.3 (channels, `DeviceChannel`, `ShellGrantLedger`, `ShellGranter`) and 7.4, against an `IAccessAdmin` whose only implementation is `NoRemoteAccess` (`GrantContentsAsync` returns null; revoke does nothing). So no grant goes out yet, but all the plumbing is under test with a fake.
- **Files**: `Core/Session/HostSession.cs`, new `DeviceChannel.cs`, `ShellGranter.cs`, `ShellGrantLedger.cs`; `PhoneState.cs`, `PhoneEntry.cs`; `Core/Presentation/PhoneRowModel.cs`, `FlyoutHeader.cs`, `PairedPhone.cs`, `WatcherHints.cs` (if it keys on slots); `Core/Shell/Seams/IAccessAdmin.cs` (+ records); `App/SessionViewModel.cs`, `PhoneRow.cs`, `SettingsWindow.xaml.cs` (Forget dialog text); `App.xaml.cs` (passes `NoRemoteAccess`).
- **Tests**: `ShellGrantLedgerTests` (port of the Swift ledger tests, plus the fingerprint vector); `ShellGranterTests` with `FakeAccessAdmin` and `FakeTimeProvider`: one grant per device, answer matching, the 15/30/60/120/600 s waits, a changed fingerprint starts afresh, revoke holds until a new channel, unplug clears, `AddKeyAsync` false is shown; `HostSessionTests` reworked for per-device channels: two phones both reach Paired, an iPad pairs, a code goes to the right device, Forget revokes, the active marker; `PairedPhoneTests` (non-token slots skipped, access shown).
- **Docs**: `windows/README.md` (iPad pairs; checklist item 7 updated), `docs/GUIDE.md` §Windows, CHANGELOG.
- **Verify by hand**: an iPhone and an iPad on two cables: both pair, both show status; Forget one, the other stays.
- **Leaves out**: any shell.

### PR 3: Windows host: the shell's logic, ported from the Mac and tested with fakes

- **Scope**: everything in section 2 and 3 that is pure: `SerialQueue`; protocol pieces missing after stage 1; `HandshakeLimiter` and stores; `ScreenViewLimit`; `ShellGate`; `ShellConnection`; `PcAnswers`; `IrohShellListener`; `ShellSessionManager` and its parts; `PromptReturn`; `ShellReach`; `AccessStore`; `ShellCatalog` (Core part); the seams (`ISessionHost`, `IPty`, `IIrohEndpoint`, `ILocalAddresses`, `IHostStateSource`, `IScreenLock`); `LocalSessionHost`; `LocalRemoteAccess`. The manager needs `TranscriptStore`, so its Core port (8.1, with `ITranscriptFiles` and the memory implementation) is in this PR too; the physical files, the ACL and the window are PR 7.
- **Files**: `Core/Threading/*`, `Core/Shell/**`, `tests/Shell/**`, `tests/Fakes/FakePty.cs`, `FakeIrohEndpoint.cs`, `FakeSessionHost.cs`, `FakeHostState.cs`, `MemoryTranscriptFiles.cs`, `DuplexStream.cs`.
- **Tests**: see *Tests*; this PR carries most of them.
- **Docs**: CHANGELOG ("Not yet: nothing starts it"); `protocol/README.md` only if a PC answer was missing from stage 1's table (`screenPass`, `screenRevoke`, `rdp` before the service).
- **Verify by hand**: `dotnet test` on Windows and on a Mac.
- **Leaves out**: any Windows API; the app is unchanged.
- This PR is large (about the size of the Swift `ShellHost` target it mirrors). If review wants it split, split along the seams: (3a) sessions and parts, (3b) recording, (3c) gate, connection, listener, access store. Each still leaves `dev` green.

### PR 4: Windows host: shells on a pseudoconsole, each in its own job, from a catalog built on the PC

- **Scope**: section 5. New project `Passthrough.Windows` and `tests/Passthrough.Windows.Tests` (net10.0-windows; Windows CI only). A hidden developer switch (`PASSTHROUGH_PTY_PROBE=pwsh` in the environment) opens one session at start and writes its first kilobyte to the log, so the PR can be tried without a network.
- **Files**: `windows/src/Passthrough.Windows/Passthrough.Windows.csproj`, `Pty/ConPtyFactory.cs`, `ConPty.cs`, `JobObject.cs`, `UserEnvironment.cs`, `CommandLine.cs`, `Security/Elevation.cs`, `Shells/WindowsShellCatalogSource.cs`, `StorePackages.cs`, `TrustedLocation.cs`, `Interop/*.cs`; `windows/Passthrough.Windows.sln`; `Directory.Build.props` (lock files if stage 1 added them); `THIRD_PARTY_NOTICES.md`.
- **Tests** (real processes, Windows only): `cmd /c echo` output and exit code; input reaches the program; resize is seen (`mode con`); the child is in the job and dies when the PTY is disposed; `OtherProcesses` sees a child and then not; the environment has the user's variables, `TERM_PROGRAM` and `PASSTHROUGH_SESSION`, and not a variable set in the test process; the working directory is the profile; an unknown executable throws; the command-line quoting table; `TrustedLocation` (a file in `%TEMP%` refused, System32 accepted, a link from Program Files to `%TEMP%` refused); catalog source against a fake registry and a fake package list (Store-only pwsh found at its real folder; the alias never returned; `docker-desktop` left out; a bad distro name left out; a per-user Git ignored).
- **Docs**: `windows/README.md` build notes; CHANGELOG.
- **Verify by hand**: on the owner's PC the log lists `pwsh` (from the Store package's real folder), `powershell`, `cmd`, `wsl:Ubuntu` and no `docker-desktop`; the probe prints PowerShell's prompt; started as administrator, the probe logs the refusal.
- **Leaves out**: the network; UI.

### PR 5: Windows host: the built-in connection (iroh), as our own small library

- **Scope**: section 4. The bridge, its tests and fuzz target, the script, CI steps, the managed wrapper implementing `IIrohEndpoint`.
- **Files**: `native/iroh-bridge/**`; `scripts/build-iroh-bridge.ps1`; `.gitignore` (`windows/native/`); `windows/src/Passthrough.Windows/Iroh/*.cs`; `.github/workflows/ci.yml`; `THIRD_PARTY_NOTICES.md` (the iroh crates and what `cargo deny` lists); `CONTRIBUTING.md` (Rust toolchain, the pin moves with the phones').
- **Tests**: Rust `tests/abi.rs`, `tests/loopback.rs`; C# `IrohBridgeTests` (Windows): two endpoints with relays off dial each other over loopback; retry then validated; refuse; wrong ALPN; cancel a pending accept and a pending read; dispose with a read pending; the clean-close code both ways; "write then dispose" delivers the bytes; a stale handle after shutdown; `IrohShellListener` end to end over real endpoints with a `FakeSessionHost` (handshake, `ready` order, open, output).
- **Docs**: `windows/README.md` build steps (install rustup and the MSVC build tools; run the script; where the DLL goes); CHANGELOG.
- **Verify by hand**: run the script on the owner's PC (after installing Rust); the interop check from 4.1: a Mac's test dialer reaches the PC's endpoint directly on the LAN and through a relay with direct paths blocked.
- **Leaves out**: anything that starts an endpoint in the app.

### PR 6: Windows host: Remote access: open a shell on this PC from your phone, from anywhere

- **Scope**: the wire-up. `LocalRemoteAccess` and `LocalSessionHost` composed in `App.xaml.cs`; the cable peer check (section 6); `WindowsHostState`, `MessageWindow`, lock; Settings ▸ Remote access (switch, setup rows, Phones with access with Shell switch, Stop and Revoke); the grant notice; flyout header and tray states. This is the PR after which the stage's goal works except history and relay settings.
- **Files**: `Passthrough.Windows/Cable/LoopbackPeerInspector.cs`, `HostState/*.cs`; `Core/Transport/ByteStreamConnector.cs` (`ILoopbackConnection`); `Core/Presentation/RemoteAccessPage.cs`, `FlyoutHeader.cs`, `TrayState.cs`, `GrantNotice.cs`, `SetupRows.cs` (all strings and state logic in Core, tested); `App/App.xaml.cs`, `SessionViewModel.cs`, new `RemoteAccessViewModel.cs`, `SettingsWindow.xaml(.cs)` (a navigation list: General, Remote access), `FlyoutWindow.xaml(.cs)`, `TrayIcon.cs`.
- **Tests**: `LoopbackPeerInspectorTests` (Windows: a loopback listener in the test process is "the current user's" for the adb rule and is **not** Apple's service for the usbmux rule; a closed connection is Unknown); presentation tests for every row, header and notice string in *UX states*; `LocalRemoteAccess` lifecycle with fakes (on, off, relay change, reset, failure, revoke ordering: key gone before the connection is cut).
- **Docs**: `windows/README.md` (roadmap rewritten to the master plan's stages; the real-PC checklist items below); `docs/GUIDE.md` §Windows (Remote access, what a shell is and is not, WSL, the 27015 note restated with the check); `SECURITY.md` (the rule "a shell only to a device paired over the cable" restated for a PC, the peer check, what running as the same account means); `README.md` feature table; CHANGELOG with **Before you rebuild** (Rust toolchain, run the script).
- **Verify by hand**: the checklist's shell items.
- **Leaves out**: history UI and retention; relay settings UI; reset identity.

### PR 7: Windows host: sessions are recorded, and you can read them back

- **Scope**: section 8: `PhysicalTranscriptFiles`, `AclFolder`, pruning at launch / on end / on change, the history window, the retention setting, `history` and `transcript` answered from real files.
- **Files**: `Passthrough.Windows/Security/AclFolder.cs`, `Recording/PhysicalTranscriptFiles.cs`; `Core/Shell/Recording/TranscriptText.cs`; `App/HistoryWindow.xaml(.cs)`, `HistoryViewModel.cs`; settings page row.
- **Tests**: `TranscriptStoreTests` already in PR 3 run again over the physical files in a temp folder (Windows); `AclFolderTests` (one rule, no inheritance, re-applied to an existing loose folder); `TranscriptTextTests`; retention cut-offs.
- **Docs**: guide (where recordings live, how long, how to delete, what a backup tool will see); `SECURITY.md` (recordings hold whatever was printed); CHANGELOG.
- **Verify by hand**: run a session, end it, read it in the window and from the phone's History; set 7 days and see an old one go; check the folder's Security tab.
- **Leaves out**: a drawn terminal for replay.

### PR 8: Windows host: your own relay, and a new identity when you want one

- **Scope**: Settings ▸ Remote access ▸ Relay settings (URL, token, **Use the public relays**), **Reset identity…**, the *From anywhere* row's failure states and **Relay settings** button; the regrant when what grants carry changes.
- **Files**: `Core/Presentation/RelaySettings.cs` (validation with `IrohInfo`), `App/RelaySettingsDialog.xaml(.cs)`, settings page.
- **Tests**: validation strings; token registered with `LogText` before the endpoint restarts; a relay change changes the fingerprint and re-grants the attached phone; reset changes the endpoint id and re-grants; an unreachable relay shows its row and leaves direct paths working.
- **Docs**: guide (running your own relay points at the existing section for the Mac; what reset does); CHANGELOG.
- **Verify by hand**: set a private relay with a token, see the phone reconnect through it; grep the log for the token; reset identity, plug the phone in, connect again.

## Interfaces

### This stage defines (others depend on these): name, shape, owner

| Name | Shape | Owner / where | Depended on by |
|---|---|---|---|
| `ISessionHost`, `ISessionHostEvents`, `HostState`, `OpenResult`, `AttachResult` | 3.4 | `Core/Shell/Seams` | stage 4 (pipe), stage 5 (`LockAsync`, console state), stage 8 (`SavePassAsync`) |
| `IAccessAdmin` and its records | 3.5 | `Core/Shell/Seams` | stage 4 (pipe, per-account filtering), stage 5 (Screen switch, setup rows), stage 7 (computers) |
| `IAccessCheck` | 2.4 | `Core/Shell/Host` | stage 4's TLS listener uses the same gate |
| `ShellGate`, `ShellConnection`, `PcAnswers` | 2.4, 2.5 | `Core/Shell/Host` | stage 4 (second listener on the same gate type), stage 5 (`rdp`) |
| `IPty`, `IPtyFactory`, `PtyLaunch` | 3.1 | `Core/Shell/Seams`; implemented in `Passthrough.Windows` | stage 8 does not use it; stage 7 (terminals on the PC) will extend it |
| `IIrohEndpointFactory`, `IIrohEndpoint`, `IIrohIncoming`, `IrohStream` | 3.2 | Core seam; `Passthrough.Windows/Iroh` | stage 4 (service hosts it), stage 8 (dialing) |
| The bridge's C ABI, version 1 | 4.3, 4.4 | `native/iroh-bridge/include/passthrough_iroh_bridge.h` | stages 4 and 8 |
| `ILocalAddresses` | 3.3 | Core seam, portable default | stage 4 (Windows implementation, tunnel fixtures) |
| `ICablePeerInspector`, `ILoopbackConnection`, `PeerVerdict` | 6 | Core seam; `Passthrough.Windows/Cable` | stage 5 reuses the TCP-table technique for the Remote Desktop far end |
| `IShellCatalog`, `ShellEntry`, shell ids (`pwsh`, `powershell`, `cmd`, `wsl:<name>`, `gitbash`) | 5.3 | Core + Windows source | stage 2 (the phone's chooser shows `name`, sends `id`), stage 8 |
| `AccessStore` format (`shell.phones`) and the `host-secrets` folder | 2.10, 7.5 | Core / App | stage 4's hand-over |
| `TranscriptStore` location and format | 8 | Core / Windows | stage 4 (`TranscriptAsync` over the pipe) |
| `SerialQueue` | 1 | `Core/Threading` | everything after |
| Settings keys `remoteAccess`, `relayUrl`, `historyRetentionDays` | 7.5 | `settings.json` | stage 4 migrates the first two |
| `ShellGrantContents.NoListenerPin` | 2.12 | Core | stage 4 replaces it with the real hash |

### This stage consumes (from which stage)

| What | From | If it is missing |
|---|---|---|
| The Windows CI job (`windows-latest`, `dotnet test`; the macOS job also runs `dotnet test`), NuGet lock files | stage 1(a) | PR 3 cannot gate on Windows; add the job first |
| C# `ShellEnvelope` with every field and tag, incl. `host`, `shell` on `open`, `signed_out`, `rdp`, `message`/`detail` on `error`, `hostKind` on `shellGrant` | stage 1(b) | PR 3 adds what is missing, fixtures first |
| The `host` message's exact field names and the form of `os` | stage 1(b) fixtures | follow the master plan's list; `os` as in section 10 |
| The table of what a PC answers to Mac-only requests, in fixtures | stage 1(b) | `PcAnswers` follows the master plan; add `screenPass`, `screenRevoke` (→ `bad_request`) and `rdp` before the service (→ `rdp_unavailable`, `detail` `service`) |
| Whether `ShellSessionInfo` carries the session's shell (for "Ubuntu · running · 4m") | stage 1(b) / stage 2 | the title starts as the shell's name, which shows the kind until a command is typed |
| What a phone is told when its Shell switch is off | stage 1(b) / stage 2 | `error` `not_allowed` on `open`, `attach`, `history`, `transcript`; stage 2 words it as "doesn't let this iPhone open shells" |
| Phones that understand a PC (wording, the chooser, `host`) | stage 2 | stage 3 works against today's phone builds (they show the PC as a Mac and open the default shell), so it is testable, but not shippable in words |
| The ConPTY spike's answer on OSC 7501 and OSC 52 through the bundled console | stage 0 | PR 4 measures it; without OSC 7501 the status falls back to the question heuristic |
| The iroh bridge spike (PC and Mac dial each other) | stage 0 | PR 5's interop check is that spike |

## Tests

### Automated

**`windows/tests/Passthrough.Core.Tests`** (any OS; fakes only). Each suite mirrors a Swift one in `Packages/PassthroughCore/Tests/ShellHostTests` and ports its cases one for one unless it concerns a feature not ported (Mac terminals, screen passes, push, events).

| Suite | Mirrors | Pins, beyond the ports |
|---|---|---|
| `SerialQueueTests` | new | order, async items, `PostAfter` with fake time, suspend/resume |
| `HandshakeLimiterTests`, `FileProvenAddressStoreTests` | limiter tests in `PhoneTransportTests` | buckets, reserved slots, timeout vs release |
| `ShellGateTests` | `ShellListenerTests` (handshake cases) | two keys always checked; refusal line then close; proof line limit hard at 4096; timeout before and after the stream exists; stop mid-handshake |
| `ShellConnectionOrderTests` | `ShellListenerTests` | **`ready`, `macInfo`, `host`, `macState`, `sessions`, byte for byte**; no `macInfo` while the endpoint is starting; screen-only id gets `ready` only |
| `ShellConnectionRequestTests` | `ShellListenerTests` | `busy`: `open` then `resize` then `list` answered in order with the resize reaching the new session; reading paused while busy; `ref` echoed on `opened` and on every refusal; `attach` to another session detaches first; `input` to a session not attached; `close` of an ended session; overlong line closes; bad JSON keeps the connection; 8 MiB backlog drops; **`macState` exactly 1 s after `lock`** (fake time); `Detached` with an old generation ignored; host going away → `detached` + `signed_out` |
| `PcAnswersTests` | stage 1's fixtures | one test per row of the table in 2.5 |
| `ShellHistoryReplyTests` | same name | 500 newest; binary search to fit the line |
| `IrohShellListenerTests` | same name | retry before a slot; relay bucket cap 8; per-IP cap 2; refuse when full; cancel at timeout; paths preferred direct |
| `ShellSessionManagerTests` | same name | cap with opens in flight; attach order **`Replaying`, replay chunks, `Replayed`, then live**; takeover tells the old client with its generation; redraw trick only when partial + alt screen + same size, and restores after 0.25 s; ended session attach gives `Replayed` then `Ended`; retention prune; `CloseSessions(openedBy)` |
| `SessionTitleTests` | part of the above | title from echo; no title from a no-echo prompt; escape keys skipped; Ctrl-C starts over; window of 2048 bytes |
| `ProgramStatusTests`, `TerminalModesTests`, `ShellQuestionTests`, `ScrollbackBufferTests`, `TerminalReportsTests` | same names | **`SupportReply` is written to the PTY before the chunk reaches any client** (order observed on `FakePty` vs the events) |
| `ProgramLeftTests` | the status-owner cases of `ShellSessionManagerTests` | owner set at first report; dropped when its processes leave the job; another program taking over; the 2 s poll; `PromptReturn` for a PTY that cannot tell |
| `TranscriptStoreTests` | same name | over `MemoryTranscriptFiles` |
| `ShellReplayTests` | in `PassthroughCoreTests` | lines, sizes, `done` |
| `AccessStoreTests` | `ShellAccessStoreTests` | previous key rules; slot mismatch refused; `viewer.` and `computer.` ids refused; fail-closed revoke and switches with a store that fails writes; empty TTL; Shell switch carried over a re-grant |
| `ShellReachTests` | same name | |
| `ShellAddressPolicyTests` | fixtures `shell.addresses` | |
| `ShellCatalogTests` | new | default order; id grammar; lookup is exact; a wire id never reaches an argument |
| `LocalRemoteAccessTests` | new | lifecycle in section 9 with fakes |
| `ShellGrantLedgerTests`, `ShellGranterTests`, `HostSessionTests`, `ControlClientTests`, `LogTextTests`, presentation tests | PRs 1, 2, 6 | |

**`windows/tests/Passthrough.Windows.Tests`** (Windows CI only): ConPTY, job, environment, catalog source, trusted location, peer inspector, ACL folder, the bridge wrapper, the listener end to end over real endpoints.

**`native/iroh-bridge`**: `cargo test --locked` (`tests/abi.rs`, `tests/loopback.rs`); `cargo fuzz run calls -- -max_total_time=60` on pull requests that touch it; `cargo deny check`; `cargo audit`.

**Cross-implementation** (the macOS job, once stage 1 has `dotnet` there): the C# gate and connection behind a loopback TCP stream, driven by the Swift `ShellClient` through a small test harness executable (`windows/tests/Passthrough.Core.Tests/Harness`), covering handshake, `ready` order, open, replay, takeover. The reverse direction belongs to stage 8.

### Fixtures added (to `protocol/fixtures.json`, fixtures first)

- `shell.grantFingerprint`: inputs and the expected `ShellGrantLedger.contents` string, including one with absent iroh fields; asserted in Swift and C#.
- `shell.programStatus.supportReply`: the reply's bytes (base64), asserted in Swift and C#.
- `shell.pcGrant`: a `shellGrant` line as a PC sends it before it has a listener (zero pin, port 7893, no addresses, `hostKind`), which the Swift and Kotlin suites must accept and store.

### Real-hardware checklist (added to `windows/README.md`, "First things to try on a real PC")

11. **The connection library builds.** With rustup and the MSVC build tools installed, `scripts\build-iroh-bridge.ps1` ends by printing the DLL's size and hash; the app then builds. Without it, the build says to run the script.
12. **Shells listed.** Settings ▸ Remote access lists the shells found. On a PC whose only PowerShell 7 is the Store's, PowerShell is listed and opens. `docker-desktop` is not listed. Uninstall PowerShell 7: the default becomes Windows PowerShell.
13. **Remote access on.** Turn on *Use this PC's shell*: *From anywhere* reads "Ready, through *relay*." within a few seconds; Start at login is now on. Plug in a paired iPhone: the flyout shows the notice "*iPhone* can now open shells on this PC." and the phone lists the PC.
14. **A shell from the phone**, away from the PC's network (cellular): New shell opens PowerShell; `whoami` names you; `whoami /groups` shows a medium integrity level. Type a command: the session's title becomes that command. Settings shows the phone "Connected · directly" or "through a relay".
15. **Through a relay only.** On a network that blocks UDP hole punching (or with the PC behind a second router), the shell still opens and Settings says "through a relay".
16. **Dropped and back.** With `ping -t localhost` running, turn airplane mode on for 20 seconds and off: the same session comes back and its screen is drawn in one go, then carries on. Quit the phone app and open it: the session is still listed and attaches.
17. **Full-screen programs.** In `vim` (WSL or Git Bash) or Claude Code, leave and come back after a megabyte of output: the screen redraws whole.
18. **Claude Code.** Start it in a PowerShell session: the phone shows working, then "needs you" with the question, then done. Kill it from Task Manager: within a few seconds the session is a plain shell again.
19. **Android and iPad.** The same from an Android phone. Plug in an iPad: it pairs with a code and gets a shell.
20. **Shell switch.** Turn Shell off for a phone in Settings: its sessions end and it is told it may not open shells; on again, it can, with no cable.
21. **Stop, Revoke, Forget.** With a session open: Stop ends it and the phone can open another. Revoke ends it and the phone is refused until it is plugged in again. Forget pairing does the same and the phone must pair again.
22. **The cable check.** Stop Apple Mobile Device Service, run a program that listens on 127.0.0.1:27015 and forwards to nothing, start the app: no grant is sent and the row says why. With adb started from another Windows account's session, an Android phone pairs but gets no grant.
23. **Never elevated.** Start Passthrough with "Run as administrator": Remote access cannot be turned on and says why. On an account with UAC off, the same.
24. **WSL and Git Bash** open, at the home directory, with a working prompt, arrow keys and colours.
25. **Recording.** End a session; it is in Session history with its text; the `.cast` plays in asciinema; `ShellHistory` grants access to you alone.
26. **Relay settings.** Set a relay of your own with a token: the phone reconnects through it after its next cable connection or its next connection. `findstr` the log for the token and for a shell key: nothing.
27. **Reset identity.** The phone can no longer reach the PC; plug it in; it can.
28. **Quit** with a session open ends the session (its recording has an end time) and the process within six seconds.
29. **Lock** from the phone locks the PC; the phone shows it locked; the shell keeps running.

## Security considerations for this stage

- **Who can get a shell.** Only a device that (a) paired over the cable with a code typed on this PC, (b) was handed a key over a control channel whose far end was checked to be Apple Mobile Device Service or the user's own adb, and (c) proves that key on every connection. iroh authenticates the PC to the phone (the endpoint id in the grant); the shell key authenticates the phone to the PC. A stranger who learns the endpoint id gets a QUIC handshake, a slot for 10 s at most, and `not_authorized`.
- **Before proof**: nothing a peer sends is acted on. Slots: 16 at once, 2 per direct IP, 8 for relayed attempts, 4 held for addresses that proved themselves; only address-validated attempts get one; the hello and proof lines are capped at 4096 bytes.
- **Never elevated.** Shells run with the app's own token; the app refuses to host when that token is elevated. The job has no breakaway, so a shell's children die with the session or the app.
- **Nothing from the wire reaches a command line.** `open.shell` selects a catalog entry; executables are absolute, found under Program Files and System32 by system APIs and `HKLM`, resolved through links, owned by the system or administrators; arguments are fixed per shell; a WSL distro's name comes from the PC's own list and must match a strict pattern. `PATH`, `HKCU` and the Store alias folder are never used to find a program.
- **Environment.** Built fresh from the user's profile, never inherited from the app's launcher.
- **Keys at rest.** Phones' keys, the iroh secret key and the relay token are DPAPI-protected for the current user in a folder only that user can open. A program running as the same Windows account can read them (and could be the shell host itself): that is code running as you, outside the threat model, as on the Mac; say so in `SECURITY.md`.
- **Key rotation.** Each grant is a new key; the previous one works until the phone first proves the new one, then is dropped. A phone cannot claim another phone's id from a different pairing, nor an id the host mints (`viewer.`, `computer.`).
- **Revocation fails closed** in memory even when the store cannot be written; connections are cut after the key is gone, never before.
- **Logs.** Session events name the phone and the action, never what was typed or shown. Keys, tokens and proofs never reach the log by construction (`ToString` overrides), and `LogText` catches a slip. Endpoint ids are public and are logged shortened to 10 characters.
- **Recordings** hold whatever a program printed, secrets included: owner-only folder, bounded size, pruned by age, never logged.
- **The bridge** is the one piece of native code that parses bytes from the internet (through `iroh`). Handles are checked ids; no export trusts a pointer it did not just receive; panics are contained; it is fuzzed; dependencies are locked, licence-checked and audited in CI. It is loaded by full path from the app's folder.
- **ConPTY** binaries are Microsoft-signed, checked at build.
- **The cable check's limits.** It shows the process that accepted the connection is Apple's service (or the user's adb) at that moment. It does not defend against an administrator, nor against a program already running as the same user for adb. Android's weaker position (any program of the user's could run adb) is the same as on the Mac.
- **Shared PCs.** Per-account by construction in this stage: each account's tray app has its own keys, endpoint identity and sessions. Two accounts signed in at once each run an endpoint; neither can read the other's folder.
- **What a phone with shell access can do**: run anything as the account, read its files, start elevated things only through a UAC prompt on the PC's own screen (which a phone cannot answer in this stage). Said plainly in the guide.

## UX states and strings for this stage

Wording follows the master plan §1; where it gives a sentence, that sentence is used. New sentences are marked (new).

### Settings ▸ Remote access, before stage 4 exists

A second page in Settings (a two-item list on the left: General, Remote access).

- Title: **Remote access**. Under it (new): "Reach this PC from the phones you've paired over the cable."
- ☑ **Use this PC's shell** (a switch; this is the whole of "Turn on" in this stage, with no administrator prompt). Caption (new): "Phones open shells as you, never as administrator, from anywhere. Passthrough starts at login while this is on."
- ☐ **See and control its screen**: shown, dimmed, not switchable. Caption (new): "Needs the background service, which isn't in this build yet."
- When the app is elevated, the switch is off and disabled, with (new): "Passthrough is running as administrator, so it won't host shells: they would open as administrator too. Quit it and start it normally."
- Setup rows, shown once the switch is on:

| Row | State | Text | Button |
|---|---|---|---|
| From anywhere | working | "Starting…" (new) | |
| | done | "Ready, through *relay host*." | |
| | done, own relay | "Ready, through *relay host* (yours)." (new) | **Relay settings** |
| | problem | "The relay isn't answering. Phones that can reach this PC directly still work." (adapted: there is no local network path yet) | **Relay settings** |
| | problem | "Couldn't start: *reason*." (new) | **Try again** |
| | problem | "This build has no connection library. Run scripts\build-iroh-bridge.ps1 and rebuild." (new) | |
| On this network | optional | "Needs the background service, which isn't in this build yet. Phones use the built-in connection instead." (new) | |
| Shells | done | "PowerShell, Windows PowerShell, Command Prompt, Ubuntu. New shells open PowerShell." (new) | |
| | problem | "No shell was found in a place Passthrough trusts." (new) | |

- **Phones with access** (a card per phone, newest first): name; second line "Granted 14 Nov · Connected, directly · 2 shells open" / "…through a relay" / "Not connected" (new); a **Shell** switch (automation name "Shell for *iPhone*"); a dimmed **Screen** switch with the tooltip "Needs the background service."; **Stop** (only while it has a connection or a shell; "Its shells close. It can connect again." (new)); **Revoke…** → dialog "Revoke *iPhone*'s access? Its shells close. Plug it in again to give access back." (new, after the master plan's "Its shells and any view of the screen close.") **Revoke** · **Cancel** (default Cancel).
- Empty: "No phone has access yet. Plug in a paired phone." (new)
- A switch that could not be saved off: "Shell is off for *iPhone*, but that couldn't be saved: it may come back when Passthrough restarts. Turn it off again, or revoke the phone." (after the Mac's)
- **Session history…** and, under it, "Kept for 30 days · 412 MB on this PC".
- **Relay settings…** dialog (PR 8): "Relay" with two choices, "The public relays (n0)" and "My own relay"; fields "Address" (placeholder `https://relay.example.com`) and "Token (optional)"; errors "That isn't an https address." / "The address is too long." / "The token is too long."; note "Phones learn a new relay the next time they connect or are plugged in." **Save** · **Cancel**.
- **Reset identity…**: "Give this PC a new identity for the built-in connection? Phones will lose this PC until they are plugged in again." **Reset** · **Cancel** (default Cancel).

### Settings ▸ General ▸ Paired phones

- A pairing with access shows "Can open shells on this PC" under its detail (new).
- Forget dialog body becomes: "This PC will no longer be paired with it, and it can no longer open shells here. Its shells close. You can pair again with the code the phone shows." (new, extends `SettingsWindow.xaml.cs:147`)

### Flyout and tray (the master plan's table, the rows that apply now)

| State | Header | Tray | Action |
|---|---|---|---|
| Off | "Remote access is off" / "Phones can't reach this PC" | plain | **Turn on…** (opens Settings ▸ Remote access) |
| On, idle | "This PC is reachable" / "From anywhere" (the plan's "On this network and from anywhere" needs stage 4) | tinted; tooltip "Passthrough · reachable" | |
| Starting | "This PC is reachable" / "Starting the built-in connection…" (new) | tinted | |
| Something failing | "Remote access needs a look" / the first failing row's text | amber | **Fix** (opens the page) |
| A phone has shells | "*iPhone* has 2 shells open" (one: "1 shell open"; two phones: "2 phones have 3 shells open" (new)) | dot | **Stop** |
| Access first granted | notice that stays: "*iPhone* can now open shells on this PC." | amber dot | **OK** · **Revoke** (the plan's **Allow screen** arrives with stage 5) |
| A shell is asking | "*PowerShell* is asking" (the session's title) | amber dot | none yet ("Open here" is later) |

Precedence, top wins: failing, a shell is asking, a phone has shells, on idle, off. The existing phone header ("Connected to *iPhone*", "Pair with…", `FlyoutHeader.cs:15-40`) moves to a second line group under it; with Remote access off and a phone attached, the header is today's.

Phone rows keep today's lines and gain one (new): "Can open shells on this PC" / "Waiting for the phone to store its key…" / "Couldn't save shell access for *iPhone*. Plug it in again to retry." / the two cable-check sentences in section 6. An iPad's row is a phone's row.

The grant notice is kept in settings until acknowledged, so it survives a restart, and is shown once per phone id (a renewed key is not news).

**Quit** with shells open (the plan's dialog, without the screen sentence, which needs the service): "Quit Passthrough? 2 shells end, and phones can't reach this PC until it is open again." **Quit** · **Cancel** (new wording for this stage; stage 4 restores the plan's three-button form).

### Accessibility

Every switch has an automation name including the phone's name; the setup rows are a live region (`AutomationProperties.LiveSetting="Polite"`); row state is an icon and a word, never colour alone; dialogs default to the safe button; the history list is keyboard-navigable and the text box is read by Narrator as plain text.

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| **The Store package's real `pwsh.exe` cannot be started by an unpackaged process** (package files can carry an ACL that asks for package identity) | PR 4's first task on the owner's PC: `CreateProcess` on the path from `PackageManager`. Pass: it starts. Fail: the verified-alias fallback in 5.3, written and tested in the same PR. Either way PowerShell 7 is listed |
| **OSC 7501 or its reply does not survive the bundled console in order** | stage 0's ConPTY spike; PR 4 re-measures with a script that sends the query followed by a device-attributes request and checks the order of what the program reads. Fail: status falls back to the question heuristic and done-when item 5 is reworded in the PR |
| **ConPTY rewrites output** (it re-renders rather than passing bytes through; the scrollback replay and `TerminalModes` assume the program's own sequences) | PR 4 measures alt-screen, mouse and bracketed-paste sequences end to end with the bundled console (which passes VT through in recent versions). If the alt-screen switch is not visible in the output, the redraw trick is applied on every partial replay instead of only on the alternate screen |
| **`ConptyClosePseudoConsole` blocks or loses the last output** | the reader keeps draining on its own thread while another thread closes; a test writes 1 MiB then exits and checks every byte and the order `Output…` then `Exited` |
| **The iroh bridge does not interoperate with the phones' 1.1.0** | pin `iroh = "=1.0.2"` from `iroh-ffi`'s own lock file; PR 5's interop check against a Mac before merge; the real-PC items 14 and 15 |
| **iroh 1.0.2's Rust API differs from what the ABI assumes** (synchronous getters, relay auth token, the minimal preset's name) | the ABI is defined by what the callers need, not by iroh's shape; `iroh-ffi`'s source at `v1.1.0` is the reference for each mapping; getters that turn out asynchronous are resolved inside the accept task (4.4) |
| **The owner's PC has no Rust toolchain; CI is the only builder** | the script checks and says what to install; CI builds on every PR; the app builds without the DLL (`SkipIrohBridge`) and says so in its row |
| **PR 3 is too large to review** | it mirrors existing, tested Swift file by file, with the Swift tests ported; the split in PR 3's note is ready |
| **The `HostSession` refactor regresses pairing** | its 1 091 lines of tests are reworked first, per device; PR 2 changes no wire behaviour and is tried with two devices before merge |
| **Apple's service has another name or is not a Windows service under the Store's Apple Devices** | PR 6 logs the verdict and the owning process on the owner's PC before grants depend on it; if the service cannot be named, the fallback is to require the owning process's image to be under `%ProgramFiles%` and signed by Apple (`WinVerifyTrust`), decided in that PR |
| **A grant with a zero pin and no addresses confuses a phone build** | fixture `shell.pcGrant` in the Swift and Kotlin suites; real-PC item 13 with today's phone builds |
| **Job tracking misreads PowerShell's own helper processes as "a program"** (conhost is outside the job, but pwsh may start children) | owner-set logic only cares whether the set present at the first report has gone; `ProgramLeftTests` plus item 18 |
| **`PromptReturn` drops a live WSL program's status** | needs 5 s of silence while "working" and a prompt-shaped last line; tests with recorded Claude Code output; it is WSL-only |
| **Quit takes longer than the app allows** | the limit goes to 6 s; `CloseAllAsync` is bounded at 5 s; the job kills what is left |
| **Two instances fight over one endpoint identity** (fast user switching is per account, but a second launch in the same session) | the single-instance mutex stays (`App.xaml.cs:58`); per account there is one app |

## Decisions made here

1. **One control channel per attached device** instead of the Mac's lent channel. Reasons in 7.3: no tunnel rides on the channel on Windows, no lending state machine, iPads and second phones just work, grants need per-device state anyway.
2. **The attach generation is chosen by the caller** (`ShellConnection`), not returned by the host. An awaited return value races the ordered event stream; a number the caller already holds cannot. It is unique per connection, which is all the check needs.
3. **`ISessionHostEvents` includes `Replaying`**, because the host must send it since #41.
4. **A completion queue, not callbacks, for the bridge.** Native code never calls managed code, so there is no reverse-P/Invoke lifetime problem, nothing unwinds across the boundary, shutdown is one wake-up, and the fuzzer can drive the whole ABI from C.
5. **`iroh = "=1.0.2"`**, the version `iroh-ffi v1.1.0` locks.
6. **A zero certificate pin, port 7893 and no addresses in the grant** until a listener exists (2.12).
7. **Shell secrets in their own folder** (`host-secrets`), so Paired phones never lists them and stage 4's hand-over is one folder.
8. **A per-phone Shell switch stored as `shell` (absent = on)**; off refuses `open`, `attach`, `history`, `transcript` with `not_allowed`, ends that phone's sessions, and keeps renewing its key so turning it on needs no cable.
9. **Remote access turns Start at login on** (master plan §2 says so for the service era; it is just as true now) and does not turn it off again when Remote access goes off.
10. **Turning Remote access off ends every session**, as the Mac's switch does.
11. **Session titles start as the shell's name**, not `~`.
12. **The shell exiting ends the session and its job**, even if it left children behind.
13. **No fallback to the inbox pseudoconsole**: bundled or nothing.
14. **Trusted locations are Program Files, Program Files (x86) and System32, by API, with an owner check**; a per-user Git, a `dotnet tool` PowerShell and the Store alias are not listed.
15. **WSL distros left out by name**: `docker-desktop`, `docker-desktop-data`, `rancher-desktop`, `rancher-desktop-data`, `podman-machine-*`.
16. **"The program left" uses the job's process list** on each chunk and every 2 s; WSL uses `PromptReturn`.
17. **The history window shows plain text**, not a drawn terminal, and offers the `.cast` file.
18. **Retention choices are the Mac's**: 7, 30 (default), 90 days, forever; 2 GiB cap; 64 MiB per session.
19. **`Passthrough.Windows` is created in this stage** and holds every Windows API that is not UI.
20. **The iroh listener keeps proven addresses in memory only**, as the Mac's does.
21. **`lock` is honoured whatever `macState.control` says** (see the first correction).
22. **Not ported**: Mac-terminal viewers and themes, screen passes, push registration storage, the event log, `control`, the shared iPhone slot, reading paused by a slow viewer.
23. **Endpoint ids are logged, shortened; 64-hex strings are not redacted.**
24. **The transcript read is collected in the gate (bounded at 8 MiB of output) before lines are built**, so `done` lands on the true last line; the interface is still chunked for the pipe.

## Corrections to the master plan

1. **`macState` with `control:false` and "Lock from the phone: supported" disagree** on today's phones: `control` is documented as "this phone may send `setAwake`, `setVPN` and `lock`" (`protocol/README.md:530`) and the iPhone hides its controls without it (`iOS/App/Home/MacHomeView.swift:571`). Fix: the PC honours `lock` regardless, and stage 2 shows Lock for a PC from `host.kind`, not from `control`. Until then Lock is simply not offered for a PC.
2. **The grant before the TLS listener exists** is not specified, and phones drop a grant without a certificate hash and a port. This stage sends a zero pin, port 7893 and no addresses (2.12).
3. **`ISessionHost`'s events lack `Replaying`**, and "`AttachAsync` returning a generation" is replaced by a caller-chosen generation (decisions 2 and 3).
4. **"`HostSession` opens grant channels to every paired device"**: channels go to every *attached* device, paired or not, because an unpaired one needs a channel to take its code (an iPad especially).
5. **Stage 3's PR order** lists "relay settings, reset identity" last and "recording and history" before it; kept. But "grant plumbing in `ControlClient` + redaction" cannot include the peer check's Windows half, which needs `Passthrough.Windows`; the check's seam lands in PR 1 and its implementation in PR 6, and no grant can be sent in between.
6. **The flyout's "On, idle" second line** ("On this network and from anywhere") and the **Quit dialog's** three buttons assume the service; this stage uses "From anywhere" and a two-button dialog, and stage 4 restores the plan's text.
7. **"Access first granted" notice** offers **Allow screen** · **Revoke** in the plan; there is no screen until stage 5, so it is **OK** · **Revoke** here.
8. **`ShellAccessStore.swift, ScreenPassStore.swift → Shell/AccessStore`**: `ScreenPassStore` holds passes *to other Macs' screens* (the viewer role) and is not part of the host's access store; it belongs to stage 8. `viewer.` passes are never minted by a PC (the plan says so elsewhere), so the store has one item, not the Mac's two.
9. **The PC's answer table** omits `screenPass`, `screenRevoke`, and `rdp` before the service exists. Proposed: `bad_request`, `bad_request`, and `rdp_unavailable` with `detail` `service`.
10. **No wire signal for "this phone's Shell switch is off"** exists in the protocol changes, though the phone's state table has a sentence for it. Proposed: `not_allowed` on `open` and `attach`.
11. **PowerShell 7 "found under Program Files"**: for the Store install that is `%ProgramFiles%\WindowsApps\…`, found through the package manager, not by a fixed path; and whether an unpackaged process may start it is unmeasured (first risk).
12. **`FileProvenAddressStore` is listed with the iroh listener**; the Mac's iroh listener does not use one (only the TLS listener does). Ported now, first used in stage 4.

## Open questions for the owner (each with a recommended default)

1. **Should turning Remote access off also end running shells?** Default: yes, as on the Mac ("no shell outlives the setting"). The alternative (shells keep running, unreachable) leaves programs running with no way to see them.
2. **May Remote access turn Start at login on by itself?** Default: yes, with the caption saying so; turning Remote access off leaves Start at login as it is.
3. **Is plain text enough for the history window in this stage?** Default: yes, with **Open file** for the `.cast`. A drawn replay needs a terminal emulator in the Windows app, which nothing else needs before stage 8.
4. **Per-user Git for Windows and `dotnet tool` PowerShell are not offered as shells** because they live in folders your account can write. Default: keep them out. Allowing them would be one setting ("Also list shells installed for this account only") in a later PR.
5. **Which WSL distros to hide.** Default: the container engines' (`docker-desktop*`, `rancher-desktop*`, `podman-machine-*`). A distro you want hidden for another reason would need a per-distro switch; not planned.
6. **Reset identity strands phones until the next cable connection** in this stage (there is no second path to tell them). Default: accept, with the confirmation saying so; stage 4's local path softens it.
7. **Rust on your PC.** Building the app from source now needs rustup and the MSVC build tools once (about 1.5 GB). Default: require it and document it; CI builds prove it. The alternative, committing a prebuilt DLL, goes against "first-party source is built, not committed".
8. **The relay by default is n0's public relays**, as on the Mac. Default: keep; your own relay is one dialog away.
