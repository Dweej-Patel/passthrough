using System.Runtime.InteropServices;
using Passthrough.Core.ClipSync;

namespace Passthrough.Windows.ClipSync;

/// <summary>A line a screen window shows about clipboard sync: one that stays until replaced, or goes after a few seconds; with buttons when it asks something.</summary>
public sealed record ClipStatus(string Text, bool Hold, IReadOnlyList<ClipStatusAction> Actions);

/// <summary>A button beside a <see cref="ClipStatus"/>; <see cref="Run"/> may be called on any thread.</summary>
public sealed record ClipStatusAction(string Label, Action Run);

/// <summary>
/// A screen window's side of clipboard sync with the computer it shows (protocol/README.md, "Clipboard sync"): what is
/// copied on this PC after the window opens goes there, that computer's copies land here, and files dropped on the
/// window are sent to be dropped there. A copy of files over 50 MB asks before it is sent, and one that large coming
/// in can be stopped. One per window, across reconnects, so the copies it keeps for pasting span them.
/// <c>onStatus</c> gets what to show (null clears it), on any thread.
/// </summary>
public sealed class ClipSyncViewer : IDisposable
{
    private const ulong Large = 20_000_000;

    private readonly string _host;
    private readonly Action<ClipStatus?> _onStatus;
    private readonly Action<string>? _log;
    private readonly Func<WinClipboard> _clipboard;
    private readonly string _staging = Path.Combine(ClipStaging.Root, "viewer-" + Guid.NewGuid().ToString("N"));
    private readonly Lock _lock = new();
    private readonly List<string> _clipboardFolders = [];
    /// <summary>Drops on their way, by transfer: how many things were dropped, for what's said when they land.</summary>
    private readonly Dictionary<uint, int> _drops = [];
    private ClipSyncSession? _session;
    private IAsyncDisposable? _owner;
    private IDisposable? _watch;
    private uint? _copyingOut, _copyingIn;
    /// <summary>A copy of files too large to send unasked, waiting for Send or Don't send.</summary>
    private ClipPayload? _asking;

    public ClipSyncViewer(string hostName, Action<ClipStatus?> onStatus, Action<string>? log = null, Func<WinClipboard>? clipboard = null)
    {
        _host = hostName;
        _onStatus = onStatus;
        _log = log;
        _clipboard = clipboard ?? (() => WinClipboard.Shared);
    }

    public bool IsActive { get { lock (_lock) return _session is not null; } }

    /// <summary>
    /// Syncs over <paramref name="stream"/> (after <c>clipSyncReady</c>) until it ends or <see cref="Stop"/>;
    /// <paramref name="ended"/> runs when the stream ends by itself. Nothing is sent as it starts: only what is copied
    /// from then on goes across, never what was on the clipboard when the window opened.
    /// </summary>
    public void Start(Stream stream, ReadOnlyMemory<byte> initialBytes, IAsyncDisposable? owner, Action ended)
    {
        Stop(forget: false);
        ClipSyncSession? session = null;
        session = new ClipSyncSession(stream, initialBytes, ClipFileSystem.Options(_staging, acceptDrops: false), e => Handle(session!, e, ended));
        lock (_lock)
        {
            _session = session;
            _owner = owner;
            _watch = _clipboard().Watch(Copied);
        }
        _ = session.RunAsync();
    }

    /// <summary>Ends the sync. With <paramref name="forget"/> (the window closed, or sync was turned off) the received files go too.</summary>
    public void Stop(bool forget = true)
    {
        ClipSyncSession? session;
        IAsyncDisposable? owner;
        List<string> older = [];
        lock (_lock)
        {
            (session, _session) = (_session, null);
            (owner, _owner) = (_owner, null);
            _watch?.Dispose();
            _watch = null;
            _drops.Clear();
            _copyingIn = _copyingOut = null;
            _asking = null;
            // The newest copy stays: this PC's clipboard may still point at its files, and paste should still find
            // them. It goes when Passthrough next starts.
            if (forget && _clipboardFolders.Count > 1)
            {
                older = _clipboardFolders[..^1];
                _clipboardFolders.RemoveRange(0, _clipboardFolders.Count - 1);
            }
        }
        session?.Close();
        if (owner is not null) _ = owner.DisposeAsync().AsTask();
        foreach (var folder in older) Delete(folder);
    }

    public void Dispose() => Stop();

