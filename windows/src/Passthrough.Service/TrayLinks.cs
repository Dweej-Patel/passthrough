using System.ComponentModel;
using System.IO.Pipes;
using Passthrough.Core.Pipe;
using Passthrough.Windows.Pipes;

namespace Passthrough.Service;

/// <summary>
/// The service's end of the pipe: it holds the name from the moment it starts, takes each tray app that connects,
/// checks who it is from its token, and links it to that account's <see cref="PipeSessionHost"/>. One link per account:
/// a newer tray app of the same account replaces an older one.
/// </summary>
internal sealed class TrayLinks(Func<IReadOnlyCollection<string>> allowedAccounts, Func<PipeWelcome> welcome, Action<string> log) : ITrayHosts
{
    public const long ServiceBacklogLimit = 4 << 20;
    private readonly Dictionary<string, PipeSessionHost> _hosts = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, PipeLink> _links = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Answers a tray app's requests about its account's phones (set before <see cref="RunAsync"/>).</summary>
    public Func<string, PipeAdminRequest, PipeAdminReply>? Admin { get; set; }

    /// <summary>Pushes an event to <paramref name="account"/>'s tray app, when it is linked.</summary>
    public void Tell(string account, PipeAdminEvent e)
    {
        PipeLink? link;
        lock (_lock) _links.TryGetValue(account, out link);
        link?.Send(PipeFrame.Json(PipeKind.AdminEvent, e));
    }

    public void TellAll(PipeAdminEvent e)
    {
        List<PipeLink> links;
        lock (_lock) links = [.. _links.Values];
        foreach (var link in links) link.Send(PipeFrame.Json(PipeKind.AdminEvent, e));
    }
    private readonly Lock _lock = new();
    private DateTime _lastRefusalLog;

    // MARK: Clipboard sync (a pipe of its own per sync, so file bytes never share the shells' link or its backlog limit)

    /// <summary>How long the tray app has to open the pipe it said it would.</summary>
    internal static readonly TimeSpan ClipPipeLimit = TimeSpan.FromSeconds(5);
    private readonly Dictionary<string, (string Account, TaskCompletionSource<Stream> Pipe)> _clips = new(StringComparer.Ordinal);

