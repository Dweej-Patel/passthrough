using Passthrough.Core.Shell.Access;

namespace Passthrough.Core.Pipe;

/// <summary>
/// The tray app's <see cref="IAccessAdmin"/> once the service holds the phones (stage 4): every question goes across
/// the pipe, about this account's phones only. With no link, no grant goes out and nothing is kept.
/// </summary>
public sealed class PipeAccessAdmin : IAccessAdmin
{
    public static readonly TimeSpan ReplyLimit = TimeSpan.FromSeconds(5);
    private readonly PipeSessionServer _server;
    private readonly Lock _lock = new();
    private readonly Dictionary<uint, TaskCompletionSource<PipeAdminReply>> _pending = [];
    private uint _nextId;

    public PipeAccessAdmin(PipeSessionServer server)
    {
        _server = server;
        server.OtherFrame += OnFrame;
        server.LinkChanged += linked =>
        {
            if (!linked) FailAll();
            Changed?.Invoke();
            AccessChanged?.Invoke();
            NoticesChanged?.Invoke();
        };
    }

    /// <summary>What a grant carries may have changed (the link came or went, the service said so).</summary>
    public event Action? Changed;

    /// <summary>The phones with access changed (refresh the list).</summary>
    public event Action? AccessChanged;

    private void OnFrame(PipeFrame frame)
    {
        if (frame.Kind == PipeKind.AdminReply && frame.Read<PipeAdminReply>() is { } reply)
        {
            TaskCompletionSource<PipeAdminReply>? pending;
            lock (_lock) _pending.Remove(reply.Id, out pending);
            pending?.TrySetResult(reply);
        }
        else if (frame.Kind == PipeKind.AdminEvent && frame.Read<PipeAdminEvent>() is { } e)
        {
            if (e.What == PipeAdminEvent.Grant) Changed?.Invoke();
            if (e.What == PipeAdminEvent.Access) AccessChanged?.Invoke();
            if (e.What == PipeAdminEvent.Notice) NoticesChanged?.Invoke();
        }
    }

    private void FailAll()
    {
        List<TaskCompletionSource<PipeAdminReply>> pending;
        lock (_lock)
        {
            pending = [.. _pending.Values];
            _pending.Clear();
        }
        foreach (var p in pending) p.TrySetResult(new PipeAdminReply { Error = "no_link" });
    }

    /// <summary>The service's answer; <c>error: no_link</c> when there is no link or it didn't answer in time.</summary>
    public async Task<PipeAdminReply> AskAsync(PipeAdminRequest request)
    {
        var pending = new TaskCompletionSource<PipeAdminReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        uint id;
        lock (_lock)
        {
            id = ++_nextId;
            _pending[id] = pending;
        }
        if (!_server.SendFrame(PipeFrame.Json(PipeKind.Admin, request with { Id = id })))
        {
            lock (_lock) _pending.Remove(id);
            return new PipeAdminReply { Id = id, Error = "no_link" };
        }
        try { return await pending.Task.WaitAsync(ReplyLimit).ConfigureAwait(false); }
        catch (TimeoutException)
        {
            lock (_lock) _pending.Remove(id);
            return new PipeAdminReply { Id = id, Error = "no_link" };
        }
    }

    public async Task<GrantContents?> GrantContentsAsync() =>
        (await AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.GrantInfo }).ConfigureAwait(false)).Grant?.ToContents();

    public async Task<bool> AddKeyAsync(string phoneId, string label, string pairingSlot, ReadOnlyMemory<byte> key) =>
        (await AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.AddKey, Phone = phoneId, Label = label, PairingSlot = pairingSlot, Key = Convert.ToBase64String(key.Span) })
            .ConfigureAwait(false)).Error is null;

    public Task RevokeSlotAsync(string pairingSlot) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.RevokeSlot, PairingSlot = pairingSlot });

    public async Task<IReadOnlyList<PipeDevice>> ListAsync() =>
        (await AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.List }).ConfigureAwait(false)).Devices ?? [];

    public Task<PipeAdminReply> SetScreenAsync(string phoneId, bool on) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.SetScreen, Phone = phoneId, On = on });

    public Task<PipeAdminReply> RevokeAsync(string phoneId) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.Revoke, Phone = phoneId });

    public Task<PipeAdminReply> DisconnectAsync(string phoneId) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.Disconnect, Phone = phoneId });

    public Task<PipeAdminReply> SetMayShareAsync(string phoneId, bool on) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.SetMayShare, Phone = phoneId, On = on });

    public async Task<IReadOnlyList<PipeNotice>> NoticesAsync() =>
        (await AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.Notices }).ConfigureAwait(false)).NoticeList ?? [];

    public Task<PipeAdminReply> AnswerNoticeAsync(string id) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.AnswerNotice, NoticeId = id });

    /// <summary>Fires when the service says the notices changed.</summary>
    public event Action? NoticesChanged;

    public Task<PipeAdminReply> ScreenAsync() => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.Screen });

    public Task<PipeAdminReply> StopScreenAsync(string phoneId) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.Disconnect, Phone = phoneId, What = "screen" });

    public Task<PipeAdminReply> PowerAsync() => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.Power });

    public Task<PipeAdminReply> SetStayAwakeAsync(bool on) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.SetStayAwake, On = on });

    public Task<PipeAdminReply> HandOverAsync(IReadOnlyList<ShellPhone> records) => AskAsync(new PipeAdminRequest { Op = PipeAdminRequest.HandOver, Records = [.. records] });
}
