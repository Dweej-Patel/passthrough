using System.Buffers;
using System.IO.Pipelines;
using System.Text;

namespace Passthrough.Windows.Iroh;

/// <summary>How an iroh connection is carried (as <c>IrohPath</c> in IrohByteStream.swift).</summary>
public enum IrohPath { Unknown, Direct, Relay }

/// <summary>Which relays an endpoint uses: none (tests), n0's public ones, or the host's own with its token.</summary>
public sealed record IrohRelay(string? Url = null, string? Token = null, bool Disabled = false)
{
    public static readonly IrohRelay None = new(Disabled: true);
    public static readonly IrohRelay N0 = new();
}

/// <summary>
/// An iroh endpoint (a port of IrohEndpointHost and IrohDialer): the host's, with a stable id from its stored secret
/// key, accepting connections; or a viewer's, with an ephemeral key, dialling. Peers are reached by id plus explicit
/// addresses and the relay: no n0 DNS publishing or lookup, as on the Mac.
/// </summary>
public sealed unsafe class IrohEndpoint : IDisposable
{
    /// <summary>The remote shell's protocol on iroh connections.</summary>
    public const string ShellAlpn = "passthrough/shell/1";

    private readonly ulong _handle;
    private int _disposed;

    private IrohEndpoint(ulong handle) => _handle = handle;

    /// <summary>Loads the bridge from <paramref name="folder"/> (an administrators-only install folder), not beside this exe. Before any other call.</summary>
    public static void UseLibraryIn(string folder) => IrohNative.LibraryFolder = folder;

    /// <summary>The bridge is where it will be loaded from.</summary>
    public static bool IsAvailable => IrohNative.IsAvailable;

    /// <summary>A fresh 32-byte endpoint secret key, for the host to store.</summary>
    public static byte[] NewSecretKey()
    {
        var key = new byte[32];
        fixed (byte* p = key) IrohNative.Check(IrohNative.pt_iroh_generate_secret_key(p));
        return key;
    }

    /// <summary>The endpoint id a secret key gives, without binding anything.</summary>
    public static string IdOf(ReadOnlySpan<byte> secretKey)
    {
        if (secretKey.Length != 32) throw new ArgumentException("a secret key is 32 bytes", nameof(secretKey));
        fixed (byte* k = secretKey) { var key = k; return IrohNative.Text((b, c) => IrohNative.pt_iroh_endpoint_id_of_key(key, b, c)); }
    }

    /// <summary>Binds an endpoint. <paramref name="secretKey"/>: 32 bytes for a stable id, or null for an ephemeral one.</summary>
    public static IrohEndpoint Bind(ReadOnlySpan<byte> secretKey, IrohRelay relay, params string[] alpns)
    {
        if (!secretKey.IsEmpty && secretKey.Length != 32) throw new ArgumentException("a secret key is 32 bytes", nameof(secretKey));
        var mode = relay.Disabled ? IrohNative.RelayDisabled : relay.Url is null ? IrohNative.RelayN0 : IrohNative.RelayCustom;
        var url = Encoding.UTF8.GetBytes(relay.Url ?? "");
        var token = Encoding.UTF8.GetBytes(relay.Token ?? "");
        var protocols = Encoding.UTF8.GetBytes(string.Join('\n', alpns));
        ulong handle;
        fixed (byte* k = secretKey)
        fixed (byte* u = url)
        fixed (byte* t = token)
        fixed (byte* a = protocols)
            IrohNative.Check(IrohNative.pt_iroh_endpoint_bind(secretKey.IsEmpty ? null : k, mode, u, (nuint)url.Length, t, (nuint)token.Length,
                a, (nuint)protocols.Length, &handle));
        return new IrohEndpoint(handle);
    }

    public string Id => IrohNative.Text((b, c) => IrohNative.pt_iroh_endpoint_id(_handle, b, c));

    /// <summary>The relay it is reachable through now, if any.</summary>
    public string? HomeRelay => IrohNative.Text((b, c) => IrohNative.pt_iroh_endpoint_home_relay(_handle, b, c)) is { Length: > 0 } r ? r : null;

    /// <summary>The direct "ip:port" addresses iroh knows for this endpoint.</summary>
    public IReadOnlyList<string> DirectAddresses => Lines(IrohNative.Text((b, c) => IrohNative.pt_iroh_endpoint_direct_addresses(_handle, b, c)));

    /// <summary>Loopback forms of the bound sockets (same-machine dialling: tests).</summary>
    public IReadOnlyList<string> LoopbackAddresses => Lines(IrohNative.Text((b, c) => IrohNative.pt_iroh_endpoint_loopback_addresses(_handle, b, c)));

    /// <summary>Waits until the endpoint has reached its home relay; false after <paramref name="timeout"/>.</summary>
    public bool WaitOnline(TimeSpan timeout)
    {
        var code = IrohNative.pt_iroh_endpoint_wait_online(_handle, (uint)Math.Clamp(timeout.TotalMilliseconds, 0, uint.MaxValue));
        if (code == IrohNative.ErrTimeout) return false;
        IrohNative.Check(code);
        return true;
    }

