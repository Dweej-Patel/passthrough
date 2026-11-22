using System.Net;
using System.Threading.Channels;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;

namespace Passthrough.Core.Client;

/// <summary>Access to another computer's shell, as this PC keeps it (a port of ShellCredential in ShellClient.swift).</summary>
public sealed record ShellCredential(
    string HostId, string HostName, string CertSha256, byte[] ShellKey, string ClientId,
    int Port, IReadOnlyList<string> Addresses,
    string? IrohId = null, string? IrohRelay = null, string? RelayToken = null, string? HostKind = null)
{
    /// <summary>Never shows the key; the relay token only as redacted.</summary>
    public override string ToString() =>
        $"ShellCredential(host: {HostName}, client: {ClientId}, port: {Port}, addresses: {Addresses.Count}, iroh: {IrohId ?? "none"}, relayToken: {(RelayToken is null ? "none" : "<redacted>")})";
}

public enum ShellConnectMode { Automatic, LocalOnly }
public enum ShellPath { Local, Direct, Relay, Unknown }

public readonly record struct ShellEndpoint(string Host, int Port);

/// <summary>A connection's stream, and the local address it left from (null over iroh).</summary>
public interface IShellStream : IAsyncDisposable
{
    Stream Stream { get; }
    IPAddress? LocalAddress { get; }
}

/// <summary>One TLS 1.3 connection that accepts exactly the certificate whose SHA-256 is the pin.</summary>
public interface IPinnedTlsDialer
{
    Task<IShellStream> ConnectAsync(ShellEndpoint endpoint, string certSha256, CancellationToken cancel);
}

public interface IShellIrohDialer
{
    Task<IShellStream> ConnectAsync(string irohId, string? relayUrl, string? relayToken, IReadOnlyList<string> addresses, CancellationToken cancel);
    ShellPath PathOf(IShellStream stream);
}

public abstract record ShellClientEvent
{
    public sealed record Ready(ShellPath Path) : ShellClientEvent;
    public sealed record HostInfoMessage(ShellEnvelope Message) : ShellClientEvent;
    public sealed record Host(Shell.HostInfo Value) : ShellClientEvent;
    public sealed record State(HostState Value) : ShellClientEvent;
    public sealed record Sessions(IReadOnlyList<ShellSessionInfo> List) : ShellClientEvent;
    public sealed record Opened(string Session) : ShellClientEvent;
    public sealed record OpenFailed(ShellError Reason, string? Message) : ShellClientEvent;
    public sealed record Output(string Session, ReadOnlyMemory<byte> Data) : ShellClientEvent;
    public sealed record Replaying(string Session) : ShellClientEvent;
    public sealed record Attached(string Session) : ShellClientEvent;
    public sealed record Ended(string Session, int ExitStatus) : ShellClientEvent;
    public sealed record Detached(string Session) : ShellClientEvent;
    public sealed record Failed(ShellError Reason, string? Session) : ShellClientEvent;
    public sealed record GoingAway(string Reason) : ShellClientEvent;
    /// <summary>Once per <see cref="ShellClient.Connect"/>: the connection is over (an error, or none for a clean end).</summary>
    public sealed record Disconnected(Exception? Error) : ShellClientEvent;
    /// <summary>
    /// The host answered <see cref="ShellClient.RequestScreen"/>: the stream is now the screen's (ScreenVideoWire's with
    /// <c>video</c>), starting with <paramref name="InitialBytes"/>. The client lets go of it and sends and reports nothing
    /// more, not even <see cref="Disconnected"/>; the receiver disposes the stream.
    /// </summary>
    public sealed record Screen(IShellStream Stream, ReadOnlyMemory<byte> InitialBytes) : ShellClientEvent;
}

/// <summary>The host stopped answering pings (15 s of silence).</summary>
public sealed class StoppedAnsweringException() : IOException("The computer stopped answering.");

/// <summary>The host refused the proof, or ended the handshake with an error.</summary>
public sealed class ShellRefusedException(ShellError reason) : IOException($"Refused: {reason.ToWire()}")
{
    public ShellError Reason { get; } = reason;
}

/// <summary>
/// One connection to another computer's shell (a port of ShellClient.swift, for the PC as viewer): it dials every
/// candidate (found addresses first, then the granted ones 0.25 s apart, iroh 0.75 s after the first), the first to
/// prove itself wins and every other attempt is dropped; then the shell protocol on that path, with a ping after 5 s of
/// silence and giving up at 15 s. It doesn't reconnect: <see cref="ShellClientEvent.Disconnected"/> is final for a
/// <see cref="Connect"/>; redialling is the caller's. Events are delivered in order on one task.
/// </summary>
public sealed class ShellClient : IAsyncDisposable
{
    public static readonly TimeSpan AttemptTimeout = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan IrohAttemptTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan Stagger = TimeSpan.FromMilliseconds(250);
    public static readonly TimeSpan IrohDelay = TimeSpan.FromMilliseconds(750);
    public static readonly TimeSpan PingAfter = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan Silence = TimeSpan.FromSeconds(15);

