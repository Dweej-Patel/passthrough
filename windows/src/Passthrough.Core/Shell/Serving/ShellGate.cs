using System.Security.Cryptography;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Core.Shell.Serving;

/// <summary>What the gate asks the rest of the host. Each may be called on any thread and must not block for long.</summary>
public sealed class ShellGateHooks
{
    /// <summary>Sent right after <c>ready</c> (the iroh id, relay and its token, addresses); null: none.</summary>
    public Func<ShellEnvelope?> MacInfo { get; init; } = () => null;

    /// <summary>What the host says about itself to a phone (<c>host</c>), after <c>macInfo</c>.</summary>
    public Func<string, HostInfo?> Host { get; init; } = _ => null;

    /// <summary>The host's state as this phone may see it (<c>macState</c>); null: none sent.</summary>
    public Func<string, HostState?> State { get; init; } = _ => null;

    /// <summary>What to call a phone in sessions and events.</summary>
    public Func<string, string> Label { get; init; } = id => id;

    /// <summary>A phone asked the host to lock its screen: null when done, else why not. Unset: not offered.</summary>
    public Func<string, ShellError?>? Lock { get; init; }

    /// <summary>
    /// A phone asked for the screen through Remote Desktop (<c>rdp</c>) and may see it, but there is no relay here:
    /// why, in <see cref="HostInfo.Rdp"/>'s words.
    /// </summary>
    public Func<string, string> RdpUnavailable { get; init; } = _ => "service";

    /// <summary>This PC's Remote Desktop, when the relay runs here (the service); null: none (<see cref="RdpUnavailable"/> answers).</summary>
    public Screen.IRemoteDesktopGate? RemoteDesktop { get; init; }

    /// <summary>The account that granted a phone (whose consent to Screen counts, whose caps it shares).</summary>
    public Func<string, string?> AccountOf { get; init; } = _ => null;

    /// <summary>A view of the screen started and ended (the log, the after-view notice).</summary>
    public Action<Screen.RelayRecord>? ViewEnded { get; init; }
    public Action<Screen.RelayRecord>? ViewStarted { get; init; }

    /// <summary>A phone's screen grant for a computer waits for the owner at this host (a PC: Windows asks for a password).</summary>
    public bool ScreenNeedsOwner { get; init; } = true;

    /// <summary>
    /// A phone hands this host access to another computer (<c>computerPass</c>, stage 7): kept by the account the phone
    /// belongs to. Null when kept, else the error the phone is told. Unset: refused.
    /// </summary>
    public Func<string, string, ShellEnvelope, Task<ShellError?>>? SaveComputerPass { get; init; }

    /// <summary>A phone gave a computer access here (the notice that stays until the owner answers it).</summary>
    public Action<string, Access.ShellComputer>? ComputerGranted { get; init; }

    /// <summary>Something a person would want in the log ("iPhone opened a session"). Never secrets.</summary>
    public Action<string>? Event { get; init; }

    /// <summary>
    /// A computer viewing the screen asked to sync clipboards (<c>clipSync</c>): the stream to whatever owns that
    /// account's clipboard (the tray app in its session), or why there is none (<c>clip_sync_off</c>,
    /// <c>clip_sync_unavailable</c>). Asked with the device's id and label. Unset: unavailable.
    /// </summary>
    public Func<string, string, CancellationToken, Task<(Stream? Stream, ShellError? Error)>>? ClipSync { get; init; }
}

/// <summary>
/// Where every connection to the host's shell comes in, whatever carried it (iroh now; TLS from stage 4): the
/// handshake (a port of ShellGate in ShellListener.swift), then a <see cref="ShellConnection"/> per proven phone.
/// Unproven attempts hold a <see cref="HandshakeLimiter"/> slot, few at once and few from one address, each for a
/// bounded time. A proof is always checked against two keys, so an unknown phone costs what a wrong key does.
/// </summary>
public sealed class ShellGate
{
    private readonly HandshakeLimiter _limiter;
    private readonly Lock _lock = new();
    private readonly HashSet<ShellConnection> _connections = [];
    private readonly HashSet<Admission> _admissions = [];
    private bool _stopped;