    /// <summary>
    /// Asks <paramref name="account"/>'s tray app to sync its clipboard with a device and waits for the pipe it opens for
    /// that (it names the one-time token given here; the account is read from its token, as for every tray app).
    /// </summary>
    public async Task<(Stream? Stream, Passthrough.Core.Shell.ShellError? Error)> OpenClipAsync(string account, string phone, string label, CancellationToken cancel)
    {
        var token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
        var pipe = new TaskCompletionSource<Stream>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_lock) _clips[token] = (account, pipe);
        try
        {
            if (await HostFor(account).OpenClipAsync(phone, label, token).ConfigureAwait(false) is { } refused) return (null, refused);
            return (await pipe.Task.WaitAsync(ClipPipeLimit, cancel).ConfigureAwait(false), null);
        }
        catch (Exception e) when (e is TimeoutException or OperationCanceledException or Passthrough.Core.Shell.Sessions.ShellException)
        {
            // Given up on: a pipe that arrives now is refused; one that arrived as the wait ended is closed, since nobody will use it.
            if (!pipe.TrySetCanceled() && pipe.Task.IsCompletedSuccessfully) pipe.Task.Result.Dispose();
            return (null, Passthrough.Core.Shell.ShellError.ClipSyncUnavailable);
        }
        finally
        {
            lock (_lock) _clips.Remove(token);
        }
    }

    /// <summary>A pipe the tray app opened for one clipboard sync: handed to whoever waits for its token, and held until they close it.</summary>
    private async Task ServeClipAsync(NamedPipeServerStream pipe, string account, string token)
    {
        (string Account, TaskCompletionSource<Stream> Pipe) waiting;
        lock (_lock)
        {
            if (!_clips.Remove(token, out waiting) || !string.Equals(waiting.Account, account, StringComparison.OrdinalIgnoreCase)) return;
        }
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var handed = new HandedPipe(pipe, () => closed.TrySetResult());
        if (!waiting.Pipe.TrySetResult(handed)) return;
        await closed.Task.ConfigureAwait(false);
    }

    /// <summary>The pipe as its user sees it: closing it ends this instance's turn (the accept loop disposes the pipe itself).</summary>
    private sealed class HandedPipe(Stream pipe, Action closed) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default) => pipe.ReadAsync(buffer, cancel);
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancel) => pipe.ReadAsync(buffer, offset, count, cancel);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancel = default) => pipe.WriteAsync(buffer, cancel);
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancel) => pipe.WriteAsync(buffer, offset, count, cancel);
        public override int Read(byte[] buffer, int offset, int count) => pipe.Read(buffer, offset, count);
        public override void Write(byte[] buffer, int offset, int count) => pipe.Write(buffer, offset, count);
        public override void Flush() { }
        public override Task FlushAsync(CancellationToken cancel) => Task.CompletedTask;
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                pipe.Dispose();
                closed();
            }
            base.Dispose(disposing);
        }
    }
    private int _alive;

    /// <summary>Fires when an account's tray app comes or goes, or its sessions or state change.</summary>
    public event Action<PipeSessionHost>? Changed;

    /// <summary>The shells of <paramref name="account"/>, linked or not.</summary>
    public PipeSessionHost HostFor(string account)
    {
        lock (_lock)
        {
            if (_hosts.TryGetValue(account, out var host)) return host;
            host = new PipeSessionHost(account, log: log);
            host.Changed += () => Changed?.Invoke(host);
            host.StateChanged += () => Changed?.Invoke(host);
            _hosts[account] = host;
            return host;
        }
    }

    public IReadOnlyList<PipeSessionHost> Hosts { get { lock (_lock) return [.. _hosts.Values]; } }

    /// <summary>Accepts tray apps until <paramref name="stopping"/>. Never opens a pipe it didn't make first.</summary>
    public async Task RunAsync(CancellationToken stopping)
    {
        while (!stopping.IsCancellationRequested)
        {
            NamedPipeServerStream instance;
            // With none of its own instances alive, the name may have lapsed: only one the service makes first counts.
            var first = Volatile.Read(ref _alive) == 0;
            try { instance = ServicePipe.CreateInstance(first); }
            catch (Win32Exception e) when (e.NativeErrorCode is 5 or 231) // access denied, pipe busy
            {
                if (first) log("pipe: another program holds the service's pipe name; trying again in 5 s");
                await Task.Delay(first ? TimeSpan.FromSeconds(5) : TimeSpan.FromMilliseconds(100), stopping).ConfigureAwait(false);
                continue;
            }
            Interlocked.Increment(ref _alive);
            try { await instance.WaitForConnectionAsync(stopping).ConfigureAwait(false); }
            catch (OperationCanceledException) { Interlocked.Decrement(ref _alive); await instance.DisposeAsync().ConfigureAwait(false); break; }
            catch (IOException) { Interlocked.Decrement(ref _alive); await instance.DisposeAsync().ConfigureAwait(false); continue; }
            _ = Task.Run(() => ServeAsync(instance, stopping), stopping);
        }
    }

    private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken stopping)
    {
        try
        {
            var peer = ServicePipe.Peer(pipe);
            var refusal = peer is null ? PipeRefused.ReasonNotAllowed : PipePeerPolicy.Refusal(peer, allowedAccounts());
            var greeting = welcome() with { Account = peer?.Account ?? "", Session = peer?.Session ?? 0 };
            var accepted = await PipeHandshakes.ServerAsync(pipe, refusal, greeting, stopping).ConfigureAwait(false);
            if (accepted is null || peer is null)
            {
                if (refusal is not null && DateTime.UtcNow - _lastRefusalLog > TimeSpan.FromMinutes(1))
                {
                    _lastRefusalLog = DateTime.UtcNow;
                    log($"pipe: refused a tray app ({refusal})");
                }
                return;
            }
            // A second connection, for one clipboard sync: no frames on it, and it replaces no link.
            if (accepted.Value.Hello.Clip is { } clipToken)
            {
                await ServeClipAsync(pipe, peer.Account, clipToken).ConfigureAwait(false);
                return;
            }
            var host = HostFor(peer.Account);
            await using var link = new PipeLink(pipe, service: true, ServiceBacklogLimit, log: log);
            host.Link(link);
            lock (_lock) _links[peer.Account] = link;
            log($"pipe: account …{Tail(peer.Account)} linked (session {peer.Session}, build {accepted.Value.Hello.Build})");
            var account = peer.Account;
            await link.RunAsync(frame =>
            {
                // An account taken off the allowed list since it linked is dropped at its next frame, whatever it is.
                if (!IsAllowed(account)) { link.Close(); return ValueTask.CompletedTask; }
                if (frame.Kind != PipeKind.Admin) return host.OnFrameAsync(frame);
                // Off the pipe's reader: a store write must not hold up output. The account is the token's, never the frame's.
                if (frame.Read<PipeAdminRequest>() is { } request && Admin is { } admin)
                    _ = Task.Run(() => link.Send(PipeFrame.Json(PipeKind.AdminReply, admin(account, request))));
                return ValueTask.CompletedTask;
            }).ConfigureAwait(false);
            host.Unlink(link);
            lock (_lock) if (_links.TryGetValue(account, out var current) && ReferenceEquals(current, link)) _links.Remove(account);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
        finally
        {
            Interlocked.Decrement(ref _alive);
            await pipe.DisposeAsync().ConfigureAwait(false);
        }
    }

    private bool IsAllowed(string account) => allowedAccounts().Contains(account, StringComparer.OrdinalIgnoreCase);

    /// <summary>After a reload: the links of accounts no longer allowed close now (the next connect is refused).</summary>
    public void DropDisallowed()
    {
        List<(string Account, PipeLink Link)> links;
        lock (_lock) links = [.. _links.Select(l => (l.Key, l.Value))];
        foreach (var (account, link) in links.Where(l => !IsAllowed(l.Account)))
        {
            log($"pipe: account …{Tail(account)} is no longer allowed; its link closed");
            link.Close();
        }
    }

    /// <summary>An account in the log: the last part of its SID, never its name.</summary>
    internal static string Tail(string sid) => sid.Split('-')[^1];
}
