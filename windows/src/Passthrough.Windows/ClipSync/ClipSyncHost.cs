using System.Runtime.InteropServices;
using Passthrough.Core.ClipSync;
using Passthrough.Core.Pipe;
using Passthrough.Core.Shell;

namespace Passthrough.Windows.ClipSync;

/// <summary>Where received files are put: <c>%LOCALAPPDATA%\Passthrough\Received</c>, a folder per side, cleared when the app starts.</summary>
public static class ClipStaging
{
    private static int _cleared;

    public static string Root { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Passthrough", "Received");

    /// <summary>What earlier runs received (a quit or a crash leaves it) is of no use now. Once per process, before anything is received.</summary>
    public static void ClearAtLaunch()
    {
        if (Interlocked.Exchange(ref _cleared, 1) == 1) return;
        try { if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Keeps <paramref name="folder"/> as the newest of <paramref name="kept"/> and deletes the oldest past <paramref name="count"/>.</summary>
    public static void Keep(List<string> kept, string folder, int count)
    {
        kept.Add(folder);
        while (kept.Count > count)
        {
            try { Directory.Delete(kept[0], recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            kept.RemoveAt(0);
        }
    }
}

/// <summary>Whether this process's Windows session is being shown through Remote Desktop now.</summary>
public static class RemoteSession
{
    public static bool IsRemote()
    {
        // WTSClientProtocolType: 0 the console, 2 Remote Desktop.
        if (WTSQuerySessionInformation(IntPtr.Zero, -1 /* this session */, 16, out var buffer, out var bytes) && buffer != IntPtr.Zero)
        {
            try { if (bytes >= 2) return Marshal.ReadInt16(buffer) == 2; }
            finally { WTSFreeMemory(buffer); }
        }
        return GetSystemMetrics(0x1000 /* SM_REMOTESESSION */) != 0;
    }

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
}

/// <summary>
/// This account's side of clipboard sync with the computers viewing its screen (protocol/README.md, "Clipboard sync"),
/// in the tray app: the service passes each viewer's <c>clipSync</c> connection here over a pipe of its own. A copy here
/// goes to all of them; a copy there lands on this clipboard and goes on to the others; files a viewer drops are
/// dragged to where they were dropped. Only while this session is the one Remote Desktop shows, and while the owner
/// leaves it on.
/// </summary>
public sealed class ClipSyncHost : IDisposable
{
    public const int ClipboardsKept = 3, DropsKept = 5;
    public const long DropBytesKept = 2L << 30;
    private static readonly TimeSpan DropLimit = TimeSpan.FromSeconds(8);

    private readonly Func<bool> _enabled;
    private readonly Func<string, CancellationToken, Task<Stream>> _connect;
    private readonly Func<WinClipboard> _clipboard;
    private readonly Func<bool> _viewed;
    private readonly Action<string>? _log;

    /// <summary>Fires, on any thread, when a computer starts or stops syncing (the flyout says who is).</summary>
    public event Action? Changed;

    /// <summary>
    /// Something the person at this PC should see as it happens (a title and a sentence): a viewer is dropping files
    /// here, or they went to Downloads.
    /// </summary>
    public event Action<string, string>? Notice;
    private readonly string _staging = Path.Combine(ClipStaging.Root, "host");
    private readonly Lock _lock = new();
    private readonly Dictionary<string, Entry> _sessions = new(StringComparer.Ordinal);
    private readonly List<string> _clipboardFolders = [];
    private readonly List<(string Folder, long Bytes)> _dropFolders = [];
    private IDisposable? _watch;

    private sealed class Entry
    {
        public required ClipSyncSession Session;
        public required string Label;
        /// <summary>Drops on their way: what was at the point when each was offered, and how large it is.</summary>
        public readonly Dictionary<uint, (int X, int Y, DropPerformer.Target? At, ulong Total)> Drops = [];
    }

    /// <param name="enabled">The owner's switch.</param>
    /// <param name="connect">Opens the pipe to the service for one sync, saying the token it gave.</param>
    /// <param name="viewed">Whether this session is the one being viewed now (<see cref="RemoteSession.IsRemote"/>).</param>
    public ClipSyncHost(Func<bool> enabled, Func<string, CancellationToken, Task<Stream>> connect, Action<string>? log = null,
        Func<WinClipboard>? clipboard = null, Func<bool>? viewed = null)
    {
        _enabled = enabled;
        _connect = connect;
        _log = log;
        _clipboard = clipboard ?? (() => WinClipboard.Shared);
        _viewed = viewed ?? RemoteSession.IsRemote;
    }

    /// <summary>Whether the device with this id is syncing with this clipboard now.</summary>
    public bool IsSyncing(string id) { lock (_lock) return _sessions.ContainsKey(id); }

    /// <summary>
    /// The service asks for one device (<see cref="PipeSessionServer.ClipOpen"/>): an error's wire name, or null, after
    /// which this end opens the pipe and syncs until it closes.
    /// </summary>
    public Task<string?> OpenAsync(PipeMessage m)
    {
        if (m.Phone is not { } phone || m.Token is not { } token) return Task.FromResult<string?>(ShellError.ClipSyncUnavailable.ToWire());
        if (!_enabled()) return Task.FromResult<string?>(ShellError.ClipSyncOff.ToWire());
        // The clipboard here is this account's in this session: synced only with someone looking at this session.
        if (!_viewed()) return Task.FromResult<string?>(ShellError.ClipSyncUnavailable.ToWire());
        _ = Task.Run(() => RunAsync(phone, m.Label ?? "A computer", token));
        return Task.FromResult<string?>(null);
    }

    /// <summary>The owner turned sync off: every session ends.</summary>
    public void EndAll()
    {
        List<Entry> all;
        lock (_lock) all = [.. _sessions.Values];
        foreach (var entry in all) entry.Session.Close();
    }

    private async Task RunAsync(string phone, string label, string token)
    {
        Stream pipe;
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            pipe = await _connect(token, limit.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or PipeRefusedException)
        {
            _log?.Invoke($"clipsync: couldn't open the pipe for {label} ({e.GetType().Name})");
            return;
        }
        Entry? entry = null;
        var session = new ClipSyncSession(pipe, default, ClipFileSystem.Options(_staging, acceptDrops: true), e =>
        {
            if (entry is { } mine) Handle(phone, mine, e);
        });
        entry = new Entry { Session = session, Label = label };
        Entry? before;
        lock (_lock)
        {
            // One per device: a new one replaces the old.
            _sessions.TryGetValue(phone, out before);
            _sessions[phone] = entry;
            _watch ??= _clipboard().Watch(Copied);
        }
        before?.Session.Close();
        // Switched off, or no longer viewed, while the pipe opened.
        if (!_enabled() || !_viewed()) session.Close();
        _log?.Invoke($"clipsync: {label} syncs the clipboard");
        Changed?.Invoke();
        await session.RunAsync().ConfigureAwait(false);
        lock (_lock)
        {
            if (_sessions.TryGetValue(phone, out var now) && ReferenceEquals(now, entry)) _sessions.Remove(phone);
            if (_sessions.Count == 0)
            {
                _watch?.Dispose();
                _watch = null;
            }
        }
        _log?.Invoke($"clipsync: {label}'s sync ended");
        Changed?.Invoke();
    }

    /// <summary>Something was copied on this PC: it goes to every viewer. Too large can't be said on their clipboards; it's simply not sent.</summary>
    private void Copied(ClipSnapshot snapshot)
    {
        if (snapshot is not ClipSnapshot.Contents { Payload: var payload } || !_enabled()) return;
        List<Entry> all;
        lock (_lock) all = [.. _sessions.Values];
        foreach (var entry in all) entry.Session.Send(payload, ClipKind.Clipboard);
    }

    private void Handle(string phone, Entry entry, ClipEvent e)
    {
        switch (e)
        {
            case ClipEvent.Incoming { Kind: ClipKind.Drop } incoming:
                // What is at the point now, as the files are let go there: the drop goes ahead only if it still is when they've arrived.
                var (x, y) = DropPerformer.PointOf(incoming.X, incoming.Y);
                lock (_lock) entry.Drops[incoming.Transfer] = (x, y, DropPerformer.At(x, y), incoming.Total);
                break;
            case ClipEvent.IncomingEnded ended:
                lock (_lock) entry.Drops.Remove(ended.Transfer);
                break;
            case ClipEvent.Received { Transfer: { Kind: ClipKind.Clipboard } copy }:
                _ = Task.Run(() => PasteAsync(phone, entry, copy));
                break;
            case ClipEvent.Received { Transfer: { Kind: ClipKind.Drop } drop }:
                (int X, int Y, DropPerformer.Target? At, ulong Total) noted;
                lock (_lock)
                {
                    if (!entry.Drops.Remove(drop.Transfer, out noted)) noted = (0, 0, null, 0);
                }
                _ = Task.Run(() => Drop(entry, drop, noted));
                break;
        }
    }

    private async Task PasteAsync(string phone, Entry entry, ReceivedTransfer copy)
    {
        bool placed;
        try { placed = _enabled() && await _clipboard().WriteAsync(copy).ConfigureAwait(false); }
        catch (Exception e) when (e is InvalidOperationException or IOException or COMException)
        {
            _log?.Invoke($"clipsync: a copy from {entry.Label} couldn't be put on the clipboard ({e.GetType().Name})");
            placed = false;
        }
        entry.Session.Result(copy.Transfer, placed ? ClipResult.Placed : ClipResult.Failed);
        List<Entry> others;
        lock (_lock)
        {
            if (copy.Folder is { } folder) ClipStaging.Keep(_clipboardFolders, folder, ClipboardsKept);
            others = placed ? [.. _sessions.Where(s => s.Key != phone).Select(s => s.Value)] : [];
        }
        // The other viewers see this PC's clipboard change too.
        if (others.Count == 0) return;
        var payload = copy.ToPayload();
        foreach (var other in others) other.Session.Send(payload, ClipKind.Clipboard);
    }

    private void Drop(Entry entry, ReceivedTransfer drop, (int X, int Y, DropPerformer.Target? At, ulong Total) noted)
    {
        var files = drop.TopLevel;
        var status = ClipResult.Failed;
        try
        {
            if (files.Count == 0 || !_enabled()) return;
            // Still the same window there as when the files were let go, and still a session someone is looking at.
            var same = noted.At is { } then && DropPerformer.At(noted.X, noted.Y) == then && _viewed();
            var things = files.Count == 1 ? "1 item" : $"{files.Count} items";
            // Someone at this PC sees its pointer move by itself: said as it happens.
            if (same) Notice?.Invoke("Files dropped on this PC", $"{entry.Label} is dropping {things} here…");
            var outcome = same ? DropPerformer.Drop(files, noted.X, noted.Y, DropLimit, _log) : DropOutcome.NotTaken;
            if (!same) _log?.Invoke($"clipsync: what was at {entry.Label}'s drop point has changed; the files go to Downloads");
            if (outcome != DropOutcome.Dropped) Notice?.Invoke("Files dropped on this PC", $"{entry.Label} dropped {things} into Downloads.");
            status = outcome switch
            {
                DropOutcome.Dropped => ClipResult.Placed,
                // No answer in time: whatever is there may still be taking them, so they're copied, not moved.
                DropOutcome.TimedOut => DropPerformer.SaveToDownloads(files, copy: true, _log) ? ClipResult.SavedToDownloads : ClipResult.Failed,
                _ => DropPerformer.SaveToDownloads(files, copy: false, _log) ? ClipResult.SavedToDownloads : ClipResult.Failed,
            };
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or COMException)
        {
            _log?.Invoke($"clipsync: a drop from {entry.Label} failed ({e.GetType().Name})");
        }
        finally
        {
            entry.Session.Result(drop.Transfer, status);
            if (drop.Folder is { } folder) KeepDrop(folder, (long)Math.Min(noted.Total, long.MaxValue));
        }
    }

    /// <summary>Dropped files stay a while, for an app that took them by reference: the last few, within a size, the newest always.</summary>
    private void KeepDrop(string folder, long bytes)
    {
        lock (_lock)
        {
            _dropFolders.Add((folder, bytes));
            while (_dropFolders.Count > 1 && (_dropFolders.Count > DropsKept || _dropFolders.Sum(d => d.Bytes) > DropBytesKept))
            {
                try { Directory.Delete(_dropFolders[0].Folder, recursive: true); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
                _dropFolders.RemoveAt(0);
            }
        }
    }

    public void Dispose()
    {
        EndAll();
        lock (_lock)
        {
            _watch?.Dispose();
            _watch = null;
        }
    }
}
