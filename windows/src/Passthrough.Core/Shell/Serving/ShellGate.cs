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
    /// A phone asked for the screen through Remote Desktop (<c>rdp</c>), and may see it: why it can't be had now, in
    /// <see cref="HostInfo.Rdp"/>'s words, until the relay exists (stage 5).
    /// </summary>
    public Func<string, string> RdpUnavailable { get; init; } = _ => "off";

    /// <summary>Something a person would want in the log ("iPhone opened a session"). Never secrets.</summary>
    public Action<string>? Event { get; init; }
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

    public ShellGate(ShellSessionManager manager, TranscriptStore transcripts, ShellAccessStore access, HandshakeLimiter limiter,
        ShellGateHooks? hooks = null, TimeProvider? time = null, Action<string>? log = null)
    {
        Manager = manager;
        Transcripts = transcripts;
        Access = access;
        _limiter = limiter;
        Hooks = hooks ?? new ShellGateHooks();
        Time = time ?? TimeProvider.System;
        Log = log;
    }

    internal ShellSessionManager Manager { get; }
    internal TranscriptStore Transcripts { get; }
    internal ShellAccessStore Access { get; }
    internal ShellGateHooks Hooks { get; }
    internal TimeProvider Time { get; }
    internal Action<string>? Log { get; }

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

    /// <summary>Runs the handshake on <paramref name="stream"/> within the admission's time, then the connection; owns the stream.</summary>
    public async Task ServeAsync(Admission admission, Stream stream, bool expectHello = true)
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
            var phoneId = proof is null ? null : Verify(proof, nonce);
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
                connection = new ShellConnection(this, stream, reader, phoneId, Hooks.Label(phoneId));
                _connections.Add(connection);
            }
            Log?.Invoke("shell: a phone connected");
            await connection.RunAsync().ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException or LineTooLongException) { }
        finally
        {
            Abandon(admission);
            if (connection is not null) lock (_lock) _connections.Remove(connection);
            connection?.Close();
            stream.Dispose();
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
    private string? Verify(byte[] line, byte[] nonce)
    {
        if (Decode(line) is not { T: ShellEnvelope.Proof, PhoneID: { } phoneId, Mac: { } macText }) return null;
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
        if (matched is not { } index) return null;
        if (index == 0 && keys.Count > 1 && keys[0] is { } proven)
            ThreadPool.QueueUserWorkItem(_ => Access.ConfirmCurrentKey(phoneId, proven));
        return phoneId;
    }

    /// <summary>Ends <paramref name="phoneId"/>'s connections and the sessions it opened (it was revoked).</summary>
    public void Disconnect(string phoneId)
    {
        List<ShellConnection> closing;
        lock (_lock) closing = [.. _connections.Where(c => c.PhoneId == phoneId)];
        closing.ForEach(c => c.Close());
        Manager.CloseSessions(phoneId);
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
        var list = Manager.Sessions;
        foreach (var connection in Connections()) connection.SendSessions(list);
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

    /// <summary>Tells every phone why the host is about to go (<c>sleeping</c>, <c>turned_off</c>, <c>shutting_down</c>).</summary>
    public async Task GoingAwayAsync(string reason)
    {
        try
        {
            await Task.WhenAll(Connections().Select(c => c.SendAndWaitAsync(new ShellEnvelope(ShellEnvelope.GoingAway) { Reason = reason })))
                .WaitAsync(TimeSpan.FromSeconds(2), Time).ConfigureAwait(false);
        }
        catch (TimeoutException) { } // going anyway
    }

    private List<ShellConnection> Connections()
    {
        lock (_lock) return [.. _connections];
    }
}