    /// <summary>Files dropped on the window at (<paramref name="x"/>, <paramref name="y"/>), each 0…65535 across the stream.</summary>
    public void Drop(IReadOnlyList<string> paths, ushort x, ushort y)
    {
        if (!IsActive) { Status($"Clipboard sync isn't running, so files can't go to {_host}."); return; }
        Status(paths.Count == 1 ? "Preparing 1 item…" : $"Preparing {paths.Count} items…", hold: true);
        // A big folder takes a while to count: not on the window's thread.
        _ = Task.Run(() =>
        {
            var (payload, failed) = ClipFiles.Collect(paths, maxItems: (int)ClipSyncWire.MaxDropItems);
            ClipSyncSession? session;
            lock (_lock) session = _session;
            if (session is null) { Status(null); return; }
            if (failed == ClipFiles.Failure.TooLarge)
            {
                Status($"That's too many files to drop at once ({ClipSyncWire.MaxDropItems:N0} at most). Try a few folders at a time.");
                return;
            }
            if (payload is not { Items.Count: > 0 }) { Status("Those files couldn't be read."); return; }
            // Said and noted before the session can report on it, so its outcome never comes first and leaves this line up.
            Status($"Sending {Things(paths.Count, payload.Total)} to {_host}…", hold: true);
            lock (_lock) _drops[session.Send(payload, ClipKind.Drop, x, y)] = paths.Count;
        });
    }

    private void Copied(ClipSnapshot snapshot)
    {
        ClipSyncSession? session;
        lock (_lock) session = _session;
        if (session is null) return;
        switch (snapshot)
        {
            case ClipSnapshot.Contents { Payload: var payload } when payload.HasFiles && payload.Total > ClipSyncWire.AskAbove:
                // A big upload nobody asked for: it waits for a yes. A newer copy replaces the question.
                lock (_lock) _asking = payload;
                _onStatus(new ClipStatus($"Send {Size(payload.Total)} of files to {_host}?", true,
                [
                    new ClipStatusAction("Send", () => Answer(payload, send: true)),
                    new ClipStatusAction("Don't send", () => Answer(payload, send: false)),
                ]));
                break;
            case ClipSnapshot.Contents { Payload: var payload }:
                bool wasAsking;
                lock (_lock) { wasAsking = _asking is not null; _asking = null; }
                Send(session, payload, cleared: wasAsking);
                break;
            case ClipSnapshot.TooLarge { Files: var files }:
                lock (_lock) _asking = null;
                Status(files
                    ? "Too large to sync (files up to 500 MB). Drag them onto the window instead."
                    : "Too large to sync (text up to 16 MB, pictures up to 64 MB). Save it as a file and drag that onto the window.");
                break;
        }
    }

    private void Send(ClipSyncSession session, ClipPayload payload, bool cleared)
    {
        var id = session.Send(payload, ClipKind.Clipboard);
        bool replaced;
        lock (_lock)
        {
            replaced = _copyingOut is not null || cleared;
            _copyingOut = payload.Total > Large ? id : null;
        }
        if (payload.Total > Large) Status($"Copying {Size(payload.Total)} to {_host}…", hold: true);
        else if (replaced) Status(null); // the big copy, or the question about it, was replaced by this one
    }

    /// <summary>Send or Don't send, for the copy that asked (a newer copy since makes the answer moot).</summary>
    private void Answer(ClipPayload payload, bool send)
    {
        ClipSyncSession? session;
        lock (_lock)
        {
            if (!ReferenceEquals(_asking, payload)) return;
            _asking = null;
            session = _session;
        }
        if (send && session is not null) Send(session, payload, cleared: false);
        else Status(send ? $"Clipboard sync with {_host} isn't running, so it wasn't sent." : null);
    }