    /// <summary>
    /// Waits for the next incoming attempt (blocking; run one accept loop on a thread of its own). Returns before the
    /// handshake, so one slow peer can't hold up the loop; null once the endpoint is closed.
    /// </summary>
    public IrohIncoming? Accept(string alpn = ShellAlpn)
    {
        var protocol = Encoding.UTF8.GetBytes(alpn);
        ulong handle;
        int code;
        fixed (byte* a = protocol) code = IrohNative.pt_iroh_endpoint_accept(_handle, a, (nuint)protocol.Length, &handle);
        if (code == IrohNative.End) return null;
        IrohNative.Check(code);
        return new IrohIncoming(handle);
    }

    /// <summary>Dials endpoint <paramref name="id"/> at its relay and/or addresses and opens a stream (blocking).</summary>
    public IrohStream Connect(string id, string? relayUrl, IEnumerable<string> addresses, string alpn = ShellAlpn)
    {
        var i = Encoding.UTF8.GetBytes(id);
        var r = Encoding.UTF8.GetBytes(relayUrl ?? "");
        var a = Encoding.UTF8.GetBytes(string.Join('\n', addresses));
        var p = Encoding.UTF8.GetBytes(alpn);
        ulong handle;
        fixed (byte* ip = i)
        fixed (byte* rp = r)
        fixed (byte* ap = a)
        fixed (byte* pp = p)
            IrohNative.Check(IrohNative.pt_iroh_endpoint_connect(_handle, ip, (nuint)i.Length, rp, (nuint)r.Length, ap, (nuint)a.Length, pp, (nuint)p.Length, &handle));
        return new IrohStream(handle);
    }

    /// <summary>Closes the endpoint: a pending <see cref="Accept"/> returns null, handshakes and dials fail.</summary>
    public void Close() => IrohNative.pt_iroh_endpoint_close(_handle);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 1) return;
        IrohNative.pt_iroh_endpoint_close(_handle);
        IrohNative.pt_iroh_free(_handle);
    }

    private static string[] Lines(string text) => text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>An incoming connection attempt, not yet handshaken (a port of IrohIncoming).</summary>
public sealed unsafe class IrohIncoming : IDisposable
{
    private readonly ulong _handle;
    private int _disposed;

    internal IrohIncoming(ulong handle) => _handle = handle;

    /// <summary>Where the attempt comes from, before any handshake: the path and, for a direct one, the peer's IP.</summary>
    public (IrohPath Path, string? Ip) Origin()
    {
        var path = new int[1];
        var ip = IrohNative.Text((b, c) => { fixed (int* p = path) return IrohNative.pt_iroh_incoming_origin(_handle, p, b, c); });
        return (ToPath(path[0]), ip.Length > 0 ? ip : null);
    }

    /// <summary>The peer has shown it receives packets at the address it came from (QUIC address validation).</summary>
    public bool IsAddressValidated => IrohNative.Check(IrohNative.pt_iroh_incoming_is_validated(_handle)) == 1;

    /// <summary>Ends the attempt with a QUIC retry; false if it can't be asked (it already came with a token).</summary>
    public bool Retry() => IrohNative.pt_iroh_incoming_retry(_handle) == IrohNative.Ok;

    /// <summary>Completes the handshake and waits for the peer's first stream (blocking). Throws when cancelled, on another ALPN, or on failure.</summary>
    public IrohStream AcceptStream()
    {
        ulong handle;
        IrohNative.Check(IrohNative.pt_iroh_incoming_accept(_handle, &handle));
        return new IrohStream(handle);
    }

    /// <summary>Turns the attempt away, or abandons a handshake under way: a pending <see cref="AcceptStream"/> fails.</summary>
    public void Cancel() => IrohNative.pt_iroh_incoming_cancel(_handle);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 1) return;
        IrohNative.pt_iroh_free(_handle);
    }

    internal static IrohPath ToPath(int path) => path switch
    {
        IrohNative.PathDirect => IrohPath.Direct,
        IrohNative.PathRelay => IrohPath.Relay,
        _ => IrohPath.Unknown,
    };
}

/// <summary>How an iroh connection ended.</summary>
public enum IrohClose { Clean, Application, Lost }

/// <summary>
/// One bidirectional QUIC stream of an iroh connection, as a <see cref="Stream"/> (a port of IrohByteStream). It owns
/// its connection: disposing it closes the connection gracefully, delivering what was already written (bounded at 2 s).
/// Reads come off a thread of its own into a pipe, so <see cref="ReadAsync(Memory{byte}, CancellationToken)"/> never
/// holds a pool thread; writes are serialized in the order issued.
/// </summary>
public sealed class IrohStream : Stream
{
    private const int ReadChunk = 65536;
    private readonly ulong _handle;
    private readonly Pipe _incoming = new(new PipeOptions(pauseWriterThreshold: 1 << 20, resumeWriterThreshold: 1 << 19, useSynchronizationContext: false));
    private readonly SemaphoreSlim _writing = new(1, 1);
    private readonly TaskCompletionSource<(IrohClose Kind, ulong Code)> _closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _disposed;

