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
        var first = true;
        while (!stopping.IsCancellationRequested)
        {
            NamedPipeServerStream instance;
            try { instance = ServicePipe.CreateInstance(first); }
            catch (Win32Exception e) when (e.NativeErrorCode is 5 or 231) // access denied, pipe busy
            {
                if (first) log("pipe: another program holds the service's pipe name; trying again in 5 s");
                await Task.Delay(TimeSpan.FromSeconds(5), stopping).ConfigureAwait(false);
                continue;
            }
            first = false;
            try { await instance.WaitForConnectionAsync(stopping).ConfigureAwait(false); }
            catch (OperationCanceledException) { await instance.DisposeAsync().ConfigureAwait(false); break; }
            catch (IOException) { await instance.DisposeAsync().ConfigureAwait(false); continue; }
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
            var host = HostFor(peer.Account);
            await using var link = new PipeLink(pipe, service: true, ServiceBacklogLimit, log: log);
            host.Link(link);
            lock (_lock) _links[peer.Account] = link;
            log($"pipe: account …{Tail(peer.Account)} linked (session {peer.Session}, build {accepted.Value.Hello.Build})");
            var account = peer.Account;
            await link.RunAsync(frame =>
            {
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
        finally { await pipe.DisposeAsync().ConfigureAwait(false); }
    }

    /// <summary>An account in the log: the last part of its SID, never its name.</summary>
    internal static string Tail(string sid) => sid.Split('-')[^1];
}