    private readonly ShellCredential _credential;
    private readonly IPinnedTlsDialer? _tls;
    private readonly IShellIrohDialer? _iroh;
    private readonly ShellConnectMode _mode;
    private readonly Trust.IComputerIdentity? _identity;
    private readonly TimeProvider _time;
    private readonly Channel<ShellClientEvent> _events = Channel.CreateUnbounded<ShellClientEvent>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Channel<byte[]> _outgoing = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _closing = new();
    private readonly Lock _lock = new();
    private IShellStream? _winner;
    private int _nextRef;
    private int? _pendingOpen;
    private string? _attached;
    private long _lastHeard;
    private int _connected;
    private volatile bool _screenRequested;
    private volatile bool _handedOver;

    public ShellClient(ShellCredential credential, IPinnedTlsDialer? tls, IShellIrohDialer? iroh, Action<ShellClientEvent> onEvent,
        ShellConnectMode mode = ShellConnectMode.Automatic, TimeProvider? time = null, Trust.IComputerIdentity? identity = null)
    {
        _credential = credential;
        _identity = identity;
        _tls = tls;
        _iroh = iroh;
        _mode = mode;
        _time = time ?? TimeProvider.System;
        _ = Task.Run(async () =>
        {
            await foreach (var e in _events.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                try { onEvent(e); }
                catch (Exception) { } // a listener's failure never stops the connection
            }
        });
    }

    public ShellPath? Path { get; private set; }

    public bool OpenPending { get { lock (_lock) return _pendingOpen is not null; } }

    // MARK: Where to dial

    /// <summary>Found endpoints first, then each granted address at the credential's port, without repeats.</summary>
    public static IReadOnlyList<ShellEndpoint> Candidates(ShellCredential c, IReadOnlyList<ShellEndpoint> discovered)
    {
        var seen = new HashSet<ShellEndpoint>();
        return [.. discovered.Concat(c.Addresses.Select(a => new ShellEndpoint(a, c.Port))).Where(seen.Add)];
    }

    /// <summary>
    /// Each candidate and when to start it: TCP 0.25 s apart, iroh 0.75 s after the first (at once with none), only
    /// in <see cref="ShellConnectMode.Automatic"/> and with a valid id. A credential whose pin is the no-listener pin
    /// (sixty-four zeros: a host without a listener) gets no TCP candidates.
    /// </summary>
    public static IReadOnlyList<(ShellEndpoint? Tcp, bool Iroh, TimeSpan Delay)> Schedule(ShellCredential c, IReadOnlyList<ShellEndpoint> discovered, ShellConnectMode mode)
    {
        var list = new List<(ShellEndpoint?, bool, TimeSpan)>();
        var noListener = c.CertSha256 == new string('0', 64);
        var tcp = noListener ? [] : Candidates(c, discovered);
        for (var i = 0; i < tcp.Count; i++) list.Add((tcp[i], false, Stagger * i));
        if (mode == ShellConnectMode.Automatic && IrohInfo.IsValidId(c.IrohId))
            list.Add((null, true, tcp.Count == 0 ? TimeSpan.Zero : IrohDelay));
        return [.. list.OrderBy(x => x.Item3).ThenBy(x => x.Item2 ? 1 : 0)];
    }

    // MARK: Connecting

    /// <summary>Dials, proves, and serves until the connection ends; <see cref="ShellClientEvent.Disconnected"/> says when.</summary>
    public void Connect(IReadOnlyList<ShellEndpoint>? discovered = null)
    {
        if (Interlocked.Exchange(ref _connected, 1) == 1) return;
        _ = Task.Run(() => RunAsync(discovered ?? []));
    }