    private void Handle(ClipSyncSession session, ClipEvent e, Action ended)
    {
        // Only the current session's: one stopped since says nothing more.
        lock (_lock) if (!ReferenceEquals(_session, session)) return;
        switch (e)
        {
            case ClipEvent.Received { Transfer: { Kind: ClipKind.Clipboard } copy }:
                _ = Task.Run(() => PasteAsync(session, copy));
                break;
            case ClipEvent.Received { Transfer: var unasked }:
                // A host doesn't drop on its viewer (the session declines the offer; this is belt and braces).
                session.Result(unasked.Transfer, ClipResult.Failed);
                Delete(unasked.Folder);
                break;
            case ClipEvent.Incoming { Kind: ClipKind.Clipboard } incoming when incoming.Total > Large:
                lock (_lock) _copyingIn = incoming.Transfer;
                // A large one can be stopped: it is declined, and what came of it thrown away.
                var stop = incoming.Total > ClipSyncWire.AskAbove
                    ? new[] { new ClipStatusAction("Stop", () => StopIncoming(session, incoming.Transfer)) }
                    : [];
                _onStatus(new ClipStatus($"Copying {Size(incoming.Total)} from {_host}…", true, stop));
                break;
            case ClipEvent.IncomingEnded ended1:
                bool shown;
                lock (_lock)
                {
                    shown = _copyingIn == ended1.Transfer;
                    if (shown) _copyingIn = null;
                }
                if (shown) Status(null);
                break;
            case ClipEvent.Sent sent:
                int? dropped;
                bool copied;
                lock (_lock)
                {
                    dropped = _drops.TryGetValue(sent.Transfer, out var n) ? n : null;
                    copied = _copyingOut == sent.Transfer;
                    if (copied) _copyingOut = null;
                }
                if (dropped is { } count) Status($"Dropping {Things(count)} on {_host}…", hold: true);
                else if (copied) Status($"Sent to {_host}.");
                break;
            case ClipEvent.Outcome outcome:
                int landed;
                lock (_lock) if (!_drops.Remove(outcome.Transfer, out landed)) return;
                Status(outcome.Status switch
                {
                    ClipResult.Placed => $"Dropped {Things(landed)} on {_host}.",
                    ClipResult.SavedToDownloads => $"{(landed == 1 ? "It" : "They")} went to {_host}'s Downloads instead: nothing took {(landed == 1 ? "it" : "them")} at that spot, or another window came up there.",
                    _ => $"{_host} couldn't take {(landed == 1 ? "that file" : "those files")}.",
                });
                break;
            case ClipEvent.Declined declined:
                int? declinedCount;
                lock (_lock)
                {
                    if (_copyingOut == declined.Transfer) _copyingOut = null;
                    declinedCount = _drops.Remove(declined.Transfer, out var n) ? n : null;
                }
                var those = declinedCount switch { null => "That copy", 1 => "That file", var n => $"Those {n} items" };
                var are = declinedCount is > 1 ? "are" : "is";
                Status(declined.Reason switch
                {
                    ClipDecline.TooLarge => $"{those} {are} too large for {_host}.",
                    ClipDecline.NoRoom => $"{_host} doesn't have room for {char.ToLowerInvariant(those[0]) + those[1..]} right now.",
                    ClipDecline.SyncOff => $"{_host} has clipboard sync turned off.",
                    _ => $"{those} couldn't go to {_host}.",
                });
                break;
            case ClipEvent.Closed closed:
                IAsyncDisposable? owner;
                lock (_lock)
                {
                    _session = null;
                    (owner, _owner) = (_owner, null);
                    _watch?.Dispose();
                    _watch = null;
                    _drops.Clear();
                    _copyingIn = _copyingOut = null;
                    _asking = null;
                }
                if (owner is not null) _ = owner.DisposeAsync().AsTask();
                if (closed.Error is { } error) _log?.Invoke($"clipsync: the sync with {_host} ended ({error.GetType().Name})");
                Status(null);
                ended();
                break;
        }
    }

    private async Task PasteAsync(ClipSyncSession session, ReceivedTransfer copy)
    {
        bool placed;
        try { placed = await _clipboard().WriteAsync(copy).ConfigureAwait(false); }
        catch (Exception e) when (e is InvalidOperationException or IOException or COMException) { placed = false; }
        session.Result(copy.Transfer, placed ? ClipResult.Placed : ClipResult.Failed);
        bool wasShown;
        lock (_lock)
        {
            wasShown = _copyingIn == copy.Transfer;
            if (wasShown) _copyingIn = null;
            // The clipboard points at the files: the last few stay for pasting.
            if (copy.Folder is { } folder) ClipStaging.Keep(_clipboardFolders, folder, ClipSyncHost.ClipboardsKept);
        }
        if (!placed) Status("This PC's clipboard is busy; that copy didn't land.");
        else if (copy.Folder is not null) Status($"Ready to paste: {Things(copy.TopLevel.Count)} from {_host}.");
        else if (wasShown) Status($"Ready to paste from {_host}.");
    }

    private void StopIncoming(ClipSyncSession session, uint transfer)
    {
        session.StopIncoming(transfer);
        lock (_lock) if (_copyingIn == transfer) _copyingIn = null;
        Status($"Stopped. {_host}'s copy wasn't brought over.");
    }

    private static void Delete(string? folder)
    {
        if (folder is null) return;
        try { Directory.Delete(folder, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private void Status(string? text, bool hold = false) => _onStatus(text is null ? null : new ClipStatus(text, hold, []));

    private static string Things(int count, ulong? bytes = null) =>
        (count == 1 ? "1 item" : $"{count} items") + (bytes is > 0 ? $" ({Size(bytes.Value)})" : "");

    /// <summary>A size as the other computer says it too: in thousands, so the same copy reads the same on both.</summary>
    internal static string Size(ulong bytes) => bytes switch
    {
        >= 1_000_000_000 => $"{bytes / 1e9:0.#} GB",
        >= 1_000_000 => $"{bytes / 1e6:0.#} MB",
        >= 1_000 => $"{bytes / 1e3:0} KB",
        _ => $"{bytes} bytes",
    };
}