    internal IrohStream(ulong handle)
    {
        _handle = handle;
        new Thread(Pump) { IsBackground = true, Name = "iroh stream" }.Start();
        new Thread(WatchClose) { IsBackground = true, Name = "iroh close" }.Start();
    }

    /// <summary>The peer's endpoint id.</summary>
    public unsafe string RemoteId => IrohNative.Text((b, c) => IrohNative.pt_iroh_stream_remote_id(_handle, b, c));

    /// <summary>The path the connection uses now and, for a direct one, the peer's IP.</summary>
    public unsafe (IrohPath Path, string? Ip) CurrentPath
    {
        get
        {
            var path = new int[1];
            var ip = IrohNative.Text((b, c) => { unsafe { fixed (int* p = path) return IrohNative.pt_iroh_stream_path(_handle, p, b, c); } });
            return (IrohIncoming.ToPath(path[0]), ip.Length > 0 ? ip : null);
        }
    }

    /// <summary>Completes once the connection under the stream has ended, saying how.</summary>
    public Task<(IrohClose Kind, ulong Code)> Closed => _closed.Task;

    private unsafe void Pump()
    {
        Exception? failure = null;
        try
        {
            while (true)
            {
                var memory = _incoming.Writer.GetMemory(ReadChunk);
                nuint read = 0;
                int code;
                fixed (byte* p = memory.Span) code = IrohNative.pt_iroh_stream_read(_handle, p, (nuint)memory.Length, &read);
                if (code == IrohNative.End) break;
                if (code < 0)
                {
                    var error = IrohNative.Failure(code);
                    if (!error.IsCancelled) failure = error;
                    break;
                }
                _incoming.Writer.Advance((int)read);
                // Waits while the reader is a megabyte behind: back-pressure all the way to the peer.
                if (_incoming.Writer.FlushAsync().AsTask().GetAwaiter().GetResult().IsCompleted) break;
            }
        }
        catch (Exception e) { failure = e; }
        _incoming.Writer.Complete(failure);
    }

    private unsafe void WatchClose()
    {
        int kind = 0;
        ulong code = 0;
        var result = IrohNative.pt_iroh_stream_wait_closed(_handle, &kind, &code);
        _closed.TrySetResult(result < 0 ? (IrohClose.Lost, 0) : (kind switch
        {
            IrohNative.CloseClean => IrohClose.Clean,
            IrohNative.CloseApplication => IrohClose.Application,
            _ => IrohClose.Lost,
        }, code));
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (buffer.IsEmpty) return 0;
        var result = await _incoming.Reader.ReadAsync(cancellationToken).ConfigureAwait(false);
        var available = result.Buffer;
        if (available.IsEmpty && result.IsCompleted)
        {
            _incoming.Reader.AdvanceTo(available.End);
            return 0;
        }
        var count = (int)Math.Min(buffer.Length, available.Length);
        available.Slice(0, count).CopyTo(buffer.Span);
        _incoming.Reader.AdvanceTo(available.GetPosition(count));
        return count;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        await _writing.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await Task.Run(() => WriteNow(buffer, finish: false), CancellationToken.None).ConfigureAwait(false); }
        finally { _writing.Release(); }
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override void Write(byte[] buffer, int offset, int count)
    {
        _writing.Wait();
        try { WriteNow(buffer.AsMemory(offset, count), finish: false); }
        finally { _writing.Release(); }
    }

    /// <summary>Ends this side's data: the peer reads to its end.</summary>
    public async Task FinishAsync()
    {
        await _writing.WaitAsync().ConfigureAwait(false);
        try { await Task.Run(() => WriteNow(ReadOnlyMemory<byte>.Empty, finish: true)).ConfigureAwait(false); }
        finally { _writing.Release(); }
    }

    private unsafe void WriteNow(ReadOnlyMemory<byte> data, bool finish)
    {
        using var pin = data.Pin();
        IrohNative.Check(IrohNative.pt_iroh_stream_write(_handle, (byte*)pin.Pointer, (nuint)data.Length, finish ? 1 : 0));
    }

    public override void Flush() { }
    public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            // Reads stop now; what was written is still delivered before the connection closes.
            IrohNative.pt_iroh_stream_close(_handle);
            _incoming.Reader.Complete();
            // Freed once the connection has ended, so the close watcher's handle stays good until then.
            _ = _closed.Task.ContinueWith(_ => IrohNative.pt_iroh_free(_handle), TaskScheduler.Default);
        }
        base.Dispose(disposing);
    }
}