    private async Task RunAsync(IReadOnlyList<ShellEndpoint> discovered)
    {
        Exception? error = null;
        try
        {
            var (stream, reader, path) = await RaceAsync(discovered).ConfigureAwait(false);
            lock (_lock) _winner = stream;
            Path = path;
            Interlocked.Exchange(ref _lastHeard, _time.GetTimestamp());
            Emit(new ShellClientEvent.Ready(path));
            var writer = WriteAllAsync(stream.Stream);
            using var pinger = _time.CreateTimer(_ => Tick(), null, PingAfter, TimeSpan.FromSeconds(1));
            while (await reader.ReadLineAsync(_closing.Token).ConfigureAwait(false) is { } line)
            {
                Interlocked.Exchange(ref _lastHeard, _time.GetTimestamp());
                if (_screenRequested && IsScreenReady(line))
                {
                    // Past screenReady the bytes are the screen's, not lines: nothing more is read, sent or reported.
                    _handedOver = true;
                    _outgoing.Writer.TryComplete();
                    await writer.ConfigureAwait(false);
                    lock (_lock) _winner = null;
                    Emit(new ShellClientEvent.Screen(stream, reader.TakePending()));
                    return;
                }
                Handle(line);
            }
            _outgoing.Writer.TryComplete();
            await writer.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_silent) { error = new StoppedAnsweringException(); }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is IOException or ObjectDisposedException or Protocol.ProtocolException or InvalidOperationException) { error = e; }
        finally
        {
            IShellStream? winner;
            lock (_lock) winner = _winner;
            if (winner is not null) await winner.DisposeAsync().ConfigureAwait(false);
            if (!_handedOver) Emit(new ShellClientEvent.Disconnected(error));
            _events.Writer.TryComplete();
        }
    }

    private volatile bool _silent;

    private void Tick()
    {
        var quiet = _time.GetElapsedTime(Interlocked.Read(ref _lastHeard));
        if (quiet >= Silence)
        {
            _silent = true;
            _closing.Cancel();
        }
        else if (quiet >= PingAfter) Send(new ShellEnvelope(ShellEnvelope.Ping));
    }

    /// <summary>Every candidate on its schedule; the first to read <c>ready</c> wins and the rest are dropped.</summary>
    private async Task<(IShellStream Stream, ShellLineReader Reader, ShellPath Path)> RaceAsync(IReadOnlyList<ShellEndpoint> discovered)
    {
        var schedule = Schedule(_credential, discovered, _mode);
        if (schedule.Count == 0) throw new IOException("Nowhere to dial this computer.");
        using var race = CancellationTokenSource.CreateLinkedTokenSource(_closing.Token);
        var won = new TaskCompletionSource<(IShellStream, ShellLineReader, ShellPath)>(TaskCreationOptions.RunContinuationsAsynchronously);
        var failures = 0;
        Exception? lastError = null;
        var startedAt = _time.GetTimestamp();
        var attempts = schedule.Select(async item =>
        {
            var wait = item.Delay - _time.GetElapsedTime(startedAt);
            if (wait > TimeSpan.Zero) await Task.Delay(wait, _time, race.Token).ConfigureAwait(false);
            IShellStream? stream = null;
            try
            {
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(race.Token);
                limit.CancelAfter(item.Iroh ? IrohAttemptTimeout : AttemptTimeout);
                if (item.Iroh)
                {
                    if (_iroh is null) throw new IOException("No iroh dialer.");
                    stream = await _iroh.ConnectAsync(_credential.IrohId!, _credential.IrohRelay, _credential.RelayToken, _credential.Addresses, limit.Token).ConfigureAwait(false);
                }
                else
                {
                    if (_tls is null) throw new IOException("No TLS dialer.");
                    stream = await _tls.ConnectAsync(item.Tcp!.Value, _credential.CertSha256, limit.Token).ConfigureAwait(false);
                }
                var reader = await HandshakeAsync(stream.Stream, sayHello: item.Iroh, limit.Token).ConfigureAwait(false);
                var path = item.Iroh ? _iroh!.PathOf(stream) : ShellPath.Local;
                if (won.TrySetResult((stream, reader, path))) { stream = null; race.Cancel(); }
            }
            catch (ShellRefusedException e)
            {
                // An error before ready ends every path with that reason.
                won.TrySetException(e);
                race.Cancel();
            }
            catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException or System.Security.Authentication.AuthenticationException
                or System.Net.Sockets.SocketException or Protocol.ProtocolException)
            {
                lock (won) { lastError = e is OperationCanceledException ? lastError : e; failures++; }
            }
            finally
            {
                if (stream is not null) await stream.DisposeAsync().ConfigureAwait(false);
            }
        }).ToList();
        _ = Task.WhenAll(attempts).ContinueWith(_ => won.TrySetException(lastError ?? new IOException("Couldn't reach this computer.")), TaskScheduler.Default);
        return await won.Task.ConfigureAwait(false);
    }

    /// <summary>hello (iroh only: on TLS the host speaks first), the challenge, the proof, and <c>ready</c>.</summary>
    private async Task<ShellLineReader> HandshakeAsync(Stream stream, bool sayHello, CancellationToken cancel)
    {
        var reader = new ShellLineReader(stream, RemoteShell.HandshakeLineLimit);
        if (sayHello) await stream.WriteAsync(new ShellEnvelope(ShellEnvelope.Hello) { PhoneID = _credential.ClientId }.EncodeLine(), cancel).ConfigureAwait(false);
        var challenge = Decode(await reader.ReadLineAsync(cancel).ConfigureAwait(false));
        if (challenge.T == ShellEnvelope.Error) throw new ShellRefusedException(Reason(challenge.Reason));
        if (challenge.T != ShellEnvelope.Challenge || challenge.Nonce is null) throw new IOException("The computer didn't send a challenge.");
        byte[] nonce;
        try { nonce = Convert.FromBase64String(challenge.Nonce); }
        catch (FormatException) { throw new IOException("The challenge wasn't base64."); }
        if (nonce.Length != RemoteShell.NonceLength) throw new IOException("The challenge was the wrong size.");
        await stream.WriteAsync(new ShellEnvelope(ShellEnvelope.Proof)
        {
            PhoneID = _credential.ClientId,
            Mac = Convert.ToBase64String(RemoteShell.Proof(_credential.ShellKey, nonce)),
            Sig = ComputerSignature(nonce, sayHello),
        }.EncodeLine(), cancel).ConfigureAwait(false);
        var answer = Decode(await reader.ReadLineAsync(cancel).ConfigureAwait(false));
        if (answer.T == ShellEnvelope.Error) throw new ShellRefusedException(Reason(answer.Reason));
        if (answer.T != ShellEnvelope.Ready) throw new IOException("The computer didn't say ready.");
        reader.Limit = RemoteShell.LineLimit;
        return reader;
    }

    /// <summary>
    /// As a computer (a <c>computer.</c> id), the identity key's signature bound to this host: its certificate's hash
    /// on TLS, its endpoint id on iroh (stage 7 a.1). Without the key nothing is sent.
    /// </summary>
    private string? ComputerSignature(byte[] nonce, bool iroh)
    {
        if (!Shell.Access.Computers.IsComputerId(_credential.ClientId)) return null;
        if (_identity is null) throw new IOException("This computer has no identity key to prove itself with.");
        var binding = Convert.FromHexString(iroh ? _credential.IrohId! : _credential.CertSha256);
        var message = Shell.Access.ComputerProof.Message(nonce, iroh ? Shell.Access.ComputerProof.PathIroh : Shell.Access.ComputerProof.PathTls, binding, _credential.ClientId);
        return Convert.ToBase64String(_identity.Sign(message));
    }

    private static ShellEnvelope Decode(byte[]? line) =>
        line is null ? throw new IOException("The computer closed the connection.") : ShellEnvelope.Decode(line);

    private static ShellError Reason(string? wire) => ShellErrorWire.IsKnown(wire) ? ShellErrorWire.Parse(wire) : ShellError.BadRequest;

    // MARK: After ready

    private void Handle(byte[] line)
    {
        try { HandleLine(line); }
        catch (FormatException) { } // bad base64 in one line: that line is dropped, not the connection
    }

    private void HandleLine(byte[] line)
    {
        ShellEnvelope m;
        try { m = ShellEnvelope.Decode(line); }
        catch (Protocol.ProtocolException) { return; } // a line that doesn't decode is dropped whole
        switch (m.T)
        {
            case ShellEnvelope.MacInfo: Emit(new ShellClientEvent.HostInfoMessage(m)); break;
            case ShellEnvelope.Host when m.HostInfo is { } host: Emit(new ShellClientEvent.Host(host)); break;
            case ShellEnvelope.MacState when m.State is { } state: Emit(new ShellClientEvent.State(state)); break;
            case ShellEnvelope.Sessions: Emit(new ShellClientEvent.Sessions(m.SessionList ?? [])); break;
            case ShellEnvelope.Opened when m.Session is { } opened:
                lock (_lock) { _pendingOpen = null; _attached = opened; }
                Emit(new ShellClientEvent.Opened(opened));
                break;
            case ShellEnvelope.Output when m.Session is { } s && m.Data is { } data:
                Emit(new ShellClientEvent.Output(s, Convert.FromBase64String(data)));
                break;
            case ShellEnvelope.Replaying when m.Session is { } r: Emit(new ShellClientEvent.Replaying(r)); break;
            case ShellEnvelope.Attached when m.Session is { } a: Emit(new ShellClientEvent.Attached(a)); break;
            case ShellEnvelope.Ended when m.Session is { } e:
                lock (_lock) if (_attached == e) _attached = null;
                Emit(new ShellClientEvent.Ended(e, m.ExitStatus ?? -1));
                break;
            case ShellEnvelope.Detached when m.Session is { } d:
                lock (_lock) if (_attached == d) _attached = null;
                Emit(new ShellClientEvent.Detached(d));
                break;
            case ShellEnvelope.GoingAway: Emit(new ShellClientEvent.GoingAway(m.Reason ?? "")); break;
            case ShellEnvelope.Ping: Send(new ShellEnvelope(ShellEnvelope.Pong)); break;
            case ShellEnvelope.Error:
                var reason = Reason(m.Reason);
                bool wasOpen;
                lock (_lock)
                {
                    wasOpen = m.Ref is { } r2 && r2 == _pendingOpen;
                    if (wasOpen) _pendingOpen = null;
                }
                Emit(wasOpen ? new ShellClientEvent.OpenFailed(reason, m.Message) : new ShellClientEvent.Failed(reason, m.Session));
                break;
        }
    }

    // MARK: Requests

    public void List() => Send(new ShellEnvelope(ShellEnvelope.List));

    /// <summary>A new session; <paramref name="shell"/> is a chooser id the host listed (omitted: its default).</summary>
    public void Open(int cols, int rows, string? shell = null)
    {
        int @ref;
        lock (_lock) { @ref = ++_nextRef; _pendingOpen = @ref; }
        Send(new ShellEnvelope(ShellEnvelope.Open) { Cols = cols, Rows = rows, Shell = shell, Ref = @ref });
    }

    public void Attach(string session, int cols, int rows)
    {
        lock (_lock) { _pendingOpen = null; _attached = session; }
        Send(new ShellEnvelope(ShellEnvelope.Attach) { Session = session, Cols = cols, Rows = rows });
    }

    /// <summary>Typing, in pieces of 16 KiB; dropped while an open is pending (there's no session yet).</summary>
    public void Input(ReadOnlyMemory<byte> data)
    {
        string? session;
        lock (_lock) session = _pendingOpen is null ? _attached : null;
        if (session is null) return;
        for (var offset = 0; offset < data.Length; offset += RemoteShell.OutputChunk)
            Send(new ShellEnvelope(ShellEnvelope.Input) { Session = session, Data = Convert.ToBase64String(data.Span.Slice(offset, Math.Min(RemoteShell.OutputChunk, data.Length - offset))) });
    }

    public void Resize(int cols, int rows)
    {
        string? session;
        lock (_lock) session = _attached;
        Send(new ShellEnvelope(ShellEnvelope.Resize) { Session = session, Cols = cols, Rows = rows });
    }

    public void Close(string session) => Send(new ShellEnvelope(ShellEnvelope.Close) { Session = session });

    public void SetViewing(bool on) => Send(new ShellEnvelope(ShellEnvelope.Viewing) { On = on });

    /// <summary>
    /// Asks for the host's screen: with <paramref name="video"/> its own stream (<c>screenVideo</c>), else Screen Sharing
    /// (<c>screen</c>). The answer is <see cref="ShellClientEvent.Screen"/>, or <see cref="ShellClientEvent.Failed"/> with the
    /// reason it won't (the connection then stays usable). Use a client of its own for the screen, never one with a session.
    /// </summary>
    public void RequestScreen(bool video)
    {
        _screenRequested = true;
        Send(new ShellEnvelope(video ? ShellEnvelope.ScreenVideo : ShellEnvelope.Screen));
    }

    private static bool IsScreenReady(byte[] line)
    {
        try { return ShellEnvelope.Decode(line).T is ShellEnvelope.ScreenReady or ShellEnvelope.ScreenVideoReady; }
        catch (Protocol.ProtocolException) { return false; }
    }

    private void Send(ShellEnvelope message)
    {
        if (!_handedOver) _outgoing.Writer.TryWrite(message.EncodeLine());
    }

    private async Task WriteAllAsync(Stream stream)
    {
        try
        {
            await foreach (var line in _outgoing.Reader.ReadAllAsync(_closing.Token).ConfigureAwait(false))
            {
                if (_handedOver) break; // after the hand-over the stream isn't lines any more
                await stream.WriteAsync(line, _closing.Token).ConfigureAwait(false);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { _closing.Cancel(); }
    }

    private void Emit(ShellClientEvent e) => _events.Writer.TryWrite(e);

    public void Disconnect() => _closing.Cancel();

    public ValueTask DisposeAsync()
    {
        Disconnect();
        return ValueTask.CompletedTask;
    }
}