    /// <summary>A gate for the shells of the account this process runs as (the tray app hosting them itself).</summary>
    public ShellGate(ShellSessionManager manager, TranscriptStore transcripts, IShellAccess access, HandshakeLimiter limiter,
        ShellGateHooks? hooks = null, TimeProvider? time = null, Action<string>? log = null)
        : this(new LocalSessionHost(manager, transcripts), access, limiter, hooks, time, log)
    {
    }

    /// <summary>A gate for one account's shells, wherever they are (in process, or across the service's pipe).</summary>
    public ShellGate(ISessionHost host, IShellAccess access, HandshakeLimiter limiter, ShellGateHooks? hooks = null, TimeProvider? time = null,
        Action<string>? log = null)
        : this(_ => host, access, limiter, hooks, time, log)
    {
    }

    /// <summary>A gate whose phones each reach the shells of the account that owns them (the service, on a shared PC).</summary>
    public ShellGate(Func<string, ISessionHost> hostFor, IShellAccess access, HandshakeLimiter limiter, ShellGateHooks? hooks = null,
        TimeProvider? time = null, Action<string>? log = null)
    {
        HostFor = hostFor;
        Access = access;
        _limiter = limiter;
        Hooks = hooks ?? new ShellGateHooks();
        Time = time ?? TimeProvider.System;
        Log = log;
    }

    /// <summary>The shells a phone reaches: those of the account that owns it.</summary>
    internal Func<string, ISessionHost> HostFor { get; }
    internal IShellAccess Access { get; }
    internal ShellGateHooks Hooks { get; }
    internal TimeProvider Time { get; }
    internal Action<string>? Log { get; }

    /// <summary>Views at once: 2 a phone, 4 in all, shared by every path.</summary>
    internal Screen.ScreenViewLimit Views { get; } = new();

    /// <summary>How often a grant may open the screen (RECONCILIATION's relay caps).</summary>
    public Screen.RelayRateLimit RelayRate { get; } = new();

    private readonly Dictionary<string, DateTimeOffset> _stoppedUntil = [];

    /// <summary>After Stop (or Screen turned off), a phone's next <c>rdp</c> for 30 s answers <c>try_later</c>.</summary>
    internal int StoppedFor(string phoneId)
    {
        lock (_lock)
            return _stoppedUntil.TryGetValue(phoneId, out var until) && until > Time.GetUtcNow() ? (int)Math.Ceiling((until - Time.GetUtcNow()).TotalSeconds) : 0;
    }

    /// <summary>
    /// Ends <paramref name="phoneId"/>'s views of the screen and keeps its shell connections (Stop, Screen turned off);
    /// its other connections are told why (<c>screenEnded</c>).
    /// </summary>
    public void DisconnectScreen(string phoneId, string reason)
    {
        List<ShellConnection> all;
        lock (_lock)
        {
            all = [.. _connections.Where(c => c.PhoneId == phoneId)];
            _stoppedUntil[phoneId] = Time.GetUtcNow().AddSeconds(30);
        }
        // Clipboard sync lasts only while the screen is viewed: it goes with the views.
        foreach (var c in all.Where(c => c.IsRelaying || c.IsClip)) c.Close();
        foreach (var c in all.Where(c => !c.IsRelaying && !c.IsClip)) c.SendScreenEnded(reason);
    }

    /// <summary>How long after a device's last view ends its clipboard sync is closed (within a second: protocol/README.md), so a view that reconnects keeps it.</summary>
    internal static readonly TimeSpan ClipSyncLinger = TimeSpan.FromMilliseconds(800);

    /// <summary>One clipboard sync per device: a new one replaces the old, which closes.</summary>
    internal void ClipSyncStarted(ShellConnection started)
    {
        List<ShellConnection> old;
        lock (_lock) old = [.. _connections.Where(c => c != started && c.PhoneId == started.PhoneId && c.IsClip)];
        old.ForEach(c => c.Close());
    }

    /// <summary>A view of the screen ended: if that device has none left in a moment, its clipboard sync closes.</summary>
    internal void ViewEnded(string phoneId)
    {
        _ = Task.Delay(ClipSyncLinger, Time).ContinueWith(_ =>
        {
            if (IsViewing(phoneId)) return;
            List<ShellConnection> clips;
            lock (_lock) clips = [.. _connections.Where(c => c.PhoneId == phoneId && c.IsClip)];
            clips.ForEach(c => c.Close());
        }, TaskScheduler.Default);
    }

    /// <summary>A device is syncing its clipboard with this PC now.</summary>
    public bool IsSyncingClipboard(string phoneId)
    {
        lock (_lock) return _connections.Any(c => c.PhoneId == phoneId && c.IsClip);
    }

    /// <summary>A phone or computer is viewing the screen now (one of its connections carries Remote Desktop's bytes).</summary>
    public bool IsViewing(string phoneId)
    {
        lock (_lock) return _connections.Any(c => c.PhoneId == phoneId && c.IsRelaying);
    }

    /// <summary>A phone or computer connected or left (by id): the PC's tray shows who is on it now.</summary>
    public event Action<string>? ConnectionsChanged;

    internal void RaiseConnectionsChanged(string phoneId) => ConnectionsChanged?.Invoke(phoneId);

    /// <summary>The phones connected now, one entry per connection.</summary>
    public IReadOnlyList<string> ConnectedPhones { get { lock (_lock) return [.. _connections.Select(c => c.PhoneId)]; } }

    public int PendingHandshakes => _limiter.Count;

    /// <summary>
    /// One attempt's hold on a handshake slot, from before its stream exists (an iroh attempt holds one through its
    /// QUIC handshake) until it has proved itself, failed, or timed out. At the timeout its stream is closed, or, while
    /// it has none, <c>abandon</c> runs.
    /// </summary>
    public sealed class Admission
    {
        private readonly Lock _lock = new();
        private readonly Action _abandon;
        private Stream? _stream;
        private bool _over;
        internal HandshakeLimiter.Slot? Slot;

        internal Admission(string host, Action abandon) => (Host, _abandon) = (host, abandon);

        internal string Host { get; }

        public bool IsOver { get { lock (_lock) return _over; } }

        /// <summary>The stream it now has; false (and the stream closed) when it is already over.</summary>
        internal bool Attach(Stream stream)
        {
            lock (_lock)
            {
                if (!_over) { _stream = stream; return true; }
            }
            stream.Dispose();
            return false;
        }

        /// <summary>Drops the attempt: closes its stream, or abandons it while it has none.</summary>
        internal void Drop()
        {
            Stream? stream;
            lock (_lock)
            {
                if (_over) return;
                _over = true;
                stream = _stream;
            }
            if (stream is not null) stream.Dispose(); else _abandon();
        }
    }

    /// <summary>
    /// A handshake slot for an attempt from <paramref name="host"/> (at most <paramref name="maxForHost"/> at once from
    /// it, else the limiter's per-host cap), or null when it must be refused. Hand the admission its stream with
    /// <see cref="ServeAsync(Admission, Stream, bool)"/>, or <see cref="Abandon"/> it if none comes.
    /// </summary>
    public Admission? Admit(string host, Action abandon, int? maxForHost = null)
    {
        lock (_lock) if (_stopped) return null;
        var admission = new Admission(host, abandon);
        admission.Slot = _limiter.Acquire(host, admission.Drop, maxForHost);
        if (admission.Slot is null) return null;
        lock (_lock)
        {
            if (_stopped) { admission.Slot.Release(); return null; }
            _admissions.Add(admission);
        }
        return admission;
    }

    /// <summary>The attempt ended before it had a stream: frees its slot.</summary>
    public void Abandon(Admission admission)
    {
        admission.Slot?.Release();
        lock (_lock) _admissions.Remove(admission);
    }

    /// <summary>
    /// Serves one connection until it ends; owns <paramref name="stream"/>. <paramref name="host"/> is the peer's
    /// address, what its handshake slot is counted against. When <paramref name="expectHello"/>, the first line must be <c>hello</c>.
    /// </summary>
    public Task ServeAsync(Stream stream, string host, bool expectHello = true, int? maxForHost = null)
    {
        if (Admit(host, stream.Dispose, maxForHost) is not { } admission)
        {
            stream.Dispose();
            return Task.CompletedTask;
        }
        return ServeAsync(admission, stream, expectHello);
    }

    /// <summary>
    /// Runs the handshake on <paramref name="stream"/> within the admission's time, then the connection; owns the stream.
    /// <paramref name="binding"/> is what a computer's signature must be bound to on this listener (its certificate's
    /// hash on TLS, its endpoint id on iroh); without one no computer is let in.
    /// </summary>
    public async Task ServeAsync(Admission admission, Stream stream, bool expectHello = true, ProofBinding? binding = null)
    {
        var slot = admission.Slot!;
        if (!admission.Attach(stream) || slot.IsReleased) { Abandon(admission); stream.Dispose(); return; }
        ShellConnection? connection = null;
        try
        {
            var reader = new ShellLineReader(stream, RemoteShell.HandshakeLineLimit);
            if (expectHello && (await reader.ReadLineAsync().ConfigureAwait(false) is not { } hello || Decode(hello)?.T != ShellEnvelope.Hello))
            {
                Log?.Invoke("shell: refused a connection that did not say hello");
                return;
            }
            var nonce = RandomNumberGenerator.GetBytes(RemoteShell.NonceLength);
            await stream.WriteAsync(new ShellEnvelope(ShellEnvelope.Challenge) { Nonce = Convert.ToBase64String(nonce) }.EncodeLine()).ConfigureAwait(false);
            var proof = await reader.ReadLineAsync().ConfigureAwait(false);
            var phoneId = proof is null ? null : Verify(proof, nonce, binding);
            if (phoneId is null)
            {
                Log?.Invoke("shell: refused a connection that could not prove a shell key");
                Abandon(admission);
                try
                {
                    await stream.WriteAsync(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.NotAuthorized.ToWire() }.EncodeLine())
                        .AsTask().WaitAsync(TimeSpan.FromSeconds(1), Time).ConfigureAwait(false);
                }
                catch (Exception e) when (e is IOException or ObjectDisposedException or TimeoutException) { }
                return;
            }
            // Timed out meanwhile: the slot is gone and the stream closed.
            if (!slot.Release()) return;
            lock (_lock) _admissions.Remove(admission);
            _limiter.Proven(admission.Host);
            reader.Limit = RemoteShell.LineLimit;
            lock (_lock)
            {
                if (_stopped) return;
                connection = new ShellConnection(this, HostFor(phoneId), stream, reader, phoneId, Hooks.Label(phoneId));
                _connections.Add(connection);
            }
            Log?.Invoke("shell: a phone connected");
            // A computer coming or going changes its granter's computerList (connected).
            if (Computers.IsComputerId(phoneId)) PushComputers();
            RaiseConnectionsChanged(phoneId);
            await connection.RunAsync().ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException or LineTooLongException) { }
        finally
        {
            Abandon(admission);
            if (connection is not null) lock (_lock) _connections.Remove(connection);
            connection?.Close();
            stream.Dispose();
            if (connection is not null && Computers.IsComputerId(connection.PhoneId)) PushComputers();
            if (connection is not null) RaiseConnectionsChanged(connection.PhoneId);
        }
    }
    private static ShellEnvelope? Decode(byte[] line)
    {
        try { return ShellEnvelope.Decode(line); }
        catch (Protocol.ProtocolException) { return null; }
    }

    /// <summary>
    /// The phone's id when <paramref name="line"/> proves one of its keys for <paramref name="nonce"/>. Every proof is
    /// checked against two keys whatever the phone: missing ones (an unknown phone, no previous key) are throwaway keys.
    /// Proving the current key while a previous one is still accepted retires the previous one.
    /// </summary>
    private string? Verify(byte[] line, byte[] nonce, ProofBinding? binding)
    {
        if (Decode(line) is not { T: ShellEnvelope.Proof, PhoneID: { } phoneId, Mac: { } macText } proof) return null;
        // A computer also signs the challenge with its identity key, bound to this host (stage 7 a.1). One ECDSA check
        // always runs for a computer id, against a decoy when there's nothing real, so a missing record costs the same.
        var computerOk = true;
        if (Computers.IsComputerId(phoneId))
        {
            byte[]? sig = null;
            try { sig = proof.Sig is { } s ? Convert.FromBase64String(s) : null; } catch (FormatException) { }
            var key = Access.Computer(phoneId)?.IdentityKey;
            var real = key is not null && sig is { Length: 64 } && binding is not null;
            var message = ComputerProof.Message(nonce, binding?.Path ?? 0, binding?.HostBinding ?? new byte[32], phoneId);
            var valid = ComputerProof.IsValid(real ? sig! : ComputerProof.DecoySignature, real ? key! : ComputerProof.DecoyKey, message);
            computerOk = real && valid;
        }
        byte[] mac;
        try { mac = Convert.FromBase64String(macText); }
        catch (FormatException) { return null; }
        var keys = Access.CandidateKeys(phoneId).Take(2).Select(k => k.Length >= RemoteShell.KeyLength ? k : null).ToList();
        int? matched = null;
        for (var i = 0; i < 2; i++)
        {
            var key = i < keys.Count ? keys[i] : null;
            var valid = RemoteShell.ProofIsValid(mac, key ?? RandomNumberGenerator.GetBytes(RemoteShell.KeyLength), nonce);
            if (valid && key is not null && matched is null) matched = i;
        }
        if (matched is not { } index || !computerOk) return null;
        if (index == 0 && keys.Count > 1 && keys[0] is { } proven)
            ThreadPool.QueueUserWorkItem(_ => Access.ConfirmCurrentKey(phoneId, proven));
        if (Computers.IsComputerId(phoneId)) ThreadPool.QueueUserWorkItem(_ => Access.ComputerUsed(phoneId));
        return phoneId;
    }

    /// <summary>Ends <paramref name="phoneId"/>'s connections and the sessions it opened (it was revoked).</summary>
    public void Disconnect(string phoneId)
    {
        List<ShellConnection> closing;
        lock (_lock) closing = [.. _connections.Where(c => c.PhoneId == phoneId)];
        closing.ForEach(c => c.Close());
        HostFor(phoneId).CloseSessions(phoneId);
    }

    /// <summary>Drops every attempt and connection, and refuses new ones. Sessions keep running.</summary>
    public void Stop()
    {
        List<ShellConnection> closing;
        List<Admission> pending;
        lock (_lock)
        {
            _stopped = true;
            closing = [.. _connections];
            pending = [.. _admissions];
            _admissions.Clear();
        }
        pending.ForEach(a => { a.Slot?.Release(); a.Drop(); });
        closing.ForEach(c => c.Close());
    }

    /// <summary>Sends every phone the session list, unasked (the manager's list changed).</summary>
    public void PushSessions()
    {
        foreach (var connection in Connections()) connection.SendSessions(connection.Host.Sessions);
    }

    /// <summary>Sends the phones of <paramref name="host"/>'s account its session list (it changed, or the tray app came or went).</summary>
    public void PushSessions(ISessionHost host)
    {
        foreach (var connection in Connections().Where(c => c.Host == host)) connection.SendSessions(host.Sessions);
    }

    /// <summary>Sends <c>host</c> again to the phones of <paramref name="host"/>'s account.</summary>
    public void PushHost(ISessionHost host)
    {
        foreach (var connection in Connections().Where(c => c.Host == host)) connection.SendHost();
    }

    /// <summary>Sends <c>computerList</c> again to every phone that asked for it (a grant, a revoke, a computer came or went).</summary>
    public void PushComputers()
    {
        foreach (var connection in Connections()) connection.SendComputers();
    }

    /// <summary>Sends every phone the host's state again.</summary>
    public void PushState()
    {
        foreach (var connection in Connections()) connection.SendState();
    }

    /// <summary>Sends every phone <c>host</c> again (signed in, shells, the screen changed).</summary>
    public void PushHost()
    {
        foreach (var connection in Connections()) connection.SendHost();
    }

    /// <summary>
    /// Tells every phone why the host is about to go (<c>sleeping</c>, <c>turned_off</c>, <c>shutting_down</c>), waits for
    /// the lines to be written up to <paramref name="limit"/> (2 s when not given), and with <paramref name="close"/>
    /// closes every connection. The gate keeps accepting (a PC that wakes takes phones again).
    /// </summary>
    public async Task GoingAwayAsync(string reason, TimeSpan? limit = null, bool close = false)
    {
        var connections = Connections();
        try
        {
            await Task.WhenAll(connections.Select(c => c.SendAndWaitAsync(new ShellEnvelope(ShellEnvelope.GoingAway) { Reason = reason })))
                .WaitAsync(limit ?? TimeSpan.FromSeconds(2), Time).ConfigureAwait(false);
        }
        catch (TimeoutException) { } // going anyway
        if (close) connections.ForEach(c => c.Close());
    }

    private List<ShellConnection> Connections()
    {
        lock (_lock) return [.. _connections];
    }
}
